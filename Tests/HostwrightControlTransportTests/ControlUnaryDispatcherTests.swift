import Foundation
import HostwrightCore
import HostwrightControlPlane
import XCTest
@testable import HostwrightControlTransport

final class ControlUnaryDispatcherTests: XCTestCase {
    func testDisconnectCancelsDispatchedRequestContext() throws {
        let started = DispatchSemaphore(value: 0)
        let finished = expectation(description: "request observed cancellation")
        let context = ControlStreamConnectionContext(
            descriptor: -1, globalBudget: ControlStreamGlobalBudget(), validateSession: {}
        )
        let dispatcher = ControlUnaryDispatcher(descriptor: -1, context: context) { _ in
            defer { finished.fulfill() }
            let token = try XCTUnwrap(HostwrightCancellationContext.token)
            started.signal()
            let deadline = Date().addingTimeInterval(2)
            while !token.isCancelled && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertTrue(token.isCancelled)
            throw CancellationError()
        }
        try dispatcher.submit(ControlRequestEnvelope(
            requestID: "disconnect-context", operation: "status", timeoutMilliseconds: 3_000
        ))
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        dispatcher.cancel()
        wait(for: [finished], timeout: 3)
        dispatcher.drain()
        XCTAssertNil(HostwrightCancellationContext.token)
    }
}
