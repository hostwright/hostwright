import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightState

final class WorkloadProfileRepositoryTests: XCTestCase {
  private let createdAt = "2026-08-03T00:00:00Z"
  private let updatedAt = "2026-08-03T00:01:00Z"

  func testCanonicalCreateListAndReopenRoundTrip() throws {
    try withStore { store, repository in
      let record = try repository.create(record(profile("root")))
      XCTAssertEqual(try repository.listProfiles(), [record])

      let reopened = SQLiteStateStore(path: store.path)
      XCTAssertEqual(try reopened.workloadProfiles.profile(id: "root"), record)
      XCTAssertEqual(try reopened.workloadProfiles.listProfiles(), [record])
      XCTAssertEqual(record.profileSHA256, try WorkloadProfileRecord.digest(record.profile))
    }
  }

  func testUpdateAdvancesGenerationAndPreservesCreator() throws {
    try withStore { _, repository in
      let original = try repository.create(record(profile("root")))
      let replacement = profile("root", resources: ResourceProfile(cpu: 2, memoryMiB: 256))

      let updated = try repository.update(
        profile: replacement, expectedGeneration: original.generation,
        actorSubjectID: "owner", updatedAt: updatedAt)
      XCTAssertEqual(updated.generation, 2)
      XCTAssertEqual(updated.createdBySubjectID, "owner")
      XCTAssertEqual(updated.createdAt, createdAt)
      XCTAssertEqual(updated.updatedAt, updatedAt)
      XCTAssertEqual(updated.profile.resources?.cpu, 2)
      XCTAssertThrowsError(
        try repository.update(
          profile: replacement, expectedGeneration: original.generation,
          actorSubjectID: "owner", updatedAt: updatedAt))
    }
  }

  func testMissingParentIsRejectedBeforePersistence() throws {
    try withStore { _, repository in
      XCTAssertThrowsError(
        try repository.create(record(profile("orphan", parent: "missing")))) { error in
          guard case .notFound = error as? StateStoreError else {
            return XCTFail("Expected missing parent, got \(error)")
          }
        }
      XCTAssertNil(try repository.profile(id: "orphan"))
    }
  }

  func testCycleUpdateIsRejectedAndTransactionRollsBack() throws {
    try withStore { _, repository in
      let root = try repository.create(record(profile("root")))
      _ = try repository.create(record(profile("child", parent: "root")))

      XCTAssertThrowsError(
        try repository.update(
          profile: profile("root", parent: "child"), expectedGeneration: root.generation,
          actorSubjectID: "owner", updatedAt: updatedAt))
      let restored = try XCTUnwrap(repository.profile(id: "root"))
      XCTAssertNil(restored.profile.parent)
      XCTAssertEqual(restored.generation, root.generation)
    }
  }

  func testParentDeletionIsProtectedWhileChildExists() throws {
    try withStore { _, repository in
      let root = try repository.create(record(profile("root")))
      _ = try repository.create(record(profile("child", parent: "root")))

      XCTAssertThrowsError(try repository.delete(id: root.profile.identifier, expectedGeneration: root.generation))
      XCTAssertNotNil(try repository.profile(id: "root"))
      XCTAssertNotNil(try repository.profile(id: "child"))
    }
  }

  func testInheritanceDepthAboveThirtyTwoIsRejectedTransactionally() throws {
    try withStore { _, repository in
      var parent: String?
      for index in 1...32 {
        let identifier = "depth-\(index)"
        _ = try repository.create(record(profile(identifier, parent: parent)))
        parent = identifier
      }
      XCTAssertThrowsError(
        try repository.create(record(profile("depth-33", parent: parent))))
      XCTAssertNil(try repository.profile(id: "depth-33"))
      XCTAssertEqual(try repository.listProfiles().count, 32)
    }
  }

  func testTamperedCanonicalJSONAndDigestFailClosed() throws {
    try withStore { store, repository in
      let stored = try repository.create(record(profile("root")))
      let rawJSON = try XCTUnwrap(
        store.withConnection(createIfNeeded: false, readOnly: true) { connection in
          try connection.query(
            "SELECT profile_json FROM workload_profiles WHERE profile_id = ?", bindings: [.text("root")]
          ).first?.first ?? nil
        })
      let connection = try SQLiteConnection(
        path: store.path, createIfNeeded: false, profile: .portableArtifact)
      defer { try? connection.close() }

      try connection.run(
        "UPDATE workload_profiles SET profile_json = ? WHERE profile_id = ?",
        bindings: [.text(rawJSON + " "), .text("root")])
      XCTAssertThrowsError(try repository.profile(id: "root"))

      try connection.run(
        "UPDATE workload_profiles SET profile_json = ?, profile_sha256 = ? WHERE profile_id = ?",
        bindings: [.text(rawJSON), .text(String(repeating: "0", count: 64)), .text("root")])
      XCTAssertThrowsError(try repository.profile(id: "root"))
      XCTAssertNotEqual(stored.profileSHA256, String(repeating: "0", count: 64))
    }
  }

  func testLatestSchemaPersistsWorkloadProfiles() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    let latestSchemaVersion = MigrationRunner.latestSchemaVersion
    try MigrationRunner().apply(to: store, throughVersion: latestSchemaVersion)
    try store.controlIdentities.bootstrap(identity("owner"))
    XCTAssertEqual(try store.schemaVersion(), latestSchemaVersion)

    let stored = try store.workloadProfiles.create(record(profile("latest-root")))
    let row = try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
      try connection.query(
        "SELECT profile_id, version, generation, profile_sha256 FROM workload_profiles WHERE profile_id = ?",
        bindings: [.text("latest-root")])
    }.first
    XCTAssertEqual(row?.count, 4)
    XCTAssertEqual(row?[0], "latest-root")
    XCTAssertEqual(row?[1], "1")
    XCTAssertEqual(row?[2], "1")
    XCTAssertEqual(row?[3], stored.profileSHA256)
  }

  func testSchemaV20RejectsWorkloadProfilePersistence() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try MigrationRunner().apply(to: store, throughVersion: 20)
    XCTAssertEqual(try store.schemaVersion(), 20)

    do {
      _ = try store.workloadProfiles.create(record(profile("v20-root")))
      XCTFail("Expected workload profile creation to be rejected")
    } catch let error as StateStoreError {
      guard case .incompatibleSchema = error else {
        return XCTFail("Expected incompatible schema, got \(error)")
      }
    } catch {
      XCTFail("Expected StateStoreError.incompatibleSchema, got \(error)")
    }
  }

  private func withStore(
    _ body: (SQLiteStateStore, WorkloadProfileRepository) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner"))
    try body(store, store.workloadProfiles)
  }

  private func record(_ profile: WorkloadProfile) throws -> WorkloadProfileRecord {
    try WorkloadProfileRecord(
      profile: profile, createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt)
  }

  private func profile(
    _ identifier: String, parent: String? = nil, resources: ResourceProfile? = nil
  ) -> WorkloadProfile {
    WorkloadProfile(
      identifier: identifier, parent: parent,
      filesystem: FilesystemProfile(readOnlyRoot: true, denyHostRoot: true),
      network: NetworkProfile(mode: .isolated), resources: resources,
      secrets: SecretsProfile(), images: ImagesProfile(requireDigest: true, requireSignature: false),
      runtime: RuntimeProfile(), hostAccess: HostAccessProfile(allowed: false),
      observability: ObservabilityProfile(logs: false, metrics: false, traces: false),
      accelerators: AcceleratorsProfile(), syscalls: SyscallProfile(defaultDeny: false))
  }

  private func identity(_ subject: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subject, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
        codeDirectoryHash: String(repeating: "a", count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: subject, declaredAt: createdAt, updatedAt: createdAt)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-workload-profile-repository-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
