import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
@testable import HostwrightExtensions
import HostwrightState
import HostwrightWASIProviderRuntime
import XCTest

final class ActivePluginProviderRuntimeTests: XCTestCase {
  func testActiveDigestSelectsExactWASIPackageAndRevocationStopsInvocation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-active-provider-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity())
    let package = try store.plugins.persistVerifiedPackage(package(root: root))
    _ = try store.plugins.activate(
      digest: package.packageDigest, expectedActivationGeneration: nil,
      actorSubjectID: "owner", timestamp: "2026-08-04T10:01:00Z")
    let captured = LockedExecution()
    let runtime = ActivePluginProviderRuntime(
      repository: store.plugins,
      wasiExecution: { execution in
        captured.set(execution)
        return PluginResult(invocationID: execution.invocation.invocationID)
      },
      xpcProof: { _, _ in throw ActivePluginProviderRuntimeError.providerMismatch })
    let invocation = PluginInvocation(
      invocationID: "invoke-active", pluginIdentifier: package.manifest.identifier,
      capability: .policy, timestamp: Date(timeIntervalSince1970: 1), seed: 1,
      input: .object(["scope": .string("project")]))
    let invocationResult = try await runtime.invoke(invocation)
    XCTAssertEqual(invocationResult.invocationID, "invoke-active")
    XCTAssertEqual(captured.value()?.expectedModuleDigest, package.manifest.artifactDigest)
    XCTAssertEqual(
      captured.value()?.moduleURL.path,
      URL(fileURLWithPath: package.storagePath, isDirectory: true)
        .appendingPathComponent(package.manifest.entrypoint).path)

    try store.plugins.revoke(
      revocationID: "revoke-active", targetKind: "package",
      targetIdentifier: package.packageDigest, reason: "security-test",
      actorSubjectID: "owner", timestamp: "2026-08-04T10:02:00Z")
    do {
      _ = try await runtime.invoke(invocation)
      XCTFail("revoked active package must not execute")
    } catch let error as ActivePluginProviderRuntimeError {
      XCTAssertEqual(error, .inactive)
    }
  }

  func testRuntimeRevocationCancelsInFlightActiveInvocation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-active-provider-revoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity())
    let package = try store.plugins.persistVerifiedPackage(package(root: root))
    _ = try store.plugins.activate(
      digest: package.packageDigest, expectedActivationGeneration: nil,
      actorSubjectID: "owner", timestamp: "2026-08-04T10:01:00Z")
    let started = LockedFlag()
    let runtime = ActivePluginProviderRuntime(
      repository: store.plugins,
      wasiExecution: { _ in
        started.set()
        while true { try await Task.sleep(nanoseconds: 10_000_000) }
      },
      xpcProof: { _, _ in throw ActivePluginProviderRuntimeError.providerMismatch })
    let invocation = PluginInvocation(
      invocationID: "invoke-revoked", pluginIdentifier: package.manifest.identifier,
      capability: .policy, timestamp: Date(timeIntervalSince1970: 1), seed: 1,
      input: .object(["scope": .string("project")]))
    let task = Task { try await runtime.invoke(invocation) }
    for _ in 0..<100 where !started.value() {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(started.value())

    runtime.revoke(packageDigest: package.packageDigest)
    do {
      _ = try await task.value
      XCTFail("revocation must cancel in-flight active execution")
    } catch let error as ActivePluginProviderRuntimeError {
      XCTAssertEqual(error, .revoked)
    }
  }

  private func package(root: URL) throws -> PluginPackageRecord {
    let packageDigest = digest("a")
    let artifactDigest = digest("b")
    let storagePath = root.appendingPathComponent("package", isDirectory: true).path
    let manifest = PluginPackageManifest(
      identifier: "dev.hostwright.active", packageVersion: "1.0.0",
      hostwrightCompatibility: ">=0.0.2 <0.1.0", providerKind: .wasi,
      entrypoint: "plugin.wasm",
      grants: [PluginGrant(capability: .policy, scope: "project")],
      artifactDigest: artifactDigest,
      contentDigests: [PluginContentDigest(path: "plugin.wasm", digest: artifactDigest)],
      provenance: PluginProvenance(
        checksum: packageDigest, signature: "signature", signerIdentifier: "signer",
        source: PluginSource(kind: .localDirectory, locator: root.path)),
      cmsSignature: "cms", signerIdentifier: "signer")
    return try PluginPackageRecord(
      packageDigest: packageDigest, manifest: manifest, storagePath: storagePath,
      ownershipLedger: [try PluginOwnedArtifact(
        path: storagePath, kind: .directory, deviceID: 1, inode: 1)],
      lifecycleState: .staged, createdBySubjectID: "owner",
      createdAt: "2026-08-04T10:00:00Z", updatedAt: "2026-08-04T10:00:00Z")
  }

  private func identity() -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: "owner", userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
        codeDirectoryHash: String(repeating: "a", count: 40),
        validationMode: .installedRequirement),
      declaredBySubjectID: "owner", declaredAt: "2026-08-04T10:00:00Z",
      updatedAt: "2026-08-04T10:00:00Z")
  }

  private func digest(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
  }
}

private final class LockedExecution: @unchecked Sendable {
  private let lock = NSLock()
  private var execution: WASIProviderExecution?
  func set(_ value: WASIProviderExecution) { lock.withLock { execution = value } }
  func value() -> WASIProviderExecution? { lock.withLock { execution } }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() { lock.withLock { flag = true } }
  func value() -> Bool { lock.withLock { flag } }
}
