import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime
@testable import HostwrightState

final class CertificateStateRepositoryTests: XCTestCase {
    private let projectID = "certificate-project"
    private let projectUUID = "12000000-0000-4000-8000-000000000001"
    private let certificateID = "22000000-0000-4000-8000-000000000001"

    func testV15ToV16AddsCertificateTableAndIndexes() throws {
        try withStore(throughVersion: 15) { store in
            XCTAssertFalse(try objectNames(store, type: "table").contains("network_certificates"))
            try store.migrate()
            XCTAssertTrue(try objectNames(store, type: "table").contains("network_certificates"))
            XCTAssertTrue(
                Set(try objectNames(store, type: "index")).isSuperset(of: [
                    "network_certificates_project_idx",
                    "network_certificates_provider_idx",
                    "network_certificates_operation_idx",
                ])
            )
            let columns = try store.withConnection(createIfNeeded: false, readOnly: true) {
                try $0.query("PRAGMA table_info(network_certificates)")
                    .compactMap { $0.count > 1 ? $0[1] : nil }
            }
            XCTAssertFalse(columns.contains { $0.contains("persistent_ref") || $0.contains("key") })
        }
    }

    func testLifecycleCASAndManagedExactPurge() throws {
        try withStore { store in
            try seedProject(store)
            let create = try group(store, suffix: "01")
            let creating = certificate(generation: 1, group: create)
            XCTAssertEqual(try store.certificates.save(creating, authority: authority(create)), creating)
            try finish(store, create.id)

            let availableGroup = try group(store, suffix: "02")
            let available = certificate(
                generation: 2,
                group: availableGroup,
                lifecycle: .available,
                finalizer: .active,
                status: .available,
                observed: digest("b")
            )
            XCTAssertEqual(
                try store.certificates.save(
                    available,
                    replacing: version(creating),
                    authority: authority(availableGroup)
                ),
                available
            )
            try finish(store, availableGroup.id)

            let deletingGroup = try group(store, suffix: "03")
            let deleting = certificate(
                generation: 3,
                group: deletingGroup,
                lifecycle: .deleting,
                finalizer: .releasing,
                status: .revoking,
                observed: digest("b")
            )
            XCTAssertEqual(
                try store.certificates.save(
                    deleting,
                    replacing: version(available),
                    authority: authority(deletingGroup)
                ),
                deleting
            )
            try finish(store, deletingGroup.id)

            let deletedGroup = try group(store, suffix: "04")
            let deleted = certificate(
                generation: 4,
                group: deletedGroup,
                lifecycle: .deleted,
                finalizer: .released,
                status: .revoked,
                observed: digest("b")
            )
            XCTAssertEqual(
                try store.certificates.save(deleted, replacing: version(deleting), authority: authority(deletedGroup)),
                deleted
            )
            try store.certificates.purge(
                id: certificateID,
                expected: version(deleted),
                authority: authority(deletedGroup)
            )
            XCTAssertNil(try store.certificates.load(id: certificateID))
        }
    }

    func testRejectsStaleFenceAndIllegalTransition() throws {
        try withStore { store in
            try seedProject(store)
            let create = try group(store, suffix: "05")
            let creating = certificate(generation: 1, group: create)
            _ = try store.certificates.save(creating, authority: authority(create))
            try finish(store, create.id)
            let update = try group(store, suffix: "06")
            let available = certificate(
                generation: 2,
                group: update,
                lifecycle: .available,
                finalizer: .active,
                status: .available,
                observed: digest("b")
            )
            XCTAssertThrowsError(
                try store.certificates.save(
                    available,
                    replacing: .init(generation: 1, fencingToken: "ffffffff-ffff-4fff-8fff-ffffffffffff"),
                    authority: authority(update)
                )
            )
            let deleted = certificate(
                generation: 2,
                group: update,
                lifecycle: .deleted,
                finalizer: .released,
                status: .revoked,
                observed: digest("b")
            )
            XCTAssertThrowsError(
                try store.certificates.save(deleted, replacing: version(creating), authority: authority(update))
            )
        }
    }

    func testImportedIdentityStateCanBeReleasedWithoutOwningKeychainIdentity() throws {
        try withStore { store in
            try seedProject(store)
            let create = try group(store, suffix: "07")
            let imported = certificate(generation: 1, group: create, source: .imported, ownership: .external)
            _ = try store.certificates.save(imported, authority: authority(create))
            try finish(store, create.id)
            let deletion = try group(store, suffix: "08")
            let deleting = certificate(
                generation: 2,
                group: deletion,
                source: .imported,
                ownership: .external,
                lifecycle: .deleting,
                finalizer: .releasing,
                status: .available
            )
            _ = try store.certificates.save(deleting, replacing: version(imported), authority: authority(deletion))
            let deleted = certificate(
                generation: 3,
                group: deletion,
                source: .imported,
                ownership: .external,
                lifecycle: .deleted,
                finalizer: .released,
                status: .released,
                observed: digest("b")
            )
            _ = try store.certificates.save(deleted, replacing: version(deleting), authority: authority(deletion))
            try store.certificates.purge(id: certificateID, expected: version(deleted), authority: authority(deletion))
            XCTAssertNil(try store.certificates.load(id: certificateID))
        }
    }

    func testCanonicalJSONBoundsAndIntegrityDoNotExposeKeyMaterial() throws {
        try withStore { store in
            try seedProject(store)
            let create = try group(store, suffix: "09")
            var invalid = certificate(generation: 1, group: create)
            invalid = CertificateStateRecord(
                id: invalid.id,
                projectUUID: invalid.projectUUID,
                manifestName: invalid.manifestName,
                generation: invalid.generation,
                providerID: invalid.providerID,
                providerGeneration: invalid.providerGeneration,
                fencingToken: invalid.fencingToken,
                sourceKind: invalid.sourceKind,
                ownershipKind: invalid.ownershipKind,
                leafSHA256: invalid.leafSHA256,
                issuerSHA256: invalid.issuerSHA256,
                sanJSON: "[ \"example.test\" ]",
                ekuJSON: invalid.ekuJSON,
                notBefore: invalid.notBefore,
                notAfter: invalid.notAfter,
                status: invalid.status,
                revocationStatus: invalid.revocationStatus,
                statusCheckedAt: invalid.statusCheckedAt,
                desiredSHA256: invalid.desiredSHA256,
                observedSHA256: invalid.observedSHA256,
                lifecycleState: invalid.lifecycleState,
                finalizerState: invalid.finalizerState,
                operationGroupID: invalid.operationGroupID,
                createdAt: invalid.createdAt,
                updatedAt: invalid.updatedAt
            )
            XCTAssertThrowsError(try store.certificates.save(invalid, authority: authority(create)))
            let oversized = String(repeating: "a", count: 16_385)
            let tooLarge = CertificateStateRecord(
                id: invalid.id,
                projectUUID: invalid.projectUUID,
                manifestName: invalid.manifestName,
                generation: invalid.generation,
                providerID: invalid.providerID,
                providerGeneration: invalid.providerGeneration,
                fencingToken: invalid.fencingToken,
                sourceKind: invalid.sourceKind,
                ownershipKind: invalid.ownershipKind,
                leafSHA256: invalid.leafSHA256,
                issuerSHA256: invalid.issuerSHA256,
                sanJSON: oversized,
                ekuJSON: invalid.ekuJSON,
                notBefore: invalid.notBefore,
                notAfter: invalid.notAfter,
                status: invalid.status,
                revocationStatus: invalid.revocationStatus,
                statusCheckedAt: invalid.statusCheckedAt,
                desiredSHA256: invalid.desiredSHA256,
                observedSHA256: invalid.observedSHA256,
                lifecycleState: invalid.lifecycleState,
                finalizerState: invalid.finalizerState,
                operationGroupID: invalid.operationGroupID,
                createdAt: invalid.createdAt,
                updatedAt: invalid.updatedAt
            )
            XCTAssertThrowsError(try store.certificates.save(tooLarge, authority: authority(create)))
            let valid = certificate(generation: 1, group: create)
            _ = try store.certificates.save(valid, authority: authority(create))
            let report = StateIntegrityService(store: store).inspect()
            XCTAssertEqual(report.health, .healthy)
            XCTAssertFalse(
                report.checks.map(\.message).joined(separator: " ").localizedCaseInsensitiveContains("persistent_ref")
            )
        }
    }

    private func certificate(
        generation: Int64,
        group: (id: String, fence: String),
        source: CertificateSourceKind = .provider,
        ownership: CertificateOwnershipKind = .managed,
        lifecycle: NetworkStateResourceLifecycle = .creating,
        finalizer: NetworkStateFinalizer = .pending,
        status: CertificateStatus = .creating,
        observed: String? = nil
    ) -> CertificateStateRecord {
        CertificateStateRecord(
            id: certificateID,
            projectUUID: projectUUID,
            manifestName: "web-tls",
            generation: generation,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: group.fence,
            sourceKind: source,
            ownershipKind: ownership,
            leafSHA256: digest("1"),
            issuerSHA256: source == .imported ? nil : digest("2"),
            sanJSON: "[\"example.test\"]",
            ekuJSON: "[\"serverAuth\"]",
            notBefore: "2026-07-26T12:00:00Z",
            notAfter: "2027-07-26T12:00:00Z",
            status: status,
            revocationStatus: .good,
            statusCheckedAt: nil,
            desiredSHA256: digest("a"),
            observedSHA256: observed,
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            operationGroupID: group.id,
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt: "2026-07-26T12:00:00Z"
        )
    }

    private func version(_ record: CertificateStateRecord) -> NetworkStateExpectedVersion {
        .init(generation: record.generation, fencingToken: record.fencingToken)
    }
    private func authority(_ group: (id: String, fence: String)) -> NetworkStateMutationAuthority {
        .init(
            providerID: "apple-container-cli",
            providerGeneration: 1,
            operationGroupID: group.id,
            fencingToken: group.fence,
            plannedCapabilitySHA256: digest("7"),
            currentCapabilitySHA256: digest("7")
        )
    }
    private func digest(_ character: Character) -> String { String(repeating: String(character), count: 64) }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.withConnection {
            try $0.run(
                "INSERT INTO projects (id,name,manifest_path,manifest_hash,created_at,updated_at,resource_uuid,manifest_version,mutation_provider,provider_generation) VALUES (?,?,NULL,?,?,?, ?,2,?,1)",
                bindings: [
                    .text(projectID), .text("certificate-project"), .text(digest("1")), .text("2026-07-26T12:00:00Z"),
                    .text("2026-07-26T12:00:00Z"), .text(projectUUID), .text("apple-container-cli"),
                ]
            )
        }
    }

    private func group(_ store: SQLiteStateStore, suffix: String) throws -> (id: String, fence: String) {
        let id = "52000000-0000-4000-8000-0000000000\(suffix)"
        let fence = "62000000-0000-4000-8000-0000000000\(suffix)"
        let group = OperationGroupRecord(
            id: id,
            operationID: "certificate-operation-\(suffix)",
            groupKind: "certificate",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "certificate",
            status: .active,
            groupIdempotencyKey: "certificate:\(suffix)",
            planHash: digest("9"),
            checkpoint: "intent-persisted",
            lockOwner: "certificate-state-test",
            lockExpiresAt: "2027-07-26T12:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt: "2026-07-26T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: "{\"capabilitySHA256\":\"\(digest("7"))\"}"
        )
        XCTAssertEqual(try store.operationGroups.acquire(group).acquired, group)
        return (id, fence)
    }

    private func finish(_ store: SQLiteStateStore, _ groupID: String) throws {
        try store.operationGroups.finish(
            groupID: groupID,
            status: .succeeded,
            checkpoint: "verified",
            manualRecoveryHintRedacted: "",
            updatedAt: "2026-07-26T12:30:00Z",
            metadataJSONRedacted: "{}"
        )
    }

    private func objectNames(_ store: SQLiteStateStore, type: String) throws -> [String] {
        try store.withConnection(createIfNeeded: false, readOnly: true) {
            try $0.query("SELECT name FROM sqlite_master WHERE type = ?", bindings: [.text(type)]).compactMap {
                $0.first ?? nil
            }
        }
    }
    private func withStore(throughVersion: Int? = nil, _ body: (SQLiteStateStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-certificate-state-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        if let throughVersion {
            try MigrationRunner().apply(to: store, throughVersion: throughVersion)
        } else {
            try store.migrate()
        }
        try body(store)
    }
}
