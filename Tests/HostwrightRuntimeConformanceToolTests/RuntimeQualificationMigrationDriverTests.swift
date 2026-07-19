import Foundation
import HostwrightCore
import HostwrightRuntime
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationMigrationDriverTests: XCTestCase {
    func testSpecificationAcceptsOnlyLockedCrossProviderDirections() throws {
        for (source, target, sourceVersion, targetVersion) in [
            (
                RuntimeProviderID.appleContainerCLI,
                RuntimeProviderID.appleContainerization,
                "1.1.0",
                ContainerizationRuntimeAssetContract.frameworkVersion
            ),
            (
                RuntimeProviderID.appleContainerization,
                RuntimeProviderID.appleContainerCLI,
                ContainerizationRuntimeAssetContract.frameworkVersion,
                "1.0.0"
            ),
        ] {
            let specification = RuntimeQualificationMigrationSpecification(
                sourceProviderID: source,
                targetProviderID: target,
                expectedSourceVersion: sourceVersion,
                expectedTargetVersion: targetVersion,
                localImage: "docker.io/library/python:alpine"
            )
            XCTAssertNoThrow(try specification.validated())
            XCTAssertNoThrow(try RuntimeQualificationMigrationDriver(specification: specification))
        }

        let invalid = [
            RuntimeQualificationMigrationSpecification(
                sourceProviderID: .appleContainerCLI,
                targetProviderID: .appleContainerCLI,
                expectedSourceVersion: "1.1.0",
                expectedTargetVersion: "1.1.0",
                localImage: "docker.io/library/python:alpine"
            ),
            RuntimeQualificationMigrationSpecification(
                sourceProviderID: .appleContainerCLI,
                targetProviderID: .appleContainerization,
                expectedSourceVersion: "1.2.0",
                expectedTargetVersion: ContainerizationRuntimeAssetContract.frameworkVersion,
                localImage: "docker.io/library/python:alpine"
            ),
            RuntimeQualificationMigrationSpecification(
                sourceProviderID: .appleContainerization,
                targetProviderID: .appleContainerCLI,
                expectedSourceVersion: ContainerizationRuntimeAssetContract.frameworkVersion,
                expectedTargetVersion: "1.1.0",
                localImage: "unsafe\nimage"
            ),
        ]
        for specification in invalid {
            XCTAssertThrowsError(try RuntimeQualificationMigrationDriver(specification: specification)) {
                XCTAssertEqual(
                    $0 as? RuntimeQualificationMigrationDriverError,
                    .invalidSpecification
                )
            }
        }
    }

    func testStateFoundationUsesSchemaV7ExactUUIDOwnershipAndExactCleanup() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-phase03-migration-parent-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("unmanaged-sentinel")
        try Data("preserve\n".utf8).write(to: sentinel, options: .withoutOverwriting)

        let foundation = try RuntimeQualificationMigrationStateFoundation.make(
            sourceProviderID: .appleContainerCLI,
            image: "docker.io/library/python:alpine",
            parentDirectory: parent
        )
        XCTAssertEqual(try foundation.store.schemaVersion(), 7)
        let project = try foundation.store.desiredStates.loadProject(id: foundation.projectID)
        let desired = try XCTUnwrap(
            try foundation.store.desiredStates.loadDesiredServices(
                projectID: foundation.projectID
            ).first
        )
        let ownership = try XCTUnwrap(
            try foundation.store.ownership.loadAll().first(where: {
                $0.resourceUUID == foundation.resourceUUID
            })
        )
        XCTAssertEqual(project.resourceUUID, foundation.projectUUID)
        XCTAssertEqual(project.mutationProvider, RuntimeProviderID.appleContainerCLI.rawValue)
        XCTAssertEqual(project.providerGeneration, 1)
        XCTAssertEqual(desired.resourceUUID, foundation.resourceUUID)
        XCTAssertEqual(ownership.resourceUUID, foundation.resourceUUID)
        XCTAssertEqual(ownership.projectResourceUUID, foundation.projectUUID)
        XCTAssertEqual(ownership.runtimeAdapter, RuntimeProviderID.appleContainerCLI.rawValue)
        XCTAssertEqual(ownership.providerGeneration, 1)
        XCTAssertEqual(ownership.fencingToken, foundation.sourceFencingToken)

        try foundation.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: foundation.directory.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve\n".utf8))
    }

    func testEvidenceRoundTripsWithoutLosingGateResults() throws {
        let digest = String(repeating: "a", count: 64)
        let evidence = RuntimeQualificationMigrationEvidence(
            schemaVersion: 1,
            sourceProviderID: RuntimeProviderID.appleContainerCLI.rawValue,
            targetProviderID: RuntimeProviderID.appleContainerization.rawValue,
            projectUUID: "11111111-1111-4111-8111-111111111111",
            resourceUUID: "22222222-2222-4222-8222-222222222222",
            fixtureImageReference: "docker.io/library/python:alpine",
            fixtureImageDescriptorDigest: "sha256:" + digest,
            fixtureImageVariantDigest: "sha256:" + digest,
            sourceCapabilitySHA256: digest,
            targetCapabilitySHA256: digest,
            staleConfirmationRefused: true,
            targetCollisionRefused: true,
            unavailableImageRefused: true,
            rollbackVerified: true,
            checkpointRecovered: true,
            forwardCheckpoint: "sourceRetired",
            reverseCheckpoint: "sourceRetired",
            stateSchemaVersion: 7,
            sourceInventoryBeforeSHA256: digest,
            sourceInventoryAfterSHA256: digest,
            targetInventoryBeforeSHA256: digest,
            targetInventoryAfterSHA256: digest,
            cleanupComplete: true
        )
        let data = try JSONEncoder().encode(evidence)
        XCTAssertEqual(try JSONDecoder().decode(
            RuntimeQualificationMigrationEvidence.self,
            from: data
        ), evidence)
    }

    func testStateFoundationRefusesCleanupAfterOwnershipMarkerTampering() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-phase03-migration-parent-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let foundation = try RuntimeQualificationMigrationStateFoundation.make(
            sourceProviderID: .appleContainerCLI,
            image: "docker.io/library/python:alpine",
            parentDirectory: parent
        )
        let marker = foundation.directory.appendingPathComponent(".hostwright-phase03-owned")
        try Data("tampered\n".utf8).write(to: marker)

        XCTAssertThrowsError(try foundation.remove()) {
            XCTAssertEqual(
                $0 as? RuntimeQualificationMigrationDriverError,
                .cleanupFailed
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foundation.directory.path))
    }
}
