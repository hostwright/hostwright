import Foundation
import HostwrightCore
import HostwrightRuntime

public struct NetworkPortReservationRepository: Sendable {
    public static let dynamicRange = 49_152...65_535

    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func save(
        _ record: NetworkPortReservationRecord,
        replacing expected: NetworkStateExpectedVersion? = nil
    ) throws -> NetworkPortReservationRecord {
        try Self.validate(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateProjectBinding(
                    projectUUID: record.projectUUID,
                    providerID: record.providerID,
                    providerGeneration: record.providerGeneration,
                    on: connection
                )
                try Self.validateOperationGroup(
                    id: record.operationGroupID,
                    projectUUID: record.projectUUID,
                    fencingToken: record.fencingToken,
                    on: connection
                )
                if let existing = try Self.load(id: record.id, on: connection) {
                    if existing == record {
                        return record
                    }
                    try Self.validateReplacement(
                        existing: existing,
                        incoming: record,
                        expected: expected
                    )
                    try Self.validateNoConflict(
                        record,
                        excludingID: existing.id,
                        on: connection
                    )
                    try connection.run(
                        """
                        UPDATE network_port_reservations
                        SET generation = ?, provider_generation = ?,
                            fencing_token = ?, desired_sha256 = ?,
                            observed_sha256 = ?, lifecycle_state = ?,
                            finalizer_state = ?, operation_group_id = ?,
                            updated_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .int64(record.generation),
                            .int64(record.providerGeneration),
                            .text(record.fencingToken),
                            .text(record.desiredSHA256),
                            optionalText(record.observedSHA256),
                            .text(record.lifecycleState.rawValue),
                            .text(record.finalizerState.rawValue),
                            .text(record.operationGroupID),
                            .text(record.updatedAt),
                            .text(record.id),
                            .int64(expected!.generation),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    guard expected == nil,
                          record.generation == 1,
                          record.lifecycleState == .reserved,
                          record.finalizerState == .active,
                          record.observedSHA256 == nil else {
                        throw StateStoreError.invalidRecord(
                            "A new port reservation must begin as generation 1 durable reserved intent."
                        )
                    }
                    try Self.validateNoConflict(
                        record,
                        excludingID: nil,
                        on: connection
                    )
                    try connection.run(
                        """
                        INSERT INTO network_port_reservations (
                            id, project_uuid, resource_uuid,
                            service_name, generation, provider_id,
                            provider_generation, fencing_token,
                            bind_address, host_port, container_port,
                            protocol, allocation_kind,
                            desired_sha256, observed_sha256,
                            lifecycle_state, finalizer_state,
                            operation_group_id, created_at, updated_at
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                        )
                        """,
                        bindings: [
                            .text(record.id),
                            .text(record.projectUUID),
                            .text(record.resourceUUID),
                            .text(record.serviceName),
                            .int64(record.generation),
                            .text(record.providerID),
                            .int64(record.providerGeneration),
                            .text(record.fencingToken),
                            .text(record.bindAddress),
                            .int(record.hostPort),
                            .int(record.containerPort),
                            .text(record.protocolName.rawValue),
                            .text(record.allocationKind.rawValue),
                            .text(record.desiredSHA256),
                            optionalText(record.observedSHA256),
                            .text(record.lifecycleState.rawValue),
                            .text(record.finalizerState.rawValue),
                            .text(record.operationGroupID),
                            .text(record.createdAt),
                            .text(record.updatedAt)
                        ]
                    )
                }
                guard try Self.load(id: record.id, on: connection) ==
                        record else {
                    throw StateStoreError.transactionInvariantViolation(
                        message:
                            "Port reservation compare-and-swap did not persist the exact record."
                    )
                }
                return record
            }
        }
    }

    public func load(id: String) throws -> NetworkPortReservationRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            try Self.load(id: id, on: connection)
        }
    }

    public func loadProject(
        projectUUID: String,
        includeReleased: Bool = false
    ) throws -> [NetworkPortReservationRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let suffix = includeReleased
                ? ""
                : " AND lifecycle_state != 'released'"
            let rows = try connection.query(
                """
                SELECT id, project_uuid, resource_uuid, service_name,
                       generation, provider_id, provider_generation,
                       fencing_token, bind_address, host_port,
                       container_port, protocol, allocation_kind,
                       desired_sha256, observed_sha256,
                       lifecycle_state, finalizer_state,
                       operation_group_id, created_at, updated_at
                FROM network_port_reservations
                WHERE project_uuid = ?\(suffix)
                ORDER BY bind_address ASC, host_port ASC,
                         protocol ASC, resource_uuid ASC, id ASC
                """,
                bindings: [.text(projectUUID)]
            )
            return try rows.map(Self.record(from:))
        }
    }

    public func activeHostPorts(
        bindAddress: String,
        protocolName: NetworkPortReservationProtocol
    ) throws -> Set<Int> {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT host_port
                FROM network_port_reservations
                WHERE bind_address = ? AND protocol = ?
                  AND lifecycle_state != 'released'
                ORDER BY host_port ASC
                """,
                bindings: [
                    .text(bindAddress),
                    .text(protocolName.rawValue)
                ]
            )
            return Set(try rows.map { row in
                guard row.count == 1,
                      let value = row[0],
                      let port = Int(value) else {
                    throw StateStoreError.invalidRecord(
                        "Port reservation query returned an invalid host port."
                    )
                }
                return port
            })
        }
    }

    public func firstAvailableDynamicPort(
        bindAddress: String,
        protocolName: NetworkPortReservationProtocol,
        additionallyUnavailable: Set<Int> = []
    ) throws -> Int? {
        let unavailable = try activeHostPorts(
            bindAddress: bindAddress,
            protocolName: protocolName
        ).union(additionallyUnavailable)
        return Self.dynamicRange.first { !unavailable.contains($0) }
    }

    private static func load(
        id: String,
        on connection: SQLiteConnection
    ) throws -> NetworkPortReservationRecord? {
        let rows = try connection.query(
            """
            SELECT id, project_uuid, resource_uuid, service_name,
                   generation, provider_id, provider_generation,
                   fencing_token, bind_address, host_port,
                   container_port, protocol, allocation_kind,
                   desired_sha256, observed_sha256,
                   lifecycle_state, finalizer_state,
                   operation_group_id, created_at, updated_at
            FROM network_port_reservations
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        )
        return try rows.first.map(record(from:))
    }

    private static func record(
        from row: [String?]
    ) throws -> NetworkPortReservationRecord {
        guard row.count == 20,
              let id = row[0],
              let projectUUID = row[1],
              let resourceUUID = row[2],
              let serviceName = row[3],
              let generationText = row[4],
              let generation = Int64(generationText),
              let providerID = row[5],
              let providerGenerationText = row[6],
              let providerGeneration = Int64(providerGenerationText),
              let fencingToken = row[7],
              let bindAddress = row[8],
              let hostPortText = row[9],
              let hostPort = Int(hostPortText),
              let containerPortText = row[10],
              let containerPort = Int(containerPortText),
              let protocolRaw = row[11],
              let protocolName =
                NetworkPortReservationProtocol(rawValue: protocolRaw),
              let allocationRaw = row[12],
              let allocationKind =
                NetworkPortAllocationKind(rawValue: allocationRaw),
              let desiredSHA256 = row[13],
              let lifecycleRaw = row[15],
              let lifecycleState =
                NetworkPortReservationLifecycle(rawValue: lifecycleRaw),
              let finalizerRaw = row[16],
              let finalizerState =
                NetworkStateFinalizer(rawValue: finalizerRaw),
              let operationGroupID = row[17],
              let createdAt = row[18],
              let updatedAt = row[19] else {
            throw StateStoreError.invalidRecord(
                "Port reservation row is malformed."
            )
        }
        let record = NetworkPortReservationRecord(
            id: id,
            projectUUID: projectUUID,
            resourceUUID: resourceUUID,
            serviceName: serviceName,
            generation: generation,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            bindAddress: bindAddress,
            hostPort: hostPort,
            containerPort: containerPort,
            protocolName: protocolName,
            allocationKind: allocationKind,
            desiredSHA256: desiredSHA256,
            observedSHA256: row[14],
            lifecycleState: lifecycleState,
            finalizerState: finalizerState,
            operationGroupID: operationGroupID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func validate(
        _ record: NetworkPortReservationRecord
    ) throws {
        guard HostwrightResourceUUID.isValid(record.id),
              HostwrightResourceUUID.isValid(record.projectUUID),
              HostwrightResourceUUID.isValid(record.resourceUUID),
              HostwrightResourceUUID.isValid(record.fencingToken),
              !record.serviceName.isEmpty,
              record.serviceName.utf8.count <= 255,
              record.serviceName.rangeOfCharacter(
                from: .newlines
              ) == nil,
              record.generation > 0,
              record.providerGeneration > 0,
              RuntimeProviderID.knownValues.contains(
                RuntimeProviderID(rawValue: record.providerID)
              ),
              ["127.0.0.1", "::1"].contains(record.bindAddress),
              (1...65_535).contains(record.containerPort),
              (1_024...65_535).contains(record.hostPort),
              record.allocationKind != .dynamic ||
                dynamicRange.contains(record.hostPort),
              isSHA256(record.desiredSHA256),
              record.observedSHA256.map(isSHA256) ?? true,
              Self.validState(record),
              ISO8601DateFormatter().date(from: record.createdAt) != nil,
              ISO8601DateFormatter().date(from: record.updatedAt) != nil else {
            throw StateStoreError.invalidRecord(
                "Port reservation record is invalid."
            )
        }
    }

    private static func validState(
        _ record: NetworkPortReservationRecord
    ) -> Bool {
        switch (record.lifecycleState, record.finalizerState) {
        case (.reserved, .active):
            return record.observedSHA256 == nil
        case (.active, .active):
            return record.observedSHA256 != nil
        case (.releasing, .releasing):
            return true
        case (.released, .released):
            return record.observedSHA256 != nil
        case (.faulted, .active),
             (.faulted, .releasing),
             (.faulted, .quarantined):
            return true
        default:
            return false
        }
    }

    private static func validateReplacement(
        existing: NetworkPortReservationRecord,
        incoming: NetworkPortReservationRecord,
        expected: NetworkStateExpectedVersion?
    ) throws {
        guard let expected,
              expected.generation == existing.generation,
              expected.fencingToken == existing.fencingToken,
              incoming.id == existing.id,
              incoming.projectUUID == existing.projectUUID,
              incoming.resourceUUID == existing.resourceUUID,
              incoming.serviceName == existing.serviceName,
              incoming.providerID == existing.providerID,
              incoming.bindAddress == existing.bindAddress,
              incoming.hostPort == existing.hostPort,
              incoming.containerPort == existing.containerPort,
              incoming.protocolName == existing.protocolName,
              incoming.allocationKind == existing.allocationKind,
              incoming.createdAt == existing.createdAt,
              incoming.providerGeneration >=
                existing.providerGeneration,
              validTransition(
                from: existing.lifecycleState,
                to: incoming.lifecycleState,
                sameGeneration:
                    incoming.generation == existing.generation
              ),
              incoming.generation == existing.generation ||
                incoming.generation == existing.generation + 1 else {
            throw StateStoreError.invalidRecord(
                "Port reservation replacement lost immutable identity, exact fence, generation, or lifecycle order."
            )
        }
    }

    private static func validTransition(
        from: NetworkPortReservationLifecycle,
        to: NetworkPortReservationLifecycle,
        sameGeneration: Bool
    ) -> Bool {
        if sameGeneration {
            switch (from, to) {
            case (.reserved, .active),
                 (.reserved, .faulted),
                 (.active, .faulted),
                 (.releasing, .released),
                 (.releasing, .faulted):
                return true
            default:
                return false
            }
        }
        switch (from, to) {
        case (.active, .reserved),
             (.reserved, .releasing),
             (.active, .releasing),
             (.faulted, .releasing):
            return true
        default:
            return false
        }
    }

    private static func validateNoConflict(
        _ record: NetworkPortReservationRecord,
        excludingID: String?,
        on connection: SQLiteConnection
    ) throws {
        guard record.lifecycleState != .released else { return }
        let rows = try connection.query(
            """
            SELECT id
            FROM network_port_reservations
            WHERE bind_address = ? AND host_port = ?
              AND protocol = ? AND lifecycle_state != 'released'
              AND (? IS NULL OR id != ?)
            LIMIT 1
            """,
            bindings: [
                .text(record.bindAddress),
                .int(record.hostPort),
                .text(record.protocolName.rawValue),
                optionalText(excludingID),
                optionalText(excludingID)
            ]
        )
        guard rows.isEmpty else {
            throw StateStoreError.invalidRecord(
                "Port reservation conflicts with an existing active reservation."
            )
        }
    }

    private static func validateProjectBinding(
        projectUUID: String,
        providerID: String,
        providerGeneration: Int64,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT mutation_provider, provider_generation
            FROM projects
            WHERE resource_uuid = ?
            LIMIT 1
            """,
            bindings: [.text(projectUUID)]
        )
        guard let row = rows.first,
              row.count == 2,
              let persistedProvider = row[0],
              RuntimeProviderBinding.stableID(
                for: persistedProvider
              )?.rawValue == providerID,
              let generationText = row[1],
              Int64(generationText) == providerGeneration else {
            throw StateStoreError.invalidRecord(
                "Port reservation requires the exact project provider binding and generation."
            )
        }
    }

    private static func validateOperationGroup(
        id: String,
        projectUUID: String,
        fencingToken: String,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT operation.fencing_token, project.resource_uuid
            FROM operation_groups AS operation
            JOIN projects AS project
              ON project.id = operation.project_id
            WHERE operation.id = ?
              AND operation.status = 'active'
            LIMIT 1
            """,
            bindings: [.text(id)]
        )
        guard rows.count == 1,
              rows[0][0] == fencingToken,
              rows[0][1] == projectUUID else {
            throw StateStoreError.invalidRecord(
                "Port reservation requires an active project operation group with the exact fencing token."
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }
}

public extension SQLiteStateStore {
    var networkPorts: NetworkPortReservationRepository {
        NetworkPortReservationRepository(store: self)
    }
}
