import Foundation
import HostwrightNetworking
import XCTest

@testable import HostwrightState

final class ServiceTunnelStateRepositoryTests: XCTestCase {
    private let projectID = "project-tunnel"
    private let projectUUID =
        "11111111-1111-4111-8111-111111111111"
    private let peerUUID =
        "22222222-2222-4222-8222-222222222222"
    private let fence =
        "33333333-3333-4333-8333-333333333333"
    private let operationGroup =
        "44444444-4444-4444-8444-444444444444"

    func testSchemaV15MigrationAddsTunnelAuthorityTable()
        throws
    {
        try withStore(throughVersion: 15) { store in
            XCTAssertFalse(
                try tableNames(store).contains(
                    "service_tunnel_sessions"
                )
            )
            try store.migrate()
            XCTAssertTrue(
                try tableNames(store).contains(
                    "service_tunnel_sessions"
                )
            )
        }
    }

    func testSQLiteAdapterRecoversAndExactlyCleansSession()
        throws
    {
        try withStore { store in
            try seedAuthority(store)
            let route = try makeRoute()
            let connecting = HostwrightTunnelSessionIntent(
                route: route,
                phase: .connecting,
                finalizer: .pending,
                selectedTransport: .direct,
                keyEpoch: 1,
                reconnectAttempt: 0,
                observedSHA256: nil,
                updatedAtUnixMilliseconds: 1_000
            )
            try store.serviceTunnels.save(connecting)
            XCTAssertEqual(
                try store.serviceTunnels.load(
                    routeUUID: route.routeUUID
                ),
                connecting
            )
            XCTAssertEqual(
                try store.serviceTunnels.listRecoverable(),
                [
                    try XCTUnwrap(
                        store.serviceTunnels.load(
                            id: route.routeUUID
                        )
                    )
                ]
            )

            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(
                try reopened.serviceTunnels.load(
                    routeUUID: route.routeUUID
                ),
                connecting
            )
            let active = HostwrightTunnelSessionIntent(
                route: route,
                phase: .active,
                finalizer: .active,
                selectedTransport: .direct,
                keyEpoch: 1,
                reconnectAttempt: 0,
                observedSHA256: route.desiredSHA256,
                updatedAtUnixMilliseconds: 2_000
            )
            try reopened.serviceTunnels.save(active)

            let staleRoute = try HostwrightTunnelRoute(
                routeUUID: route.routeUUID,
                projectUUID: projectUUID,
                peerUUID: peerUUID,
                generation: 1,
                providerID: "apple-container-cli",
                providerGeneration: 1,
                fencingToken:
                    "55555555-5555-4555-8555-555555555555",
                operationGroupID: operationGroup,
                desiredSHA256: route.desiredSHA256,
                authenticatedEndpoints:
                    route.authenticatedEndpoints
            )
            XCTAssertThrowsError(
                try reopened.serviceTunnels.save(
                    HostwrightTunnelSessionIntent(
                        route: staleRoute,
                        phase: .active,
                        finalizer: .active,
                        selectedTransport: .direct,
                        keyEpoch: 1,
                        reconnectAttempt: 0,
                        observedSHA256:
                            route.desiredSHA256,
                        updatedAtUnixMilliseconds: 3_000
                    )
                )
            )

            try reopened.serviceTunnels.save(
                HostwrightTunnelSessionIntent(
                    route: route,
                    phase: .draining,
                    finalizer: .releasing,
                    selectedTransport: .direct,
                    keyEpoch: 1,
                    reconnectAttempt: 0,
                    observedSHA256: route.desiredSHA256,
                    updatedAtUnixMilliseconds: 4_000
                )
            )
            try reopened.serviceTunnels.save(
                HostwrightTunnelSessionIntent(
                    route: route,
                    phase: .closed,
                    finalizer: .released,
                    selectedTransport: .direct,
                    keyEpoch: 1,
                    reconnectAttempt: 0,
                    observedSHA256: route.desiredSHA256,
                    updatedAtUnixMilliseconds: 5_000
                )
            )
            XCTAssertEqual(
                try reopened.serviceTunnels
                    .listRecoverable()
                    .map(\.lifecycleState),
                [.closed]
            )
            XCTAssertThrowsError(
                try reopened.serviceTunnels.remove(
                    routeUUID: route.routeUUID,
                    generation: 1,
                    fencingToken:
                        "55555555-5555-4555-8555-555555555555"
                )
            )
            try reopened.serviceTunnels.remove(
                routeUUID: route.routeUUID,
                generation: 1,
                fencingToken: fence
            )
            XCTAssertNil(
                try reopened.serviceTunnels.load(
                    routeUUID: route.routeUUID
                )
            )
            XCTAssertEqual(
                try rowCount(reopened),
                0
            )
        }
    }

    func testDuplicatePeerAndConflictingGenerationFailClosed()
        throws
    {
        try withStore { store in
            try seedAuthority(store)
            let first = try makeRoute()
            try store.serviceTunnels.save(
                intent(route: first, updatedAt: 1_000)
            )
            let duplicate = try HostwrightTunnelRoute(
                projectUUID: projectUUID,
                peerUUID: peerUUID,
                generation: 2,
                providerID: "apple-container-cli",
                providerGeneration: 1,
                fencingToken: fence,
                operationGroupID: operationGroup,
                desiredSHA256:
                    String(repeating: "b", count: 64),
                authenticatedEndpoints: [
                    try HostwrightTunnelEndpoint(
                        host: "127.0.0.1",
                        port: 8444
                    )
                ]
            )
            XCTAssertThrowsError(
                try store.serviceTunnels.save(
                    intent(route: duplicate, updatedAt: 2_000)
                )
            )
        }
    }

    private func intent(
        route: HostwrightTunnelRoute,
        updatedAt: Int64
    ) -> HostwrightTunnelSessionIntent {
        HostwrightTunnelSessionIntent(
            route: route,
            phase: .connecting,
            finalizer: .pending,
            selectedTransport: .direct,
            keyEpoch: 1,
            reconnectAttempt: 0,
            observedSHA256: nil,
            updatedAtUnixMilliseconds: updatedAt
        )
    }

    private func makeRoute() throws -> HostwrightTunnelRoute {
        try HostwrightTunnelRoute(
            routeUUID:
                "66666666-6666-4666-8666-666666666666",
            projectUUID: projectUUID,
            peerUUID: peerUUID,
            generation: 1,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: fence,
            operationGroupID: operationGroup,
            desiredSHA256:
                String(repeating: "a", count: 64),
            authenticatedEndpoints: [
                try HostwrightTunnelEndpoint(
                    host: "127.0.0.1",
                    port: 8443
                )
            ]
        )
    }

    private func seedAuthority(
        _ store: SQLiteStateStore
    ) throws {
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
                    .text("tunnel"),
                    .text(String(repeating: "1", count: 64)),
                    .text("2026-07-29T12:00:00Z"),
                    .text("2026-07-29T12:00:00Z"),
                    .text(projectUUID),
                    .text("apple-container-cli")
                ]
            )
        }
        let group = OperationGroupRecord(
            id: operationGroup,
            operationID: "tunnel-operation",
            groupKind: "service-tunnel",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "connect",
            status: .active,
            groupIdempotencyKey: "tunnel:\(peerUUID)",
            planHash: String(repeating: "2", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "service-tunnel-test",
            lockExpiresAt: "2027-07-29T12:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-29T12:00:00Z",
            updatedAt: "2026-07-29T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: "{}"
        )
        XCTAssertEqual(
            try store.operationGroups.acquire(group).acquired,
            group
        )
    }

    private func rowCount(
        _ store: SQLiteStateStore
    ) throws -> Int {
        try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) {
            let value = try $0.query(
                "SELECT COUNT(*) FROM service_tunnel_sessions"
            ).first?.first ?? nil
            return try XCTUnwrap(value.flatMap(Int.init))
        }
    }

    private func tableNames(
        _ store: SQLiteStateStore
    ) throws -> [String] {
        try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) {
            try $0.query(
                """
                SELECT name FROM sqlite_master
                WHERE type = 'table'
                ORDER BY name
                """
            ).compactMap { $0.first ?? nil }
        }
    }

    private func withStore(
        throughVersion: Int? = nil,
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "hostwright-tunnel-state-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent(
                "state.sqlite"
            ).path
        )
        if let throughVersion {
            try MigrationRunner().apply(
                to: store,
                throughVersion: throughVersion
            )
        } else {
            try store.migrate()
        }
        try body(store)
    }
}
