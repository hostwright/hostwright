import Foundation
import XCTest
import HostwrightCore
@testable import HostwrightReleaseQualification

final class ReleaseQualificationRegistryTests: XCTestCase {
    func testDefaultRegistryPlansReadyLocalLanesAndExplicitBlockers() throws {
        let root = ReleaseQualificationTestSupport.repositoryRoot()
        let document = try ReleaseQualificationRegistryPlanner().plan(sourceRoot: root)
        try document.validate()
        XCTAssertEqual(document.registry.lanes.count, document.lanes.count)
        XCTAssertEqual(
            document.lanes.first(where: { $0.laneID == "qualification-json-boundary" })?.status,
            .ready
        )
        let protocolPlan = try XCTUnwrap(
            document.lanes.first(where: { $0.laneID == "phase08-protocol-fuzz" })
        )
        XCTAssertTrue(protocolPlan.blockers.contains {
            $0.reason == .liveRuntimePhase08Boundary
        })
        XCTAssertTrue(document.lanes.contains {
            $0.blockers.contains { $0.reason == .sanitizerUnavailable }
        })
    }

    func testParserBoundaryHarnessAcceptsCanonicalAndRejectsUnknownData() throws {
        let budget = ReleaseQualificationBudget(
            maximumDurationSeconds: 30,
            maximumCPUHours: 0,
            maximumInputBytes: 4_096,
            maximumOutputBytes: 1_024
        )
        let valid = try ReleaseQualificationJSON.encode(budget)
        XCTAssertTrue(
            ReleaseQualificationParserBoundaryHarness.evaluate(
                data: valid,
                target: .qualificationContractJSON
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["unknownFutureField"] = true
        let unknown = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let result = ReleaseQualificationParserBoundaryHarness.evaluate(
            data: unknown,
            target: .qualificationContractJSON,
            expectation: .reject
        )
        XCTAssertTrue(result.satisfied)
        XCTAssertFalse(result.accepted)
    }

    func testMissingOrTamperedSeededCorpusIsBlocked() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpusDirectory = root
            .appendingPathComponent("Tests/HostwrightReleaseQualificationTests/Fixtures/corpus")
        try FileManager.default.createDirectory(
            at: corpusDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let source = ReleaseQualificationTestSupport.repositoryRoot()
            .appendingPathComponent(
                "Tests/HostwrightReleaseQualificationTests/Fixtures/corpus/qualification-budget-valid.json"
            )
        let destination = corpusDirectory.appendingPathComponent(
            "qualification-budget-valid.json"
        )
        var data = try Data(contentsOf: source)
        data.append(Data("x".utf8))
        try data.write(to: destination, options: [.atomic])
        let document = try ReleaseQualificationRegistryPlanner().plan(sourceRoot: root)
        let plan = try XCTUnwrap(
            document.lanes.first(where: { $0.laneID == "qualification-json-boundary" })
        )
        XCTAssertTrue(plan.blockers.contains {
            $0.reason == .tamperedEvidence || $0.reason == .corpusMismatch
        })
    }

    func testSafeChecksUseRealBoundedInputsAndAggregateDeterministically() throws {
        let results = try ReleaseQualificationSafeCheckRunner().run(
            sourceRoot: ReleaseQualificationTestSupport.repositoryRoot()
        )
        XCTAssertEqual(
            results.map(\.checkID),
            ["dependency-lock-integrity", "secret-scan"]
        )
        XCTAssertEqual(results[0].status, .passed)
        XCTAssertEqual(results[1].status, .failed)
        XCTAssertTrue(
            results[1].failures.contains {
                $0.contains("AWS-access-key") || $0.contains("GitHub-token")
            }
        )
        XCTAssertEqual(
            try ReleaseQualificationSafeCheckAggregation.status(results),
            .failed
        )
    }
}
