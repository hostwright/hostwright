import Foundation
import HostwrightControlPlane
import HostwrightXPCProvider

@main
struct HostwrightXPCProviderQualificationTool {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 4, arguments[0] == "--service-name",
        arguments[2] == "--scenario", let scenario = Scenario(rawValue: arguments[3])
      else { throw Exit.usage }
      let serviceName = arguments[1]
      switch scenario {
      case .proof:
        let first = try await proof(serviceName: serviceName, requestID: "gate11-proof-1")
        let second = try await proof(serviceName: serviceName, requestID: "gate11-proof-2")
        guard first == second else { throw QualificationFailure(reasonCode: "identity-drift") }
      case .timeout:
        try await expect(.timedOut, serviceName: serviceName, operation: .timeout)
      case .cancel:
        try await expect(.cancelled, serviceName: serviceName, operation: .cancel)
      case .revoke:
        try await expect(.revoked, serviceName: serviceName, operation: .revoke)
      case .unavailable:
        try await expect(.serviceUnavailable, serviceName: serviceName, operation: .unavailable)
      case .malformed:
        try await expect(.invalidResponse, serviceName: serviceName, operation: .malformed)
      case .oversized:
        try await expect(.invalidResponse, serviceName: serviceName, operation: .oversized)
      case .authentication:
        try await expect(.authenticationFailed, serviceName: serviceName, operation: .unavailable)
      }
      print("Gate 11 XPC live conformance passed: \(scenario.rawValue).")
    } catch Exit.usage {
      FileHandle.standardError.write(Data(
        "usage: hostwright-xpc-provider-qualification --service-name <name> --scenario <proof|timeout|cancel|revoke|unavailable|malformed|oversized|authentication>\n".utf8))
      exit(64)
    } catch let error as XPCProviderError {
      FileHandle.standardError.write(Data(
        "Gate 11 XPC live conformance failed: \(error.reasonCode).\n".utf8))
      exit(70)
    } catch let error as QualificationFailure {
      FileHandle.standardError.write(Data(
        "Gate 11 XPC live conformance failed: \(error.reasonCode).\n".utf8))
      exit(70)
    } catch {
      FileHandle.standardError.write(Data("Gate 11 XPC live conformance failed: internal.\n".utf8))
      exit(70)
    }
  }

  private static func proof(serviceName: String, requestID: String) async throws
    -> CodeIdentityProof
  {
    let client = try XPCProviderClient(serviceName: serviceName)
    let response = try await client.execute(XPCRequest(
      requestID: requestID, timeoutMilliseconds: 5_000))
    guard response.status == .completed, let proof = response.proof else {
      throw QualificationFailure(reasonCode: response.error?.code ?? response.status.rawValue)
    }
    try proof.validate()
    return proof
  }

  private static func expect(
    _ expected: XPCProviderError, serviceName: String, operation: ExpectedOperation
  ) async throws {
    let client = try XPCProviderClient(serviceName: serviceName)
    let timeout = switch operation {
    case .timeout, .cancel, .revoke: 100
    case .oversized: 500
    case .unavailable: 1_000
    case .malformed: 5_000
    }
    let request = XPCRequest(
      requestID: "gate11-\(operation.rawValue)", timeoutMilliseconds: timeout)
    do {
      switch operation {
      case .timeout, .unavailable, .malformed, .oversized:
        _ = try await client.execute(request)
      case .cancel:
        let task = Task { try await client.execute(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = try await task.value
      case .revoke:
        let task = Task { try await client.execute(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        client.revoke()
        _ = try await task.value
      }
      throw QualificationFailure(reasonCode: "expected-\(expected.reasonCode)")
    } catch let error as XPCProviderError where error == expected {}
  }

  private enum Exit: Error { case usage }
  private enum Scenario: String {
    case proof, timeout, cancel, revoke, unavailable, malformed, oversized, authentication
  }
  private enum ExpectedOperation: String {
    case timeout, cancel, revoke, unavailable, malformed, oversized
  }
  private struct QualificationFailure: Error { let reasonCode: String }
}
