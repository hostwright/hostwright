import HostwrightControlPlane
import HostwrightXPCProvider
import XCTest
import XPC

final class XPCProviderCodecTests: XCTestCase {
  func testRequestAndCancelRoundTripThroughExactDictionary() throws {
    let request = XPCRequest(requestID: "request-1", timeoutMilliseconds: 5_000)
    XCTAssertEqual(
      try XPCProviderMessageCodec.decodeRequest(XPCProviderMessageCodec.encode(request)), request)
    let cancel = XPCRequest(
      kind: .cancel, requestID: request.requestID, operation: nil, timeoutMilliseconds: nil)
    XCTAssertEqual(
      try XPCProviderMessageCodec.decodeRequest(XPCProviderMessageCodec.encode(cancel)), cancel)
  }

  func testUnknownOversizedAndWrongTypedFieldsFailClosed() throws {
    let message = try XPCProviderMessageCodec.encode(XPCRequest(
      requestID: "request-2", timeoutMilliseconds: 5_000))
    let bytes = [UInt8](repeating: 0, count: XPCRequest.maximumMessageBytes + 1)
    bytes.withUnsafeBytes {
      xpc_dictionary_set_data(message, "unexpected", $0.baseAddress, $0.count)
    }
    XCTAssertThrowsError(try XPCProviderMessageCodec.decodeRequest(message))

    let wrongType = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(wrongType, "protocolVersion", "1")
    xpc_dictionary_set_string(wrongType, "kind", "request")
    xpc_dictionary_set_string(wrongType, "requestID", "request-2")
    xpc_dictionary_set_string(wrongType, "operation", "codeIdentityProof")
    xpc_dictionary_set_uint64(wrongType, "timeoutMilliseconds", 5_000)
    XCTAssertThrowsError(try XPCProviderMessageCodec.decodeRequest(wrongType))
  }

  func testEveryResponseShapeRoundTripsAndCannotOverlap() throws {
    let proof = CodeIdentityProof(
      signingIdentifier: XPCServiceContract.serviceIdentifier,
      codeDirectoryHash: String(repeating: "a", count: 40))
    let responses = [
      XPCResponse(requestID: "response-1", status: .completed, proof: proof),
      XPCResponse(requestID: "response-2", status: .cancelled),
      XPCResponse(
        requestID: "response-3", status: .error,
        error: SanitizedError(code: "rejected", message: "Request rejected.")),
    ]
    for response in responses {
      let encoded = try XPCProviderMessageCodec.encode(response)
      XCTAssertEqual(try XPCProviderMessageCodec.decodeResponse(encoded), response)
      var keys = Set<String>()
      xpc_dictionary_apply(encoded) { key, _ in keys.insert(String(cString: key)); return true }
      switch response.status {
      case .completed:
        XCTAssertEqual(keys, [
          "protocolVersion", "requestID", "status", "teamIdentifier", "signingIdentifier",
          "codeDirectoryHash", "entitlementProjection",
        ])
        let projection = try XCTUnwrap(
          xpc_dictionary_get_value(encoded, "entitlementProjection"))
        var projectionKeys = Set<String>()
        xpc_dictionary_apply(projection) {
          key, _ in projectionKeys.insert(String(cString: key)); return true
        }
        XCTAssertEqual(projectionKeys, ["com.apple.security.app-sandbox"])
      case .cancelled:
        XCTAssertEqual(keys, ["protocolVersion", "requestID", "status"])
      case .error:
        XCTAssertEqual(keys, [
          "protocolVersion", "requestID", "status", "errorCode", "errorMessage",
        ])
      }
    }
    let overlapping = try XPCProviderMessageCodec.encode(responses[0])
    xpc_dictionary_set_string(overlapping, "errorCode", "unexpected")
    XCTAssertThrowsError(try XPCProviderMessageCodec.decodeResponse(overlapping))
  }

  func testFrozenRequirementsAndServiceNameValidation() throws {
    XCTAssertTrue(XPCProviderPeerRequirements.service.contains(
      "identifier \"dev.hostwright.xpc-provider\""))
    XCTAssertTrue(XPCProviderPeerRequirements.service.contains(
      "entitlement[\"com.apple.security.app-sandbox\"]"))
    XCTAssertTrue(XPCProviderPeerRequirements.daemon.contains("identifier \"hostwrightd\""))
    XCTAssertNoThrow(try XPCProviderClient())
    XCTAssertThrowsError(try XPCProviderClient(serviceName: "bad/name"))
  }
}
