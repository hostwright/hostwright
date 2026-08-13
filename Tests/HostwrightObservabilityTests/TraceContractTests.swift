import Foundation
import XCTest
@testable import HostwrightObservability

final class TraceContractTests: XCTestCase {
    func testContractIsVersionedFixedAndBounded() {
        XCTAssertEqual(HostwrightTraceContract.schemaVersion, 1)
        XCTAssertEqual(HostwrightTraceContract.maximumSpans, 64)
        XCTAssertEqual(HostwrightTraceContract.maximumDepth, 12)
        XCTAssertEqual(HostwrightTraceContract.maximumAttributes, 8)
        XCTAssertEqual(HostwrightTraceContract.maximumEventLinks, 16)
        XCTAssertEqual(HostwrightTraceContract.maximumOperationLinks, 16)
        XCTAssertEqual(HostwrightTraceSpanName.allCases.count, 12)
        XCTAssertEqual(HostwrightTraceAttributeKey.allCases.count, 10)
        XCTAssertThrowsError(try HostwrightTraceAttribute(key: .component, value: "project-secret"))
        XCTAssertThrowsError(try HostwrightTraceAttribute(key: .reasonCode, value: "credential=raw"))
        XCTAssertThrowsError(try HostwrightTraceAttribute(key: .command, value: "phase09-api"))
    }

    func testDeterministicSamplingRetainsOnlySummaryAndFailureOverrideRetainsChildren() throws {
        let successSink = RecordingTraceSink()
        let success = try makeSession(selected: false)
        success.attach(successSink)
        HostwrightTraceContext.withSession(success) {
            let root = success.start(.cliRequest)
            HostwrightTraceContext.withSpan(root) {
                let child = success.start(.planCompile)
                _ = success.finish(child, status: .succeeded)
            }
            _ = success.finish(
                root,
                status: .succeeded,
                attributes: success.rootCompletionAttributes(sampling: "deterministic-1-of-16")
            )
            success.complete(status: .succeeded)
        }
        XCTAssertEqual(successSink.records.map(\.name), [.cliRequest])
        XCTAssertEqual(
            successSink.records[0].attributes.first(where: { $0.key == .droppedSpans })?.value,
            "1"
        )

        let failureSink = RecordingTraceSink()
        let failure = try makeSession(selected: false)
        failure.attach(failureSink)
        HostwrightTraceContext.withSession(failure) {
            let root = failure.start(.cliRequest)
            HostwrightTraceContext.withSpan(root) {
                let child = failure.start(.providerApply)
                _ = failure.finish(child, status: .failed)
            }
            _ = failure.finish(
                root,
                status: .failed,
                attributes: failure.rootCompletionAttributes(sampling: "failure-override")
            )
            failure.complete(status: .failed)
        }
        XCTAssertEqual(Set(failureSink.records.map(\.name)), [.cliRequest, .providerApply])
        let failureRoot = try XCTUnwrap(failureSink.records.first { $0.name == .cliRequest })
        XCTAssertEqual(
            failureRoot.attributes.first(where: { $0.key == .droppedSpans })?.value,
            "0"
        )
    }

    func testConcurrentChildContextsStayUnderTheOwningRoot() async throws {
        let sink = RecordingTraceSink()
        let session = try makeSession(selected: true)
        session.attach(sink)
        await HostwrightTraceContext.withSession(session) {
            let root = session.start(.daemonReconciliation)
            await HostwrightTraceContext.withSpan(root) {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            await HostwrightTraceContext.withSpan(.providerObserve) {
                                await Task.yield()
                            }
                        }
                    }
                }
            }
            _ = session.finish(
                root,
                status: .succeeded,
                attributes: session.rootCompletionAttributes(sampling: "deterministic-1-of-16")
            )
            session.complete(status: .succeeded)
        }
        let root = try XCTUnwrap(sink.records.first { $0.name == .daemonReconciliation })
        let children = sink.records.filter { $0.name == .providerObserve }
        XCTAssertEqual(children.count, 8)
        XCTAssertTrue(children.allSatisfy { $0.parentSpanID == root.spanID && $0.depth == 1 })
        XCTAssertEqual(Set(sink.records.map(\.traceID)), [root.traceID])
    }

    func testLimitsAndDegradedSinkNeverThrowIntoControlFlow() throws {
        let sink = RecordingTraceSink(degraded: true)
        let session = try makeSession(selected: true)
        session.attach(sink)
        HostwrightTraceContext.withSession(session) {
            for _ in 0..<(HostwrightTraceContract.maximumSpans + 10) {
                let token = session.start(.statePersist)
                _ = session.finish(token, status: .succeeded)
            }
            session.complete(status: .succeeded)
        }
        XCTAssertEqual(sink.records.count, HostwrightTraceContract.maximumSpans)
    }

    func testSensitiveLookingEventAndOperationLinksAreDroppedAtConstruction() throws {
        let sink = RecordingTraceSink()
        let session = try makeSession(selected: true)
        session.attach(sink)
        HostwrightTraceContext.withSession(session) {
            let root = session.start(.cliRequest)
            session.linkEvent("event-AKIA1234567890ABCDEF")
            session.linkOperation("operation-ghp_abcdefghijklmnopqrstuvwxyz")
            session.linkEvent("event-safe-123")
            session.linkOperation("operation-safe-456")
            _ = session.finish(root, status: .failed)
            session.complete(status: .failed)
        }
        let root = try XCTUnwrap(sink.records.first)
        XCTAssertEqual(root.eventIDs, ["event-safe-123"])
        XCTAssertEqual(root.operationIDs, ["operation-safe-456"])
    }

    private func makeSession(selected: Bool) throws -> HostwrightTraceSession {
        try HostwrightTraceSession(
            traceID: "11111111-1111-4111-8111-111111111111",
            processCorrelationID: "22222222-2222-4222-8222-222222222222",
            selected: selected
        )
    }
}

private final class RecordingTraceSink: HostwrightTraceSinking, @unchecked Sendable {
    private let lock = NSLock()
    private let degraded: Bool
    private var storage: [HostwrightTraceSpanRecord] = []

    init(degraded: Bool = false) {
        self.degraded = degraded
    }

    var records: [HostwrightTraceSpanRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ span: HostwrightTraceSpanRecord) -> HostwrightTraceEmission {
        lock.lock()
        storage.append(span)
        lock.unlock()
        return HostwrightTraceEmission(status: degraded ? .degraded : .persisted)
    }
}
