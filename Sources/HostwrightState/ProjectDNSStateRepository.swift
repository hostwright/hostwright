import Foundation
import HostwrightCore
import HostwrightRuntime

public struct ProjectDNSStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func save(
        _ record: ProjectDNSStateRecord,
        replacing expected: NetworkStateExpectedVersion? = nil,
        authority: NetworkStateMutationAuthority
    ) throws -> ProjectDNSStateRecord {
        try Self.validate(record)
        try Self.validate(authority)
        guard authority.providerID == record.providerID,
              authority.providerGeneration ==
                record.providerGeneration,
              authority.operationGroupID == record.operationGroupID,
              authority.fencingToken == record.fencingToken else {
            throw StateStoreError.invalidRecord(
                "Project DNS mutation authority does not match the exact provider, generation, operation group, and fence."
            )
        }

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
                    capabilitySHA256:
                        authority.plannedCapabilitySHA256,
                    on: connection
                )

                if let existing = try Self.load(
                    id: record.id,
                    on: connection
                ) {
                    try Self.validateReplacement(
                        existing: existing,
                        incoming: record,
                        expected: expected
                    )
                    try connection.run(
                        """
                        UPDATE network_dns_instances
                        SET generation = ?, provider_generation = ?,
                            fencing_token = ?, desired_sha256 = ?,
                            observed_sha256 = ?, lifecycle_state = ?,
                            finalizer_state = ?,
                            last_ready_record_sha256 = ?,
                            operation_group_id = ?
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
                            optionalText(
                                record.lastReadyRecordSHA256
                            ),
                            .text(record.operationGroupID),
                            .text(record.id),
                            .int64(expected!.generation),
                            .text(expected!.fencingToken)
                        ]
                    )
                } else {
                    guard expected == nil,
                          record.lifecycleState == .creating,
                          record.finalizerState == .pending,
                          record.observedSHA256 == nil,
                          record.lastReadyRecordSHA256 == nil else {
                        throw StateStoreError.invalidRecord(
                            "New project DNS state requires exact durable create intent."
                        )
                    }
                    if record.generation != 1 {
                        try Self.validateMonotonicRecreate(
                            record: record,
                            authority: authority,
                            on: connection
                        )
                    }
                    try connection.run(
                        """
                        INSERT INTO network_dns_instances (
                            id, project_uuid, generation, provider_id,
                            provider_generation, fencing_token,
                            desired_sha256, observed_sha256,
                            lifecycle_state, finalizer_state,
                            last_ready_record_sha256,
                            operation_group_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(record.id),
                            .text(record.projectUUID),
                            .int64(record.generation),
                            .text(record.providerID),
                            .int64(record.providerGeneration),
                            .text(record.fencingToken),
                            .text(record.desiredSHA256),
                            optionalText(record.observedSHA256),
                            .text(record.lifecycleState.rawValue),
                            .text(record.finalizerState.rawValue),
                            optionalText(
                                record.lastReadyRecordSHA256
                            ),
                            .text(record.operationGroupID)
                        ]
                    )
                }

                guard try Self.load(id: record.id, on: connection) ==
                        record else {
                    throw StateStoreError
                        .transactionInvariantViolation(
                            message: "Project DNS compare-and-swap did not persist the exact record."
                        )
                }
                return record
            }
        }
    }

    public func load(
        id: String
    ) throws -> ProjectDNSStateRecord? {
        try Self.validateUUID(id, label: "project DNS instance id")
        return try store.withValidatedConnection(readOnly: true) {
            try Self.load(id: id, on: $0)
        }
    }

    public func load(
        projectUUID: String
    ) throws -> ProjectDNSStateRecord? {
        try Self.validateUUID(
            projectUUID,
            label: "project DNS project UUID"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            try connection.query(
                Self.select +
                    " WHERE project_uuid = ? LIMIT 1",
                bindings: [.text(projectUUID)]
            ).first.map(Self.record(from:))
        }
    }

    public func list() throws -> [ProjectDNSStateRecord] {
        try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.select + " ORDER BY project_uuid, id"
            ).map(Self.record(from:))
        }
    }

    public func evaluateRecovery(
        id: String,
        expected: NetworkStateExpectedVersion,
        authority: NetworkStateMutationAuthority,
        trigger: NetworkStateRecoveryTrigger,
        observation: NetworkStateRecoveryObservation
    ) throws -> NetworkStateRecoveryDecision {
        try Self.validateUUID(id, label: "project DNS instance id")
        try Self.validate(expected)
        try Self.validate(authority)
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            guard let record = try Self.load(
                id: id,
                on: connection
            ) else {
                throw StateStoreError.notFound(
                    "Project DNS instance '\(id)' does not exist."
                )
            }
            guard authority.providerID == record.providerID,
                  authority.providerGeneration ==
                    record.providerGeneration,
                  expected.generation == record.generation,
                  expected.fencingToken ==
                    record.fencingToken else {
                throw StateStoreError.invalidRecord(
                    "Project DNS recovery refused a stale provider generation, record generation, or fencing token."
                )
            }
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
                capabilitySHA256:
                    authority.plannedCapabilitySHA256,
                on: connection
            )
            return try Self.recoveryDecision(
                record: record,
                trigger: trigger,
                observation: observation
            )
        }
    }

    @discardableResult
    public func quarantine(
        id: String,
        expected: NetworkStateExpectedVersion,
        authority: NetworkStateMutationAuthority,
        observedSHA256: String? = nil
    ) throws -> ProjectDNSStateRecord {
        guard let existing = try load(id: id) else {
            throw StateStoreError.notFound(
                "Project DNS instance '\(id)' does not exist."
            )
        }
        let quarantined = ProjectDNSStateRecord(
            id: existing.id,
            projectUUID: existing.projectUUID,
            generation: existing.generation + 1,
            providerID: existing.providerID,
            providerGeneration: authority.providerGeneration,
            fencingToken: authority.fencingToken,
            desiredSHA256: existing.desiredSHA256,
            observedSHA256:
                observedSHA256 ?? existing.observedSHA256,
            lifecycleState: .faulted,
            finalizerState: .quarantined,
            lastReadyRecordSHA256:
                existing.lastReadyRecordSHA256,
            operationGroupID: authority.operationGroupID
        )
        return try save(
            quarantined,
            replacing: expected,
            authority: authority
        )
    }

    @discardableResult
    public func removeDeleted(
        id: String,
        expected: NetworkStateExpectedVersion
    ) throws -> Bool {
        try Self.validateUUID(id, label: "project DNS instance id")
        try Self.validate(expected)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let record = try Self.load(
                    id: id,
                    on: connection
                ) else {
                    return false
                }
                guard record.generation == expected.generation,
                      record.fencingToken ==
                        expected.fencingToken,
                      record.lifecycleState == .deleted,
                      record.finalizerState == .released else {
                    throw StateStoreError.invalidRecord(
                        "Project DNS removal requires exact released ownership and fencing."
                    )
                }
                try connection.run(
                    """
                    DELETE FROM network_dns_instances
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
                guard try Self.load(id: id, on: connection) ==
                        nil else {
                    throw StateStoreError
                        .transactionInvariantViolation(
                            message: "Project DNS exact owned removal did not remove the terminal record."
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
        for row in try connection.query(select) {
            do {
                let value = try record(from: row)
                try validateProjectBinding(
                    projectUUID: value.projectUUID,
                    providerID: value.providerID,
                    providerGeneration: value.providerGeneration,
                    on: connection
                )
            } catch {
                invalid += 1
            }
        }
        return invalid
    }

    private static let select = """
        SELECT id, project_uuid, generation, provider_id,
               provider_generation, fencing_token,
               desired_sha256, observed_sha256,
               lifecycle_state, finalizer_state,
               last_ready_record_sha256, operation_group_id
        FROM network_dns_instances
        """

    private static func load(
        id: String,
        on connection: SQLiteConnection
    ) throws -> ProjectDNSStateRecord? {
        try connection.query(
            select + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ).first.map(record(from:))
    }

    private static func record(
        from row: [String?]
    ) throws -> ProjectDNSStateRecord {
        guard row.count == 12,
              let id = row[0],
              let projectUUID = row[1],
              let generationText = row[2],
              let generation = Int64(generationText),
              let providerID = row[3],
              let providerGenerationText = row[4],
              let providerGeneration =
                Int64(providerGenerationText),
              let fencingToken = row[5],
              let desiredSHA256 = row[6],
              let lifecycleText = row[8],
              let lifecycle =
                NetworkStateResourceLifecycle(
                    rawValue: lifecycleText
                ),
              let finalizerText = row[9],
              let finalizer =
                NetworkStateFinalizer(rawValue: finalizerText),
              let operationGroupID = row[11] else {
            throw StateStoreError.invalidRecord(
                "Could not decode project DNS state."
            )
        }
        let value = ProjectDNSStateRecord(
            id: id,
            projectUUID: projectUUID,
            generation: generation,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            desiredSHA256: desiredSHA256,
            observedSHA256: row[7],
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            lastReadyRecordSHA256: row[10],
            operationGroupID: operationGroupID
        )
        try validate(value)
        return value
    }

    private static func validate(
        _ record: ProjectDNSStateRecord
    ) throws {
        try validateUUID(record.id, label: "project DNS instance id")
        try validateUUID(
            record.projectUUID,
            label: "project DNS project UUID"
        )
        try validateProvider(
            id: record.providerID,
            generation: record.providerGeneration
        )
        try validate(
            NetworkStateExpectedVersion(
                generation: record.generation,
                fencingToken: record.fencingToken
            )
        )
        try validateSHA256(record.desiredSHA256)
        try record.observedSHA256.map(validateSHA256)
        try record.lastReadyRecordSHA256.map(validateSHA256)
        try validateUUID(
            record.operationGroupID,
            label: "project DNS operation group id"
        )
        guard valid(
            lifecycle: record.lifecycleState,
            finalizer: record.finalizerState,
            observed: record.observedSHA256,
            readyRecords: record.lastReadyRecordSHA256
        ) else {
            throw StateStoreError.invalidRecord(
                "Project DNS lifecycle, finalizer, observation, and ready-record state are inconsistent."
            )
        }
    }

    private static func validate(
        _ authority: NetworkStateMutationAuthority
    ) throws {
        try validateProvider(
            id: authority.providerID,
            generation: authority.providerGeneration
        )
        try validateUUID(
            authority.operationGroupID,
            label: "project DNS authority operation group id"
        )
        try validateUUID(
            authority.fencingToken,
            label: "project DNS authority fencing token"
        )
        try validateSHA256(authority.plannedCapabilitySHA256)
        try validateSHA256(authority.currentCapabilitySHA256)
        guard authority.plannedCapabilitySHA256 ==
                authority.currentCapabilitySHA256 else {
            throw StateStoreError.invalidRecord(
                "Project DNS mutation refused because the negotiated capability snapshot is stale."
            )
        }
    }

    private static func validate(
        _ expected: NetworkStateExpectedVersion
    ) throws {
        guard expected.generation >= 1 else {
            throw StateStoreError.invalidRecord(
                "Project DNS state generation must be positive."
            )
        }
        try validateUUID(
            expected.fencingToken,
            label: "project DNS fencing token"
        )
    }

    private static func validateReplacement(
        existing: ProjectDNSStateRecord,
        incoming: ProjectDNSStateRecord,
        expected: NetworkStateExpectedVersion?
    ) throws {
        guard let expected,
              expected.generation == existing.generation,
              expected.fencingToken == existing.fencingToken,
              incoming.generation == existing.generation + 1,
              incoming.id == existing.id,
              incoming.projectUUID == existing.projectUUID,
              incoming.providerID == existing.providerID,
              incoming.providerGeneration >=
                existing.providerGeneration,
              validTransition(
                from: existing.lifecycleState,
                to: incoming.lifecycleState
              ) else {
            throw StateStoreError.invalidRecord(
                "Project DNS replacement lost immutable identity, exact generation, fence, or lifecycle order."
            )
        }
    }

    private static func validateMonotonicRecreate(
        record: ProjectDNSStateRecord,
        authority: NetworkStateMutationAuthority,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT og.id, og.planned_action_type, og.status,
                   og.checkpoint, og.fencing_token,
                   og.intent_json_redacted
            FROM operation_groups AS og
            JOIN projects AS p ON p.id = og.project_id
            WHERE p.resource_uuid = ?
              AND og.group_kind = 'project-dns'
            ORDER BY og.created_at DESC, og.rowid DESC
            LIMIT 2
            """,
            bindings: [.text(record.projectUUID)]
        )
        guard rows.count == 2,
              rows[0].count == 6,
              rows[1].count == 6,
              rows[0][0] == record.operationGroupID,
              rows[0][1] == "create",
              rows[0][2] == OperationGroupStatus.active.rawValue,
              rows[0][3] == "intent-persisted",
              rows[0][4] == record.fencingToken,
              rows[1][1] == "delete",
              rows[1][2] ==
                OperationGroupStatus.succeeded.rawValue,
              rows[1][3] == "state-committed",
              let currentJSON = rows[0][5],
              let priorJSON = rows[1][5],
              let current = try? decodeRecreateIntent(
                  currentJSON
              ),
              let prior = try? decodeRecreateIntent(
                  priorJSON
              ),
              current.schemaVersion == 1,
              current.action == "create",
              current.projectUUID == record.projectUUID,
              current.dnsUUID == record.id,
              current.stateGeneration == record.generation,
              current.providerID == record.providerID,
              current.providerGeneration ==
                Int(record.providerGeneration),
              current.capabilitySHA256 ==
                authority.plannedCapabilitySHA256,
              current.desiredSHA256 ==
                record.desiredSHA256,
              prior.schemaVersion == 1,
              prior.action == "delete",
              prior.projectUUID == record.projectUUID,
              prior.dnsUUID == record.id,
              prior.providerID == record.providerID,
              prior.providerGeneration ==
                Int(record.providerGeneration),
              let priorStateGeneration =
                prior.priorStateGeneration,
              let priorFence = prior.priorFence,
              record.generation >= 4,
              prior.stateGeneration ==
                record.generation - 2,
              priorStateGeneration ==
                record.generation - 3 else {
            throw StateStoreError.invalidRecord(
                "Project DNS recreate requires the exact active successor of one committed delete."
            )
        }
        try validateUUID(
            priorFence,
            label: "prior project DNS fencing token"
        )
    }

    private static func decodeRecreateIntent(
        _ value: String
    ) throws -> ProjectDNSRecreateOperationIntent {
        guard value.utf8.count <= 1_048_576,
              let data = value.data(using: .utf8) else {
            throw StateStoreError.invalidRecord(
                "Project DNS operation intent is invalid."
            )
        }
        return try JSONDecoder().decode(
            ProjectDNSRecreateOperationIntent.self,
            from: data
        )
    }

    private static func recoveryDecision(
        record: ProjectDNSStateRecord,
        trigger: NetworkStateRecoveryTrigger,
        observation: NetworkStateRecoveryObservation
    ) throws -> NetworkStateRecoveryDecision {
        let normalized: NormalizedObservation
        switch observation {
        case .absent:
            normalized = .absent
        case .indeterminate:
            normalized = .conflicting
        case .conflictingOwner(let digest):
            try digest.map(validateSHA256)
            normalized = .conflicting
        case .exactOwned(let digest):
            try validateSHA256(digest)
            normalized =
                record.observedSHA256 == nil ||
                record.observedSHA256 == digest
                    ? .exactOwned
                    : .conflicting
        }

        let action: NetworkStateRecoveryAction
        switch normalized {
        case .conflicting:
            action = .quarantine
        case .absent:
            switch record.lifecycleState {
            case .creating, .available:
                action = .retryMutation
            case .deleting, .faulted:
                action = record.finalizerState == .quarantined
                    ? .quarantine
                    : .finalizeDeletion
            case .deleted:
                action = .purgeTerminalRecord
            }
        case .exactOwned:
            switch record.lifecycleState {
            case .creating:
                action = .verifyAndAdvance
            case .available:
                action = .stable
            case .deleting:
                action = .resumeDeletion
            case .faulted:
                switch record.finalizerState {
                case .active:
                    action = .verifyAndAdvance
                case .releasing:
                    action = .resumeDeletion
                case .quarantined, .pending, .released:
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
                "Project DNS state requires the exact project provider binding and generation."
            )
        }
    }

    private static func validateOperationGroup(
        id: String,
        projectUUID: String,
        fencingToken: String,
        capabilitySHA256: String,
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
              rows[0][1] == projectUUID,
              let intentJSON = rows[0][2],
              intentJSON.utf8.count <= 1_048_576,
              let data = intentJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any],
              object["capabilitySHA256"] as? String ==
                capabilitySHA256 else {
            throw StateStoreError.invalidRecord(
                "Project DNS state requires an active project operation group with the exact fence and capability digest."
            )
        }
    }

    private static func valid(
        lifecycle: NetworkStateResourceLifecycle,
        finalizer: NetworkStateFinalizer,
        observed: String?,
        readyRecords: String?
    ) -> Bool {
        switch lifecycle {
        case .creating:
            return finalizer == .pending &&
                observed == nil && readyRecords == nil
        case .available:
            return finalizer == .active &&
                observed != nil && readyRecords != nil
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

    private static func validateProvider(
        id: String,
        generation: Int64
    ) throws {
        guard RuntimeProviderBinding.stableID(for: id)?.rawValue == id,
              generation >= 1 else {
            throw StateStoreError.invalidRecord(
                "Project DNS provider identity must be stable and its generation positive."
            )
        }
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
                "Project DNS evidence digest must be lowercase SHA256."
            )
        }
    }

    private enum NormalizedObservation {
        case absent
        case exactOwned
        case conflicting
    }
}

private struct ProjectDNSRecreateOperationIntent: Decodable {
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

public extension SQLiteStateStore {
    var projectDNS: ProjectDNSStateRepository {
        ProjectDNSStateRepository(store: self)
    }
}
