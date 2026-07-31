import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightState

final class ProjectDNSStateRepositoryTests: XCTestCase {
    private let projectID = "project-dns"
    private let projectUUID =
        "11000000-0000-4000-8000-000000000001"
    private let dnsID =
        "21000000-0000-4000-8000-000000000001"

    func testSchemaStoresOnlyFencedDNSIdentityAndDigests()
        throws
    {
        try withStore { store in
            let columns = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) {
                try $0.query(
                    "PRAGMA table_info(network_dns_instances)"
                ).compactMap { row in
                    row.count > 1 ? row[1] : nil
                }
            }
            XCTAssertEqual(
                columns,
                [
                    "id",
                    "project_uuid",
                    "generation",
                    "provider_id",
                    "provider_generation",
                    "fencing_token",
                    "desired_sha256",
                    "observed_sha256",
                    "lifecycle_state",
                    "finalizer_state",
                    "last_ready_record_sha256",
                    "operation_group_id"
                ]
            )
            XCTAssertFalse(
                columns.contains {
                    $0.contains("secret") || $0.contains("record_json")
                }
            )
        }
    }

    func testCreateIntentPrecedesAtomicReadyRecordCommit()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let create = try operationGroup(store, suffix: "01")
            let intent = record(
                generation: 1,
                fence: create.fence,
                operationGroupID: create.id
            )

            XCTAssertThrowsError(
                try store.projectDNS.save(
                    intent,
                    authority: authority(
                        create,
                        plannedCapability: digest("7"),
                        currentCapability: digest("8")
                    )
                )
            )
            XCTAssertNil(try store.projectDNS.load(id: dnsID))

            XCTAssertEqual(
                try store.projectDNS.save(
                    intent,
                    authority: authority(create)
                ),
                intent
            )
            try finish(store, create.id)

            let readyGroup = try operationGroup(
                store,
                suffix: "02"
            )
            let incompleteReady = record(
                generation: 2,
                fence: readyGroup.fence,
                lifecycle: .available,
                finalizer: .active,
                observedSHA256: digest("b"),
                readyRecordSHA256: nil,
                operationGroupID: readyGroup.id
            )
            XCTAssertThrowsError(
                try store.projectDNS.save(
                    incompleteReady,
                    replacing: version(intent),
                    authority: authority(readyGroup)
                )
            )
            XCTAssertEqual(
                try store.projectDNS.load(id: dnsID),
                intent
            )

            let ready = record(
                generation: 2,
                fence: readyGroup.fence,
                lifecycle: .available,
                finalizer: .active,
                observedSHA256: digest("b"),
                readyRecordSHA256: digest("c"),
                operationGroupID: readyGroup.id
            )
            XCTAssertEqual(
                try store.projectDNS.save(
                    ready,
                    replacing: version(intent),
                    authority: authority(readyGroup)
                ),
                ready
            )
            XCTAssertEqual(
                try store.projectDNS.load(
                    projectUUID: projectUUID
                ),
                ready
            )
            XCTAssertEqual(try store.projectDNS.list(), [ready])
        }
    }

    func testHelperRestartRecoveryRequiresExactOwnership()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let available = try persistAvailable(store)
            let recovery = try operationGroup(
                store,
                suffix: "13"
            )

            XCTAssertEqual(
                try store.projectDNS.evaluateRecovery(
                    id: dnsID,
                    expected: version(available),
                    authority: authority(recovery),
                    trigger: .processTerminated,
                    observation: .exactOwned(
                        observedSHA256: digest("b")
                    )
                ).action,
                .stable
            )
            XCTAssertEqual(
                try store.projectDNS.evaluateRecovery(
                    id: dnsID,
                    expected: version(available),
                    authority: authority(recovery),
                    trigger: .processTerminated,
                    observation: .absent
                ).action,
                .retryMutation
            )
            XCTAssertEqual(
                try store.projectDNS.evaluateRecovery(
                    id: dnsID,
                    expected: version(available),
                    authority: authority(recovery),
                    trigger: .processTerminated,
                    observation: .exactOwned(
                        observedSHA256: digest("d")
                    )
                ).action,
                .quarantine
            )
            XCTAssertThrowsError(
                try store.projectDNS.evaluateRecovery(
                    id: dnsID,
                    expected: NetworkStateExpectedVersion(
                        generation: available.generation,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    ),
                    authority: authority(recovery),
                    trigger: .processTerminated,
                    observation: .absent
                )
            )
        }
    }

    func testAmbiguousDNSOwnershipIsQuarantined()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let available = try persistAvailable(store)
            let recovery = try operationGroup(
                store,
                suffix: "23"
            )
            XCTAssertEqual(
                try store.projectDNS.evaluateRecovery(
                    id: dnsID,
                    expected: version(available),
                    authority: authority(recovery),
                    trigger: .partialEffect,
                    observation: .conflictingOwner(
                        observedSHA256: digest("d")
                    )
                ).action,
                .quarantine
            )

            let quarantined = try store.projectDNS.quarantine(
                id: dnsID,
                expected: version(available),
                authority: authority(recovery),
                observedSHA256: digest("d")
            )
            XCTAssertEqual(
                quarantined.lifecycleState,
                .faulted
            )
            XCTAssertEqual(
                quarantined.finalizerState,
                .quarantined
            )
            XCTAssertEqual(
                quarantined.lastReadyRecordSHA256,
                available.lastReadyRecordSHA256
            )
            XCTAssertEqual(
                try store.projectDNS.evaluateRecovery(
                    id: dnsID,
                    expected: version(quarantined),
                    authority: authority(recovery),
                    trigger: .processTerminated,
                    observation: .absent
                ).action,
                .quarantine
            )
        }
    }

    func testExactReleasedDNSOwnershipIsRequiredForRemoval()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let available = try persistAvailable(store)

            let removal = try operationGroup(
                store,
                suffix: "33"
            )
            let deleting = record(
                generation: 3,
                fence: removal.fence,
                lifecycle: .deleting,
                finalizer: .releasing,
                observedSHA256: digest("b"),
                readyRecordSHA256: digest("c"),
                operationGroupID: removal.id
            )
            _ = try store.projectDNS.save(
                deleting,
                replacing: version(available),
                authority: authority(removal)
            )
            try finish(store, removal.id)

            let finalize = try operationGroup(
                store,
                suffix: "34"
            )
            let deleted = record(
                generation: 4,
                fence: finalize.fence,
                lifecycle: .deleted,
                finalizer: .released,
                observedSHA256: digest("e"),
                readyRecordSHA256: digest("c"),
                operationGroupID: finalize.id
            )
            _ = try store.projectDNS.save(
                deleted,
                replacing: version(deleting),
                authority: authority(finalize)
            )
            try finish(store, finalize.id)

            XCTAssertThrowsError(
                try store.projectDNS.removeDeleted(
                    id: dnsID,
                    expected: NetworkStateExpectedVersion(
                        generation: deleted.generation,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                )
            )
            XCTAssertTrue(
                try store.projectDNS.removeDeleted(
                    id: dnsID,
                    expected: version(deleted)
                )
            )
            XCTAssertNil(try store.projectDNS.load(id: dnsID))
        }
    }

    func testCommittedDeletePermitsExactMonotonicRecreate()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let create = try projectDNSOperationGroup(
                store,
                suffix: "51",
                action: "create",
                stateGeneration: 1
            )
            let creating = record(
                generation: 1,
                fence: create.fence,
                operationGroupID: create.id
            )
            _ = try store.projectDNS.save(
                creating,
                authority: authority(create)
            )
            let available = record(
                generation: 2,
                fence: create.fence,
                lifecycle: .available,
                finalizer: .active,
                observedSHA256: digest("b"),
                readyRecordSHA256: digest("c"),
                operationGroupID: create.id
            )
            _ = try store.projectDNS.save(
                available,
                replacing: version(creating),
                authority: authority(create)
            )
            try finish(
                store,
                create.id,
                checkpoint: "state-committed"
            )

            let deletion = try projectDNSOperationGroup(
                store,
                suffix: "52",
                action: "delete",
                stateGeneration: 3,
                priorStateGeneration: 2,
                priorFence: create.fence
            )
            let deleting = record(
                generation: 3,
                fence: deletion.fence,
                lifecycle: .deleting,
                finalizer: .releasing,
                observedSHA256: digest("b"),
                readyRecordSHA256: digest("c"),
                operationGroupID: deletion.id
            )
            _ = try store.projectDNS.save(
                deleting,
                replacing: version(available),
                authority: authority(deletion)
            )
            let deleted = record(
                generation: 4,
                fence: deletion.fence,
                lifecycle: .deleted,
                finalizer: .released,
                observedSHA256: digest("e"),
                readyRecordSHA256: digest("c"),
                operationGroupID: deletion.id
            )
            _ = try store.projectDNS.save(
                deleted,
                replacing: version(deleting),
                authority: authority(deletion)
            )
            try finish(
                store,
                deletion.id,
                checkpoint: "state-committed"
            )
            XCTAssertTrue(
                try store.projectDNS.removeDeleted(
                    id: dnsID,
                    expected: version(deleted)
                )
            )

            let recreate = try projectDNSOperationGroup(
                store,
                suffix: "53",
                action: "create",
                stateGeneration: 5
            )
            let recreated = record(
                generation: 5,
                fence: recreate.fence,
                operationGroupID: recreate.id
            )
            XCTAssertEqual(
                try store.projectDNS.save(
                    recreated,
                    authority: authority(recreate)
                ),
                recreated
            )
        }
    }

    func testIntegrityRejectsDNSBindingDrift() throws {
        try withStore { store in
            try seedProject(store)
            _ = try persistAvailable(store)
            try store.withConnection { connection in
                try connection.run(
                    """
                    UPDATE projects
                    SET provider_generation = 2
                    WHERE resource_uuid = ?
                    """,
                    bindings: [.text(projectUUID)]
                )
            }
            let report =
                StateIntegrityService(store: store).inspect()
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(
                report.checks.contains {
                    $0.identifier ==
                        "hostwright.authoritative-records" &&
                        $0.affectedRows >= 1
                }
            )
        }
    }

    private func persistAvailable(
        _ store: SQLiteStateStore
    ) throws -> ProjectDNSStateRecord {
        let create = try operationGroup(store, suffix: "11")
        let intent = record(
            generation: 1,
            fence: create.fence,
            operationGroupID: create.id
        )
        _ = try store.projectDNS.save(
            intent,
            authority: authority(create)
        )
        try finish(store, create.id)

        let readyGroup = try operationGroup(
            store,
            suffix: "12"
        )
        let ready = record(
            generation: 2,
            fence: readyGroup.fence,
            lifecycle: .available,
            finalizer: .active,
            observedSHA256: digest("b"),
            readyRecordSHA256: digest("c"),
            operationGroupID: readyGroup.id
        )
        _ = try store.projectDNS.save(
            ready,
            replacing: version(intent),
            authority: authority(readyGroup)
        )
        try finish(store, readyGroup.id)
        return ready
    }

    private func record(
        generation: Int64,
        fence: String,
        lifecycle: NetworkStateResourceLifecycle = .creating,
        finalizer: NetworkStateFinalizer = .pending,
        observedSHA256: String? = nil,
        readyRecordSHA256: String? = nil,
        operationGroupID: String
    ) -> ProjectDNSStateRecord {
        ProjectDNSStateRecord(
            id: dnsID,
            projectUUID: projectUUID,
            generation: generation,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: fence,
            desiredSHA256: digest("a"),
            observedSHA256: observedSHA256,
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            lastReadyRecordSHA256: readyRecordSHA256,
            operationGroupID: operationGroupID
        )
    }

    private func version(
        _ record: ProjectDNSStateRecord
    ) -> NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private func authority(
        _ group: (id: String, fence: String),
        plannedCapability: String? = nil,
        currentCapability: String? = nil
    ) -> NetworkStateMutationAuthority {
        NetworkStateMutationAuthority(
            providerID: "apple-container-cli",
            providerGeneration: 1,
            operationGroupID: group.id,
            fencingToken: group.fence,
            plannedCapabilitySHA256:
                plannedCapability ?? digest("7"),
            currentCapabilitySHA256:
                currentCapability ?? digest("7")
        )
    }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash,
                    created_at, updated_at, resource_uuid,
                    manifest_version, mutation_provider,
                    provider_generation
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, 2, ?, 1)
                """,
                bindings: [
                    .text(projectID),
                    .text("dns-project"),
                    .text(digest("1")),
                    .text("2026-07-26T12:00:00Z"),
                    .text("2026-07-26T12:00:00Z"),
                    .text(projectUUID),
                    .text("apple-container-cli")
                ]
            )
        }
    }

    private func operationGroup(
        _ store: SQLiteStateStore,
        suffix: String
    ) throws -> (id: String, fence: String) {
        let id =
            "51000000-0000-4000-8000-0000000000\(suffix)"
        let fence =
            "61000000-0000-4000-8000-0000000000\(suffix)"
        let group = OperationGroupRecord(
            id: id,
            operationID: "dns-operation-\(suffix)",
            groupKind: "network-dns",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "project-dns",
            status: .active,
            groupIdempotencyKey: "project-dns:\(suffix)",
            planHash: digest("9"),
            checkpoint: "intent-persisted",
            lockOwner: "project-dns-state-test",
            lockExpiresAt: "2027-07-26T12:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt: "2026-07-26T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted:
                "{\"capabilitySHA256\":\"\(digest("7"))\"}"
        )
        XCTAssertEqual(
            try store.operationGroups.acquire(group).acquired,
            group
        )
        return (id, fence)
    }

    private func projectDNSOperationGroup(
        _ store: SQLiteStateStore,
        suffix: String,
        action: String,
        stateGeneration: Int64,
        priorStateGeneration: Int64? = nil,
        priorFence: String? = nil
    ) throws -> (id: String, fence: String) {
        let id =
            "52000000-0000-4000-8000-0000000000\(suffix)"
        let fence =
            "62000000-0000-4000-8000-0000000000\(suffix)"
        let intent = DNSOperationIntentFixture(
            schemaVersion: 1,
            action: action,
            projectUUID: projectUUID,
            dnsUUID: dnsID,
            stateGeneration: stateGeneration,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            capabilitySHA256: digest("7"),
            desiredSHA256: digest("a"),
            priorStateGeneration: priorStateGeneration,
            priorFence: priorFence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "project-dns",
            projectID: projectID,
            serviceName: "hostwright-dns",
            plannedActionType: action,
            status: .active,
            groupIdempotencyKey: "project-dns:\(suffix)",
            planHash: digest("9"),
            checkpoint: "intent-persisted",
            lockOwner: "project-dns-state-test",
            lockExpiresAt: "2027-07-26T12:00:00Z",
            rollbackAvailable: action != "delete",
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt: "2026-07-26T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: String(
                decoding: try encoder.encode(intent),
                as: UTF8.self
            )
        )
        XCTAssertEqual(
            try store.operationGroups.acquire(group).acquired,
            group
        )
        return (id, fence)
    }

    private func finish(
        _ store: SQLiteStateStore,
        _ groupID: String,
        checkpoint: String = "verified"
    ) throws {
        try store.operationGroups.finish(
            groupID: groupID,
            status: .succeeded,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: "",
            updatedAt: "2026-07-26T12:30:00Z",
            metadataJSONRedacted: "{}"
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func withStore(
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-project-dns-state-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        try body(store)
    }
}

private struct DNSOperationIntentFixture: Encodable {
    let schemaVersion: Int
    let action: String
    let projectUUID: String
    let dnsUUID: String
    let stateGeneration: Int64
    let providerID: String
    let providerGeneration: Int
    let capabilitySHA256: String
    let desiredSHA256: String
    let priorStateGeneration: Int64?
    let priorFence: String?
}
