import Foundation
import HostwrightCLI
import HostwrightObservability
import XCTest

final class ObservabilityCLIIntegrationTests: XCTestCase {
    func testStatusParserAndVersionedJSONContract() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["observability", "status", "--json"]),
            .observabilityStatus(output: .json)
        )
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: ["observability", "status", "--enabled"])
        )

        var environment = CLIEnvironment.live
        environment.observabilitySink = DisabledHostwrightLogSink()
        environment.observabilityCorrelationID = { "99999999-aaaa-bbbb-cccc-dddddddddddd" }
        let result = HostwrightCLI.run(
            arguments: ["observability", "status", "--json"],
            environment: environment
        )
        XCTAssertEqual(result.exitCode, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["subsystem"] as? String, "dev.hostwright")
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["durableAuthority"] as? String, "sqlite-event-ledger-v1")
        XCTAssertEqual(object["rotationAuthority"] as? String, "macos-unified-logging")
        XCTAssertEqual(object["automaticUpload"] as? Bool, false)
        XCTAssertEqual(object["maximumActiveSignposts"] as? Int, 64)
    }

    func testSuccessfulCommandEmitsOneCorrelatedStartAndSuccessWithoutOutputContent() {
        let sink = CLILogCapture()
        var environment = CLIEnvironment.live
        environment.observabilitySink = sink
        environment.observabilityCorrelationID = { "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }

        let result = HostwrightCLI.run(arguments: ["--version"], environment: environment)

        XCTAssertEqual(result.exitCode, 0)
        let records = sink.records()
        XCTAssertEqual(records.map(\.reason), [.cliStarted, .cliSucceeded])
        XCTAssertEqual(Set(records.map(\.correlationID)), ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
        XCTAssertEqual(records.last?.outcome, .succeeded)
        XCTAssertEqual(records.last?.fields.first(where: { $0.name == .exitCode })?.value, "0")
        XCTAssertFalse(records.map(\.canonicalMessage).joined().contains(result.standardOutput))
    }

    func testUsageFailureDoesNotLogUntrustedArgumentOrMisleadingSuccess() {
        let sink = CLILogCapture()
        var environment = CLIEnvironment.live
        environment.observabilitySink = sink
        environment.observabilityCorrelationID = { "bbbbbbbb-cccc-dddd-eeee-ffffffffffff" }

        let result = HostwrightCLI.run(
            arguments: ["arbitrary-supersecret-command"],
            environment: environment
        )

        XCTAssertNotEqual(result.exitCode, 0)
        let records = sink.records()
        XCTAssertEqual(records.map(\.reason), [.cliStarted, .cliFailed])
        XCTAssertEqual(records.last?.outcome, .failed)
        XCTAssertTrue(records.allSatisfy { !$0.canonicalMessage.contains("supersecret") })
        XCTAssertEqual(
            records.last?.fields.first(where: { $0.name == .command })?.value,
            "unknown"
        )
    }

    func testSinkFailureCannotChangeCommandResultOrFabricateSuccess() {
        var environment = CLIEnvironment.live
        environment.observabilitySink = DegradedCLILogSink()
        environment.observabilityCorrelationID = { "cccccccc-dddd-eeee-ffff-000000000000" }

        let success = HostwrightCLI.run(arguments: ["--version"], environment: environment)
        let failure = HostwrightCLI.run(arguments: ["invalid"], environment: environment)

        XCTAssertEqual(success.exitCode, 0)
        XCTAssertNotEqual(failure.exitCode, 0)
    }
}

private final class CLILogCapture: HostwrightLogSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [HostwrightLogRecord] = []

    func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        lock.lock()
        captured.append(record)
        lock.unlock()
        return HostwrightLogEmission(status: .emitted)
    }

    func records() -> [HostwrightLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private struct DegradedCLILogSink: HostwrightLogSinking {
    func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        HostwrightLogEmission(status: .degraded, reasonCode: HostwrightLogReason.sinkDegraded.rawValue)
    }
}
