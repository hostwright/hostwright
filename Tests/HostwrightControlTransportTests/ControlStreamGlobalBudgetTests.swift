import XCTest
@testable import HostwrightControlTransport

final class ControlStreamGlobalBudgetTests: XCTestCase {
  func testPerSubjectBoundaryAndReleasePermitExactlyOneReplacement() throws {
    let budget = ControlStreamGlobalBudget()
    let subject = "subject-a"
    for index in 0..<ControlStreamGlobalBudget.maximumSubjectStreams {
      try budget.acquire(key: "subject-a-\(index)", subjectID: subject)
    }
    XCTAssertEqual(budget.activeCount, ControlStreamGlobalBudget.maximumSubjectStreams)
    XCTAssertThrowsError(
      try budget.acquire(key: "subject-a-overflow", subjectID: subject)
    ) { error in
      XCTAssertEqual(error as? ControlStreamGlobalBudgetError, .subjectLimit)
    }

    budget.release(key: "subject-a-0")
    try budget.acquire(key: "subject-a-replacement", subjectID: subject)
    XCTAssertEqual(budget.activeCount, ControlStreamGlobalBudget.maximumSubjectStreams)
  }

  func testGlobalBoundaryAcrossSubjectsAndReleasePermitExactlyOneReplacement() throws {
    let budget = ControlStreamGlobalBudget()
    for index in 0..<ControlStreamGlobalBudget.maximumGlobalStreams {
      try budget.acquire(key: "global-\(index)", subjectID: "subject-\(index)")
    }
    XCTAssertEqual(budget.activeCount, ControlStreamGlobalBudget.maximumGlobalStreams)
    XCTAssertThrowsError(
      try budget.acquire(key: "global-overflow", subjectID: "replacement-subject")
    ) { error in
      XCTAssertEqual(error as? ControlStreamGlobalBudgetError, .globalLimit)
    }

    budget.release(key: "global-0")
    try budget.acquire(key: "global-replacement", subjectID: "replacement-subject")
    XCTAssertEqual(budget.activeCount, ControlStreamGlobalBudget.maximumGlobalStreams)
  }

  func testDuplicateAcquireAndDuplicateReleaseDoNotChangeOwnershipCounts() throws {
    let budget = ControlStreamGlobalBudget()
    try budget.acquire(key: "owned", subjectID: "subject")
    try budget.acquire(key: "owned", subjectID: "other-subject")
    XCTAssertEqual(budget.activeCount, 1)
    budget.release(key: "owned")
    budget.release(key: "owned")
    XCTAssertEqual(budget.activeCount, 0)
    XCTAssertNoThrow(try budget.acquire(key: "replacement", subjectID: "subject"))
  }
}
