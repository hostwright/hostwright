import Foundation
import HostwrightControlPlane
@testable import HostwrightExtensions
import HostwrightState
import XCTest

final class PluginProviderHealthCheckerTests: XCTestCase {
  func testRevokeCancelsInflightWASICheckAndReturnsRevoked() throws {
    let started = expectation(description: "WASI provider started")
    let cancelled = expectation(description: "WASI provider cancelled")
    let finished = expectation(description: "health check finished")
    let result = LockedHealthResult()
    let checker = try PluginProviderHealthChecker(wasiExecution: { invocation in
      try await withTaskCancellationHandler {
        started.fulfill()
        while !Task.isCancelled {
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
      } onCancel: {
        cancelled.fulfill()
      }
    })
    let package = try Self.package()
    DispatchQueue.global().async {
      do {
        try checker.check(package, timeoutMilliseconds: 5_000)
        result.set(nil)
      } catch {
        result.set(error)
      }
      finished.fulfill()
    }
    wait(for: [started], timeout: 2)
    checker.revoke(packageDigest: package.packageDigest)
    wait(for: [cancelled, finished], timeout: 2)
    XCTAssertEqual(result.value() as? PluginProviderHealthError, .revoked)
  }

  private static func package() throws -> PluginPackageRecord {
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let artifact = "sha256:" + String(repeating: "b", count: 64)
    let manifest = PluginPackageManifest(
      identifier: "dev.hostwright.health", packageVersion: "1.0.0",
      hostwrightCompatibility: ">=0.0.2 <0.1.0", providerKind: .wasi,
      entrypoint: "plugin.wasm",
      grants: [PluginGrant(capability: .policy, scope: "project")],
      artifactDigest: artifact,
      contentDigests: [PluginContentDigest(path: "plugin.wasm", digest: artifact)],
      provenance: PluginProvenance(
        checksum: digest, signature: "signature", signerIdentifier: "signer",
        source: PluginSource(kind: .localDirectory, locator: "/private/tmp/plugin")),
      cmsSignature: "cms", signerIdentifier: "signer")
    return try PluginPackageRecord(
      packageDigest: digest, manifest: manifest, storagePath: "/private/tmp/plugin-installed",
      ownershipLedger: [try PluginOwnedArtifact(
        path: "/private/tmp/plugin-installed", kind: .directory,
        deviceID: 1, inode: 1)], lifecycleState: .staged,
      createdBySubjectID: "owner", createdAt: "2026-08-04T10:00:00Z",
      updatedAt: "2026-08-04T10:00:00Z")
  }
}

private final class LockedHealthResult: @unchecked Sendable {
  private let lock = NSLock()
  private var error: Error?
  func set(_ value: Error?) { lock.withLock { error = value } }
  func value() -> Error? { lock.withLock { error } }
}
