import CryptoKit
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime

public struct ServiceTunnelStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func save(
        _ record: ServiceTunnelStateRecord,
        replacing expected: ServiceTunnelExpectedVersion? = nil
    ) throws -> ServiceTunnelStateRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let existing = try Self.load(
                    id: record.id,
                    on: connection
                )
                try Self.validateAuthority(
                    record,
                    allowsSucceededGroup: existing != nil,
                    on: connection
                )
                if let existing {
                    if existing == record { return record }
                    guard let expected,
                          existing.generation == expected.generation,
                          existing.fencingToken == expected.fencingToken,
                          existing.projectUUID == record.projectUUID,
                          existing.peerUUID == record.peerUUID,
                          existing.providerID == record.providerID,
                          existing.providerGeneration == record.providerGeneration,
                          existing.operationGroupID == record.operationGroupID,
                          Self.validTransition(from: existing.lifecycleState, to: record.lifecycleState) else {
                        throw StateStoreError.invalidRecord(
                            "Service tunnel replacement lost exact generation, provider, operation-group, or fencing authority."
                        )
                    }
                    try connection.run(
                        """
                        UPDATE service_tunnel_sessions
                        SET generation = ?, fencing_token = ?, desired_sha256 = ?,
                            observed_sha256 = ?, route_json = ?,
                            route_json_sha256 = ?, lifecycle_state = ?,
                            finalizer_state = ?, selected_transport = ?,
                            key_epoch = ?, reconnect_attempt = ?, updated_at_ms = ?
                        WHERE id = ? AND generation = ? AND fencing_token = ?
                        """,
                        bindings: [
                            .int64(record.generation), .text(record.fencingToken),
                            .text(record.desiredSHA256), Self.optional(record.observedSHA256),
                            .text(record.routeJSON), .text(record.routeJSONSHA256),
                            .text(record.lifecycleState.rawValue),
                            .text(record.finalizerState.rawValue),
                            Self.optional(record.selectedTransport?.rawValue),
                            .int64(record.keyEpoch), .int(record.reconnectAttempt),
                            .int64(record.updatedAtUnixMilliseconds), .text(record.id),
                            .int64(expected.generation), .text(expected.fencingToken)
                        ]
                    )
                } else {
                    guard expected == nil,
                          [.intended, .connecting].contains(record.lifecycleState),
                          record.finalizerState == .pending,
                          record.observedSHA256 == nil else {
                        throw StateStoreError.invalidRecord(
                            "New service tunnel state must begin as a persisted intended or connecting intent."
                        )
                    }
                    try connection.run(
                        """
                        INSERT INTO service_tunnel_sessions (
                            id, project_uuid, peer_uuid, generation, provider_id,
                            provider_generation, fencing_token, operation_group_id,
                            desired_sha256, observed_sha256, route_json,
                            route_json_sha256,
                            lifecycle_state, finalizer_state, selected_transport,
                            key_epoch, reconnect_attempt, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(record.id), .text(record.projectUUID), .text(record.peerUUID),
                            .int64(record.generation), .text(record.providerID),
                            .int64(record.providerGeneration), .text(record.fencingToken),
                            .text(record.operationGroupID), .text(record.desiredSHA256),
                            Self.optional(record.observedSHA256), .text(record.routeJSON),
                            .text(record.routeJSONSHA256),
                            .text(record.lifecycleState.rawValue), .text(record.finalizerState.rawValue),
                            Self.optional(record.selectedTransport?.rawValue),
                            .int64(record.keyEpoch), .int(record.reconnectAttempt),
                            .int64(record.createdAtUnixMilliseconds),
                            .int64(record.updatedAtUnixMilliseconds)
                        ]
                    )
                }
                guard try Self.load(id: record.id, on: connection) == record else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Service tunnel compare-and-swap did not persist the exact intent."
                    )
                }
                return record
            }
        }
    }

    public func load(id: String) throws -> ServiceTunnelStateRecord? {
        try Self.validateUUID(id, label: "service tunnel id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.load(id: id, on: $0)
        }
    }

    public func listRecoverable(projectUUID: String? = nil) throws -> [ServiceTunnelStateRecord] {
        if let projectUUID { try Self.validateUUID(projectUUID, label: "project UUID") }
        return try store.withValidatedConnection(readOnly: true) { connection in
            let filter = projectUUID == nil
                ? ""
                : " WHERE project_uuid = ?"
            let bindings = projectUUID.map { [SQLiteValue.text($0)] } ?? []
            return try connection.query(
                Self.select + filter + " ORDER BY project_uuid, peer_uuid, generation, id",
                bindings: bindings
            ).map(Self.decode)
        }
    }

    public func removeReleased(
        id: String,
        expected: ServiceTunnelExpectedVersion
    ) throws {
        try Self.validateUUID(id, label: "service tunnel id")
        try Self.validateUUID(expected.fencingToken, label: "service tunnel fence")
        try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let record = try Self.load(id: id, on: connection),
                      record.generation == expected.generation,
                      record.fencingToken == expected.fencingToken,
                      record.lifecycleState == .closed,
                      record.finalizerState == .released,
                      record.observedSHA256 != nil else {
                    throw StateStoreError.invalidRecord(
                        "Service tunnel cleanup requires exact released generation and fence."
                    )
                }
                try connection.run(
                    """
                    DELETE FROM service_tunnel_sessions
                    WHERE id = ? AND generation = ? AND fencing_token = ?
                      AND lifecycle_state = 'closed' AND finalizer_state = 'released'
                    """,
                    bindings: [.text(id), .int64(expected.generation), .text(expected.fencingToken)]
                )
                guard try Self.load(id: id, on: connection) == nil else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Service tunnel exact cleanup left authoritative state behind."
                    )
                }
            }
        }
    }

    static func invalidStoredRecordCount(
        on connection: SQLiteConnection
    ) throws -> Int {
        var invalid = 0
        for row in try connection.query(
            select + " ORDER BY project_uuid, peer_uuid, generation, id"
        ) {
            do {
                let record = try decode(row)
                try validateStoredBinding(record, on: connection)
                try validateStoredRoute(record)
            } catch {
                invalid += 1
            }
        }
        return invalid
    }

    private static func validateAuthority(
        _ record: ServiceTunnelStateRecord,
        allowsSucceededGroup: Bool,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT operation.fencing_token, project.resource_uuid,
                   project.mutation_provider, project.provider_generation,
                   operation.status
            FROM operation_groups AS operation
            JOIN projects AS project ON project.id = operation.project_id
            WHERE operation.id = ?
            LIMIT 1
            """,
            bindings: [.text(record.operationGroupID)]
        )
        guard rows.count == 1,
              rows[0][0] == record.fencingToken,
              rows[0][1] == record.projectUUID,
              let provider = rows[0][2],
              RuntimeProviderBinding.stableID(for: provider)?.rawValue == record.providerID,
              rows[0][3].flatMap(Int64.init) == record.providerGeneration,
              rows[0][4] == OperationGroupStatus.active.rawValue ||
                (
                    allowsSucceededGroup &&
                    rows[0][4] ==
                        OperationGroupStatus.succeeded.rawValue
                ) else {
            throw StateStoreError.invalidRecord(
                "Service tunnel intent requires the active operation group and exact project provider fence."
            )
        }
    }

    private static func validateStoredBinding(
        _ record: ServiceTunnelStateRecord,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT project.mutation_provider, project.provider_generation,
                   operation.fencing_token, project.resource_uuid
            FROM projects AS project
            JOIN operation_groups AS operation
              ON operation.project_id = project.id
            WHERE project.resource_uuid = ? AND operation.id = ?
            LIMIT 1
            """,
            bindings: [.text(record.projectUUID), .text(record.operationGroupID)]
        )
        guard let row = rows.first,
              row.count == 4,
              RuntimeProviderBinding.stableID(
                for: row[0] ?? ""
              )?.rawValue == record.providerID,
              Int64(row[1] ?? "") == record.providerGeneration,
              row[2] == record.fencingToken,
              row[3] == record.projectUUID else {
            throw StateStoreError.invalidRecord(
                "Service tunnel stored provider and operation ownership is inconsistent."
            )
        }
    }

    private static func validateStoredRoute(
        _ record: ServiceTunnelStateRecord
    ) throws {
        let route = try decodeCanonicalRoute(record.routeJSON)
        guard sha256(Data(record.routeJSON.utf8))
                == record.routeJSONSHA256,
              route.routeUUID == record.id,
              route.projectUUID == record.projectUUID,
              route.peerUUID == record.peerUUID,
              route.generation == record.generation,
              route.providerID == record.providerID,
              route.providerGeneration == record.providerGeneration,
              route.fencingToken == record.fencingToken,
              route.operationGroupID == record.operationGroupID,
              route.desiredSHA256 == record.desiredSHA256 else {
            throw StateStoreError.invalidRecord(
                "Persisted service tunnel route lost exact authority."
            )
        }
    }

    private static func validate(_ record: ServiceTunnelStateRecord) throws {
        try validateUUID(record.id, label: "service tunnel id")
        try validateUUID(record.projectUUID, label: "project UUID")
        try validateUUID(record.peerUUID, label: "peer UUID")
        try validateUUID(record.fencingToken, label: "service tunnel fence")
        try validateUUID(record.operationGroupID, label: "operation group id")
        try validateSHA256(record.desiredSHA256)
        if let observed = record.observedSHA256 { try validateSHA256(observed) }
        try validateSHA256(record.routeJSONSHA256)
        guard record.generation > 0, record.providerGeneration > 0,
              record.keyEpoch > 0, (0...8).contains(record.reconnectAttempt),
              record.updatedAtUnixMilliseconds >= record.createdAtUnixMilliseconds,
              record.routeJSON.utf8.count <= 65_536,
              StateJSON.isObject(record.routeJSON),
              validShape(record) else {
            throw StateStoreError.invalidRecord("Service tunnel intent has invalid lifecycle or bounded evidence.")
        }
        try validateStoredRoute(record)
    }

    private static func validShape(_ record: ServiceTunnelStateRecord) -> Bool {
        switch record.lifecycleState {
        case .intended:
            return record.finalizerState == .pending && record.observedSHA256 == nil
        case .connecting:
            return (record.finalizerState == .pending && record.observedSHA256 == nil)
                || (record.finalizerState == .active && record.observedSHA256 != nil)
        case .active:
            return record.finalizerState == .active && record.observedSHA256 != nil
        case .draining:
            return record.finalizerState == .releasing
        case .closed:
            return record.finalizerState == .released && record.observedSHA256 != nil
        case .faulted:
            return record.finalizerState == .quarantined
        }
    }

    private static func validTransition(
        from: ServiceTunnelLifecycleState,
        to: ServiceTunnelLifecycleState
    ) -> Bool {
        switch from {
        case .intended: return [.connecting, .faulted].contains(to)
        case .connecting: return [.connecting, .active, .draining, .faulted].contains(to)
        case .active: return [.active, .connecting, .draining, .faulted].contains(to)
        case .draining: return [.connecting, .closed, .faulted].contains(to)
        case .faulted: return [.connecting, .draining, .faulted].contains(to)
        case .closed: return false
        }
    }

    private static func load(id: String, on connection: SQLiteConnection) throws -> ServiceTunnelStateRecord? {
        try connection.query(Self.select + " WHERE id = ? LIMIT 1", bindings: [.text(id)])
            .first.map(Self.decode)
    }

    private static let select = """
        SELECT id, project_uuid, peer_uuid, generation, provider_id,
               provider_generation, fencing_token, operation_group_id,
               desired_sha256, observed_sha256, route_json,
               route_json_sha256, lifecycle_state, finalizer_state,
               selected_transport, key_epoch,
               reconnect_attempt, created_at_ms, updated_at_ms
        FROM service_tunnel_sessions
        """

    private static func decode(_ row: [String?]) throws -> ServiceTunnelStateRecord {
        guard row.count == 19,
              let id = row[0], let project = row[1], let peer = row[2],
              let generation = row[3].flatMap(Int64.init), let provider = row[4],
              let providerGeneration = row[5].flatMap(Int64.init), let fence = row[6],
              let group = row[7], let desired = row[8], let routeJSON = row[10],
              let routeJSONSHA256 = row[11],
              let lifecycleText = row[12], let lifecycle = ServiceTunnelLifecycleState(rawValue: lifecycleText),
              let finalizerText = row[13], let finalizer = ServiceTunnelFinalizerState(rawValue: finalizerText),
              let keyEpoch = row[15].flatMap(Int64.init),
              let reconnect = row[16].flatMap(Int.init),
              let created = row[17].flatMap(Int64.init), let updated = row[18].flatMap(Int64.init) else {
            throw StateStoreError.invalidRecord("Persisted service tunnel intent is incomplete.")
        }
        let transport = try row[14].map {
            guard let value = ServiceTunnelTransportState(rawValue: $0) else {
                throw StateStoreError.invalidRecord("Persisted service tunnel transport is invalid.")
            }
            return value
        }
        let record = ServiceTunnelStateRecord(
            id: id, projectUUID: project, peerUUID: peer, generation: generation,
            providerID: provider, providerGeneration: providerGeneration,
            fencingToken: fence, operationGroupID: group, desiredSHA256: desired,
            observedSHA256: row[9], routeJSON: routeJSON,
            routeJSONSHA256: routeJSONSHA256, lifecycleState: lifecycle,
            finalizerState: finalizer, selectedTransport: transport, keyEpoch: keyEpoch,
            reconnectAttempt: reconnect, createdAtUnixMilliseconds: created,
            updatedAtUnixMilliseconds: updated
        )
        try validate(record)
        return record
    }

    private static func optional(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    private static func decodeCanonicalRoute(
        _ routeJSON: String
    ) throws -> HostwrightTunnelRoute {
        let data = Data(routeJSON.utf8)
        do {
            let route = try JSONDecoder().decode(
                HostwrightTunnelRoute.self,
                from: data
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .sortedKeys,
                .withoutEscapingSlashes
            ]
            guard try encoder.encode(route) == data else {
                throw StateStoreError.invalidRecord(
                    "Persisted service tunnel route JSON is not canonical."
                )
            }
            return route
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.invalidRecord(
                "Persisted service tunnel route JSON is invalid."
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func validateUUID(_ value: String, label: String) throws {
        guard HostwrightResourceUUID.isValid(value) else {
            throw StateStoreError.invalidRecord("\(label) must be a canonical UUID.")
        }
    }

    private static func validateSHA256(_ value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StateStoreError.invalidRecord("Service tunnel evidence must be lowercase SHA256.")
        }
    }
}

public extension SQLiteStateStore {
    var serviceTunnels: ServiceTunnelStateRepository {
        ServiceTunnelStateRepository(store: self)
    }
}

extension ServiceTunnelStateRepository: HostwrightTunnelIntentPersisting {
    public func save(_ intent: HostwrightTunnelSessionIntent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let routeData = try encoder.encode(intent.route)
        let routeJSON = String(
            decoding: routeData,
            as: UTF8.self
        )
        let existing = try load(id: intent.route.routeUUID)
        let record = ServiceTunnelStateRecord(
            id: intent.route.routeUUID,
            projectUUID: intent.route.projectUUID,
            peerUUID: intent.route.peerUUID,
            generation: intent.route.generation,
            providerID: intent.route.providerID,
            providerGeneration: intent.route.providerGeneration,
            fencingToken: intent.route.fencingToken,
            operationGroupID: intent.route.operationGroupID,
            desiredSHA256: intent.route.desiredSHA256,
            observedSHA256: intent.observedSHA256,
            routeJSON: routeJSON,
            routeJSONSHA256: Self.sha256(routeData),
            lifecycleState: Self.lifecycle(intent.phase),
            finalizerState: Self.finalizer(intent.finalizer),
            selectedTransport: intent.selectedTransport.map {
                ServiceTunnelTransportState(rawValue: $0.rawValue)!
            },
            keyEpoch: intent.keyEpoch,
            reconnectAttempt: intent.reconnectAttempt,
            createdAtUnixMilliseconds:
                existing?.createdAtUnixMilliseconds
                ?? intent.updatedAtUnixMilliseconds,
            updatedAtUnixMilliseconds:
                intent.updatedAtUnixMilliseconds
        )
        _ = try save(
            record,
            replacing: existing.map {
                ServiceTunnelExpectedVersion(
                    generation: $0.generation,
                    fencingToken: $0.fencingToken
                )
            }
        )
    }

    public func load(
        routeUUID: String
    ) throws -> HostwrightTunnelSessionIntent? {
        guard let record = try load(id: routeUUID) else {
            return nil
        }
        let route = try Self.decodeCanonicalRoute(record.routeJSON)
        guard
            route.routeUUID == record.id,
            route.projectUUID == record.projectUUID,
            route.peerUUID == record.peerUUID,
            route.generation == record.generation,
            route.providerID == record.providerID,
            route.providerGeneration == record.providerGeneration,
            route.fencingToken == record.fencingToken,
            route.operationGroupID == record.operationGroupID,
            route.desiredSHA256 == record.desiredSHA256,
            let phase = HostwrightTunnelSessionPhase(
                rawValue: record.lifecycleState.rawValue
            ),
            let finalizer = HostwrightTunnelFinalizer(
                rawValue: record.finalizerState.rawValue
            )
        else {
            throw StateStoreError.invalidRecord(
                "Persisted service tunnel route lost exact authority."
            )
        }
        return HostwrightTunnelSessionIntent(
            route: route,
            phase: phase,
            finalizer: finalizer,
            selectedTransport: record.selectedTransport.flatMap {
                HostwrightTunnelTransport(rawValue: $0.rawValue)
            },
            keyEpoch: record.keyEpoch,
            reconnectAttempt: record.reconnectAttempt,
            observedSHA256: record.observedSHA256,
            updatedAtUnixMilliseconds:
                record.updatedAtUnixMilliseconds
        )
    }

    public func remove(
        routeUUID: String,
        generation: Int64,
        fencingToken: String
    ) throws {
        try removeReleased(
            id: routeUUID,
            expected: ServiceTunnelExpectedVersion(
                generation: generation,
                fencingToken: fencingToken
            )
        )
    }

    private static func lifecycle(
        _ phase: HostwrightTunnelSessionPhase
    ) -> ServiceTunnelLifecycleState {
        ServiceTunnelLifecycleState(rawValue: phase.rawValue)!
    }

    private static func finalizer(
        _ value: HostwrightTunnelFinalizer
    ) -> ServiceTunnelFinalizerState {
        ServiceTunnelFinalizerState(rawValue: value.rawValue)!
    }
}
