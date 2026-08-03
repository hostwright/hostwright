import CryptoKit
import Foundation
import HostwrightControlPlane
import HostwrightWASIProviderRuntime

@main
struct HostwrightWASIProviderQualificationTool {
  static func main() async {
    var stage = "arguments"
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 4, arguments[0] == "--reference", arguments[2] == "--adversarial" else {
        throw WASIProviderRuntimeError.invalidInvocation
      }
      let reference = URL(fileURLWithPath: arguments[1])
      let adversarial = URL(fileURLWithPath: arguments[3])
      let worker = ProcessInfo.processInfo.environment["HOSTWRIGHT_WASI_PROVIDER_WORKER"]
        .map { URL(fileURLWithPath: $0) }
      let ownershipLedger = ProcessInfo.processInfo.environment["HOSTWRIGHT_WASI_OWNERSHIP_LEDGER"]
        .map { URL(fileURLWithPath: $0) }
      let executor = try WASIProviderHostExecutor(
        workerExecutableURL: worker, ownershipLedgerURL: ownershipLedger)
      let referenceDigest = try digest(reference)
      let adversarialDigest = try digest(adversarial)
      let grant = PluginGrant(capability: .policy, scope: "project")

      stage = "reference-first"
      let first = try await executor.execute(WASIProviderExecution(
        moduleURL: reference, expectedModuleDigest: referenceDigest,
        invocation: invocation(id: "gate10-reference-1", input: .object(["operation": .string("plan")])),
        grants: [grant]))
      stage = "reference-second"
      let second = try await executor.execute(WASIProviderExecution(
        moduleURL: reference, expectedModuleDigest: referenceDigest,
        invocation: invocation(id: "gate10-reference-1", input: .object(["operation": .string("plan")])),
        grants: [grant]))
      guard try canonical(first) == canonical(second), first.actions.count == 1 else {
        throw WASIProviderRuntimeError.invalidResult
      }

      stage = "ambient"
      let ambient = try await executor.execute(WASIProviderExecution(
        moduleURL: adversarial, expectedModuleDigest: adversarialDigest,
        invocation: invocation(id: "gate10-ambient", input: .object(["adversarial": .string("ambient")])),
        grants: [grant]))
      guard ambient.diagnostics.contains(where: { $0.code == "ambient-probe" && $0.message == "denied" }) else {
        throw WASIProviderRuntimeError.invalidResult
      }
      stage = "wrong-capability"
      try await expectFailure(.executionFailed, executor: executor, module: adversarial,
        digest: adversarialDigest, scenario: "wrong-capability")
      stage = "oversize"
      try await expectFailure(.outputLimitExceeded, executor: executor, module: adversarial,
        digest: adversarialDigest, scenario: "oversize")
      stage = "crash"
      try await expectFailure(.executionFailed, executor: executor, module: adversarial,
        digest: adversarialDigest, scenario: "crash")
      stage = "hang"
      try await expectFailure(.timedOut, executor: executor, module: adversarial,
        digest: adversarialDigest, scenario: "hang", timeoutMilliseconds: 100)
      stage = "revocation"
      do {
        _ = try await executor.execute(WASIProviderExecution(
          moduleURL: reference, expectedModuleDigest: referenceDigest,
          invocation: invocation(id: "gate10-revoked", input: .object([:])), grants: []))
        throw WASIProviderRuntimeError.invalidResult
      } catch WASIProviderRuntimeError.missingGrant {}

      print("Gate 10 WASI live conformance passed.")
    } catch let error as WASIProviderRuntimeError {
      FileHandle.standardError.write(Data("Gate 10 WASI live conformance failed at \(stage): \(error).\n".utf8))
      Foundation.exit(1)
    } catch {
      FileHandle.standardError.write(Data("Gate 10 WASI live conformance failed: internal.\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func invocation(
    id: String, input: ControlPlaneJSONValue, timeoutMilliseconds: Int = 5_000
  ) -> PluginInvocation {
    let scopedInput: ControlPlaneJSONValue
    if case .object(var object) = input {
      object["scope"] = .string("project")
      scopedInput = .object(object)
    } else {
      scopedInput = .object(["scope": .string("project"), "snapshot": input])
    }
    return PluginInvocation(
      invocationID: id, pluginIdentifier: "dev.hostwright.gate10.provider", capability: .policy,
      timestamp: Date(timeIntervalSince1970: 1_786_000_000), seed: 42, input: scopedInput,
      limits: WASILimits(
        moduleBytes: WASILimits.default.moduleBytes, inputBytes: WASILimits.default.inputBytes,
        outputBytes: WASILimits.default.outputBytes, memoryBytes: WASILimits.default.memoryBytes,
        normalExecutionMilliseconds: timeoutMilliseconds,
        absoluteExecutionMilliseconds: WASILimits.default.absoluteExecutionMilliseconds))
  }

  private static func digest(_ url: URL) throws -> String {
    "sha256:" + SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }

  private static func canonical(_ result: PluginResult) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(result)
  }

  private static func expectFailure(
    _ expected: WASIProviderRuntimeError, executor: WASIProviderHostExecutor, module: URL,
    digest: String, scenario: String, timeoutMilliseconds: Int = 5_000
  ) async throws {
    do {
      _ = try await executor.execute(WASIProviderExecution(
        moduleURL: module, expectedModuleDigest: digest,
        invocation: invocation(
          id: "gate10-\(scenario)", input: .object(["adversarial": .string(scenario)]),
          timeoutMilliseconds: timeoutMilliseconds),
        grants: [PluginGrant(capability: .policy, scope: "project")]))
      throw WASIProviderRuntimeError.invalidResult
    } catch let error as WASIProviderRuntimeError where error == expected {}
  }
}
