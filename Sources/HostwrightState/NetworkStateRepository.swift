import Foundation
import HostwrightCore
import HostwrightRuntime

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct NetworkStateOperationIntent: Decodable {
    let schemaVersion: Int
    let action: String
    let projectUUID: String
    let networkUUID: String
    let runtimeName: String
    let providerID: String
    let providerGeneration: Int
    let capabilitySHA256: String
    let desiredSHA256: String
    let runtimeResourceGeneration: Int
}

private struct NetworkStateOperationHistory {
    let id: String
    let plannedAction: String
    let status: String
    let checkpoint: String
    let intent: NetworkStateOperationIntent
}

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
                          try Self.validAbsentNetworkInsertion(
                            record,
                            on: connection
                          ),
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

    private static func validAbsentNetworkInsertion(
        _ record: NetworkStateResourceRecord,
        on connection: SQLiteConnection
    ) throws -> Bool {
        if record.generation == 1 {
            return true
        }
        guard record.generation > 1,
              record.generation < Int64.max else {
            return false
        }
        let rows = try connection.query(
            """
            SELECT id, planned_action_type, status, checkpoint,
                   intent_json_redacted
            FROM operation_groups
            WHERE project_id = ? AND group_kind = 'network-resource'
            ORDER BY created_at ASC, rowid ASC
            """,
            bindings: [.text(recordProjectID(
                projectUUID: record.projectUUID,
                on: connection
            ))]
        )
        let decoder = JSONDecoder()
        var history: [NetworkStateOperationHistory] = []
        for row in rows {
            guard row.count == 5,
                  let id = row[0],
                  let plannedAction = row[1],
                  let status = row[2],
                  let checkpoint = row[3],
                  let encodedIntent = row[4],
                  let data = encodedIntent.data(using: .utf8),
                  let intent = try? decoder.decode(
                    NetworkStateOperationIntent.self,
                    from: data
                  ) else {
                throw StateStoreError.invalidRecord(
                    "Network recreation operation history is ambiguous."
                )
            }
            guard intent.networkUUID == record.id else {
                continue
            }
            guard intent.schemaVersion == 1,
                  intent.projectUUID == record.projectUUID,
                  intent.runtimeName == record.runtimeName,
                  intent.providerID == record.providerID,
                  Int64(intent.providerGeneration) ==
                    record.providerGeneration,
                  plannedAction == intent.action,
                  intent.action == "create" ||
                    intent.action == "delete",
                  intent.runtimeResourceGeneration > 0 else {
                throw StateStoreError.invalidRecord(
                    "Network recreation operation history lost exact provider authority."
                )
            }
            history.append(
                NetworkStateOperationHistory(
                    id: id,
                    plannedAction: plannedAction,
                    status: status,
                    checkpoint: checkpoint,
                    intent: intent
                )
            )
        }
        guard history.count >= 2,
              let current = history.last,
              current.id == record.operationGroupID,
              current.plannedAction == "create",
              current.status == OperationGroupStatus.active.rawValue,
              current.checkpoint == "intent-persisted",
              current.intent.desiredSHA256 ==
                record.desiredSHA256 else {
            return false
        }
        for pair in zip(history, history.dropFirst()) {
            guard pair.0.intent.runtimeResourceGeneration <
                    pair.1.intent.runtimeResourceGeneration else {
                return false
            }
        }
        let prior = history[history.count - 2]
        guard prior.plannedAction == "delete",
              prior.status ==
                OperationGroupStatus.succeeded.rawValue,
              prior.checkpoint == "state-committed" else {
            return false
        }
        let priorGeneration = Int64(
            prior.intent.runtimeResourceGeneration
        )
        let currentGeneration = Int64(
            current.intent.runtimeResourceGeneration
        )
        return priorGeneration <= Int64.max - 2 &&
            priorGeneration + 2 == record.generation &&
            currentGeneration == record.generation + 1
    }

    private static func recordProjectID(
        projectUUID: String,
        on connection: SQLiteConnection
    ) throws -> String {
        let rows = try connection.query(
            """
            SELECT id FROM projects
            WHERE resource_uuid = ?
            LIMIT 1
            """,
            bindings: [.text(projectUUID)]
        )
        guard let projectID = rows.first?.first ?? nil else {
            throw StateStoreError.invalidRecord(
                "Network recreation requires the exact project identity."
            )
        }
        return projectID
    }

    @discardableResult
    public func saveNetwork(
        _ record: NetworkStateResourceRecord,
        replacing expected: NetworkStateExpectedVersion? = nil,
        authority: NetworkStateMutationAuthority
    ) throws -> NetworkStateResourceRecord {
        try Self.validateMutationAuthority(
            authority,
            providerID: record.providerID,
            providerGeneration: record.providerGeneration,
            operationGroupID: record.operationGroupID,
            fencingToken: record.fencingToken
        )
        try store.withValidatedConnection(readOnly: true) {
            connection in
            try Self.validateProjectBinding(
                projectUUID: record.projectUUID,
                providerID: authority.providerID,
                providerGeneration: authority.providerGeneration,
                on: connection
            )
            try Self.validateOperationGroup(
                id: authority.operationGroupID,
                projectUUID: record.projectUUID,
                fencingToken: authority.fencingToken,
                expectedCapabilitySHA256:
                    authority.plannedCapabilitySHA256,
                on: connection
            )
        }
        return try saveNetwork(record, replacing: expected)
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

    public func evaluateNetworkRecovery(
        id: String,
        expected: NetworkStateExpectedVersion,
        authority: NetworkStateMutationAuthority,
        trigger: NetworkStateRecoveryTrigger,
        observation: NetworkStateRecoveryObservation
    ) throws -> NetworkStateRecoveryDecision {
        try Self.validateUUID(id, label: "network id")
        try Self.validate(expected)
        try Self.validateRecoveryAuthority(authority)
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            guard let record = try Self.loadNetwork(
                id: id,
                on: connection
            ) else {
                throw StateStoreError.notFound(
                    "Network state '\(id)' does not exist."
                )
            }
            try Self.validateRecoveryAuthority(
                authority,
                recordProviderID: record.providerID,
                recordProviderGeneration: record.providerGeneration,
                expected: expected,
                recordGeneration: record.generation,
                recordFencingToken: record.fencingToken
            )
            try Self.validateProjectBinding(
                projectUUID: record.projectUUID,
                providerID: authority.providerID,
                providerGeneration: authority.providerGeneration,
                on: connection
            )
            try Self.validateOperationGroup(
                id: authority.operationGroupID,
                projectUUID: record.projectUUID,
                fencingToken: authority.fencingToken,
                expectedCapabilitySHA256:
                    authority.plannedCapabilitySHA256,
                on: connection
            )
            return try Self.recoveryDecision(
                lifecycle: record.lifecycleState,
                finalizer: record.finalizerState,
                persistedObservedSHA256: record.observedSHA256,
                trigger: trigger,
                observation: observation
            )
        }
    }

    @discardableResult
    public func quarantineNetwork(
        id: String,
        expected: NetworkStateExpectedVersion,
        authority: NetworkStateMutationAuthority,
        observedSHA256: String?,
        updatedAt: String
    ) throws -> NetworkStateResourceRecord {
        try Self.validate(expected)
        try Self.validateRecoveryAuthority(authority)
        let existing = try loadNetwork(id: id)
        guard let existing else {
            throw StateStoreError.notFound(
                "Network state '\(id)' does not exist."
            )
        }
        try Self.validateRecoveryAuthority(
            authority,
            recordProviderID: existing.providerID,
            recordProviderGeneration: existing.providerGeneration,
            expected: expected,
            recordGeneration: existing.generation,
            recordFencingToken: existing.fencingToken
        )
        let quarantined = NetworkStateResourceRecord(
            id: existing.id,
            projectUUID: existing.projectUUID,
            name: existing.name,
            runtimeName: existing.runtimeName,
            generation: existing.generation + 1,
            providerID: authority.providerID,
            providerGeneration: authority.providerGeneration,
            fencingToken: authority.fencingToken,
            driver: existing.driver,
            requestedIPv4: existing.requestedIPv4,
            requestedIPv6: existing.requestedIPv6,
            observedIPv4: existing.observedIPv4,
            observedIPv6: existing.observedIPv6,
            desiredSHA256: existing.desiredSHA256,
            observedSHA256: observedSHA256 ??
                existing.observedSHA256,
            lifecycleState: .faulted,
            finalizerState: .quarantined,
            operationGroupID: authority.operationGroupID,
            createdAt: existing.createdAt,
            updatedAt: updatedAt
        )
        return try saveNetwork(
            quarantined,
            replacing: expected,
            authority: authority
        )
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
                network.providerGeneration ==
                    record.providerGeneration else {
                    throw StateStoreError.invalidRecord(
                        "Network attachment requires the exact network authority."
                    )
                }
                let existing = try Self.loadAttachment(
                    id: record.id,
                    on: connection
                )
                guard Self.networkAuthorizesAttachment(
                    network: network,
                    incoming: record,
                    isExisting: existing != nil
                ) else {
                    throw StateStoreError.invalidRecord(
                        "Network attachment lifecycle is incompatible with the parent network lifecycle."
                    )
                }
                if let existing {
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

    @discardableResult
    public func saveAttachment(
        _ record: NetworkStateAttachmentRecord,
        replacing expected: NetworkStateExpectedVersion? = nil,
        authority: NetworkStateMutationAuthority
    ) throws -> NetworkStateAttachmentRecord {
        try Self.validateMutationAuthority(
            authority,
            providerID: record.providerID,
            providerGeneration: record.providerGeneration,
            operationGroupID: record.operationGroupID,
            fencingToken: record.fencingToken
        )
        try store.withValidatedConnection(readOnly: true) {
            connection in
            try Self.validateProjectBinding(
                projectUUID: record.projectUUID,
                providerID: authority.providerID,
                providerGeneration: authority.providerGeneration,
                on: connection
            )
            try Self.validateOperationGroup(
                id: authority.operationGroupID,
                projectUUID: record.projectUUID,
                fencingToken: authority.fencingToken,
                expectedCapabilitySHA256:
                    authority.plannedCapabilitySHA256,
                on: connection
            )
        }
        return try saveAttachment(record, replacing: expected)
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

    public func evaluateAttachmentRecovery(
        id: String,
        expected: NetworkStateExpectedVersion,
        authority: NetworkStateMutationAuthority,
        trigger: NetworkStateRecoveryTrigger,
        observation: NetworkStateRecoveryObservation
    ) throws -> NetworkStateRecoveryDecision {
        try Self.validateUUID(id, label: "network attachment id")
        try Self.validate(expected)
        try Self.validateRecoveryAuthority(authority)
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            guard let record = try Self.loadAttachment(
                id: id,
                on: connection
            ) else {
                throw StateStoreError.notFound(
                    "Network attachment state '\(id)' does not exist."
                )
            }
            try Self.validateRecoveryAuthority(
                authority,
                recordProviderID: record.providerID,
                recordProviderGeneration: record.providerGeneration,
                expected: expected,
                recordGeneration: record.generation,
                recordFencingToken: record.fencingToken
            )
            try Self.validateProjectBinding(
                projectUUID: record.projectUUID,
                providerID: authority.providerID,
                providerGeneration: authority.providerGeneration,
                on: connection
            )
            try Self.validateOperationGroup(
                id: authority.operationGroupID,
                projectUUID: record.projectUUID,
                fencingToken: authority.fencingToken,
                expectedCapabilitySHA256:
                    authority.plannedCapabilitySHA256,
                on: connection
            )
            return try Self.recoveryDecision(
                lifecycle: record.lifecycleState,
                finalizer: record.finalizerState,
                persistedObservedSHA256: record.observedSHA256,
                trigger: trigger,
                observation: observation
            )
        }
    }

    @discardableResult
    public func quarantineAttachment(
        id: String,
        expected: NetworkStateExpectedVersion,
        authority: NetworkStateMutationAuthority,
        observedSHA256: String?,
        updatedAt: String
    ) throws -> NetworkStateAttachmentRecord {
        try Self.validate(expected)
        try Self.validateRecoveryAuthority(authority)
        let existing = try loadAttachment(id: id)
        guard let existing else {
            throw StateStoreError.notFound(
                "Network attachment state '\(id)' does not exist."
            )
        }
        try Self.validateRecoveryAuthority(
            authority,
            recordProviderID: existing.providerID,
            recordProviderGeneration: existing.providerGeneration,
            expected: expected,
            recordGeneration: existing.generation,
            recordFencingToken: existing.fencingToken
        )
        let quarantined = NetworkStateAttachmentRecord(
            id: existing.id,
            networkUUID: existing.networkUUID,
            projectUUID: existing.projectUUID,
            resourceUUID: existing.resourceUUID,
            generation: existing.generation + 1,
            providerID: authority.providerID,
            providerGeneration: authority.providerGeneration,
            fencingToken: authority.fencingToken,
            desiredSHA256: existing.desiredSHA256,
            observedSHA256: observedSHA256 ??
                existing.observedSHA256,
            lifecycleState: .faulted,
            finalizerState: .quarantined,
            operationGroupID: authority.operationGroupID,
            createdAt: existing.createdAt,
            updatedAt: updatedAt
        )
        return try saveAttachment(
            quarantined,
            replacing: expected,
            authority: authority
        )
    }

    public func reverseTeardownOrder(
        projectUUID: String
    ) throws -> [NetworkStateTeardownTarget] {
        try Self.validateUUID(
            projectUUID,
            label: "network project UUID"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            let attachments = try connection.query(
                Self.attachmentSelect +
                    """
                     WHERE project_uuid = ?
                     ORDER BY network_uuid DESC,
                              resource_uuid DESC, id DESC
                    """,
                bindings: [.text(projectUUID)]
            ).map(Self.attachment(from:))
            let networks = try connection.query(
                Self.networkSelect +
                    """
                     WHERE project_uuid = ?
                     ORDER BY name DESC, id DESC
                    """,
                bindings: [.text(projectUUID)]
            ).map(Self.network(from:))
            return attachments.map {
                NetworkStateTeardownTarget(
                    kind: .attachment,
                    id: $0.id,
                    networkUUID: $0.networkUUID,
                    resourceUUID: $0.resourceUUID,
                    generation: $0.generation,
                    fencingToken: $0.fencingToken
                )
            } + networks.map {
                NetworkStateTeardownTarget(
                    kind: .network,
                    id: $0.id,
                    networkUUID: $0.id,
                    generation: $0.generation,
                    fencingToken: $0.fencingToken
                )
            }
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

    private static func validateMutationAuthority(
        _ authority: NetworkStateMutationAuthority,
        providerID: String,
        providerGeneration: Int64,
        operationGroupID: String,
        fencingToken: String
    ) throws {
        try validateRecoveryAuthority(authority)
        guard authority.providerID == providerID,
              authority.providerGeneration == providerGeneration,
              authority.operationGroupID == operationGroupID,
              authority.fencingToken == fencingToken else {
            throw StateStoreError.invalidRecord(
                "Network mutation authority does not match the exact provider, generation, operation group, and fence."
            )
        }
    }

    private static func validateRecoveryAuthority(
        _ authority: NetworkStateMutationAuthority
    ) throws {
        try validateProvider(
            id: authority.providerID,
            generation: authority.providerGeneration
        )
        try validateUUID(
            authority.operationGroupID,
            label: "network authority operation group id"
        )
        try validateUUID(
            authority.fencingToken,
            label: "network authority fencing token"
        )
        try validateSHA256(authority.plannedCapabilitySHA256)
        try validateSHA256(authority.currentCapabilitySHA256)
        guard authority.plannedCapabilitySHA256 ==
                authority.currentCapabilitySHA256 else {
            throw StateStoreError.invalidRecord(
                "Network mutation refused because the negotiated capability snapshot is stale."
            )
        }
    }

    private static func validateRecoveryAuthority(
        _ authority: NetworkStateMutationAuthority,
        recordProviderID: String,
        recordProviderGeneration: Int64,
        expected: NetworkStateExpectedVersion,
        recordGeneration: Int64,
        recordFencingToken: String
    ) throws {
        guard authority.providerID == recordProviderID,
              authority.providerGeneration ==
                recordProviderGeneration,
              expected.generation == recordGeneration,
              expected.fencingToken == recordFencingToken else {
            throw StateStoreError.invalidRecord(
                "Network recovery refused a stale provider generation, record generation, or fencing token."
            )
        }
    }

    private static func recoveryDecision(
        lifecycle: NetworkStateResourceLifecycle,
        finalizer: NetworkStateFinalizer,
        persistedObservedSHA256: String?,
        trigger: NetworkStateRecoveryTrigger,
        observation: NetworkStateRecoveryObservation
    ) throws -> NetworkStateRecoveryDecision {
        let observationState = try normalizedObservation(
            observation,
            persistedObservedSHA256: persistedObservedSHA256
        )
        let action: NetworkStateRecoveryAction
        switch observationState {
        case .conflictingOrIndeterminate:
            action = .quarantine
        case .absent:
            switch lifecycle {
            case .creating, .available:
                action = .retryMutation
            case .deleting:
                action = .finalizeDeletion
            case .faulted:
                switch finalizer {
                case .active:
                    action = .retryMutation
                case .releasing:
                    action = .finalizeDeletion
                case .quarantined:
                    action = .quarantine
                case .pending, .released:
                    action = .quarantine
                }
            case .deleted:
                action = .purgeTerminalRecord
            }
        case .exactOwned:
            switch lifecycle {
            case .creating:
                action = .verifyAndAdvance
            case .available:
                action = .stable
            case .deleting:
                action = .resumeDeletion
            case .faulted:
                switch finalizer {
                case .active:
                    action = .verifyAndAdvance
                case .releasing:
                    action = .resumeDeletion
                case .quarantined:
                    action = .quarantine
                case .pending, .released:
                    action = .quarantine
                }
            case .deleted:
                action = .quarantine
            }
        }
        return NetworkStateRecoveryDecision(
            trigger: trigger,
            action: action
        )
    }

    private static func recoveryDecision(
        lifecycle: NetworkStateAttachmentLifecycle,
        finalizer: NetworkStateFinalizer,
        persistedObservedSHA256: String?,
        trigger: NetworkStateRecoveryTrigger,
        observation: NetworkStateRecoveryObservation
    ) throws -> NetworkStateRecoveryDecision {
        let observationState = try normalizedObservation(
            observation,
            persistedObservedSHA256: persistedObservedSHA256
        )
        let action: NetworkStateRecoveryAction
        switch observationState {
        case .conflictingOrIndeterminate:
            action = .quarantine
        case .absent:
            switch lifecycle {
            case .attaching, .attached:
                action = .retryMutation
            case .detaching:
                action = .finalizeDeletion
            case .faulted:
                switch finalizer {
                case .active:
                    action = .retryMutation
                case .releasing:
                    action = .finalizeDeletion
                case .quarantined:
                    action = .quarantine
                case .pending, .released:
                    action = .quarantine
                }
            case .detached:
                action = .purgeTerminalRecord
            }
        case .exactOwned:
            switch lifecycle {
            case .attaching:
                action = .verifyAndAdvance
            case .attached:
                action = .stable
            case .detaching:
                action = .resumeDeletion
            case .faulted:
                switch finalizer {
                case .active:
                    action = .verifyAndAdvance
                case .releasing:
                    action = .resumeDeletion
                case .quarantined:
                    action = .quarantine
                case .pending, .released:
                    action = .quarantine
                }
            case .detached:
                action = .quarantine
            }
        }
        return NetworkStateRecoveryDecision(
            trigger: trigger,
            action: action
        )
    }

    private enum NormalizedRecoveryObservation {
        case absent
        case exactOwned
        case conflictingOrIndeterminate
    }

    private static func normalizedObservation(
        _ observation: NetworkStateRecoveryObservation,
        persistedObservedSHA256: String?
    ) throws -> NormalizedRecoveryObservation {
        switch observation {
        case .absent:
            return .absent
        case .indeterminate:
            return .conflictingOrIndeterminate
        case .conflictingOwner(let observedSHA256):
            try observedSHA256.map(validateSHA256)
            return .conflictingOrIndeterminate
        case .exactOwned(let observedSHA256):
            try validateSHA256(observedSHA256)
            guard persistedObservedSHA256 == nil ||
                    persistedObservedSHA256 == observedSHA256 else {
                return .conflictingOrIndeterminate
            }
            return .exactOwned
        }
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

    private static func networkAuthorizesAttachment(
        network: NetworkStateResourceRecord,
        incoming: NetworkStateAttachmentRecord,
        isExisting: Bool
    ) -> Bool {
        guard isExisting else {
            return network.lifecycleState == .available &&
                network.finalizerState == .active
        }
        switch incoming.lifecycleState {
        case .attaching, .attached:
            return network.lifecycleState == .available &&
                network.finalizerState == .active
        case .detaching, .detached, .faulted:
            return [
                .available,
                .deleting,
                .faulted
            ].contains(network.lifecycleState)
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
        expectedCapabilitySHA256: String? = nil,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT operation.fencing_token, project.resource_uuid,
                   operation.intent_json_redacted
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
        guard let expectedCapabilitySHA256 else { return }
        guard let intentJSON = rows[0][2],
              intentJSON.utf8.count <= 1_048_576,
              let data = intentJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any],
              object["capabilitySHA256"] as? String ==
                expectedCapabilitySHA256 else {
            throw StateStoreError.invalidRecord(
                "Network state requires the exact capability digest persisted in operation intent."
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
                    validObservedAddress(
                        $0,
                        family: family
                    )
              }) else {
            throw StateStoreError.invalidRecord(
                "Observed IPv\(family) addresses and subnets must be bounded, unique, sorted, and valid."
            )
        }
    }

    private static func validObservedAddress(
        _ value: String,
        family: Int
    ) -> Bool {
        if validIPAddress(value, family: family) {
            return true
        }
        let fields = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 2,
              let prefix = Int(fields[1]),
              (0...(family == 4 ? 32 : 128)).contains(prefix) else {
            return false
        }
        return validIPAddress(
            String(fields[0]),
            family: family
        )
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
