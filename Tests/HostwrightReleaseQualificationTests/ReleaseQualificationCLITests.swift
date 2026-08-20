import Foundation
import XCTest
@testable import HostwrightReleaseQualification

final class ReleaseQualificationCLITests: XCTestCase {
    func testParserRejectsUnknownAndDuplicateOptions() {
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["plan", "--unknown"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["plan", "--root", "/tmp", "--root", "/tmp"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["verify", "--cell", "not-a-committed-cell"]
            )
        )
        XCTAssertThrowsError(
            try ReleaseQualificationCLIInvocation(
                arguments: ["status", "--ledger-root", "/tmp", "--root", "/tmp"]
            )
        )
    }

    func testPlanCommandIsCanonicalAndBounded() throws {
        let invocation = try ReleaseQualificationCLIInvocation(
            arguments: [
                "plan",
                "--root",
                ReleaseQualificationTestSupport.repositoryRoot().path
            ]
        )
        let output = try ReleaseQualificationCLIExecutor().execute(
            invocation,
            currentDirectory: ReleaseQualificationTestSupport.repositoryRoot()
        )
        let document = try ReleaseQualificationJSON.decode(
            ReleaseQualificationPlanDocument.self,
            from: output
        )
        XCTAssertEqual(document.kind, "hostwright.release-qualification.plan.v1")
        XCTAssertLessThanOrEqual(
            output.count,
            ReleaseQualificationLimits.maximumJSONBytes
        )
    }

    func testPrivateLedgerStatusAndResumeAreExplicit() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerRoot = root.appendingPathComponent("ledger")
        _ = try ReleaseQualificationLedgerStore(root: ledgerRoot)
        let statusInvocation = try ReleaseQualificationCLIInvocation(
            arguments: ["status", "--ledger-root", ledgerRoot.path]
        )
        let statusData = try ReleaseQualificationCLIExecutor().execute(
            statusInvocation,
            currentDirectory: root
        )
        let summary = try ReleaseQualificationJSON.decode(
            ReleaseQualificationLedgerSummary.self,
            from: statusData
        )
        XCTAssertEqual(summary.running, 0)

        let resumeInvocation = try ReleaseQualificationCLIInvocation(
            arguments: ["resume", "--ledger-root", ledgerRoot.path]
        )
        let resumeData = try ReleaseQualificationCLIExecutor().execute(
            resumeInvocation,
            currentDirectory: root
        )
        let resume = try ReleaseQualificationJSON.decode(
            ReleaseQualificationCLIResumeReport.self,
            from: resumeData
        )
        XCTAssertTrue(resume.recoveredRunIDs.isEmpty)
    }
}
