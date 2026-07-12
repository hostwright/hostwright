import XCTest
@testable import HostwrightCore

final class EvidenceModelsTests: XCTestCase {
    func testPassingHardwareEvidenceRequiresCommandsCountsAndExactCleanup() throws {
        let report = evidence(status: .passed)
        XCTAssertNoThrow(try report.validate())

        let missingCleanup = HostwrightEvidenceReport(
            evidenceClass: .hardwareBenchmark,
            status: .passed,
            recordedAt: report.recordedAt,
            source: report.source,
            environment: report.environment,
            commands: report.commands,
            rawResults: report.rawResults,
            failures: [],
            blockers: [],
            cleanup: HostwrightEvidenceCleanup(status: .notRequired, exactResourceIdentifiers: [])
        )
        XCTAssertThrowsError(try missingCleanup.validate()) { error in
            XCTAssertEqual(error as? HostwrightEvidenceValidationError, .invalidCleanup)
        }
    }

    func testBlockedAndFailedEvidenceCannotMasqueradeAsPassing() {
        var blocked = evidence(status: .blocked)
        XCTAssertNoThrow(try blocked.validate())

        blocked = HostwrightEvidenceReport(
            evidenceClass: blocked.evidenceClass,
            status: .blocked,
            recordedAt: blocked.recordedAt,
            source: blocked.source,
            environment: blocked.environment,
            commands: blocked.commands,
            rawResults: blocked.rawResults,
            failures: [],
            blockers: [],
            cleanup: blocked.cleanup
        )
        XCTAssertThrowsError(try blocked.validate()) { error in
            XCTAssertEqual(error as? HostwrightEvidenceValidationError, .missingBlocker)
        }

        let failed = evidence(status: .failed)
        XCTAssertNoThrow(try failed.validate())
    }

    func testEvidenceRejectsInvalidCommitAndInconsistentRawCounts() {
        let valid = evidence(status: .blocked)
        let invalidCommit = HostwrightEvidenceReport(
            evidenceClass: valid.evidenceClass,
            status: valid.status,
            recordedAt: valid.recordedAt,
            source: HostwrightEvidenceSource(commit: "not-a-commit", dirty: true),
            environment: valid.environment,
            commands: valid.commands,
            rawResults: valid.rawResults,
            failures: valid.failures,
            blockers: valid.blockers,
            cleanup: valid.cleanup
        )
        XCTAssertThrowsError(try invalidCommit.validate()) { error in
            XCTAssertEqual(error as? HostwrightEvidenceValidationError, .invalidSourceCommit)
        }

        let zeroCommit = HostwrightEvidenceReport(
            evidenceClass: valid.evidenceClass,
            status: valid.status,
            recordedAt: valid.recordedAt,
            source: HostwrightEvidenceSource(commit: String(repeating: "0", count: 40), dirty: true),
            environment: valid.environment,
            commands: valid.commands,
            rawResults: valid.rawResults,
            failures: valid.failures,
            blockers: valid.blockers,
            cleanup: valid.cleanup
        )
        XCTAssertThrowsError(try zeroCommit.validate()) { error in
            XCTAssertEqual(error as? HostwrightEvidenceValidationError, .invalidSourceCommit)
        }

        let invalidCounts = HostwrightEvidenceReport(
            evidenceClass: valid.evidenceClass,
            status: valid.status,
            recordedAt: valid.recordedAt,
            source: valid.source,
            environment: valid.environment,
            commands: valid.commands,
            rawResults: HostwrightEvidenceCounts(executed: 3, passed: 1, failed: 0, blocked: 1),
            failures: valid.failures,
            blockers: valid.blockers,
            cleanup: valid.cleanup
        )
        XCTAssertThrowsError(try invalidCounts.validate()) { error in
            XCTAssertEqual(error as? HostwrightEvidenceValidationError, .invalidResultCounts)
        }
    }

    private func evidence(status: HostwrightEvidenceStatus) -> HostwrightEvidenceReport {
        let failed = status == .failed ? 1 : 0
        let blocked = status == .blocked ? 1 : 0
        return HostwrightEvidenceReport(
            evidenceClass: .hardwareBenchmark,
            status: status,
            recordedAt: "2026-07-12T00:00:00Z",
            source: HostwrightEvidenceSource(commit: String(repeating: "a", count: 40), dirty: true),
            environment: HostwrightEvidenceEnvironment(
                operatingSystem: "macOS 26.5",
                build: "25F90",
                architecture: "arm64",
                hardwareModel: "Mac16,8",
                memoryBytes: 24_000_000_000,
                toolVersions: ["hostwright": "0.1.0-alpha.1"]
            ),
            commands: [HostwrightEvidenceCommand(command: "real command", exitCode: status == .passed ? 0 : 1, durationMilliseconds: 1)],
            rawResults: HostwrightEvidenceCounts(executed: 1, passed: status == .passed ? 1 : 0, failed: failed, blocked: blocked),
            failures: status == .failed ? ["real failure"] : [],
            blockers: status == .blocked ? ["missing capability"] : [],
            cleanup: HostwrightEvidenceCleanup(status: .succeeded, exactResourceIdentifiers: ["hostwright-v2-bench-probe-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        )
    }
}
