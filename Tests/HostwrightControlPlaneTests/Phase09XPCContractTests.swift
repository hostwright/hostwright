import Foundation
import XCTest

@testable import HostwrightControlPlane

final class Phase09XPCContractTests: XCTestCase {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  private var contracts: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("contracts/v0.0.2", isDirectory: true)
  }

  func testFrozenServiceIdentityAndSandboxEntitlementAreExact() throws {
    XCTAssertEqual(XPCServiceContract.serviceIdentifier, "dev.hostwright.xpc-provider")
    XCTAssertEqual(XPCServiceContract.teamIdentifier, "993YC3JY4Q")
    XCTAssertEqual(
      XPCServiceContract.requiredEntitlements,
      ["com.apple.security.app-sandbox": .bool(true)])
    XCTAssertEqual(XPCRequest.maximumMessageBytes, 1_048_576)
    XCTAssertNoThrow(try XPCServiceContract().validate())

    XCTAssertThrowsError(
      try XPCServiceContract(serviceIdentifier: "dev.hostwright.other").validate())
    XCTAssertThrowsError(
      try XPCServiceContract(teamIdentifier: "DIFFERENT").validate())
    XCTAssertThrowsError(
      try XPCServiceContract(entitlements: [:]).validate())
    XCTAssertThrowsError(
      try XPCServiceContract(entitlements: [
        "com.apple.security.app-sandbox": .bool(true), "extra": .bool(true),
      ]).validate())
  }

  func testRequestAndCancellationCombinationsAreExclusiveAndBounded() throws {
    XCTAssertNoThrow(
      try XPCRequest(
        requestID: "request-1", operation: .codeIdentityProof, timeoutMilliseconds: 1
      ).validate())
    XCTAssertNoThrow(
      try XPCRequest(
        requestID: "request-1", operation: .codeIdentityProof, timeoutMilliseconds: 5_000
      ).validate())
    XCTAssertNoThrow(try XPCRequest(kind: .cancel, requestID: "request-1", operation: nil).validate())

    for request in [
      XPCRequest(protocolVersion: 0, requestID: "request-1", timeoutMilliseconds: 1),
      XPCRequest(protocolVersion: 2, requestID: "request-1", timeoutMilliseconds: 1),
      XPCRequest(requestID: "", timeoutMilliseconds: 1),
      XPCRequest(requestID: "request-1", timeoutMilliseconds: nil),
      XPCRequest(requestID: "request-1", timeoutMilliseconds: 0),
      XPCRequest(requestID: "request-1", timeoutMilliseconds: 5_001),
      XPCRequest(kind: .cancel, requestID: "request-1", operation: .codeIdentityProof),
      XPCRequest(kind: .cancel, requestID: "request-1", operation: nil, timeoutMilliseconds: 1),
    ] {
      XCTAssertThrowsError(try request.validate())
    }
  }

  func testCodeIdentityProofAcceptsOnlyLowercaseFortyOrSixtyFourCharacterCDHashes() throws {
    for hash in [String(repeating: "a", count: 40), String(repeating: "b", count: 64)] {
      XCTAssertNoThrow(try proof(hash: hash).validate())
    }

    for hash in [
      String(repeating: "a", count: 39), String(repeating: "a", count: 41),
      String(repeating: "a", count: 63), String(repeating: "a", count: 65),
      String(repeating: "A", count: 40), String(repeating: "g", count: 40),
    ] {
      XCTAssertThrowsError(try proof(hash: hash).validate())
    }
    XCTAssertThrowsError(
      try CodeIdentityProof(
        teamIdentifier: "OTHERTEAM", signingIdentifier: XPCServiceContract.serviceIdentifier,
        codeDirectoryHash: String(repeating: "a", count: 40)
      ).validate())
    XCTAssertThrowsError(
      try CodeIdentityProof(
        signingIdentifier: "dev.hostwright.other", codeDirectoryHash: String(repeating: "a", count: 40)
      ).validate())
  }

  func testResponseStatusPayloadsAreMutuallyExclusive() throws {
    let validProof = proof(hash: String(repeating: "a", count: 40))
    let validError = SanitizedError(code: "failed", message: "safe diagnostic")

    XCTAssertNoThrow(
      try XPCResponse(requestID: "request-1", status: .completed, proof: validProof).validate())
    XCTAssertNoThrow(try XPCResponse(requestID: "request-1", status: .cancelled).validate())
    XCTAssertNoThrow(
      try XPCResponse(requestID: "request-1", status: .error, error: validError).validate())

    for response in [
      XPCResponse(requestID: "", status: .cancelled),
      XPCResponse(protocolVersion: 0, requestID: "request-1", status: .cancelled),
      XPCResponse(protocolVersion: 2, requestID: "request-1", status: .cancelled),
      XPCResponse(requestID: "request-1", status: .completed),
      XPCResponse(requestID: "request-1", status: .completed, proof: validProof, error: validError),
      XPCResponse(requestID: "request-1", status: .cancelled, proof: validProof),
      XPCResponse(requestID: "request-1", status: .cancelled, error: validError),
      XPCResponse(requestID: "request-1", status: .error),
      XPCResponse(requestID: "request-1", status: .error, proof: validProof, error: validError),
      XPCResponse(
        requestID: "request-1", status: .error,
        error: SanitizedError(code: "", message: "safe diagnostic")),
    ] {
      XCTAssertThrowsError(try response.validate())
    }
  }

  func testFrozenRequestFixtureRoundTrips() throws {
    let fixture = try Data(contentsOf: contracts.appendingPathComponent("phase09-xpc-v1.json"))
    let request = try Phase09StrictDecoder.decode(
      XPCRequest.self, from: fixture,
      allowedKeys: ["protocolVersion", "kind", "requestID", "operation", "timeoutMilliseconds"],
      requiredKeys: ["protocolVersion", "kind", "requestID", "operation", "timeoutMilliseconds"],
      decoder: decoder)
    try request.validate()
    XCTAssertEqual(request.protocolVersion, 1)
    XCTAssertEqual(request.kind, .request)
    XCTAssertEqual(request.requestID, "phase09-xpc-1")
    XCTAssertEqual(request.operation, .codeIdentityProof)
    XCTAssertEqual(request.timeoutMilliseconds, 5_000)
    XCTAssertEqual(try decoder.decode(XPCRequest.self, from: encoder.encode(request)), request)
  }

  func testFrozenResponseFixturesRoundTripExactShapes() throws {
    let fixtures: [(String, XPCResponseStatus, Set<String>)] = [
      (
        "phase09-xpc-response-completed-v1.json", .completed,
        ["protocolVersion", "requestID", "status", "proof"]
      ),
      (
        "phase09-xpc-response-cancelled-v1.json", .cancelled,
        ["protocolVersion", "requestID", "status"]
      ),
      (
        "phase09-xpc-response-error-v1.json", .error,
        ["protocolVersion", "requestID", "status", "error"]
      ),
    ]
    for (name, status, keys) in fixtures {
      let data = try Data(contentsOf: contracts.appendingPathComponent(name))
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(Set(object.keys), keys, name)
      let response = try Phase09StrictDecoder.decode(
        XPCResponse.self, from: data, allowedKeys: keys, requiredKeys: keys,
        decoder: decoder)
      try response.validate()
      XCTAssertEqual(response.status, status)
      XCTAssertEqual(try decoder.decode(XPCResponse.self, from: encoder.encode(response)), response)

      if status == .completed {
        let proof = try XCTUnwrap(object["proof"] as? [String: Any])
        XCTAssertEqual(Set(proof.keys), [
          "teamIdentifier", "signingIdentifier", "codeDirectoryHash", "entitlementProjection",
        ])
        let projection = try XCTUnwrap(
          proof["entitlementProjection"] as? [String: Any])
        XCTAssertEqual(Set(projection.keys), ["com.apple.security.app-sandbox"])
        XCTAssertEqual(projection["com.apple.security.app-sandbox"] as? Bool, true)
      } else if status == .error {
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(Set(error.keys), ["code", "message"])
      }
    }
  }

  private func proof(hash: String) -> CodeIdentityProof {
    CodeIdentityProof(
      signingIdentifier: XPCServiceContract.serviceIdentifier,
      codeDirectoryHash: hash)
  }
}
