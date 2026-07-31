import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class RuntimeProjectDNSTests: XCTestCase {
    private let projectUUID =
        "11111111-1111-4111-8111-111111111111"

    func testWorkloadAndInfrastructureLabelsUseExactProjectIdentity() throws {
        let resourceUUID = HostwrightResourceUUID.legacy(
            kind: "project-dns",
            identifier: projectUUID
        )
        let zone = "\(projectUUID).hostwright.internal"

        let workload = try RuntimeProjectDNSContract.workloadLabels(
            projectUUID: projectUUID
        )
        XCTAssertEqual(
            workload,
            [
                RuntimeProjectDNSContract.resourceUUIDLabel:
                    resourceUUID,
                RuntimeProjectDNSContract.zoneLabel: zone
            ]
        )
        XCTAssertFalse(
            RuntimeProjectDNSContract.isInfrastructure(workload)
        )

        let infrastructure =
            try RuntimeProjectDNSContract.infrastructureLabels(
                projectUUID: projectUUID
            )
        XCTAssertEqual(
            infrastructure[
                RuntimeProjectDNSContract.resourceKindLabel
            ],
            RuntimeProjectDNSContract.resourceKind
        )
        XCTAssertTrue(
            RuntimeProjectDNSContract.isInfrastructure(
                infrastructure
            )
        )
    }

    func testRequirementRoundTripsExactWorkloadAndInfrastructureLabels() throws {
        for labels in [
            try RuntimeProjectDNSContract.workloadLabels(
                projectUUID: projectUUID
            ),
            try RuntimeProjectDNSContract.infrastructureLabels(
                projectUUID: projectUUID
            )
        ] {
            let requirement = try XCTUnwrap(
                RuntimeProjectDNSContract.requirement(
                    from: labels,
                    projectUUID: projectUUID
                )
            )
            XCTAssertEqual(requirement.projectUUID, projectUUID)
            XCTAssertEqual(
                requirement.resourceUUID,
                HostwrightResourceUUID.legacy(
                    kind: "project-dns",
                    identifier: projectUUID
                )
            )
            XCTAssertEqual(
                requirement.zone,
                "\(projectUUID).hostwright.internal"
            )
        }
    }

    func testAbsentDNSLabelsProduceNoRequirement() throws {
        XCTAssertNil(
            try RuntimeProjectDNSContract.requirement(
                from: ["example": "value"],
                projectUUID: projectUUID
            )
        )
    }

    func testPartialWrongKindAndWrongZoneRequirementsFailClosed() throws {
        let valid = try RuntimeProjectDNSContract.workloadLabels(
            projectUUID: projectUUID
        )

        XCTAssertThrowsError(
            try RuntimeProjectDNSContract.requirement(
                from: [
                    RuntimeProjectDNSContract.resourceUUIDLabel:
                        try XCTUnwrap(
                            valid[
                                RuntimeProjectDNSContract
                                    .resourceUUIDLabel
                            ]
                        )
                ],
                projectUUID: projectUUID
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProjectDNSError,
                .incompleteRequirement
            )
        }

        var wrongKind = valid
        wrongKind[RuntimeProjectDNSContract.resourceKindLabel] =
            "other"
        XCTAssertThrowsError(
            try RuntimeProjectDNSContract.requirement(
                from: wrongKind,
                projectUUID: projectUUID
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProjectDNSError,
                .incompleteRequirement
            )
        }

        var wrongZone = valid
        wrongZone[RuntimeProjectDNSContract.zoneLabel] =
            "other.hostwright.internal"
        XCTAssertThrowsError(
            try RuntimeProjectDNSContract.requirement(
                from: wrongZone,
                projectUUID: projectUUID
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProjectDNSError,
                .invalidRequirement
            )
        }
    }

    func testRequirementRejectsValidButNonDerivedDNSResourceUUID() throws {
        var labels = try RuntimeProjectDNSContract.workloadLabels(
            projectUUID: projectUUID
        )
        labels[RuntimeProjectDNSContract.resourceUUIDLabel] =
            "99999999-9999-4999-8999-999999999999"

        XCTAssertThrowsError(
            try RuntimeProjectDNSContract.requirement(
                from: labels,
                projectUUID: projectUUID
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProjectDNSError,
                .invalidRequirement
            )
        }
    }
}
