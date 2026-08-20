import Foundation
import XCTest
@testable import HostwrightReleaseQualification

final class ReleaseQualificationContractsTests: XCTestCase {
    func testCommittedMatrixIsClosedAndCanonical() throws {
        let matrix = ReleaseQualificationSupportedMatrix.committed
        try matrix.validate()
        let first = try ReleaseQualificationJSON.encode(matrix)
        let second = try ReleaseQualificationJSON.encode(matrix)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try ReleaseQualificationJSON.decode(
            ReleaseQualificationSupportedMatrix.self,
            from: first
        ), matrix)
    }

    func testFutureSchemaAndUnknownKeysFailClosed() throws {
        let matrixData = try ReleaseQualificationJSON.encode(
            ReleaseQualificationSupportedMatrix.committed
        )
        var matrixObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: matrixData) as? [String: Any]
        )
        matrixObject["schemaVersion"] = 2
        let futureData = try JSONSerialization.data(
            withJSONObject: matrixObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationSupportedMatrix.self,
                from: futureData
            )
        ) { error in
            XCTAssertEqual(
                error as? ReleaseQualificationContractError,
                .unsupportedSchemaVersion(2)
            )
        }

        let budgetData = try ReleaseQualificationJSON.encode(
            ReleaseQualificationBudget(
                maximumDurationSeconds: 30,
                maximumCPUHours: 0,
                maximumInputBytes: 4_096,
                maximumOutputBytes: 1_024
            )
        )
        var budgetObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: budgetData) as? [String: Any]
        )
        budgetObject["unknownFutureField"] = true
        let unknownData = try JSONSerialization.data(
            withJSONObject: budgetObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try ReleaseQualificationJSON.decode(
                ReleaseQualificationBudget.self,
                from: unknownData
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseQualificationContractError, .nonCanonicalJSON)
        }
    }

    func testUnsupportedFutureAndNonAppleArchitectureAreBlocked() {
        let future = ReleaseQualificationEnvironmentEvaluator().evaluate(
            cell: ReleaseQualificationSupportedMatrix.committed.cells[0],
            environment: ReleaseQualificationTestSupport.environment(
                host: ReleaseQualificationTestSupport.host(macOSMajor: 27)
            )
        )
        XCTAssertEqual(future.status, .blocked)
        XCTAssertTrue(future.blockers.contains { $0.reason == .futureVersion })

        let x86 = ReleaseQualificationEnvironmentEvaluator().evaluate(
            cell: ReleaseQualificationSupportedMatrix.committed.cells[0],
            environment: ReleaseQualificationTestSupport.environment(
                host: ReleaseQualificationTestSupport.host(
                    architecture: .x86_64,
                    arm64Capability: false
                )
            )
        )
        XCTAssertEqual(x86.status, .blocked)
        XCTAssertTrue(x86.blockers.contains { $0.reason == .unsupportedArchitecture })
    }

    func testUncleanMockAndFixtureEvidenceCannotSatisfyAGate() throws {
        let dirtyEnvironment = ReleaseQualificationTestSupport.environment(
            source: ReleaseQualificationTestSupport.source(dirty: true)
        )
        let dirty = try ReleaseQualificationTestSupport.evidence(
            environment: dirtyEnvironment,
            status: .dirty
        )
        try dirty.validate()
        XCTAssertFalse(dirty.satisfiesRequiredGate)

        let mock = try ReleaseQualificationTestSupport.evidence(
            status: .mock,
            blockers: [ReleaseQualificationTestSupport.blocker(.mockEvidence)]
        )
        try mock.validate()
        XCTAssertFalse(mock.satisfiesRequiredGate)

        let fixture = try ReleaseQualificationTestSupport.evidence(
            status: .fixture,
            blockers: [ReleaseQualificationTestSupport.blocker(.fixtureEvidence)]
        )
        try fixture.validate()
        XCTAssertFalse(fixture.satisfiesRequiredGate)
    }

    func testUnsafeCommandArgumentsAndUnsupportedCellFailClosed() throws {
        XCTAssertThrowsError(
            try ReleaseQualificationCommandIdentity(
                executablePath: "/usr/bin/true",
                arguments: ["--password=not-a-secret"],
                workingDirectory: "/",
                purpose: "unsafe"
            )
        )

        let cell = ReleaseQualificationMatrixCell(
            id: "future-container",
            macOSMajor: 26,
            architecture: .arm64,
            hardware: .appleSilicon,
            provider: .appleContainerCLI,
            runtimeVersion: ReleaseQualificationSemanticVersion(
                major: 9,
                minor: 9,
                patch: 9
            ),
            frameworkVersion: nil,
            requiredTools: [.appleContainer],
            requiredEvidenceClasses: [.liveRuntime],
            executionMode: .liveRuntime,
            authority: .phase08Runtime,
            claim: "unsupported future cell"
        )
        let matrix = ReleaseQualificationSupportedMatrix(
            releaseTarget: "v0.0.2",
            macOSMajors: [26],
            architectures: [.arm64],
            hardwareCells: [.appleSilicon],
            appleContainerVersions: [ReleaseQualificationSemanticVersion(
                major: 1,
                minor: 0,
                patch: 0
            )],
            containerizationVersions: [
                ReleaseQualificationSemanticVersion(major: 0, minor: 35, patch: 0)
            ],
            kubernetesVersions: [],
            dockerAPIVersions: [],
            clientFamilies: [],
            providers: [.appleContainerCLI, .appleContainerization],
            cells: [cell]
        )
        XCTAssertThrowsError(try matrix.validate())
    }
}
