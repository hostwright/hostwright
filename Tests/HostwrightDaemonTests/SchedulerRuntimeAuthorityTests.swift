import Dispatch
import Foundation
import XCTest

@testable import HostwrightDaemon

final class SchedulerRuntimeAuthorityTests: XCTestCase {
  func testPreemptionMutationDoesNotAdvanceNodeEpochForVictimRemoval() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/HostwrightDaemon/HostwrightDaemonControlService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "let schedulerPreemptionMutation"))
    let end = try XCTUnwrap(
      source.range(
        of: "let schedulerRuntimeInventoryCache",
        range: start.upperBound..<source.endIndex
      )
    )
    let preemptionSource = String(source[start.lowerBound..<end.lowerBound])
    XCTAssertFalse(preemptionSource.contains("recoverNode"))
    XCTAssertTrue(preemptionSource.contains("runtimeAdapter().inventory()"))
    XCTAssertTrue(preemptionSource.contains("schedulerPreemptionFenceEvidence"))
  }

  func testRuntimeWaitTimesOutAndCancelsChild() throws {
    let cancelled = DispatchSemaphore(value: 0)

    XCTAssertThrowsError(
      try HostwrightDaemonControlService.waitForSchedulerRuntime(
        timeoutNanoseconds: 10_000_000,
        pollNanoseconds: 1_000_000
      ) {
        try await withTaskCancellationHandler {
          try await Task.sleep(nanoseconds: 5_000_000_000)
          return ()
        } onCancel: {
          cancelled.signal()
        }
      }
    ) { error in
      XCTAssertEqual(error as? SchedulerRuntimeWaitError, .timedOut)
    }

    XCTAssertEqual(
      cancelled.wait(timeout: .now() + .seconds(1)),
      .success
    )
  }

  func testRuntimeWaitCancellationCancelsChildAndIsBounded() async throws {
    let cancelled = DispatchSemaphore(value: 0)
    let waiter = Task<Void, Error> {
      try HostwrightDaemonControlService.waitForSchedulerRuntime(
        timeoutNanoseconds: 1_000_000_000,
        pollNanoseconds: 1_000_000
      ) {
        try await withTaskCancellationHandler {
          while true {
            try await Task.sleep(nanoseconds: 1_000_000)
          }
        } onCancel: {
          cancelled.signal()
        }
      }
    }

    try await Task.sleep(nanoseconds: 10_000_000)
    waiter.cancel()
    do {
      _ = try await waiter.value
      XCTFail("cancelled scheduler runtime wait unexpectedly succeeded")
    } catch let error as SchedulerRuntimeWaitError {
      XCTAssertEqual(error, .cancelled)
    }
    XCTAssertEqual(
      cancelled.wait(timeout: .now() + .seconds(1)),
      .success
    )
  }

  func testRuntimeWaitRejectsUnboundedLimits() {
    XCTAssertThrowsError(
      try HostwrightDaemonControlService.waitForSchedulerRuntime(
        timeoutNanoseconds: schedulerRuntimeMaximumWaitNanoseconds + 1
      ) {
        ()
      }
    ) { error in
      XCTAssertEqual(error as? SchedulerRuntimeWaitError, .invalidLimit)
    }
  }
}
