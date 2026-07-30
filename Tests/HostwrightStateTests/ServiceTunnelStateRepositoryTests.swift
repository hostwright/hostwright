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
            XCTAssertTrue(
                try columnNames(
                    store,
                    table: "service_tunnel_sessions"
                ).contains("route_json_sha256")
            )
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )
        }
    }

    func testStateIntegrityRequiresTunnelSchemaObjects() throws {
        try withStore { store in
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )

            try store.withConnection { connection in
                try connection.run(
                    "DROP INDEX service_tunnel_recovery_idx"
                )
            }
            let missingIndex = StateIntegrityService(
                store: store
            ).inspect()
            XCTAssertEqual(missingIndex.health, .unrecoverable)
            XCTAssertTrue(
                missingIndex.checks.contains {
                    $0.identifier == "hostwright.schema-objects"
                        && $0.status == .failed
                        && $0.message.contains(
                            "service_tunnel_recovery_idx"
                        )
                }
            )
        }

        try withStore { store in
            try store.withConnection { connection in
                try connection.run(
                    "DROP TABLE service_tunnel_sessions"
                )
            }
            let missingTable = StateIntegrityService(
                store: store
            ).inspect()
            XCTAssertEqual(missingTable.health, .unrecoverable)
            XCTAssertTrue(
                missingTable.checks.contains {
                    $0.identifier == "hostwright.schema-objects"
                        && $0.status == .failed
                        && $0.message.contains(
                            "service_tunnel_sessions"
                        )
                }
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

    func testInvalidStoredTunnelRouteCountsAsAuthoritativeCorruption()
        throws
    {
        try withStore { store in
            try seedAuthority(store)
            let route = try makeRoute()
            try store.serviceTunnels.save(
                intent(route: route, updatedAt: 1_000)
            )

            try store.withConnection { connection in
                try connection.run(
                    """
                    UPDATE service_tunnel_sessions
                    SET route_json = ?
                    WHERE id = ?
                    """,
                    bindings: [
                        .text("{\"projectUUID\":\"\(projectUUID)\"}"),
                        .text(route.routeUUID)
                    ]
                )
            }

            try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                XCTAssertEqual(
                    try ServiceTunnelStateRepository
                        .invalidStoredRecordCount(
                            on: connection
                        ),
                    1
                )
            }

            let report = StateIntegrityService(store: store)
                .inspect()
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(
                report.checks.contains {
                    $0.identifier ==
                        "hostwright.authoritative-records"
                        && $0.status == .failed
                        && $0.affectedRows == 1
                }
            )
        }
    }

    func testAuthenticatedEndpointTamperingFailsLoadAndIntegrity()
        throws
    {
        try withStore { store in
            try seedAuthority(store)
            let route = try makeRoute()
            try store.serviceTunnels.save(
                intent(route: route, updatedAt: 1_000)
            )
            let tampered = try HostwrightTunnelRoute(
                routeUUID: route.routeUUID,
                projectUUID: route.projectUUID,
                peerUUID: route.peerUUID,
                generation: route.generation,
                providerID: route.providerID,
                providerGeneration: route.providerGeneration,
                fencingToken: route.fencingToken,
                operationGroupID: route.operationGroupID,
                desiredSHA256: route.desiredSHA256,
                authenticatedEndpoints: [
                    try HostwrightTunnelEndpoint(
                        host: "127.0.0.2",
                        port: 9443
                    )
                ],
                relayEndpoint: route.relayEndpoint
            )

            try overwriteRouteJSON(
                tampered,
                routeUUID: route.routeUUID,
                store: store
            )
            try assertLoadAndIntegrityRejectTampering(
                routeUUID: route.routeUUID,
                store: store
            )
        }
    }

    func testRelayEndpointTamperingFailsLoadAndIntegrity()
        throws
    {
        try withStore { store in
            try seedAuthority(store)
            let route = try makeRoute()
            try store.serviceTunnels.save(
                intent(route: route, updatedAt: 1_000)
            )
            let tampered = try HostwrightTunnelRoute(
                routeUUID: route.routeUUID,
                projectUUID: route.projectUUID,
                peerUUID: route.peerUUID,
                generation: route.generation,
                providerID: route.providerID,
                providerGeneration: route.providerGeneration,
                fencingToken: route.fencingToken,
                operationGroupID: route.operationGroupID,
                desiredSHA256: route.desiredSHA256,
                authenticatedEndpoints:
                    route.authenticatedEndpoints,
                relayEndpoint: try HostwrightTunnelEndpoint(
                    host: "tampered-relay.example.test",
                    port: 9444
                )
            )

            try overwriteRouteJSON(
                tampered,
                routeUUID: route.routeUUID,
                store: store
            )
            try assertLoadAndIntegrityRejectTampering(
                routeUUID: route.routeUUID,
                store: store
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
            ],
            relayEndpoint: try HostwrightTunnelEndpoint(
                host: "relay.example.test",
                port: 9443
            )
        )
    }

    private func overwriteRouteJSON(
        _ route: HostwrightTunnelRoute,
        routeUUID: String,
        store: SQLiteStateStore
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let routeJSON = String(
            decoding: try encoder.encode(route),
            as: UTF8.self
        )
        try store.withConnection { connection in
            try connection.run(
                """
                UPDATE service_tunnel_sessions
                SET route_json = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(routeJSON),
                    .text(routeUUID)
                ]
            )
        }
    }

    private func assertLoadAndIntegrityRejectTampering(
        routeUUID: String,
        store: SQLiteStateStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try store.serviceTunnels.load(id: routeUUID),
            file: file,
            line: line
        )
        XCTAssertThrowsError(
            try store.serviceTunnels.load(routeUUID: routeUUID),
            file: file,
            line: line
        )
        let report = StateIntegrityService(store: store).inspect()
        XCTAssertEqual(
            report.health,
            .unrecoverable,
            file: file,
            line: line
        )
        XCTAssertTrue(
            report.checks.contains {
                $0.identifier == "hostwright.authoritative-records"
                    && $0.status == .failed
                    && $0.affectedRows == 1
            },
            file: file,
            line: line
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

    private func columnNames(
        _ store: SQLiteStateStore,
        table: String
    ) throws -> [String] {
        try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) {
            try $0.query(
                "PRAGMA table_info(\(table))"
            ).compactMap { row in
                row.count > 1 ? row[1] : nil
            }
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
