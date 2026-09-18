import Foundation
import HostwrightCore
import XCTest
@testable import HostwrightCLI

final class CLIAsyncCancellationTests: XCTestCase {
    func testPreCancelledConnectionDoesNotStartWork() {
        let token = HostwrightCancellationToken()
        token.cancel()
        XCTAssertThrowsError(try HostwrightCancellationContext.$token.withValue(token) {
            try hostwrightWaitForAsync { XCTFail("Cancelled work must not start") }
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testAlreadyCancelledTaskDoesNotStartWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try hostwrightWaitForAsync { XCTFail("Cancelled work must not start") }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }

    func testConnectionCancellationReachesAsyncWorkAndWaitsForCleanup() throws {
        let token = HostwrightCancellationToken()
        let started = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let finished = expectation(description: "cancelled operation finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try HostwrightCancellationContext.$token.withValue(token) {
                    try hostwrightWaitForAsync {
                        defer { cleaned.signal() }
                        started.signal()
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                    }
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(cleaned.wait(timeout: .now()), .success)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        token.cancel()
        wait(for: [finished], timeout: 2)
    }
}
