import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime
@testable import HostwrightState

final class NetworkPortReservationRepositoryTests: XCTestCase {
    private let projectID = "project-ports"
    private let projectUUID =
        "91000000-0000-4000-8000-000000000001"
    private let resourceUUID =
        "92000000-0000-4000-8000-000000000001"

    func testSchemaV16IncludesFencedPortReservationState() throws {
        try withStore { store in
            let columns = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) {
                try $0.query(
                    "PRAGMA table_info(network_port_reservations)"
                ).compactMap { row in
                    row.count > 1 ? row[1] : nil
                }
            }
            XCTAssertEqual(
                columns,
                [
                    "id", "project_uuid", "resource_uuid",
                    "service_name", "generation", "provider_id",
                    "provider_generation", "fencing_token",
                    "bind_address", "host_port", "container_port",
                    "protocol", "allocation_kind", "desired_sha256",
                    "observed_sha256", "lifecycle_state",
                    "finalizer_state", "operation_group_id",
                    "created_at", "updated_at"
                ]
            )
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )
        }
    }

    func testReservationActivationAndReleaseRequireExactFences()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let reserve = try operationGroup(store, suffix: "01")
            let reserved = record(
                idSuffix: "01",
                generation: 1,
                fence: reserve.fence,
                operationGroupID: reserve.id
            )
            XCTAssertEqual(
                try store.networkPorts.save(reserved),
                reserved
            )

            let active = record(
                idSuffix: "01",
                generation: 1,
                fence: reserve.fence,
                observedSHA256: digest("b"),
                lifecycle: .active,
                operationGroupID: reserve.id
            )
            XCTAssertThrowsError(
                try store.networkPorts.save(
                    active,
                    replacing: NetworkStateExpectedVersion(
                        generation: 1,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                )
            )
            XCTAssertEqual(
                try store.networkPorts.save(
                    active,
                    replacing: reserved.expectedVersion
                ),
                active
            )
            try finish(store, reserve.id)

            let release = try operationGroup(store, suffix: "02")
            let releasing = record(
                idSuffix: "01",
                generation: 2,
                fence: release.fence,
                observedSHA256: digest("b"),
                lifecycle: .releasing,
                finalizer: .releasing,
                operationGroupID: release.id
            )
            _ = try store.networkPorts.save(
                releasing,
                replacing: active.expectedVersion
            )
            let released = record(
                idSuffix: "01",
                generation: 2,
                fence: release.fence,
                observedSHA256: digest("c"),
                lifecycle: .released,
                finalizer: .released,
                operationGroupID: release.id
            )
            _ = try store.networkPorts.save(
                released,
                replacing: releasing.expectedVersion
            )
            XCTAssertTrue(
                try store.networkPorts.loadProject(
                    projectUUID: projectUUID
                ).isEmpty
            )
            XCTAssertEqual(
                try store.networkPorts.loadProject(
                    projectUUID: projectUUID,
                    includeReleased: true
                ),
                [released]
            )
        }
    }

    func testProtocolScopedConflictsAndDynamicSelectionAreDeterministic()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let firstGroup = try operationGroup(
                store,
                suffix: "11"
            )
            let first = record(
                idSuffix: "11",
                generation: 1,
                fence: firstGroup.fence,
                hostPort: 49_152,
                allocation: .dynamic,
                operationGroupID: firstGroup.id
            )
            _ = try store.networkPorts.save(first)
            try finish(store, firstGroup.id)

            XCTAssertEqual(
                try store.networkPorts.firstAvailableDynamicPort(
                    bindAddress: "127.0.0.1",
                    protocolName: .tcp
                ),
                49_153
            )
            XCTAssertEqual(
                try store.networkPorts.firstAvailableDynamicPort(
                    bindAddress: "127.0.0.1",
                    protocolName: .udp
                ),
                49_152
            )

            let conflictingGroup = try operationGroup(
                store,
                suffix: "12"
            )
            XCTAssertThrowsError(
                try store.networkPorts.save(
                    record(
                        idSuffix: "12",
                        generation: 1,
                        fence: conflictingGroup.fence,
                        hostPort: 49_152,
                        allocation: .dynamic,
                        operationGroupID: conflictingGroup.id
                    )
                )
            )
            XCTAssertEqual(
                try store.networkPorts.loadProject(
                    projectUUID: projectUUID
                ),
                [first]
            )
        }
    }

    func testInvalidDynamicAndPrivilegedPortsFailBeforePersistence()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let group = try operationGroup(store, suffix: "21")
            XCTAssertThrowsError(
                try store.networkPorts.save(
                    record(
                        idSuffix: "21",
                        generation: 1,
                        fence: group.fence,
                        hostPort: 40_000,
                        allocation: .dynamic,
                        operationGroupID: group.id
                    )
                )
            )
            XCTAssertThrowsError(
                try store.networkPorts.save(
                    record(
                        idSuffix: "22",
                        generation: 1,
                        fence: group.fence,
                        hostPort: 443,
                        operationGroupID: group.id
                    )
                )
            )
            XCTAssertTrue(
                try store.networkPorts.loadProject(
                    projectUUID: projectUUID
                ).isEmpty
            )
        }
    }

    private func record(
        idSuffix: String,
        generation: Int64,
        fence: String,
        hostPort: Int = 18_080,
        containerPort: Int = 8_080,
        protocolName: NetworkPortReservationProtocol = .tcp,
        allocation: NetworkPortAllocationKind = .fixed,
        observedSHA256: String? = nil,
        lifecycle: NetworkPortReservationLifecycle = .reserved,
        finalizer: NetworkStateFinalizer = .active,
        operationGroupID: String
    ) -> NetworkPortReservationRecord {
        NetworkPortReservationRecord(
            id:
                "93000000-0000-4000-8000-0000000000\(idSuffix)",
            projectUUID: projectUUID,
            resourceUUID: resourceUUID,
            serviceName: "api",
            generation: generation,
            providerID: RuntimeProviderID.appleContainerCLI.rawValue,
            providerGeneration: 1,
            fencingToken: fence,
            bindAddress: "127.0.0.1",
            hostPort: hostPort,
            containerPort: containerPort,
            protocolName: protocolName,
            allocationKind: allocation,
            desiredSHA256: digest("a"),
            observedSHA256: observedSHA256,
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            operationGroupID: operationGroupID,
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt:
                "2026-07-26T12:\(String(format: "%02d", generation)):00Z"
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
                    .text("ports"),
                    .text(digest("1")),
                    .text("2026-07-26T12:00:00Z"),
                    .text("2026-07-26T12:00:00Z"),
                    .text(projectUUID),
                    .text(RuntimeProviderID.appleContainerCLI.rawValue)
                ]
            )
        }
    }

    private func operationGroup(
        _ store: SQLiteStateStore,
        suffix: String
    ) throws -> (id: String, fence: String) {
        let id =
            "94000000-0000-4000-8000-0000000000\(suffix)"
        let fence =
            "95000000-0000-4000-8000-0000000000\(suffix)"
        let group = OperationGroupRecord(
            id: id,
            operationID: "port-operation-\(suffix)",
            groupKind: "network-port-reservation",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "reserve",
            status: .active,
            groupIdempotencyKey: "port:\(suffix)",
            planHash: digest("9"),
            checkpoint: "intent-persisted",
            lockOwner: "network-port-state-test",
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

    private func finish(
        _ store: SQLiteStateStore,
        _ groupID: String
    ) throws {
        try store.operationGroups.finish(
            groupID: groupID,
            status: .succeeded,
            checkpoint: "verified",
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
                "hostwright-network-port-state-\(UUID().uuidString)",
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
