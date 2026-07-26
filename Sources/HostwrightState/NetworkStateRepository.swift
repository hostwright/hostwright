import Foundation
import HostwrightCore
import HostwrightRuntime

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct NetworkStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func saveNetwork(
        _ record: NetworkStateResourceRecord,
        replacing expected: NetworkStateExpectedVersion? = nil
    ) throws -> NetworkStateResourceRecord {
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
                if let existing = try Self.loadNetwork(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateNetworkReplacement(
                        existing: existing,
                        incoming: record,
                        expected: expected
                    )
                    try connection.run(
                        """
                        UPDATE network_resources
                        SET generation = ?, provider_generation = ?,
                            fencing_token = ?, driver = ?,
                            requested_ipv4 = ?, requested_ipv6 = ?,
                            observed_ipv4_json = ?,
                            observed_ipv6_json = ?,
                            desired_sha256 = ?, observed_sha256 = ?,
                            lifecycle_state = ?, finalizer_state = ?,
                            operation_group_id = ?, updated_at = ?
                        WHERE id = ? AND generation = ?
                          AND fencing_token = ?
                        """,
                        bindings: [
                            .int64(record.generation),
                            .int64(record.providerGeneration),
                            .text(record.fencingToken),
                            .text(record.driver.rawValue),
                            .text(record.requestedIPv4.storedValue),
                            .text(record.requestedIPv6.storedValue),
                            .text(try Self.addressJSON(record.observedIPv4)),
                            .text(try Self.addressJSON(record.observedIPv6)),
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
                          record.lifecycleState == .creating,
                          record.finalizerState == .pending,
                          record.observedSHA256 == nil,
                          record.observedIPv4.isEmpty,
                          record.observedIPv6.isEmpty else {
                        throw StateStoreError.invalidRecord(
                            "New network state must begin with generation 1 durable create intent."
                        )
                    }
                    try connection.run(
                        """
                        INSERT INTO network_resources (
                            id, project_uuid, name, runtime_name,
                            generation, provider_id,
                            provider_generation, fencing_token,
                            driver, requested_ipv4, requested_ipv6,
                            observed_ipv4_json, observed_ipv6_json,
                            desired_sha256, observed_sha256,
                            lifecycle_state, finalizer_state,
                            operation_group_id, created_at, updated_at
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?, ?, ?
                        )
                        """,
                        bindings: [
                            .text(record.id),
                            .text(record.projectUUID),
                            .text(record.name),
                            .text(record.runtimeName),
                            .int64(record.generation),
                            .text(record.providerID),
                            .int64(record.providerGeneration),
                            .text(record.fencingToken),
                            .text(record.driver.rawValue),
                            .text(record.requestedIPv4.storedValue),
                            .text(record.requestedIPv6.storedValue),
                            .text(try Self.addressJSON(record.observedIPv4)),
                            .text(try Self.addressJSON(record.observedIPv6)),
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
                guard try Self.loadNetwork(
                    id: record.id,
                    on: connection
                ) == record else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Network state compare-and-swap did not persist the exact record."
                    )
                }
                return record
            }
        }
    }

    public func loadNetwork(
        id: String
    ) throws -> NetworkStateResourceRecord? {
        try Self.validateUUID(id, label: "network id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.loadNetwork(id: id, on: $0)
        }
    }

    public func listNetworks(
        projectUUID: String? = nil
    ) throws -> [NetworkStateResourceRecord] {
        if let projectUUID {
            try Self.validateUUID(
                projectUUID,
                label: "network project UUID"
            )
        }
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            let sql = Self.networkSelect +
                (projectUUID == nil ? "" : " WHERE project_uuid = ?") +
                " ORDER BY project_uuid, name, id"
            let bindings = projectUUID.map {
                [SQLiteValue.text($0)]
            } ?? []
            return try connection.query(
                sql,
                bindings: bindings
            ).map(Self.network(from:))
        }
    }

    @discardableResult
    public func removeDeletedNetwork(
        id: String,
        expected: NetworkStateExpectedVersion
    ) throws -> Bool {
        try Self.validateUUID(id, label: "network id")
        try Self.validate(expected)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let record = try Self.loadNetwork(
                    id: id,
                    on: connection
                ) else {
                    return false
                }
                guard record.generation == expected.generation,
                      record.fencingToken == expected.fencingToken,
                      record.lifecycleState == .deleted,
                      record.finalizerState == .released else {
                    throw StateStoreError.invalidRecord(
                        "Network deletion requires the exact terminal generation and fence."
                    )
                }
                guard try connection.query(
                    """
                    SELECT 1 FROM network_attachments
                    WHERE network_uuid = ?
                    LIMIT 1
                    """,
                    bindings: [.text(id)]
                ).isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Network deletion requires all exact attachment records to be removed first."
                    )
                }
                try connection.run(
                    """
                    DELETE FROM network_resources
                    WHERE id = ? AND generation = ?
                      AND fencing_token = ?
                      AND lifecycle_state = 'deleted'
                      AND finalizer_state = 'released'
                    """,
                    bindings: [
                        .text(id),
                        .int64(expected.generation),
                        .text(expected.fencingToken)
                    ]
                )
                guard try Self.loadNetwork(
                    id: id,
                    on: connection
                ) == nil else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Network state exact deletion predicate did not remove its record."
                    )
                }
                return true
            }
        }
    }

    @discardableResult
    public func saveAttachment(
        _ record: NetworkStateAttachmentRecord,
        replacing expected: NetworkStateExpectedVersion? = nil
    ) throws -> NetworkStateAttachmentRecord {
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
                guard let network = try Self.loadNetwork(
                    id: record.networkUUID,
                    on: connection
                ),
                network.projectUUID == record.projectUUID,
                network.providerID == record.providerID,
                network.providerGeneration == record.providerGeneration,
                network.lifecycleState == .available,
                network.finalizerState == .active else {
                    throw StateStoreError.invalidRecord(
                        "Network attachment requires the exact available network authority."
                    )
                }
                if let existing = try Self.loadAttachment(
                    id: record.id,
                    on: connection
                ) {
                    if existing == record { return record }
                    try Self.validateAttachmentReplacement(
                        existing: existing,
                        incoming: record,
                        expected: expected
                    )
                    try connection.run(
                        """
                        UPDATE network_attachments
                        SET generation = ?, provider_generation = ?,
                            fencing_token = ?, desired_sha256 = ?,
                            observed_sha256 = ?,
                            lifecycle_state = ?, finalizer_state = ?,
                            operation_group_id = ?, updated_at = ?
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
                          record.lifecycleState == .attaching,
                          record.finalizerState == .pending,
                          record.observedSHA256 == nil else {
                        throw StateStoreError.invalidRecord(
                            "New network attachment state must begin with generation 1 durable attach intent."
                        )
                    }
                    try connection.run(
                        """
                        INSERT INTO network_attachments (
                            id, network_uuid, project_uuid,
                            resource_uuid, generation, provider_id,
                            provider_generation, fencing_token,
                            desired_sha256, observed_sha256,
                            lifecycle_state, finalizer_state,
                            operation_group_id, created_at, updated_at
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                        )
                        """,
                        bindings: [
                            .text(record.id),
                            .text(record.networkUUID),
                            .text(record.projectUUID),
                            .text(record.resourceUUID),
                            .int64(record.generation),
                            .text(record.providerID),
                            .int64(record.providerGeneration),
                            .text(record.fencingToken),
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
                guard try Self.loadAttachment(
                    id: record.id,
                    on: connection
                ) == record else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Network attachment compare-and-swap did not persist the exact record."
                    )
                }
                return record
            }
        }
    }

    public func loadAttachment(
        id: String
    ) throws -> NetworkStateAttachmentRecord? {
        try Self.validateUUID(id, label: "network attachment id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.loadAttachment(id: id, on: $0)
        }
    }

    public func listAttachments(
        networkUUID: String? = nil
    ) throws -> [NetworkStateAttachmentRecord] {
        if let networkUUID {
            try Self.validateUUID(
                networkUUID,
                label: "attachment network UUID"
            )
        }
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            let sql = Self.attachmentSelect +
                (networkUUID == nil ? "" : " WHERE network_uuid = ?") +
                " ORDER BY project_uuid, network_uuid, resource_uuid, id"
            let bindings = networkUUID.map {
                [SQLiteValue.text($0)]
            } ?? []
            return try connection.query(
                sql,
                bindings: bindings
            ).map(Self.attachment(from:))
        }
    }

    @discardableResult
    public func removeDetachedAttachment(
        id: String,
        expected: NetworkStateExpectedVersion
    ) throws -> Bool {
        try Self.validateUUID(id, label: "network attachment id")
        try Self.validate(expected)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let record = try Self.loadAttachment(
                    id: id,
                    on: connection
                ) else {
                    return false
                }
                guard record.generation == expected.generation,
                      record.fencingToken == expected.fencingToken,
                      record.lifecycleState == .detached,
                      record.finalizerState == .released else {
                    throw StateStoreError.invalidRecord(
                        "Attachment deletion requires the exact terminal generation and fence."
                    )
                }
                try connection.run(
                    """
                    DELETE FROM network_attachments
                    WHERE id = ? AND generation = ?
                      AND fencing_token = ?
                      AND lifecycle_state = 'detached'
                      AND finalizer_state = 'released'
                    """,
                    bindings: [
                        .text(id),
                        .int64(expected.generation),
                        .text(expected.fencingToken)
                    ]
                )
                guard try Self.loadAttachment(
                    id: id,
                    on: connection
                ) == nil else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Network attachment exact deletion predicate did not remove its record."
                    )
                }
                return true
            }
        }
    }

    static func invalidStoredRecordCount(
        on connection: SQLiteConnection
    ) throws -> Int {
        var invalid = 0
        for row in try connection.query(
            networkSelect + " ORDER BY project_uuid, name, id"
        ) {
            do {
                try validate(try network(from: row))
            } catch {
                invalid += 1
            }
        }
        for row in try connection.query(
            attachmentSelect +
                " ORDER BY project_uuid, network_uuid, resource_uuid, id"
        ) {
            do {
                try validate(try attachment(from: row))
            } catch {
                invalid += 1
            }
        }
        let relationshipRows = try connection.query(
            """
            SELECT COUNT(*)
            FROM network_attachments AS attachment
            WHERE NOT EXISTS (
                SELECT 1
                FROM network_resources AS network
                WHERE network.id = attachment.network_uuid
                  AND network.project_uuid =
                      attachment.project_uuid
                  AND network.provider_id =
                      attachment.provider_id
                  AND network.provider_generation =
                      attachment.provider_generation
            )
            """
        )
        invalid += relationshipRows.first?.first
            .flatMap { $0 }
            .flatMap(Int.init) ?? 1
        return invalid
    }

    private static let networkSelect = """
        SELECT id, project_uuid, name, runtime_name, generation,
               provider_id, provider_generation, fencing_token,
               driver, requested_ipv4, requested_ipv6,
               observed_ipv4_json, observed_ipv6_json,
               desired_sha256, observed_sha256, lifecycle_state,
               finalizer_state, operation_group_id, created_at,
               updated_at
        FROM network_resources
        """

    private static let attachmentSelect = """
        SELECT id, network_uuid, project_uuid, resource_uuid,
               generation, provider_id, provider_generation,
               fencing_token, desired_sha256, observed_sha256,
               lifecycle_state, finalizer_state,
               operation_group_id, created_at, updated_at
        FROM network_attachments
        """

    private static func loadNetwork(
        id: String,
        on connection: SQLiteConnection
    ) throws -> NetworkStateResourceRecord? {
        try connection.query(
            networkSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(network(from:))
    }

    private static func loadAttachment(
        id: String,
        on connection: SQLiteConnection
    ) throws -> NetworkStateAttachmentRecord? {
        try connection.query(
            attachmentSelect + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(attachment(from:))
    }

    private static func network(
        from row: [String?]
    ) throws -> NetworkStateResourceRecord {
        guard row.count == 20,
              let id = row[0],
              let projectUUID = row[1],
              let name = row[2],
              let runtimeName = row[3],
              let generationText = row[4],
              let generation = Int64(generationText),
              let providerID = row[5],
              let providerGenerationText = row[6],
              let providerGeneration = Int64(providerGenerationText),
              let fencingToken = row[7],
              let driverText = row[8],
              let driver = NetworkStateDriver(rawValue: driverText),
              let requestedIPv4 = row[9],
              let requestedIPv6 = row[10],
              let observedIPv4JSON = row[11],
              let observedIPv6JSON = row[12],
              let desiredSHA256 = row[13],
              let lifecycleText = row[15],
              let lifecycle = NetworkStateResourceLifecycle(
                rawValue: lifecycleText
              ),
              let finalizerText = row[16],
              let finalizer = NetworkStateFinalizer(
                rawValue: finalizerText
              ),
              let operationGroupID = row[17],
              let createdAt = row[18],
              let updatedAt = row[19] else {
            throw StateStoreError.invalidRecord(
                "Could not decode network resource state."
            )
        }
        let record = NetworkStateResourceRecord(
            id: id,
            projectUUID: projectUUID,
            name: name,
            runtimeName: runtimeName,
            generation: generation,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            driver: driver,
            requestedIPv4: NetworkStateAddressRequest(
                storedValue: requestedIPv4
            ),
            requestedIPv6: NetworkStateAddressRequest(
                storedValue: requestedIPv6
            ),
            observedIPv4: try addresses(from: observedIPv4JSON),
            observedIPv6: try addresses(from: observedIPv6JSON),
            desiredSHA256: desiredSHA256,
            observedSHA256: row[14],
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            operationGroupID: operationGroupID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func attachment(
        from row: [String?]
    ) throws -> NetworkStateAttachmentRecord {
        guard row.count == 15,
              let id = row[0],
              let networkUUID = row[1],
              let projectUUID = row[2],
              let resourceUUID = row[3],
              let generationText = row[4],
              let generation = Int64(generationText),
              let providerID = row[5],
              let providerGenerationText = row[6],
              let providerGeneration = Int64(providerGenerationText),
              let fencingToken = row[7],
              let desiredSHA256 = row[8],
              let lifecycleText = row[10],
              let lifecycle = NetworkStateAttachmentLifecycle(
                rawValue: lifecycleText
              ),
              let finalizerText = row[11],
              let finalizer = NetworkStateFinalizer(
                rawValue: finalizerText
              ),
              let operationGroupID = row[12],
              let createdAt = row[13],
              let updatedAt = row[14] else {
            throw StateStoreError.invalidRecord(
                "Could not decode network attachment state."
            )
        }
        let record = NetworkStateAttachmentRecord(
            id: id,
            networkUUID: networkUUID,
            projectUUID: projectUUID,
            resourceUUID: resourceUUID,
            generation: generation,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            desiredSHA256: desiredSHA256,
            observedSHA256: row[9],
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            operationGroupID: operationGroupID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        try validate(record)
        return record
    }

    private static func validate(
        _ record: NetworkStateResourceRecord
    ) throws {
        try validateUUID(record.id, label: "network id")
        try validateUUID(
            record.projectUUID,
            label: "network project UUID"
        )
        try validateName(record.name)
        try validateRuntimeName(record.runtimeName)
        guard (try? RuntimeNetworkIdentity(
            logicalName: record.name,
            resourceUUID: record.id,
            projectUUID: record.projectUUID,
            runtimeIdentifier: record.runtimeName
        )) != nil else {
            throw StateStoreError.invalidRecord(
                "Network state UUID and runtime name must match the canonical project-scoped identity."
            )
        }
        try validateProvider(
            id: record.providerID,
            generation: record.providerGeneration
        )
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
        try validateAddressRequest(record.requestedIPv4, family: 4)
        try validateAddressRequest(record.requestedIPv6, family: 6)
        try validateAddresses(record.observedIPv4, family: 4)
        try validateAddresses(record.observedIPv6, family: 6)
        try validateSHA256(record.desiredSHA256)
        try record.observedSHA256.map(validateSHA256)
        try validateUUID(
            record.operationGroupID,
            label: "network operation group id"
        )
        try validateTimestamps(
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
        guard valid(
            lifecycle: record.lifecycleState,
            finalizer: record.finalizerState,
            observed: record.observedSHA256
        ) else {
            throw StateStoreError.invalidRecord(
                "Network lifecycle, finalizer, and observation state are inconsistent."
            )
        }
    }

    private static func validate(
        _ record: NetworkStateAttachmentRecord
    ) throws {
        try validateUUID(record.id, label: "network attachment id")
        try validateUUID(
            record.networkUUID,
            label: "attachment network UUID"
        )
        try validateUUID(
            record.projectUUID,
            label: "attachment project UUID"
        )
        try validateUUID(
            record.resourceUUID,
            label: "attached resource UUID"
        )
        try validateProvider(
            id: record.providerID,
            generation: record.providerGeneration
        )
        try validateVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
        try validateSHA256(record.desiredSHA256)
        try record.observedSHA256.map(validateSHA256)
        try validateUUID(
            record.operationGroupID,
            label: "attachment operation group id"
        )
        try validateTimestamps(
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
        guard valid(
            lifecycle: record.lifecycleState,
            finalizer: record.finalizerState,
            observed: record.observedSHA256
        ) else {
            throw StateStoreError.invalidRecord(
                "Network attachment lifecycle, finalizer, and observation state are inconsistent."
            )
        }
    }

    private static func validate(
        _ expected: NetworkStateExpectedVersion
    ) throws {
        try validateVersion(
            generation: expected.generation,
            fencingToken: expected.fencingToken
        )
    }

    private static func validateNetworkReplacement(
        existing: NetworkStateResourceRecord,
        incoming: NetworkStateResourceRecord,
        expected: NetworkStateExpectedVersion?
    ) throws {
        guard let expected,
              expected.generation == existing.generation,
              expected.fencingToken == existing.fencingToken,
              incoming.generation == existing.generation + 1,
              incoming.id == existing.id,
              incoming.projectUUID == existing.projectUUID,
              incoming.name == existing.name,
              incoming.runtimeName == existing.runtimeName,
              incoming.providerID == existing.providerID,
              incoming.providerGeneration >=
                existing.providerGeneration,
              incoming.createdAt == existing.createdAt,
              validTransition(
                from: existing.lifecycleState,
                to: incoming.lifecycleState
              ) else {
            throw StateStoreError.invalidRecord(
                "Network replacement lost immutable identity, exact generation, fence, or lifecycle order."
            )
        }
    }

    private static func validateAttachmentReplacement(
        existing: NetworkStateAttachmentRecord,
        incoming: NetworkStateAttachmentRecord,
        expected: NetworkStateExpectedVersion?
    ) throws {
        guard let expected,
              expected.generation == existing.generation,
              expected.fencingToken == existing.fencingToken,
              incoming.generation == existing.generation + 1,
              incoming.id == existing.id,
              incoming.networkUUID == existing.networkUUID,
              incoming.projectUUID == existing.projectUUID,
              incoming.resourceUUID == existing.resourceUUID,
              incoming.providerID == existing.providerID,
              incoming.providerGeneration >=
                existing.providerGeneration,
              incoming.createdAt == existing.createdAt,
              validTransition(
                from: existing.lifecycleState,
                to: incoming.lifecycleState
              ) else {
            throw StateStoreError.invalidRecord(
                "Attachment replacement lost immutable identity, exact generation, fence, or lifecycle order."
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
                "Network state requires the exact project provider binding and generation."
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
                "Network state requires an active project operation group with the exact fencing token."
            )
        }
    }

    private static func valid(
        lifecycle: NetworkStateResourceLifecycle,
        finalizer: NetworkStateFinalizer,
        observed: String?
    ) -> Bool {
        switch lifecycle {
        case .creating:
            return finalizer == .pending && observed == nil
        case .available:
            return finalizer == .active && observed != nil
        case .deleting:
            return finalizer == .releasing
        case .deleted:
            return finalizer == .released && observed != nil
        case .faulted:
            return [
                .active,
                .releasing,
                .quarantined
            ].contains(finalizer)
        }
    }

    private static func valid(
        lifecycle: NetworkStateAttachmentLifecycle,
        finalizer: NetworkStateFinalizer,
        observed: String?
    ) -> Bool {
        switch lifecycle {
        case .attaching:
            return finalizer == .pending && observed == nil
        case .attached:
            return finalizer == .active && observed != nil
        case .detaching:
            return finalizer == .releasing
        case .detached:
            return finalizer == .released && observed != nil
        case .faulted:
            return [
                .active,
                .releasing,
                .quarantined
            ].contains(finalizer)
        }
    }

    private static func validTransition(
        from: NetworkStateResourceLifecycle,
        to: NetworkStateResourceLifecycle
    ) -> Bool {
        switch from {
        case .creating:
            return [.available, .deleting, .faulted].contains(to)
        case .available:
            return [.available, .deleting, .faulted].contains(to)
        case .deleting:
            return [.deleted, .faulted].contains(to)
        case .faulted:
            return [.deleting, .faulted].contains(to)
        case .deleted:
            return false
        }
    }

    private static func validTransition(
        from: NetworkStateAttachmentLifecycle,
        to: NetworkStateAttachmentLifecycle
    ) -> Bool {
        switch from {
        case .attaching:
            return [.attached, .detaching, .faulted].contains(to)
        case .attached:
            return [.attached, .detaching, .faulted].contains(to)
        case .detaching:
            return [.detached, .faulted].contains(to)
        case .faulted:
            return [.detaching, .faulted].contains(to)
        case .detached:
            return false
        }
    }

    private static func validateName(_ value: String) throws {
        guard value.utf8.count <= 63,
              value.range(
                of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$",
                options: .regularExpression
              ) != nil else {
            throw StateStoreError.invalidRecord(
                "Network name must be a bounded lowercase manifest identifier."
            )
        }
    }

    private static func validateRuntimeName(_ value: String) throws {
        guard value.utf8.count <= 128,
              value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
                options: .regularExpression
              ) != nil else {
            throw StateStoreError.invalidRecord(
                "Network runtime name must be a bounded stable identifier."
            )
        }
    }

    private static func validateProvider(
        id: String,
        generation: Int64
    ) throws {
        guard RuntimeProviderBinding.stableID(for: id)?.rawValue == id,
              generation >= 1 else {
            throw StateStoreError.invalidRecord(
                "Network provider identity must be stable and its generation positive."
            )
        }
    }

    private static func validateVersion(
        generation: Int64,
        fencingToken: String
    ) throws {
        guard generation >= 1 else {
            throw StateStoreError.invalidRecord(
                "Network state generation must be positive."
            )
        }
        try validateUUID(
            fencingToken,
            label: "network fencing token"
        )
    }

    private static func validateUUID(
        _ value: String,
        label: String
    ) throws {
        guard HostwrightResourceUUID.isValid(value) else {
            throw StateStoreError.invalidRecord(
                "\(label) must be a canonical UUID."
            )
        }
    }

    private static func validateSHA256(_ value: String) throws {
        guard value.utf8.count == 64,
              value.allSatisfy({
                  ("0"..."9").contains($0) ||
                    ("a"..."f").contains($0)
              }) else {
            throw StateStoreError.invalidRecord(
                "Network evidence digest must be lowercase SHA256."
            )
        }
    }

    private static func validateAddressRequest(
        _ request: NetworkStateAddressRequest,
        family: Int
    ) throws {
        if case .cidr(let value) = request {
            let fields = value.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard fields.count == 2,
                  value.utf8.count <= 128,
                  let prefix = Int(fields[1]),
                  (0...(family == 4 ? 32 : 128)).contains(prefix),
                  validIPAddress(String(fields[0]), family: family) else {
                throw StateStoreError.invalidRecord(
                    "Requested IPv\(family) network must be auto, disabled, or a valid CIDR."
                )
            }
        }
    }

    private static func validateAddresses(
        _ values: [String],
        family: Int
    ) throws {
        guard values.count <= 256,
              values == values.sorted(),
              Set(values).count == values.count,
              values.allSatisfy({
                  $0.utf8.count <= 64 &&
                    validIPAddress($0, family: family)
              }) else {
            throw StateStoreError.invalidRecord(
                "Observed IPv\(family) addresses must be bounded, unique, sorted, and valid."
            )
        }
    }

    private static func validIPAddress(
        _ value: String,
        family: Int
    ) -> Bool {
        let addressFamily = family == 4 ? AF_INET : AF_INET6
        var storage = [UInt8](
            repeating: 0,
            count: family == 4 ? 4 : 16
        )
        return value.withCString { source in
            storage.withUnsafeMutableBytes {
                inet_pton(
                    addressFamily,
                    source,
                    $0.baseAddress
                ) == 1
            }
        }
    }

    private static func validateTimestamps(
        createdAt: String,
        updatedAt: String
    ) throws {
        let created = timestamp(createdAt)
        let updated = timestamp(updatedAt)
        guard created != .distantPast,
              updated != .distantPast,
              updated >= created else {
            throw StateStoreError.invalidRecord(
                "Network timestamps must be ordered ISO-8601 values."
            )
        }
    }

    private static func timestamp(_ value: String) -> Date {
        guard value.utf8.count <= 64 else { return .distantPast }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ??
            whole.date(from: value) ?? .distantPast
    }

    private static func addressJSON(_ values: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let value = String(data: data, encoding: .utf8) else {
            throw StateStoreError.invalidRecord(
                "Network addresses could not be encoded."
            )
        }
        return value
    }

    private static func addresses(from value: String) throws -> [String] {
        guard value.utf8.count <= 16_384,
              let data = value.data(using: .utf8),
              let addresses = try JSONSerialization.jsonObject(
                with: data
              ) as? [String] else {
            throw StateStoreError.invalidRecord(
                "Network addresses must be a bounded JSON string array."
            )
        }
        return addresses
    }
}

public extension SQLiteStateStore {
    var networks: NetworkStateRepository {
        NetworkStateRepository(store: self)
    }
}
