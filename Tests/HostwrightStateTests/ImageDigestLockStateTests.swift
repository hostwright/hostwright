import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class ImageDigestLockStateTests: XCTestCase {
    func testVersionEightMigrationAddsAuthoritativeLockLedger() throws {
        try withStore(migrateThrough: 7) { store in
            XCTAssertEqual(try store.schemaVersion(), 7)

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            let report = StateIntegrityService(store: store).inspect()
            XCTAssertEqual(report.health, .healthy)
            XCTAssertEqual(
                report.stateSchemaVersion,
                HostwrightContractVersions.stateSchema
            )
        }
    }

    func testDesiredAndObservedLocksRoundTripAcrossReopenAndRefresh() throws {
        try withStore { store in
            try seedProject(store)
            let desired = try record(stateKind: .desired)
            try store.imageDigestLocks.save(desired)
            try store.imageDigestLocks.save(desired)

            let firstObserved = try record(
                stateKind: .observed,
                observationBody: "b",
                updatedAt: "2026-07-24T12:00:01Z"
            )
            try store.imageDigestLocks.save(firstObserved)
            let refreshedObserved = try record(
                stateKind: .observed,
                observationBody: "c",
                updatedAt: "2026-07-24T12:00:02Z"
            )
            try store.imageDigestLocks.save(refreshedObserved)

            let reopened = SQLiteStateStore(path: store.path)
            let records = try reopened.imageDigestLocks.load(
                projectID: "project-demo"
            )
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records.map(\.stateKind), [.desired, .observed])
            XCTAssertNil(records[0].observationSHA256)
            XCTAssertEqual(
                records[1].observationSHA256,
                String(repeating: "c", count: 64)
            )
            XCTAssertEqual(
                records[1].lock.resolvedReference,
                "registry.example/team/api@sha256:\(String(repeating: "d", count: 64))"
            )
        }
    }

    func testLockIdentityCollisionWithDifferentEvidenceFailsClosed() throws {
        try withStore { store in
            try seedProject(store)
            let original = try record(stateKind: .desired)
            try store.imageDigestLocks.save(original)
            let conflictingLock = try RuntimeImageDigestLock(
                requestedReference: "registry.example/team/api:stable",
                resolvedReference:
                    "registry.example/team/api@sha256:\(String(repeating: "e", count: 64))",
                descriptorDigest: "sha256:\(String(repeating: "e", count: 64))",
                variantDigest: "sha256:\(String(repeating: "f", count: 64))",
                operatingSystem: "linux",
                architecture: "arm64",
                providerID: .appleContainerCLI,
                capabilitySHA256: String(repeating: "a", count: 64)
            )
            let conflicting = ImageDigestLockRecord(
                id: original.id,
                projectID: original.projectID,
                resourceUUID: original.resourceUUID,
                serviceName: original.serviceName,
                replicaIndex: original.replicaIndex,
                stateKind: original.stateKind,
                lock: conflictingLock,
                providerGeneration: original.providerGeneration,
                planSHA256: original.planSHA256,
                operationGroupID: original.operationGroupID,
                observationSHA256: nil,
                createdAt: original.createdAt,
                updatedAt: original.updatedAt
            )

            XCTAssertThrowsError(
                try store.imageDigestLocks.save(conflicting)
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "different immutable evidence"
                    )
                )
            }
        }
    }

    func testIntegrityRejectsMalformedDigestLockEvidence() throws {
        try withStore { store in
            try seedProject(store)
            let desired = try record(stateKind: .desired)
            try store.imageDigestLocks.save(desired)

            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false
            )
            defer { try? connection.close() }
            try connection.run(
                """
                UPDATE image_digest_locks
                SET descriptor_digest = 'sha256:not-a-digest'
                WHERE id = ?
                """,
                bindings: [.text(desired.id)]
            )

            let report = try StateIntegrityService(store: store).inspect(
                connection: connection
            )
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(report.checks.contains {
                $0.identifier == "hostwright.authoritative-records"
                    && $0.affectedRows == 1
            })
        }
    }

    private func record(
        stateKind: ImageDigestLockStateKind,
        observationBody: Character? = nil,
        updatedAt: String = "2026-07-24T12:00:00Z"
    ) throws -> ImageDigestLockRecord {
        let plan = String(repeating: "9", count: 64)
        let resourceUUID = HostwrightResourceUUID.legacy(
            kind: "service",
            identifier: "project-demo:api:0"
        )
        let lock = try RuntimeImageDigestLock(
            requestedReference: "registry.example/team/api:stable",
            resolvedReference:
                "registry.example/team/api@sha256:\(String(repeating: "d", count: 64))",
            descriptorDigest: "sha256:\(String(repeating: "d", count: 64))",
            variantDigest: "sha256:\(String(repeating: "e", count: 64))",
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64)
        )
        return ImageDigestLockRecord(
            id: HostwrightResourceUUID.legacy(
                kind: "image-digest-lock-\(stateKind.rawValue)",
                identifier: "\(plan):\(resourceUUID)"
            ),
            projectID: "project-demo",
            resourceUUID: resourceUUID,
            serviceName: "api",
            replicaIndex: 0,
            stateKind: stateKind,
            lock: lock,
            providerGeneration: 1,
            planSHA256: plan,
            operationGroupID: HostwrightResourceUUID.legacy(
                kind: "lifecycle-group",
                identifier: plan
            ),
            observationSHA256: observationBody.map {
                String(repeating: $0, count: 64)
            },
            createdAt: "2026-07-24T12:00:00Z",
            updatedAt: updatedAt
        )
    }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: "hostwright.yaml",
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: HostwrightManifest(project: "demo", services: []),
            timestamp: "2026-07-24T11:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
        )
    }

    private func withStore(
        migrateThrough: Int? = nil,
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-image-lock-state-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        if let migrateThrough {
            try MigrationRunner().apply(
                to: store,
                throughVersion: migrateThrough
            )
        } else {
            try store.migrate()
        }
        try body(store)
    }
}
