import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightDaemon

final class SchedulerProjectPreemptionControlTests: XCTestCase {
  private let projectID = "project-a"

  func testSchedulerControlErrorsAreRedacted() throws {
    let sensitiveProject = "project-secret-tenant"
    let malformedInput: ControlPlaneJSONValue = .object([
      "pendingWorkloads": .array([
        .object(["projectID": .string(sensitiveProject)])
      ]),
      "nodes": .array([]),
      "unexpected": .string("victim-budget-secret")
    ])
    let request = ControlRequestEnvelope(
      protocolRevision: .current,
      requestID: "scheduler-redaction",
      operation: SchedulerControlOperation.simulate.rawValue,
      timeoutMilliseconds: 1_000,
      body: .object([
        "projectID": .string(projectID),
        "input": malformedInput
      ])
    )

    let response = try XCTUnwrap(SchedulerControlOperations.handle(request: request))
    assertRedactedInvalidRequest(response)
    XCTAssertFalse(response.error?.message.contains(sensitiveProject) == true)
    XCTAssertFalse(response.error?.message.contains("victim-budget-secret") == true)
  }

  private func assertRedactedInvalidRequest(
    _ response: ControlResponseEnvelope,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(response.status, .rejected, file: file, line: line)
    XCTAssertEqual(response.reasonCode, .invalidRequest, file: file, line: line)
    XCTAssertEqual(
      response.error,
      SanitizedError(
        code: "schedulerInvalidRequest",
        message: "The scheduler operation was rejected safely."
      ),
      file: file,
      line: line
    )
    XCTAssertNil(response.result, file: file, line: line)
  }

}
