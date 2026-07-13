import Foundation
import XCTest
@testable import HostwrightControl
@testable import HostwrightCore

final class ControlV2ContractTests: XCTestCase {
    func testV2IsTheDefaultControlContract() throws {
        XCTAssertEqual(LocalControlRequest(requestID: "request-1", operation: .plan).apiVersion, HostwrightContractVersions.controlAPI)
        XCTAssertEqual(
            LocalControlResponse(requestID: "request-1", operation: .plan, success: true, exitCode: 0).apiVersion,
            HostwrightContractVersions.controlAPI
        )
        XCTAssertNoThrow(
            try LocalControlRequestParser.parse(
                Data(#"{"apiVersion":2,"requestID":"request-1","operation":"plan"}"#.utf8)
            )
        )
    }

    func testV1ControlRequestsFailClosedAfterTheBreakingContractReset() {
        XCTAssertThrowsError(
            try LocalControlRequestParser.parse(
                Data(#"{"apiVersion":1,"requestID":"request-1","operation":"plan"}"#.utf8)
            )
        )
    }

    func testCheckedInControlV2GoldensDecodeThroughProductionContracts() throws {
        let root = contractRoot()
        let requestData = try Data(contentsOf: root.appendingPathComponent("control-plan-request.json"))
        let responseData = try Data(contentsOf: root.appendingPathComponent("control-plan-response.json"))

        let request = try LocalControlRequestParser.parse(requestData)
        XCTAssertEqual(request, LocalControlRequest(requestID: "golden-plan-1", operation: .plan))
        let response = try JSONDecoder().decode(LocalControlResponse.self, from: responseData)
        XCTAssertEqual(response.apiVersion, HostwrightContractVersions.controlAPI)
        XCTAssertEqual(response.requestID, "golden-plan-1")
        XCTAssertEqual(response.operation, .plan)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.exitCode, 0)
        XCTAssertNotNil(response.result)
    }

    private func contractRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v0.0.2", isDirectory: true)
    }
}
