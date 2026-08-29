import Foundation
import XCTest
@testable import HostwrightWASIProviderSDK

final class HostwrightWASIProviderSDKTests: XCTestCase {
  private var fixture: Data {
    get throws {
      let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      return try Data(contentsOf: repository.appendingPathComponent(
        "contracts/v0.0.2/phase09-plugin-invocation-v1.json"))
    }
  }

  func testFrozenInvocationFixtureRoundTripsWithStringTimestamp() throws {
    let invocation = try JSONDecoder().decode(Invocation.self, from: fixture)
    try invocation.validate()

    XCTAssertEqual(invocation.invocationID, "invoke-1")
    XCTAssertEqual(invocation.pluginIdentifier, "dev.hostwright.policy.example")
    XCTAssertEqual(invocation.capability, .policy)
    XCTAssertEqual(invocation.timestamp, "2026-08-02T16:00:00Z")
    XCTAssertEqual(invocation.seed, 42)
    XCTAssertEqual(invocation.limits, .frozen)
    XCTAssertEqual(try JSONDecoder().decode(Invocation.self, from: CanonicalJSON.encode(invocation)), invocation)
  }

  func testLimitsArePositiveAndCannotExceedFrozenCeilings() throws {
    XCTAssertNoThrow(try Limits.frozen.validate())
    XCTAssertNoThrow(try Limits(
      moduleBytes: Limits.frozen.moduleBytes - 1,
      inputBytes: Limits.frozen.inputBytes,
      outputBytes: Limits.frozen.outputBytes,
      memoryBytes: Limits.frozen.memoryBytes,
      normalExecutionMilliseconds: Limits.frozen.normalExecutionMilliseconds,
      absoluteExecutionMilliseconds: Limits.frozen.absoluteExecutionMilliseconds
    ).validate())
    XCTAssertThrowsError(try Limits(
      moduleBytes: Limits.frozen.moduleBytes + 1,
      inputBytes: Limits.frozen.inputBytes,
      outputBytes: Limits.frozen.outputBytes,
      memoryBytes: Limits.frozen.memoryBytes,
      normalExecutionMilliseconds: Limits.frozen.normalExecutionMilliseconds,
      absoluteExecutionMilliseconds: Limits.frozen.absoluteExecutionMilliseconds
    ).validate())
  }

  func testStrictInvocationRejectsUnknownFieldsAndMalformedTimestamp() throws {
    var object = try jsonObject(from: fixture)
    object["unexpected"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    XCTAssertThrowsError(try JSONDecoder().decode(Invocation.self, from: unknown))

    object = try jsonObject(from: fixture)
    object["timestamp"] = "2026-08-02T16:00:00+00:00"
    let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let invocation = try JSONDecoder().decode(Invocation.self, from: malformed)
    XCTAssertThrowsError(try invocation.validate())

    object = try jsonObject(from: fixture)
    var limits = try XCTUnwrap(object["limits"] as? [String: Any])
    limits["unexpected"] = 1
    object["limits"] = limits
    let unknownLimits = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    XCTAssertThrowsError(try JSONDecoder().decode(Invocation.self, from: unknownLimits))
  }

  func testCommandRunnerRejectsMalformedAndOversizeInputWithoutCallingHandler() throws {
    let malformed = CommandRunner.process(input: Data("{".utf8)) { _, _ in
      XCTFail("handler must not run for malformed input")
      return Result(invocationID: "unreachable")
    }
    XCTAssertEqual(malformed.status, 64)
    XCTAssertTrue(malformed.stdout.isEmpty)
    XCTAssertEqual(String(decoding: malformed.stderr, as: UTF8.self),
      "hostwright-wasi-provider-sdk: malformed-invocation\n")

    let oversized = CommandRunner.process(
      input: Data(repeating: 0, count: Limits.frozen.inputBytes + 1)
    ) { _, _ in
      XCTFail("handler must not run for oversized input")
      return Result(invocationID: "unreachable")
    }
    XCTAssertEqual(oversized.status, 64)
    XCTAssertEqual(String(decoding: oversized.stderr, as: UTF8.self),
      "hostwright-wasi-provider-sdk: input-too-large\n")

    var object = try jsonObject(from: fixture)
    var limits = try XCTUnwrap(object["limits"] as? [String: Any])
    limits["inputBytes"] = 1
    object["limits"] = limits
    let belowFrozenButTooSmall = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let lowerLimit = CommandRunner.process(input: belowFrozenButTooSmall) { _, _ in
      XCTFail("handler must not run when the invocation exceeds its lower input limit")
      return Result(invocationID: "unreachable")
    }
    XCTAssertEqual(lowerLimit.status, 64)
    XCTAssertEqual(String(decoding: lowerLimit.stderr, as: UTF8.self),
      "hostwright-wasi-provider-sdk: input-too-large\n")
  }

  func testCommandRunnerRejectsResultInvocationMismatch() throws {
    let output = CommandRunner.process(input: try fixture) { _, _ in
      Result(invocationID: "other")
    }
    XCTAssertEqual(output.status, 64)
    XCTAssertTrue(output.stdout.isEmpty)
    XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self),
      "hostwright-wasi-provider-sdk: invalid-result\n")
  }

  func testCommandRunnerRejectsActionsOutsideInvocationCapability() throws {
    let output = CommandRunner.process(input: try fixture) { invocation, _ in
      Result(
        invocationID: invocation.invocationID,
        actions: [ProposedAction(capability: .network, kind: "request", payload: .object([:]))])
    }
    XCTAssertEqual(output.status, 64)
    XCTAssertTrue(output.stdout.isEmpty)
    XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self),
      "hostwright-wasi-provider-sdk: invalid-result\n")
  }

  func testSeededContextIsDeterministic() throws {
    let invocation = try JSONDecoder().decode(Invocation.self, from: fixture)
    var first = DeterministicContext(invocation: invocation)
    var second = DeterministicContext(invocation: invocation)
    XCTAssertEqual(first.timestamp, "2026-08-02T16:00:00Z")
    XCTAssertEqual(first.nextRandomUInt64(), second.nextRandomUInt64())
    XCTAssertEqual(first.nextRandomUInt64(), second.nextRandomUInt64())
    XCTAssertEqual(first.nextRandomUInt64(), second.nextRandomUInt64())
  }

  func testCommandRunnerWritesCanonicalSortedResult() throws {
    let first = CommandRunner.process(input: try fixture) { invocation, _ in
      Result(
        invocationID: invocation.invocationID,
        actions: [ProposedAction(
          capability: .policy,
          kind: "mutate",
          payload: .object(["z": .integer(2), "a": .integer(1)])
        )],
        diagnostics: [SanitizedDiagnostic(code: "notice", message: "accepted")])
    }
    let second = CommandRunner.process(input: try fixture) { invocation, _ in
      Result(
        invocationID: invocation.invocationID,
        actions: [ProposedAction(
          capability: .policy,
          kind: "mutate",
          payload: .object(["a": .integer(1), "z": .integer(2)])
        )],
        diagnostics: [SanitizedDiagnostic(code: "notice", message: "accepted")])
    }

    XCTAssertEqual(first.status, 0, String(decoding: first.stderr, as: UTF8.self))
    XCTAssertEqual(first.stdout, second.stdout)
    XCTAssertEqual(
      String(decoding: first.stdout, as: UTF8.self),
      "{\"actions\":[{\"capability\":\"policy\",\"kind\":\"mutate\",\"payload\":{\"a\":1,\"z\":2}}],\"diagnostics\":[{\"code\":\"notice\",\"message\":\"accepted\"}],\"invocationID\":\"invoke-1\"}"
    )
  }

  private func jsonObject(from data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
