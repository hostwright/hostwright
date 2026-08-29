import CryptoKit
import Foundation
import HostwrightControlPlane
import XCTest
@testable import HostwrightWASIProviderRuntime

final class HostwrightWASIProviderRuntimeTests: XCTestCase {
  func testFrozenSandboxHasNoAmbientCapabilities() {
    XCTAssertEqual(WASISandboxContract.previewVersion, "Preview1")
    XCTAssertEqual(WASISandboxContract.preopens, [])
    XCTAssertEqual(WASISandboxContract.inheritedEnvironment, [])
    XCTAssertFalse(WASISandboxContract.ambientNetwork)
    XCTAssertFalse(WASISandboxContract.hostSocketAccess)
    XCTAssertFalse(WASISandboxContract.stateDatabaseAccess)
    XCTAssertFalse(WASISandboxContract.keychainAccess)
    XCTAssertTrue(WASISandboxContract.freshInstancePerInvocation)
  }

  func testInvalidAndMemorylessModulesFailBeforeInstantiation() {
    XCTAssertThrowsError(try WASIProviderModuleRuntime.run(
      moduleBytes: Data([0, 97, 115, 109, 1, 0, 0, 0]), wallSeconds: 1,
      wallNanoseconds: 0, seed: 1, maximumMemoryPages: 1_024)) { error in
        XCTAssertEqual(error as? WASIProviderRuntimeError, .invalidModule)
      }
    XCTAssertThrowsError(try WASIProviderModuleRuntime.run(
      moduleBytes: Data([0, 1, 2]), wallSeconds: 1,
      wallNanoseconds: 0, seed: 1, maximumMemoryPages: 1_024))
  }

  func testExcessiveTableAndGlobalDeclarationsFailBeforeInstantiation() {
    let header: [UInt8] = [0, 97, 115, 109, 1, 0, 0, 0]
    let excessiveTable: [UInt8] = [4, 7, 1, 0x70, 1, 0, 0x81, 0x80, 0x04]
    let boundedMemory: [UInt8] = [5, 4, 1, 1, 1, 1]
    XCTAssertThrowsError(try WASIProviderModuleRuntime.run(
      moduleBytes: Data(header + excessiveTable + boundedMemory), wallSeconds: 1,
      wallNanoseconds: 0, seed: 1, maximumMemoryPages: 1_024)) { error in
        XCTAssertEqual(error as? WASIProviderRuntimeError, .invalidModule)
      }

    let excessiveGlobals: [UInt8] = [6, 2, 0x81, 0x20]
    XCTAssertThrowsError(try WASIProviderModuleRuntime.run(
      moduleBytes: Data(header + excessiveGlobals + boundedMemory), wallSeconds: 1,
      wallNanoseconds: 0, seed: 1, maximumMemoryPages: 1_024)) { error in
        XCTAssertEqual(error as? WASIProviderRuntimeError, .invalidModule)
      }
  }

  func testResultBoundaryRequiresCanonicalJSONAndMatchingCapability() throws {
    let invocation = PluginInvocation(
      invocationID: "result-1", pluginIdentifier: "dev.hostwright.result", capability: .policy,
      timestamp: Date(timeIntervalSince1970: 1), seed: 1,
      input: .object(["scope": .string("project")]))
    let grants = [PluginGrant(capability: .policy, scope: "project")]
    let valid = PluginResult(
      invocationID: invocation.invocationID,
      actions: [PluginProposedAction(
        capability: .policy, kind: "propose", payload: .object(["scope": .string("project")]))])
    let canonical = try ControlPlaneCanonicalJSON.encode(valid)
    XCTAssertEqual(
      try WASIProviderHostExecutor.decodeResult(canonical, invocation: invocation, grants: grants),
      valid)
    XCTAssertThrowsError(try WASIProviderHostExecutor.decodeResult(
      Data(" ".utf8) + canonical, invocation: invocation, grants: grants))
    let unknown = Data(String(decoding: canonical, as: UTF8.self).dropLast().utf8)
      + Data(",\"unknown\":true}".utf8)
    XCTAssertThrowsError(try WASIProviderHostExecutor.decodeResult(
      unknown, invocation: invocation, grants: grants))
    let wrong = PluginResult(
      invocationID: invocation.invocationID,
      actions: [PluginProposedAction(
        capability: .network, kind: "escape", payload: .object(["scope": .string("project")]))])
    XCTAssertThrowsError(try WASIProviderHostExecutor.decodeResult(
      ControlPlaneCanonicalJSON.encode(wrong), invocation: invocation, grants: grants))
    let crossScope = PluginResult(
      invocationID: invocation.invocationID,
      actions: [PluginProposedAction(
        capability: .policy, kind: "escape", payload: .object(["scope": .string("other")]))])
    XCTAssertThrowsError(try WASIProviderHostExecutor.decodeResult(
      ControlPlaneCanonicalJSON.encode(crossScope), invocation: invocation, grants: grants))
  }
}

final class HostwrightWASIProviderCompatibilityTests: XCTestCase {
  func testPluginABIVersionAndLegacyNetworkProviderRemainFrozen() {
    XCTAssertEqual(WASISandboxContract.previewVersion, "Preview1")
    XCTAssertEqual(WASILimits.default.memoryBytes, 64 * 1_024 * 1_024)
  }
}

final class HostwrightWASIProviderSecurityTests: XCTestCase {
  func testGrantIsRequiredBeforeWorkerLaunch() async throws {
    let executor = try WASIProviderHostExecutor(workerExecutableURL: URL(fileURLWithPath: "/bin/false"))
    let invocation = PluginInvocation(
      invocationID: "security", pluginIdentifier: "dev.hostwright.security", capability: .policy,
      timestamp: Date(timeIntervalSince1970: 1), seed: 1,
      input: .object(["scope": .string("project")]))
    do {
      _ = try await executor.execute(WASIProviderExecution(
        moduleURL: URL(fileURLWithPath: "/not/read"),
        expectedModuleDigest: "sha256:" + String(repeating: "0", count: 64),
        invocation: invocation, grants: []))
      XCTFail("missing grant must fail closed")
    } catch let error as WASIProviderRuntimeError {
      XCTAssertEqual(error, .missingGrant)
    }
  }


  func testModuleDigestAndWritableFileFailClosedBeforeWorkerExecution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-wasi-security-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let module = directory.appendingPathComponent("provider.wasm")
    try Data([0, 97, 115, 109, 1, 0, 0, 0]).write(to: module)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: module.path)
    let executor = try WASIProviderHostExecutor(workerExecutableURL: URL(fileURLWithPath: "/bin/false"))
    let invocation = PluginInvocation(
      invocationID: "security", pluginIdentifier: "dev.hostwright.security", capability: .policy,
      timestamp: Date(timeIntervalSince1970: 1), seed: 1,
      input: .object(["scope": .string("project")]))
    let grant = PluginGrant(capability: .policy, scope: "project")

    do {
      _ = try await executor.execute(WASIProviderExecution(
        moduleURL: module, expectedModuleDigest: "sha256:" + String(repeating: "0", count: 64),
        invocation: invocation, grants: [grant]))
      XCTFail("digest mismatch must fail")
    } catch let error as WASIProviderRuntimeError {
      XCTAssertEqual(error, .invalidModule)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o622], ofItemAtPath: module.path)
    do {
      _ = try await executor.execute(WASIProviderExecution(
        moduleURL: module, expectedModuleDigest: "sha256:" + String(repeating: "0", count: 64),
        invocation: invocation, grants: [grant]))
      XCTFail("writable module must fail")
    } catch let error as WASIProviderRuntimeError {
      XCTAssertEqual(error, .invalidModule)
    }
  }

  func testGrantScopeMustExactlyMatchInvocationScope() async throws {
    let executor = try WASIProviderHostExecutor(workerExecutableURL: URL(fileURLWithPath: "/bin/false"))
    let invocation = PluginInvocation(
      invocationID: "scope", pluginIdentifier: "dev.hostwright.scope", capability: .policy,
      timestamp: Date(timeIntervalSince1970: 1), seed: 1,
      input: .object(["scope": .string("project-b")]))
    do {
      _ = try await executor.execute(WASIProviderExecution(
        moduleURL: URL(fileURLWithPath: "/not/read"),
        expectedModuleDigest: "sha256:" + String(repeating: "0", count: 64),
        invocation: invocation, grants: [PluginGrant(capability: .policy, scope: "project-a")]))
      XCTFail("cross-scope grant must fail before module access")
    } catch let error as WASIProviderRuntimeError {
      XCTAssertEqual(error, .missingGrant)
    }
  }

  func testFractionalTimestampIsRejectedBeforeWorkerExecution() async throws {
    let executor = try WASIProviderHostExecutor(workerExecutableURL: URL(fileURLWithPath: "/bin/false"))
    let invocation = PluginInvocation(
      invocationID: "fractional", pluginIdentifier: "dev.hostwright.time", capability: .policy,
      timestamp: Date(timeIntervalSince1970: 1.5), seed: 1,
      input: .object(["scope": .string("project")]))
    do {
      _ = try await executor.execute(WASIProviderExecution(
        moduleURL: URL(fileURLWithPath: "/not/read"),
        expectedModuleDigest: "sha256:" + String(repeating: "0", count: 64),
        invocation: invocation, grants: [PluginGrant(capability: .policy, scope: "project")]))
      XCTFail("fractional timestamps must fail before module access")
    } catch let error as WASIProviderRuntimeError {
      XCTAssertEqual(error, .invalidInvocation)
    }
  }

  func testWorkerIdentityIsRecordedInPinnedOwnershipLedgerBeforeExecution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-wasi-ledger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = directory.appendingPathComponent("ownership.tsv")
    let header = "recorded_at\ttype\tidentifier\tpath\tdevice\tinode\tidentity\n"
    try Data(header.utf8).write(to: ledger)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
    let module = directory.appendingPathComponent("provider.wasm")
    let moduleData = Data([0, 97, 115, 109, 1, 0, 0, 0])
    try moduleData.write(to: module)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: module.path)
    let digest = "sha256:" + SHA256.hash(data: moduleData).map { String(format: "%02x", $0) }.joined()
    let workerLink = directory.appendingPathComponent("provider-worker")
    try FileManager.default.createSymbolicLink(atPath: workerLink.path, withDestinationPath: "/usr/bin/false")
    let executor = try WASIProviderHostExecutor(
      workerExecutableURL: workerLink, ownershipLedgerURL: ledger)
    let invocation = PluginInvocation(
      invocationID: "ledger", pluginIdentifier: "dev.hostwright.ledger", capability: .policy,
      timestamp: Date(timeIntervalSince1970: 1), seed: 1,
      input: .object(["scope": .string("project")]))
    do {
      _ = try await executor.execute(WASIProviderExecution(
        moduleURL: module, expectedModuleDigest: digest, invocation: invocation,
        grants: [PluginGrant(capability: .policy, scope: "project")]))
      XCTFail("false worker must fail")
    } catch let error as WASIProviderRuntimeError {
      XCTAssertEqual(error, .executionFailed)
    }
    let contents = try String(contentsOf: ledger, encoding: .utf8)
    XCTAssertTrue(contents.contains("\tprocess\tprovider-worker\t/usr/bin/false\t"), contents)
    let rows = contents.split(separator: "\n").map(String.init)
    let identity = try XCTUnwrap(rows.last?.split(separator: "\t").last.map(String.init))
    XCTAssertNotNil(identity.range(
      of: "^pid=[1-9][0-9]*;command_sha256=[a-f0-9]{64};start_sha256=[a-f0-9]{64}$",
      options: .regularExpression
    ), contents)
  }
}

final class HostwrightWASIProviderResilienceTests: XCTestCase {
  func testLimitsKeepNormalDeadlineBelowAbsoluteCeiling() throws {
    XCTAssertLessThan(WASILimits.default.normalExecutionMilliseconds,
      WASILimits.default.absoluteExecutionMilliseconds)
    XCTAssertNoThrow(try WASILimits.default.validate())
  }
}
