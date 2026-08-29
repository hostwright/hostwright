import Foundation
import HostwrightControl
import XCTest

final class LocalControlProfileIntegrationTests: XCTestCase {
  func testLifecycleProfileBindingParsesAndMapsToExactCLIArguments() throws {
    let digest = String(repeating: "a", count: 64)
    let data = Data(
      """
      {"apiVersion":2,"requestID":"profile-1","operation":"up","dryRun":true,"workloadProfileID":"restricted","profileHash":"\(digest)"}
      """.utf8)
    let request = try LocalControlRequestParser.parse(data)
    XCTAssertEqual(request.workloadProfileID, "restricted")
    XCTAssertEqual(request.profileHash, digest)
    XCTAssertEqual(
      try LocalControlAPI.commandArguments(
        for: request,
        configuration: LocalControlConfiguration(
          manifestPath: "/tmp/hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite")),
      [
        "up", "/tmp/hostwright.yaml", "--state-db", "/tmp/state.sqlite", "--dry-run",
        "--workload-profile-id", "restricted", "--workload-profile-hash", digest,
        "--output", "json",
      ])
  }

  func testProfileBindingRequiresExactPairAndLifecycleOperation() {
    let digest = String(repeating: "a", count: 64)
    let invalid = [
      #"{"apiVersion":2,"requestID":"p1","operation":"up","dryRun":true,"workloadProfileID":"restricted"}"#,
      "{\"apiVersion\":2,\"requestID\":\"p2\",\"operation\":\"up\",\"dryRun\":true,\"profileHash\":\"\(digest)\"}",
      "{\"apiVersion\":2,\"requestID\":\"p3\",\"operation\":\"status\",\"workloadProfileID\":\"restricted\",\"profileHash\":\"\(digest)\"}",
      "{\"apiVersion\":2,\"requestID\":\"p4\",\"operation\":\"up\",\"dryRun\":true,\"workloadProfileID\":\"../unsafe\",\"profileHash\":\"\(digest)\"}",
    ]
    for value in invalid {
      XCTAssertThrowsError(try LocalControlRequestParser.parse(Data(value.utf8)))
    }
  }
}
