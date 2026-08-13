import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightObservability
@testable import HostwrightState

final class TraceCLIIntegrationTests: XCTestCase {
    func testDetachedCLIBridgePreservesTheOwningTraceContext() throws {
        let capture = CLITraceCapture()
        let session = try HostwrightTraceSession(
            traceID: "11111111-1111-4111-8111-111111111111",
            processCorrelationID: "22222222-2222-4222-8222-222222222222",
            selected: true
        )
        session.attach(capture)
        try HostwrightTraceContext.withSession(session) {
            let root = session.start(.cliRequest)
            try HostwrightTraceContext.withSpan(root) {
                try hostwrightWaitForAsync {
                    await HostwrightTraceContext.withSpan(.providerObserve) {
                        await Task.yield()
                    }
                }
            }
            _ = session.finish(root, status: .succeeded)
            session.complete(status: .succeeded)
        }
        let root = try XCTUnwrap(capture.records.first { $0.name == .cliRequest })
        let child = try XCTUnwrap(capture.records.first { $0.name == .providerObserve })
        XCTAssertEqual(child.parentSpanID, root.spanID)
        XCTAssertEqual(child.traceID, root.traceID)
    }

    func testParserAcceptsOnlyInspectAndConsentBoundExport() throws {
        let traceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "traces", "inspect", "--trace-id", traceID, "--limit", "7",
                "--state-db", "/tmp/state.sqlite", "--output", "json"
            ]),
            .traces(options: TraceCLIOptions(
                action: .inspect(traceID: traceID, limit: 7),
                stateDatabasePath: "/tmp/state.sqlite",
                output: .json
            ))
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "traces", "export", "--trace-id", traceID,
                "--output-path", "/tmp/trace.json", "--confirm-trace", digest
            ]),
            .traces(options: TraceCLIOptions(
                action: .export(
                    traceID: traceID,
                    outputPath: "/tmp/trace.json",
                    confirmationSHA256: digest
                ),
                stateDatabasePath: nil,
                output: .text
            ))
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["traces", "export"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "traces", "inspect", "--trace-id", traceID.uppercased()
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "traces", "export", "--trace-id", traceID, "--output-path", "relative.json",
            "--confirm-trace", digest
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "traces", "inspect", "--limit", "101"
        ]))
    }

    func testInspectAndConfirmedExportUseExistingStateAndPrivateExactFile() throws {
        try withStore { root, store, traceID in
            var environment = CLIEnvironment.live
            environment.traceDate = {
                ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
            }
            let inspect = try HostwrightCLI.run(
                command: .traces(options: TraceCLIOptions(
                    action: .inspect(traceID: traceID, limit: 1),
                    stateDatabasePath: store.path,
                    output: .json
                )),
                environment: environment
            )
            let page = try JSONDecoder().decode(
                HostwrightTracePage.self,
                from: Data(inspect.standardOutput.utf8)
            )
            let trace = try XCTUnwrap(page.traces.first)
            XCTAssertTrue(trace.complete)
            XCTAssertEqual(trace.status, .failed)
            XCTAssertFalse(page.automaticUpload)

            let outputPath = root.appendingPathComponent("trace-v1.json").path
            let result = try HostwrightCLI.run(
                command: .traces(options: TraceCLIOptions(
                    action: .export(
                        traceID: traceID,
                        outputPath: outputPath,
                        confirmationSHA256: trace.traceSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .json
                )),
                environment: environment
            )
            let receipt = try JSONDecoder().decode(
                HostwrightTraceExportReceipt.self,
                from: Data(result.standardOutput.utf8)
            )
            XCTAssertEqual(receipt.traceSHA256, trace.traceSHA256)
            XCTAssertFalse(receipt.automaticUpload)
            XCTAssertEqual(receipt.ownership, "operator-owned")
            let exported = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            XCTAssertEqual(try JSONDecoder().decode(HostwrightTraceView.self, from: exported), trace)
            let attributes = try FileManager.default.attributesOfItem(atPath: outputPath)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .traces(options: TraceCLIOptions(
                    action: .export(
                        traceID: traceID,
                        outputPath: outputPath,
                        confirmationSHA256: trace.traceSHA256
                    ),
                    stateDatabasePath: store.path,
                    output: .text
                )),
                environment: environment
            ))
        }
    }

    func testStaleConfirmationCancellationAndSymlinkParentLeaveNoArtifact() throws {
        try withStore { root, store, traceID in
            var environment = CLIEnvironment.live
            let trace = try store.traces.completeTrace(traceID)
            let stalePath = root.appendingPathComponent("stale.json").path
            XCTAssertThrowsError(try export(
                store: store,
                traceID: traceID,
                path: stalePath,
                digest: String(repeating: "0", count: 64),
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stalePath))

            environment.traceCancelled = { true }
            let cancelledPath = root.appendingPathComponent("cancelled.json").path
            XCTAssertThrowsError(try export(
                store: store,
                traceID: traceID,
                path: cancelledPath,
                digest: trace.traceSHA256,
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledPath))

            let linked = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
            environment.traceCancelled = { false }
            let linkedPath = linked.appendingPathComponent("trace.json").path
            XCTAssertThrowsError(try export(
                store: store,
                traceID: traceID,
                path: linkedPath,
                digest: trace.traceSHA256,
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("trace.json").path
            ))
        }
    }

    func testMissingDatabaseIsNotCreated() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("missing.sqlite").path
        XCTAssertThrowsError(try HostwrightCLI.run(
            command: .traces(options: TraceCLIOptions(
                action: .inspect(traceID: nil, limit: 20),
                stateDatabasePath: path,
                output: .json
            ))
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    private func export(
        store: SQLiteStateStore,
        traceID: String,
        path: String,
        digest: String,
        environment: CLIEnvironment
    ) throws -> CLIRunResult {
        try HostwrightCLI.run(
            command: .traces(options: TraceCLIOptions(
                action: .export(
                    traceID: traceID,
                    outputPath: path,
                    confirmationSHA256: digest
                ),
                stateDatabasePath: store.path,
                output: .json
            )),
            environment: environment
        )
    }

    private func withStore(
        _ body: (URL, SQLiteStateStore, String) throws -> Void
    ) throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        let traceID = "11111111-1111-4111-8111-111111111111"
        let span = try HostwrightTraceSpanRecord(
            traceID: traceID,
            spanID: "22222222-2222-4222-8222-222222222222",
            parentSpanID: nil,
            processCorrelationID: "33333333-3333-4333-8333-333333333333",
            name: .cliRequest,
            status: .failed,
            startedAt: "2026-08-01T11:59:59Z",
            endedAt: "2026-08-01T12:00:00Z",
            durationMilliseconds: 1_000,
            depth: 0,
            attributes: [
                try HostwrightTraceAttribute(key: .sampling, value: "failure-override"),
                try HostwrightTraceAttribute(key: .droppedSpans, value: "0")
            ]
        )
        XCTAssertEqual(StateTraceSink(store: store).record(span).status, .persisted)
        try body(root, store, traceID)
    }

    private func privateRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.path
        let base = raw.hasPrefix("/var/") ? "/private\(raw)" : raw
        let root = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("hostwright-trace-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
}

private final class CLITraceCapture: HostwrightTraceSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostwrightTraceSpanRecord] = []

    var records: [HostwrightTraceSpanRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ span: HostwrightTraceSpanRecord) -> HostwrightTraceEmission {
        lock.lock()
        storage.append(span)
        lock.unlock()
        return HostwrightTraceEmission(status: .persisted)
    }
}
