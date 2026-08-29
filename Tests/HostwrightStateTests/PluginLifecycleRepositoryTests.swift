import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightState

final class PluginLifecycleRepositoryTests: XCTestCase {
  private let createdAt = "2026-08-04T12:00:00Z"
  private let updatedAt = "2026-08-04T12:01:00Z"
  private let revokedAt = "2026-08-04T12:02:00Z"
  private let quarantinedAt = "2026-08-04T12:03:00Z"

  func testCanonicalVerifiedPersistenceListAndReopenRoundTrip() throws {
    try withStore { store, repository in
      let record = try verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha")

      let stored = try repository.persistVerifiedPackage(record)
      XCTAssertEqual(try repository.package(digest: stored.packageDigest), stored)
      XCTAssertEqual(try repository.listPackages(), [stored])

      let reopened = SQLiteStateStore(path: store.path)
      XCTAssertEqual(try reopened.plugins.package(digest: stored.packageDigest), stored)
      XCTAssertEqual(try reopened.plugins.listPackages(), [stored])
      XCTAssertEqual(stored.manifestDigest, try PluginPackageRecord.digest(stored.manifest))
    }
  }

  func testDuplicateIdentifierAndVersionSubstitutionIsRejected() throws {
    try withStore { store, repository in
      let original = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha"))

      XCTAssertThrowsError(try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("c"),
        manifestChar: "d",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha-v2")))

      XCTAssertEqual(try repository.package(digest: original.packageDigest), original)
      XCTAssertEqual(try repository.listPackages().map(\.packageDigest), [original.packageDigest])
    }
  }

  func testOwnershipEscapeAndDuplicatePathsAreRejectedBeforePersistence() throws {
    try withStore { store, repository in
      XCTAssertThrowsError(try verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.escape",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.escape",
        storagePath: "/tmp/plugins/escape",
        ownership: [
          try ownedArtifact("/tmp/plugins/escape"),
          try ownedArtifact("/tmp/plugins/other/file"),
        ]))

      XCTAssertThrowsError(try verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.duplicate",
        version: "1.0.0",
        packageDigest: digest("c"),
        manifestChar: "d",
        signerIdentifier: "dev.hostwright.signer.duplicate",
        storagePath: "/tmp/plugins/duplicate",
        ownership: [
          try ownedArtifact("/tmp/plugins/duplicate"),
          try ownedArtifact("/tmp/plugins/duplicate"),
        ]))

      XCTAssertEqual(try repository.listPackages(), [])
    }
  }

  func testLegalVerifiedToStagedToActiveAndRollbackActivationUpdate() throws {
    try withStore { store, repository in
      let first = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha"))
      let stagedFirst = try repository.transitionPackage(
        digest: first.packageDigest,
        to: .staged,
        expectedGeneration: first.generation,
        actorSubjectID: "owner",
        updatedAt: updatedAt)
      let firstActivation = try repository.activate(
        digest: stagedFirst.packageDigest,
        expectedActivationGeneration: nil,
        actorSubjectID: "owner",
        healthDetailDigest: digest("e"),
        timestamp: revokedAt)

      XCTAssertEqual(firstActivation.pluginIdentifier, "dev.hostwright.plugin.alpha")
      XCTAssertEqual(firstActivation.activePackageDigest, stagedFirst.packageDigest)
      XCTAssertNil(firstActivation.priorPackageDigest)
      XCTAssertEqual(firstActivation.healthStatus, "healthy")

      let second = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.1.0",
        packageDigest: digest("f"),
        manifestChar: "1",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha-1-1"))
      let stagedSecond = try repository.transitionPackage(
        digest: second.packageDigest,
        to: .staged,
        expectedGeneration: second.generation,
        actorSubjectID: "owner",
        updatedAt: quarantinedAt)
      let secondActivation = try repository.activate(
        digest: stagedSecond.packageDigest,
        expectedActivationGeneration: firstActivation.generation,
        actorSubjectID: "owner",
        healthDetailDigest: digest("2"),
        timestamp: "2026-08-04T12:04:00Z")

      XCTAssertEqual(secondActivation.activePackageDigest, stagedSecond.packageDigest)
      XCTAssertEqual(secondActivation.priorPackageDigest, stagedFirst.packageDigest)
      XCTAssertEqual(secondActivation.generation, 2)

      let activePackage = try XCTUnwrap(repository.package(digest: stagedSecond.packageDigest))
      XCTAssertEqual(activePackage.lifecycleState, .active)
      XCTAssertEqual(activePackage.generation, stagedSecond.generation + 1)

      let priorPackage = try XCTUnwrap(repository.package(digest: stagedFirst.packageDigest))
      XCTAssertEqual(priorPackage.lifecycleState, .rollback)
      XCTAssertEqual(priorPackage.generation, stagedFirst.generation + 2)
    }
  }

  func testPackageAndSignerRevocationUpdatePackagesGrantsAndActivation() throws {
    try withStore { store, repository in
      let alpha = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.shared",
        storagePath: "/tmp/plugins/alpha"))
      let stagedAlpha = try repository.transitionPackage(
        digest: alpha.packageDigest,
        to: .staged,
        expectedGeneration: alpha.generation,
        actorSubjectID: "owner",
        updatedAt: updatedAt)
      _ = try repository.activate(
        digest: stagedAlpha.packageDigest,
        expectedActivationGeneration: nil,
        actorSubjectID: "owner",
        timestamp: revokedAt)

      try repository.revoke(
        revocationID: "package-revoke",
        targetKind: "package",
        targetIdentifier: stagedAlpha.packageDigest,
        reason: "package compromise",
        actorSubjectID: "owner",
        timestamp: quarantinedAt)

      let revokedPackage = try XCTUnwrap(repository.package(digest: stagedAlpha.packageDigest))
      XCTAssertEqual(revokedPackage.lifecycleState, .revoked)
      let revokedActivation = try XCTUnwrap(repository.activation(identifier: revokedPackage.manifest.identifier))
      XCTAssertEqual(revokedActivation.healthStatus, "revoked")
      let revokedGrantCount = try count(
        store: store,
        sql: "SELECT COUNT(*) FROM plugin_grants WHERE package_digest = ? AND revoked_at = ?",
        bindings: [.text(stagedAlpha.packageDigest), .text(quarantinedAt)])
      XCTAssertEqual(revokedGrantCount, 1)

      let beta = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.beta",
        version: "2.0.0",
        packageDigest: digest("c"),
        manifestChar: "d",
        signerIdentifier: "dev.hostwright.signer.shared",
        storagePath: "/tmp/plugins/beta"))
      let gamma = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.gamma",
        version: "3.0.0",
        packageDigest: digest("e"),
        manifestChar: "f",
        signerIdentifier: "dev.hostwright.signer.shared",
        storagePath: "/tmp/plugins/gamma"))

      try repository.revoke(
        revocationID: "signer-revoke",
        targetKind: "signer",
        targetIdentifier: "dev.hostwright.signer.shared",
        reason: "signer compromise",
        actorSubjectID: "owner",
        timestamp: "2026-08-04T12:04:00Z")

      XCTAssertEqual(try repository.package(digest: beta.packageDigest)?.lifecycleState, .revoked)
      XCTAssertEqual(try repository.package(digest: gamma.packageDigest)?.lifecycleState, .revoked)
    }
  }

  func testQuarantineMarksPackageAndActivationUnhealthy() throws {
    try withStore { _, repository in
      let package = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha"))
      let staged = try repository.transitionPackage(
        digest: package.packageDigest,
        to: .staged,
        expectedGeneration: package.generation,
        actorSubjectID: "owner",
        updatedAt: updatedAt)
      _ = try repository.activate(
        digest: staged.packageDigest,
        expectedActivationGeneration: nil,
        actorSubjectID: "owner",
        timestamp: revokedAt)

      try repository.quarantine(
        quarantineID: "quarantine-alpha",
        packageDigest: staged.packageDigest,
        reasonCode: "malformed",
        detailDigest: digest("c"),
        actorSubjectID: "owner",
        timestamp: quarantinedAt)

      let quarantined = try XCTUnwrap(repository.package(digest: staged.packageDigest))
      XCTAssertEqual(quarantined.lifecycleState, .quarantined)
      let activation = try XCTUnwrap(repository.activation(identifier: quarantined.manifest.identifier))
      XCTAssertEqual(activation.healthStatus, "unhealthy")
    }
  }

  func testRollbackPersistsAcrossReopenAndDuplicateIdempotencyKeyIsDenied() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner"))
    let repository = store.plugins

    let target = try repository.persistVerifiedPackage(verifiedPackageRecord(
      identifier: "dev.hostwright.plugin.alpha",
      version: "1.0.0",
      packageDigest: digest("a"),
      manifestChar: "b",
      signerIdentifier: "dev.hostwright.signer.alpha",
      storagePath: "/tmp/plugins/alpha"))

    let rollback = PluginRollbackRecord(
      operationID: "rollback-alpha",
      pluginIdentifier: target.manifest.identifier,
      fromPackageDigest: nil,
      toPackageDigest: target.packageDigest,
      stage: "intent",
      status: "pending",
      idempotencyKey: "rollback-key-alpha",
      ownershipEffects: [try ownedArtifact("/tmp/plugins/alpha")],
      failureReasonCode: nil,
      requestedBySubjectID: "owner",
      generation: 1,
      createdAt: createdAt,
      updatedAt: createdAt)

    let stored = try repository.beginRollback(rollback)
    XCTAssertEqual(try SQLiteStateStore(path: store.path).plugins.rollback(operationID: rollback.operationID), stored)

    XCTAssertThrowsError(try repository.beginRollback(PluginRollbackRecord(
      operationID: "rollback-alpha-second",
      pluginIdentifier: target.manifest.identifier,
      fromPackageDigest: nil,
      toPackageDigest: target.packageDigest,
      stage: "intent",
      status: "pending",
      idempotencyKey: rollback.idempotencyKey,
      ownershipEffects: [try ownedArtifact("/tmp/plugins/alpha/child")],
      failureReasonCode: nil,
      requestedBySubjectID: "owner",
      generation: 1,
      createdAt: createdAt,
      updatedAt: createdAt)))

    XCTAssertEqual(try repository.rollback(operationID: rollback.operationID), stored)
    XCTAssertNil(try repository.rollback(operationID: "rollback-alpha-second"))
  }

  func testTamperedCanonicalManifestProvenanceGrantsAndDigestFailClosed() throws {
    try withStore { store, repository in
      let package = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha"))
      let manifestJSON = try XCTUnwrap(rawValue(
        store: store,
        sql: "SELECT manifest_json FROM plugin_packages WHERE package_digest = ?",
        bindings: [.text(package.packageDigest)]))
      let manifestDigest = try XCTUnwrap(rawValue(
        store: store,
        sql: "SELECT manifest_digest FROM plugin_packages WHERE package_digest = ?",
        bindings: [.text(package.packageDigest)]))
      let provenanceJSON = try XCTUnwrap(rawValue(
        store: store,
        sql: "SELECT canonical_json FROM plugin_provenance WHERE package_digest = ?",
        bindings: [.text(package.packageDigest)]))

      let connection = try SQLiteConnection(
        path: store.path,
        createIfNeeded: false,
        profile: .portableArtifact)
      defer { try? connection.close() }

      try connection.run("DROP TRIGGER plugin_package_immutable_content")
      try connection.run(
        "UPDATE plugin_packages SET manifest_json = ? WHERE package_digest = ?",
        bindings: [.text(manifestJSON + " "), .text(package.packageDigest)])
      XCTAssertThrowsError(try repository.package(digest: package.packageDigest))

      try connection.run(
        "UPDATE plugin_packages SET manifest_json = ?, manifest_digest = ? WHERE package_digest = ?",
        bindings: [.text(manifestJSON), .text(manifestDigest), .text(package.packageDigest)])
      try connection.run("DROP TRIGGER plugin_provenance_immutable")
      try connection.run(
        "UPDATE plugin_provenance SET canonical_json = ? WHERE package_digest = ?",
        bindings: [.text(provenanceJSON + " "), .text(package.packageDigest)])
      XCTAssertThrowsError(try repository.package(digest: package.packageDigest))

      try connection.run(
        "UPDATE plugin_provenance SET canonical_json = ? WHERE package_digest = ?",
        bindings: [.text(provenanceJSON), .text(package.packageDigest)])
      try connection.run(
        "UPDATE plugin_grants SET scope = ? WHERE package_digest = ?",
        bindings: [.text("substituted-scope"), .text(package.packageDigest)])
      XCTAssertThrowsError(try repository.package(digest: package.packageDigest))

      try connection.run(
        "UPDATE plugin_grants SET scope = ? WHERE package_digest = ?",
        bindings: [.text("project"), .text(package.packageDigest)])
      try connection.run(
        "UPDATE plugin_packages SET manifest_digest = ? WHERE package_digest = ?",
        bindings: [.text(digest("f")), .text(package.packageDigest)])
      XCTAssertThrowsError(try repository.package(digest: package.packageDigest))
    }
  }

  func testActivationRejectsCrossPluginPriorPackageDigestTampering() throws {
    try withStore { store, repository in
      let alpha = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.alpha",
        version: "1.0.0",
        packageDigest: digest("a"),
        manifestChar: "b",
        signerIdentifier: "dev.hostwright.signer.alpha",
        storagePath: "/tmp/plugins/alpha"))
      let stagedAlpha = try repository.transitionPackage(
        digest: alpha.packageDigest,
        to: .staged,
        expectedGeneration: alpha.generation,
        actorSubjectID: "owner",
        updatedAt: updatedAt)
      _ = try repository.activate(
        digest: stagedAlpha.packageDigest,
        expectedActivationGeneration: nil,
        actorSubjectID: "owner",
        timestamp: revokedAt)

      let beta = try repository.persistVerifiedPackage(verifiedPackageRecord(
        identifier: "dev.hostwright.plugin.beta",
        version: "1.0.0",
        packageDigest: digest("c"),
        manifestChar: "d",
        signerIdentifier: "dev.hostwright.signer.beta",
        storagePath: "/tmp/plugins/beta"))
      let stagedBeta = try repository.transitionPackage(
        digest: beta.packageDigest,
        to: .staged,
        expectedGeneration: beta.generation,
        actorSubjectID: "owner",
        updatedAt: quarantinedAt)
      _ = try repository.activate(
        digest: stagedBeta.packageDigest,
        expectedActivationGeneration: nil,
        actorSubjectID: "owner",
        timestamp: "2026-08-04T12:04:00Z")

      let connection = try SQLiteConnection(
        path: store.path,
        createIfNeeded: false,
        profile: .portableArtifact)
      defer { try? connection.close() }
      try connection.run(
        "UPDATE plugin_activations SET prior_package_digest = ? WHERE plugin_identifier = ?",
        bindings: [.text(stagedAlpha.packageDigest), .text(stagedBeta.manifest.identifier)])

      XCTAssertThrowsError(try repository.activation(identifier: stagedBeta.manifest.identifier))
    }
  }

  private func withStore(
    _ body: (SQLiteStateStore, PluginLifecycleRepository) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner"))
    try body(store, store.plugins)
  }

  private func verifiedPackageRecord(
    identifier: String,
    version: String,
    packageDigest: String,
    manifestChar: Character,
    signerIdentifier: String,
    storagePath: String,
    ownership: [PluginOwnedArtifact]? = nil
  ) throws -> PluginPackageRecord {
    let manifest = PluginPackageManifest(
      identifier: identifier,
      packageVersion: version,
      hostwrightCompatibility: ">=0.0.2,<0.1.0",
      providerKind: .wasi,
      entrypoint: "plugin.wasm",
      grants: [PluginGrant(capability: .policy, scope: "project")],
      artifactDigest: digest(manifestChar),
      contentDigests: [PluginContentDigest(path: "plugin.wasm", digest: digest(manifestChar))],
      provenance: PluginProvenance(
        checksum: packageDigest,
        signature: "cms-\(identifier)-\(version)",
        signerIdentifier: signerIdentifier,
        source: PluginSource(kind: .localDirectory, locator: storagePath)),
      cmsSignature: "cms-envelope-\(identifier)-\(version)",
      signerIdentifier: signerIdentifier)
    return try PluginPackageRecord(
      packageDigest: packageDigest,
      manifest: manifest,
      storagePath: storagePath,
      ownershipLedger: ownership ?? [
        try ownedArtifact(storagePath),
        try ownedArtifact(storagePath + "/plugin.wasm"),
      ],
      lifecycleState: .verified,
      createdBySubjectID: "owner",
      createdAt: createdAt,
      updatedAt: createdAt)
  }

  private func ownedArtifact(_ path: String) throws -> PluginOwnedArtifact {
    try PluginOwnedArtifact(
      path: path,
      deviceID: 1,
      inode: UInt64(abs(path.hashValue % 10_000) + 1),
      sha256Digest: digest("a"))
  }

  private func identity(_ subject: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subject,
      userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q",
        signingIdentifier: "hostwright",
        codeDirectoryHash: String(repeating: "a", count: 40),
        validationMode: .installedRequirement),
      declaredBySubjectID: subject,
      declaredAt: createdAt,
      updatedAt: createdAt)
  }

  private func rawValue(
    store: SQLiteStateStore,
    sql: String,
    bindings: [SQLiteValue]
  ) throws -> String? {
    try store.withConnection(createIfNeeded: false, readOnly: true) {
      try $0.query(sql, bindings: bindings).first?.first ?? nil
    }
  }

  private func digest(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
  }

  private func count(
    store: SQLiteStateStore,
    sql: String,
    bindings: [SQLiteValue]
  ) throws -> Int {
    try store.withConnection(createIfNeeded: false, readOnly: true) {
      try $0.query(sql, bindings: bindings).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
    }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-plugin-lifecycle-repository-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return root
  }
}
