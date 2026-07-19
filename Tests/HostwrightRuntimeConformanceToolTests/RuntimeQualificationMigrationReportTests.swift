import Foundation
import HostwrightRuntime
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationMigrationReportTests: XCTestCase {
    private let image = "docker.io/library/python:alpine"
    private let digest = String(repeating: "a", count: 64)

    func testComposerProducesExactHarnessSchemaFromValidatedDriverEvidence() throws {
        let report = try RuntimeQualificationMigrationReportComposer.compose(
            specification: specification(),
            evidence: evidence(),
            commands: [RuntimeQualificationCommandEvidence(
                arguments: ["hostwright-runtime-conformance", "migration"],
                exitStatus: 0
            )]
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.kind, "runtimeProviderMigrationEvidence")
        XCTAssertEqual(report.status, "passed")
        XCTAssertEqual(report.subjects, [
            RuntimeQualificationSubject(
                providerID: RuntimeProviderID.appleContainerCLI.rawValue,
                providerVersion: "1.1.0"
            ),
            RuntimeQualificationSubject(
                providerID: RuntimeProviderID.appleContainerization.rawValue,
                providerVersion: "0.35.0"
            ),
        ])
        XCTAssertEqual(
            report.fixtureImage,
            RuntimeQualificationFixtureImage(reference: image, digest: "sha256:\(digest)")
        )
        XCTAssertEqual(report.inventory.beforeSHA256, report.inventory.afterSHA256)
        XCTAssertEqual(
            report.inventory.unmanagedBeforeSHA256,
            report.inventory.unmanagedAfterSHA256
        )
        XCTAssertEqual(report.inventory.beforeSHA256.count, 64)
        XCTAssertTrue(report.unmanagedInventoryUnchanged)
        XCTAssertEqual(report.summary.passed, 11)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertTrue(report.cleanup.complete)
        XCTAssertEqual(report.cleanup.identifiers, [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        ])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set([
            "schemaVersion", "kind", "status", "subjects", "fixtureImage", "inventory",
            "unmanagedInventoryUnchanged", "summary", "commands", "cleanup", "details",
        ]))
        XCTAssertNotNil(object["details"] as? [String: Any])
    }

    func testComposerRejectsAnyUnverifiedDriverGate() throws {
        let unverified = evidence(rollbackVerified: false)
        XCTAssertThrowsError(try RuntimeQualificationMigrationReportComposer.compose(
            specification: specification(),
            evidence: unverified,
            commands: [RuntimeQualificationCommandEvidence(
                arguments: ["hostwright-runtime-conformance", "migration"],
                exitStatus: 0
            )]
        )) { error in
            XCTAssertEqual(
                error as? RuntimeQualificationMigrationReportError,
                .invalidDriverEvidence
            )
        }
    }

    func testComposerRejectsMismatchedImageAndUnsafeCommandShape() throws {
        var mismatched = evidence()
        mismatched = RuntimeQualificationMigrationEvidence(
            schemaVersion: mismatched.schemaVersion,
            sourceProviderID: mismatched.sourceProviderID,
            targetProviderID: mismatched.targetProviderID,
            projectUUID: mismatched.projectUUID,
            resourceUUID: mismatched.resourceUUID,
            fixtureImageReference: "docker.io/library/busybox:latest",
            fixtureImageDescriptorDigest: mismatched.fixtureImageDescriptorDigest,
            fixtureImageVariantDigest: mismatched.fixtureImageVariantDigest,
            sourceCapabilitySHA256: mismatched.sourceCapabilitySHA256,
            targetCapabilitySHA256: mismatched.targetCapabilitySHA256,
            staleConfirmationRefused: mismatched.staleConfirmationRefused,
            targetCollisionRefused: mismatched.targetCollisionRefused,
            unavailableImageRefused: mismatched.unavailableImageRefused,
            rollbackVerified: mismatched.rollbackVerified,
            checkpointRecovered: mismatched.checkpointRecovered,
            forwardCheckpoint: mismatched.forwardCheckpoint,
            reverseCheckpoint: mismatched.reverseCheckpoint,
            stateSchemaVersion: mismatched.stateSchemaVersion,
            sourceInventoryBeforeSHA256: mismatched.sourceInventoryBeforeSHA256,
            sourceInventoryAfterSHA256: mismatched.sourceInventoryAfterSHA256,
            targetInventoryBeforeSHA256: mismatched.targetInventoryBeforeSHA256,
            targetInventoryAfterSHA256: mismatched.targetInventoryAfterSHA256,
            cleanupComplete: mismatched.cleanupComplete
        )
        XCTAssertThrowsError(try RuntimeQualificationMigrationReportComposer.compose(
            specification: specification(),
            evidence: mismatched,
            commands: [RuntimeQualificationCommandEvidence(
                arguments: ["hostwright-runtime-conformance"],
                exitStatus: 0
            )]
        ))

        XCTAssertThrowsError(try RuntimeQualificationMigrationReportComposer.compose(
            specification: specification(),
            evidence: evidence(),
            commands: [RuntimeQualificationCommandEvidence(
                arguments: ["/unsafe/path/hostwright-runtime-conformance"],
                exitStatus: 0
            )]
        )) { error in
            XCTAssertEqual(
                error as? RuntimeQualificationMigrationReportError,
                .invalidCommandEvidence
            )
        }

        XCTAssertThrowsError(try RuntimeQualificationMigrationReportComposer.compose(
            specification: specification(),
            evidence: evidence(),
            commands: [RuntimeQualificationCommandEvidence(
                arguments: ["hostwright-runtime-conformance", "access-token=value"],
                exitStatus: 0
            )]
        )) { error in
            XCTAssertEqual(
                error as? RuntimeQualificationMigrationReportError,
                .invalidCommandEvidence
            )
        }
    }

    private func specification() -> RuntimeQualificationMigrationSpecification {
        RuntimeQualificationMigrationSpecification(
            sourceProviderID: .appleContainerCLI,
            targetProviderID: .appleContainerization,
            expectedSourceVersion: "1.1.0",
            expectedTargetVersion: "0.35.0",
            localImage: image
        )
    }

    private func evidence(
        rollbackVerified: Bool = true
    ) -> RuntimeQualificationMigrationEvidence {
        RuntimeQualificationMigrationEvidence(
            schemaVersion: 1,
            sourceProviderID: RuntimeProviderID.appleContainerCLI.rawValue,
            targetProviderID: RuntimeProviderID.appleContainerization.rawValue,
            projectUUID: "11111111-1111-4111-8111-111111111111",
            resourceUUID: "22222222-2222-4222-8222-222222222222",
            fixtureImageReference: image,
            fixtureImageDescriptorDigest: "sha256:\(digest)",
            fixtureImageVariantDigest: "sha256:\(String(repeating: "b", count: 64))",
            sourceCapabilitySHA256: digest,
            targetCapabilitySHA256: String(repeating: "b", count: 64),
            staleConfirmationRefused: true,
            targetCollisionRefused: true,
            unavailableImageRefused: true,
            rollbackVerified: rollbackVerified,
            checkpointRecovered: true,
            forwardCheckpoint: "sourceRetired",
            reverseCheckpoint: "sourceRetired",
            stateSchemaVersion: 7,
            sourceInventoryBeforeSHA256: String(repeating: "c", count: 64),
            sourceInventoryAfterSHA256: String(repeating: "c", count: 64),
            targetInventoryBeforeSHA256: String(repeating: "d", count: 64),
            targetInventoryAfterSHA256: String(repeating: "d", count: 64),
            cleanupComplete: true
        )
    }
}
