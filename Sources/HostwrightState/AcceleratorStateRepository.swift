import CryptoKit
import Foundation
import HostwrightAccelerator

public enum AcceleratorStateRepositoryKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case inventory
    case claim
    case reservation
    case grant
    case executionRequest = "execution-request"
    case executionResult = "execution-result"
    case usage
    case provenance
    case cancellation
    case revocation
    case xpcReplay = "xpc-replay"
}

public struct AcceleratorStateRepositoryFence:
    Codable,
    Equatable,
    Hashable,
    Sendable,
    Comparable
{
    public let nodeEpoch: Int64
    public let reservationSequence: Int64

    public init(nodeEpoch: Int64, reservationSequence: Int64) throws {
        guard nodeEpoch >= 1 else {
            throw AcceleratorStateRepositoryError.invalidInput(field: "nodeEpoch")
        }
        guard reservationSequence >= 1 else {
            throw AcceleratorStateRepositoryError.invalidInput(
                field: "reservationSequence"
            )
        }
        self.nodeEpoch = nodeEpoch
        self.reservationSequence = reservationSequence
    }

    public static func < (
        lhs: AcceleratorStateRepositoryFence,
        rhs: AcceleratorStateRepositoryFence
    ) -> Bool {
        if lhs.nodeEpoch != rhs.nodeEpoch {
            return lhs.nodeEpoch < rhs.nodeEpoch
        }
        return lhs.reservationSequence < rhs.reservationSequence
    }

    public var stableKey: String {
        String(nodeEpoch) + ":" + String(reservationSequence)
    }
}

public struct AcceleratorStateRepositoryExpectedVersion:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let generation: Int64
    public let fence: AcceleratorStateRepositoryFence

    public init(
        generation: Int64,
        fence: AcceleratorStateRepositoryFence
    ) throws {
        guard generation >= 1 else {
            throw AcceleratorStateRepositoryError.invalidInput(field: "generation")
        }
        self.generation = generation
        self.fence = fence
    }
}

public struct AcceleratorStateRepositoryDependency:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let kind: AcceleratorStateRepositoryKind
    public let recordID: String
    public let scopeKey: String?
    public let generation: Int64
    public let fence: AcceleratorStateRepositoryFence

    public init(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil,
        generation: Int64,
        fence: AcceleratorStateRepositoryFence
    ) throws {
        try AcceleratorStateRepositoryValidation.identifier(
            recordID,
            field: "dependency.recordID"
        )
        try AcceleratorStateRepositoryValidation.scopeKey(
            scopeKey,
            field: "dependency.scopeKey"
        )
        guard generation >= 1 else {
            throw AcceleratorStateRepositoryError.invalidInput(
                field: "dependency.generation"
            )
        }
        self.kind = kind
        self.recordID = recordID
        self.scopeKey = scopeKey
        self.generation = generation
        self.fence = fence
    }

    fileprivate var orderingKey: String {
        kind.rawValue + ":" + recordID + ":" + String(generation) + ":" + fence.stableKey
    }
}

public enum AcceleratorStateRepositoryError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidInput(field: String)
    case malformedPersistedRecord(field: String)
    case unsupportedPersistedVersion
    case payloadTooLarge
    case nodeBudgetExceeded
    case duplicateKey
    case unknownKey(field: String)
    case invalidDependency
    case missingDependency(kind: AcceleratorStateRepositoryKind, recordID: String)
    case dependencyChanged(kind: AcceleratorStateRepositoryKind, recordID: String)
    case generationConflict
    case fenceConflict
    case observedTimeRegression
    case expectedVersionRequired
    case expectedVersionMismatch
    case idempotencyConflict
    case duplicateRecordID
    case historyLimitExceeded
    case transactionInvariantViolation

    public var code: String {
        switch self {
        case .invalidInput: "ASR-001"
        case .malformedPersistedRecord: "ASR-002"
        case .unsupportedPersistedVersion: "ASR-003"
        case .payloadTooLarge: "ASR-004"
        case .nodeBudgetExceeded: "ASR-005"
        case .duplicateKey: "ASR-006"
        case .unknownKey: "ASR-007"
        case .invalidDependency: "ASR-008"
        case .missingDependency: "ASR-009"
        case .dependencyChanged: "ASR-010"
        case .generationConflict: "ASR-011"
        case .fenceConflict: "ASR-012"
        case .observedTimeRegression: "ASR-013"
        case .expectedVersionRequired: "ASR-014"
        case .expectedVersionMismatch: "ASR-015"
        case .idempotencyConflict: "ASR-016"
        case .duplicateRecordID: "ASR-017"
        case .historyLimitExceeded: "ASR-018"
        case .transactionInvariantViolation: "ASR-019"
        }
    }

    public var description: String {
        switch self {
        case .invalidInput(let field):
            return code + ": invalid input " + field
        case .malformedPersistedRecord(let field):
            return code + ": malformed persisted record " + field
        case .unsupportedPersistedVersion:
            return code + ": unsupported persisted version"
        case .payloadTooLarge:
            return code + ": accelerator state payload is too large"
        case .nodeBudgetExceeded:
            return code + ": accelerator state JSON node budget exceeded"
        case .duplicateKey:
            return code + ": duplicate JSON key"
        case .unknownKey(let field):
            return code + ": unknown JSON key " + field
        case .invalidDependency:
            return code + ": invalid dependency set"
        case .missingDependency(let kind, let recordID):
            return code + ": missing " + kind.rawValue + " dependency " + recordID
        case .dependencyChanged(let kind, let recordID):
            return code + ": dependency changed " + kind.rawValue + " " + recordID
        case .generationConflict:
            return code + ": generation is not strictly increasing"
        case .fenceConflict:
            return code + ": fence is stale or inconsistent"
        case .observedTimeRegression:
            return code + ": observed time regressed"
        case .expectedVersionRequired:
            return code + ": replacement requires an expected version"
        case .expectedVersionMismatch:
            return code + ": expected version does not match current state"
        case .idempotencyConflict:
            return code + ": mutation identity was reused with different data"
        case .duplicateRecordID:
            return code + ": record identity was reused in an append-only log"
        case .historyLimitExceeded:
            return code + ": bounded accelerator history is exhausted"
        case .transactionInvariantViolation:
            return code + ": transaction invariant failed"
        }
    }
}

extension AcceleratorStateRepositoryError: StateTransactionPreservedError {}

public struct AcceleratorStateRepositoryEntry: Equatable, Sendable {
    public let eventID: String
    public let mutationID: String
    public let kind: AcceleratorStateRepositoryKind
    public let recordID: String
    public let scopeKey: String?
    public let generation: Int64
    public let fence: AcceleratorStateRepositoryFence
    public let observedAt: Date
    public let dependencies: [AcceleratorStateRepositoryDependency]
    public let recordJSON: String
    public let recordSHA256: String

    fileprivate init(
        eventID: String,
        mutationID: String,
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String?,
        generation: Int64,
        fence: AcceleratorStateRepositoryFence,
        observedAt: Date,
        dependencies: [AcceleratorStateRepositoryDependency],
        recordJSON: String,
        recordSHA256: String
    ) {
        self.eventID = eventID
        self.mutationID = mutationID
        self.kind = kind
        self.recordID = recordID
        self.scopeKey = scopeKey
        self.generation = generation
        self.fence = fence
        self.observedAt = observedAt
        self.dependencies = dependencies
        self.recordJSON = recordJSON
        self.recordSHA256 = recordSHA256
    }

    public func decode<Record: Decodable>(
        _ type: Record.Type
    ) throws -> Record {
        guard let data = recordJSON.data(using: .utf8) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "recordJSON"
            )
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "record"
            )
        }
    }
}

public struct AcceleratorStateRepository: Sendable {
    public static let currentEnvelopeVersion = 1
    public static let maximumPayloadBytes = 4 * 1024 * 1024
    public static let maximumJSONNodes = 8_192
    public static let maximumJSONDepth = 32
    public static let maximumDependencies = 16
    public static let maximumHistoryPerRecord = 4_096
    public static let maximumJournalEntries = 16_384

    private static let eventTypePrefix = "accelerator.state."
    private static let eventSource = "accelerator-state-journal"
    private static let eventMessage = "durable accelerator state append"

    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func append<Record: Encodable>(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil,
        generation: Int64,
        fence: AcceleratorStateRepositoryFence,
        observedAt: Date,
        mutationID: String,
        dependencies: [AcceleratorStateRepositoryDependency] = [],
        expected: AcceleratorStateRepositoryExpectedVersion? = nil,
        record: Record
    ) throws -> AcceleratorStateRepositoryEntry {
        try Self.validateMutationIdentity(
            kind: kind,
            recordID: recordID,
            scopeKey: scopeKey,
            generation: generation,
            observedAt: observedAt,
            mutationID: mutationID,
            dependencies: dependencies
        )
        let encodedRecord = try Self.encodeRecord(record)
        let entry = try Self.makeEntry(
            eventID: Self.eventID(for: mutationID),
            mutationID: mutationID,
            kind: kind,
            recordID: recordID,
            scopeKey: scopeKey,
            generation: generation,
            fence: fence,
            observedAt: observedAt,
            dependencies: dependencies,
            recordJSON: encodedRecord.json,
            recordSHA256: encodedRecord.sha256
        )
        let envelope = try Self.encodeEnvelope(entry)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                if let existing = try Self.loadByMutation(
                    mutationID: mutationID,
                    on: connection
                ) {
                    guard existing == entry else {
                        throw AcceleratorStateRepositoryError.idempotencyConflict
                    }
                    return existing
                }

                let journalCount = try Self.journalCount(on: connection)
                guard journalCount < Self.maximumJournalEntries else {
                    throw AcceleratorStateRepositoryError.historyLimitExceeded
                }
                let current = try Self.loadCurrent(
                    kind: kind,
                    recordID: recordID,
                    scopeKey: scopeKey,
                    on: connection
                )
                let recordHistoryCount = try Self.historyCount(
                    kind: kind,
                    recordID: recordID,
                    scopeKey: scopeKey,
                    on: connection
                )
                guard recordHistoryCount < Self.maximumHistoryPerRecord else {
                    throw AcceleratorStateRepositoryError.historyLimitExceeded
                }
                try Self.validateAppend(
                    incoming: entry,
                    current: current,
                    expected: expected,
                    on: connection
                )

                try connection.run(
                    """
                    INSERT INTO accelerator_state_journal (
                        id, timestamp, severity, type, source, project_id,
                        service_name, runtime_adapter, message,
                        payload_json_redacted
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
                    """,
                    bindings: [
                        .text(entry.eventID),
                        .text(Self.timestampString(observedAt)),
                        .text(StateEventSeverity.info.rawValue),
                        .text(Self.eventType(for: kind)),
                        .text(Self.eventSource),
                        scopeKey.map(SQLiteValue.text) ?? .null,
                        .text(Self.eventMessage),
                        .text(envelope)
                    ]
                )
                try connection.run(
                    """
                    INSERT INTO accelerator_state_current (
                        id, timestamp, severity, type, source, project_id,
                        service_name, runtime_adapter, message,
                        payload_json_redacted, record_id, generation
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?)
                    ON CONFLICT DO UPDATE SET
                        id = excluded.id,
                        timestamp = excluded.timestamp,
                        severity = excluded.severity,
                        source = excluded.source,
                        project_id = excluded.project_id,
                        message = excluded.message,
                        payload_json_redacted = excluded.payload_json_redacted,
                        generation = excluded.generation
                    WHERE excluded.generation > accelerator_state_current.generation
                    """,
                    bindings: [
                        .text(entry.eventID),
                        .text(Self.timestampString(observedAt)),
                        .text(StateEventSeverity.info.rawValue),
                        .text(Self.eventType(for: kind)),
                        .text(Self.eventSource),
                        scopeKey.map(SQLiteValue.text) ?? .null,
                        .text(Self.eventMessage),
                        .text(envelope),
                        .text(entry.recordID),
                        .int64(entry.generation)
                    ]
                )
                guard let persisted = try Self.loadByMutation(
                    mutationID: mutationID,
                    on: connection
                ), persisted == entry else {
                    throw AcceleratorStateRepositoryError.transactionInvariantViolation
                }
                return persisted
            }
        }
    }

    @discardableResult
    public func append<Payload: AcceleratorStatePayload>(
        _ record: AcceleratorStateRecord<Payload>,
        fence: AcceleratorStateRepositoryFence,
        observedAt: Date,
        mutationID: String,
        dependencies: [AcceleratorStateRepositoryDependency] = [],
        expected: AcceleratorStateRepositoryExpectedVersion? = nil,
        scopeKey: String? = nil
    ) throws -> AcceleratorStateRepositoryEntry {
        try record.validate()
        let kind = try Self.repositoryKind(Payload.statePayloadKey)
        let resolvedScopeKey = try Self.resolvedScopeKey(
            for: record.payload,
            explicit: scopeKey
        )
        return try append(
            kind: kind,
            recordID: record.recordID.uuidString.lowercased(),
            scopeKey: resolvedScopeKey,
            generation: record.sequence,
            fence: fence,
            observedAt: observedAt,
            mutationID: mutationID,
            dependencies: dependencies,
            expected: expected,
            record: record
        )
    }

    public func current(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil
    ) throws -> AcceleratorStateRepositoryEntry? {
        try Self.validateKindAndRecordID(kind: kind, recordID: recordID)
        try AcceleratorStateRepositoryValidation.scopeKey(scopeKey, field: "scopeKey")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try Self.loadCurrent(
                kind: kind,
                recordID: recordID,
                scopeKey: scopeKey,
                on: connection
            )
        }
    }

    public func latest(
        kind: AcceleratorStateRepositoryKind
    ) throws -> AcceleratorStateRepositoryEntry? {
        return try store.withValidatedConnection(readOnly: true) { connection in
            try Self.loadLog(kind: kind, on: connection).last
        }
    }

    public func current<Record: Decodable>(
        _ type: Record.Type,
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil
    ) throws -> Record? {
        try current(kind: kind, recordID: recordID, scopeKey: scopeKey)?.decode(type)
    }

    public func history(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil
    ) throws -> [AcceleratorStateRepositoryEntry] {
        try Self.validateKindAndRecordID(kind: kind, recordID: recordID)
        try AcceleratorStateRepositoryValidation.scopeKey(scopeKey, field: "scopeKey")
        return try store.withValidatedConnection(readOnly: true) { connection in
            try Self.loadLog(kind: kind, on: connection)
                .filter { $0.recordID == recordID && $0.scopeKey == scopeKey }
        }
    }

    public func replay<Record: Decodable>(
        _ type: Record.Type,
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil
    ) throws -> [Record] {
        try history(kind: kind, recordID: recordID, scopeKey: scopeKey).map {
            try $0.decode(type)
        }
    }

    public func replay<Record: Decodable>(
        _ type: Record.Type,
        kind: AcceleratorStateRepositoryKind
    ) throws -> [Record] {
        try log(kind: kind).map { try $0.decode(type) }
    }

    public func log(
        kind: AcceleratorStateRepositoryKind
    ) throws -> [AcceleratorStateRepositoryEntry] {
        try store.withValidatedConnection(readOnly: true) { connection in
            try Self.loadLog(kind: kind, on: connection)
        }
    }

    public func snapshot() throws -> AcceleratorStateSnapshot {
        try AcceleratorStateSnapshot(
            inventories: try replay(
                AcceleratorInventoryStateRecord.self,
                kind: .inventory
            ),
            claims: try replay(
                AcceleratorClaimStateRecord.self,
                kind: .claim
            ),
            reservations: try replay(
                AcceleratorReservationStateRecord.self,
                kind: .reservation
            ),
            grants: try replay(
                AcceleratorGrantStateRecord.self,
                kind: .grant
            ),
            executions: try replay(
                AcceleratorExecutionStateRecord.self,
                kind: .executionRequest
            ),
            results: try replay(
                AcceleratorExecutionResultStateRecord.self,
                kind: .executionResult
            ),
            usages: try replay(
                AcceleratorUsageStateRecord.self,
                kind: .usage
            ),
            provenances: try replay(
                AcceleratorProvenanceStateRecord.self,
                kind: .provenance
            ),
            cancellations: try replay(
                AcceleratorCancellationStateRecord.self,
                kind: .cancellation
            ),
            revocations: try replay(
                AcceleratorRevocationStateRecord.self,
                kind: .revocation
            )
        )
    }

    public func allEntries(
        kind: AcceleratorStateRepositoryKind? = nil
    ) throws -> [AcceleratorStateRepositoryEntry] {
        try store.withValidatedConnection(readOnly: true) { connection in
            if let kind {
                return try Self.loadLog(kind: kind, on: connection)
            }
            let rows: [[String?]]
            rows = try connection.query(
                Self.entrySelect + " ORDER BY rowid ASC LIMIT ?",
                bindings: [.int(Self.maximumJournalEntries + 1)]
            )
            guard rows.count <= Self.maximumJournalEntries else {
                throw AcceleratorStateRepositoryError.historyLimitExceeded
            }
            let entries = try rows.map(Self.entry(from:))
            for kind in AcceleratorStateRepositoryKind.allCases {
                try Self.validateLog(
                    entries.filter { $0.kind == kind },
                    on: connection
                )
            }
            return entries
        }
    }
}

public extension SQLiteStateStore {
    var acceleratorState: AcceleratorStateRepository {
        AcceleratorStateRepository(store: self)
    }
}

private enum AcceleratorStateRepositoryValidation {
    static func identifier(_ value: String, field: String) throws {
        guard (1...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 58, 95:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw AcceleratorStateRepositoryError.invalidInput(field: field)
        }
    }

    static func scopeKey(_ value: String?, field: String) throws {
        guard let value else { return }
        guard (1...256).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 32...126:
                      return scalar.value != 34 && scalar.value != 92
                  default:
                      return false
                  }
              }) else {
            throw AcceleratorStateRepositoryError.invalidInput(field: field)
        }
    }
}

private extension AcceleratorStateRepository {
    static var entrySelect: String {
        "SELECT rowid, id, timestamp, severity, type, source, project_id, " +
        "service_name, runtime_adapter, message, payload_json_redacted " +
        "FROM accelerator_state_journal WHERE source = '" + eventSource + "'"
    }

    static var currentSelect: String {
        "SELECT rowid, id, timestamp, severity, type, source, project_id, " +
        "service_name, runtime_adapter, message, payload_json_redacted " +
        "FROM accelerator_state_current WHERE source = '" + eventSource + "'"
    }

    static func validateMutationIdentity(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String?,
        generation: Int64,
        observedAt: Date,
        mutationID: String,
        dependencies: [AcceleratorStateRepositoryDependency]
    ) throws {
        try validateKindAndRecordID(kind: kind, recordID: recordID)
        try AcceleratorStateRepositoryValidation.scopeKey(
            scopeKey,
            field: "scopeKey"
        )
        try AcceleratorStateRepositoryValidation.identifier(
            mutationID,
            field: "mutationID"
        )
        guard generation >= 1 else {
            throw AcceleratorStateRepositoryError.invalidInput(field: "generation")
        }
        guard observedAt.timeIntervalSince1970.isFinite else {
            throw AcceleratorStateRepositoryError.invalidInput(field: "observedAt")
        }
        guard dependencies.count <= maximumDependencies else {
            throw AcceleratorStateRepositoryError.invalidDependency
        }
        let sorted = dependencies.sorted { $0.orderingKey < $1.orderingKey }
        guard dependencies == sorted else {
            throw AcceleratorStateRepositoryError.invalidDependency
        }
        for index in dependencies.indices.dropFirst() {
            guard dependencies[index] != dependencies[index - 1] else {
                throw AcceleratorStateRepositoryError.invalidDependency
            }
        }
    }

    static func validateKindAndRecordID(
        kind: AcceleratorStateRepositoryKind,
        recordID: String
    ) throws {
        try AcceleratorStateRepositoryValidation.identifier(
            recordID,
            field: "recordID"
        )
        if kind == .inventory, recordID.isEmpty {
            throw AcceleratorStateRepositoryError.invalidInput(field: "recordID")
        }
    }

    static func encodeRecord<Record: Encodable>(
        _ record: Record
    ) throws -> (json: String, sha256: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw AcceleratorStateRepositoryError.invalidInput(field: "record")
        }
        guard data.count <= maximumPayloadBytes else {
            throw AcceleratorStateRepositoryError.payloadTooLarge
        }
        let object = try parseJSONObject(data, requireCanonical: false)
        let canonical: Data
        do {
            canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw AcceleratorStateRepositoryError.invalidInput(field: "record")
        }
        guard canonical.count <= maximumPayloadBytes else {
            throw AcceleratorStateRepositoryError.payloadTooLarge
        }
        let json = String(decoding: canonical, as: UTF8.self)
        return (json, digest(canonical))
    }

    static func makeEntry(
        eventID: String,
        mutationID: String,
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String?,
        generation: Int64,
        fence: AcceleratorStateRepositoryFence,
        observedAt: Date,
        dependencies: [AcceleratorStateRepositoryDependency],
        recordJSON: String,
        recordSHA256: String
    ) throws -> AcceleratorStateRepositoryEntry {
        guard eventID.utf8.count <= 255 else {
            throw AcceleratorStateRepositoryError.invalidInput(field: "eventID")
        }
        return AcceleratorStateRepositoryEntry(
            eventID: eventID,
            mutationID: mutationID,
            kind: kind,
            recordID: recordID,
            scopeKey: scopeKey,
            generation: generation,
            fence: fence,
            observedAt: observedAt,
            dependencies: dependencies,
            recordJSON: recordJSON,
            recordSHA256: recordSHA256
        )
    }

    static func encodeEnvelope(
        _ entry: AcceleratorStateRepositoryEntry
    ) throws -> String {
        guard let recordData = entry.recordJSON.data(using: .utf8),
              let recordObject = try? JSONSerialization.jsonObject(
                  with: recordData,
                  options: [.fragmentsAllowed]
              ) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "recordJSON"
            )
        }
        let dependencyObjects: [[String: Any]] = entry.dependencies.map { dependency in
            var object: [String: Any] = [
                "kind": dependency.kind.rawValue,
                "recordID": dependency.recordID,
                "generation": dependency.generation,
                "fence": [
                    "nodeEpoch": dependency.fence.nodeEpoch,
                    "reservationSequence": dependency.fence.reservationSequence
                ]
            ]
            object["scopeKey"] = dependency.scopeKey ?? NSNull()
            return object
        }
        var object: [String: Any] = [
            "envelopeVersion": currentEnvelopeVersion,
            "kind": entry.kind.rawValue,
            "recordID": entry.recordID,
            "generation": entry.generation,
            "fence": [
                "nodeEpoch": entry.fence.nodeEpoch,
                "reservationSequence": entry.fence.reservationSequence
            ],
            "mutationID": entry.mutationID,
            "observedAt": timestampString(entry.observedAt),
            "dependencies": dependencyObjects,
            "recordSHA256": entry.recordSHA256,
            "record": recordObject
        ]
        object["scopeKey"] = entry.scopeKey ?? NSNull()
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw AcceleratorStateRepositoryError.invalidInput(field: "envelope")
        }
        guard data.count <= maximumPayloadBytes else {
            throw AcceleratorStateRepositoryError.payloadTooLarge
        }
        _ = try parseJSONObject(data, requireCanonical: true)
        return String(decoding: data, as: UTF8.self)
    }

    static func validateAppend(
        incoming: AcceleratorStateRepositoryEntry,
        current: AcceleratorStateRepositoryEntry?,
        expected: AcceleratorStateRepositoryExpectedVersion?,
        on connection: SQLiteConnection
    ) throws {
        if let current {
            guard let expected else {
                throw AcceleratorStateRepositoryError.expectedVersionRequired
            }
            guard current.generation == expected.generation,
                  current.fence == expected.fence else {
                throw AcceleratorStateRepositoryError.expectedVersionMismatch
            }
            guard !current.generation.addingReportingOverflow(1).overflow,
                  incoming.generation == current.generation + 1 else {
                throw AcceleratorStateRepositoryError.generationConflict
            }
            guard incoming.fence >= current.fence else {
                throw AcceleratorStateRepositoryError.fenceConflict
            }
            guard incoming.observedAt >= current.observedAt else {
                throw AcceleratorStateRepositoryError.observedTimeRegression
            }
            try validatePredecessorDigest(
                incoming: incoming,
                current: current
            )
        } else {
            guard expected == nil, incoming.generation == 1 else {
                throw AcceleratorStateRepositoryError.generationConflict
            }
            try validateFirstRecordDigest(incoming)
        }
        try validateDependencyShape(incoming)
        for dependency in incoming.dependencies {
            guard dependency.kind != incoming.kind
                    || dependency.recordID != incoming.recordID else {
                throw AcceleratorStateRepositoryError.invalidDependency
            }
            guard let currentDependency = try loadEntry(
                kind: dependency.kind,
                recordID: dependency.recordID,
                scopeKey: dependency.scopeKey,
                on: connection
            ) else {
                throw AcceleratorStateRepositoryError.missingDependency(
                    kind: dependency.kind,
                    recordID: dependency.recordID
                )
            }
            guard currentDependency.recordID == dependency.recordID else {
                throw AcceleratorStateRepositoryError.dependencyChanged(
                    kind: dependency.kind,
                    recordID: dependency.recordID
                )
            }
            guard currentDependency.generation == dependency.generation,
                  currentDependency.fence == dependency.fence,
                  currentDependency.scopeKey == dependency.scopeKey else {
                throw AcceleratorStateRepositoryError.dependencyChanged(
                    kind: dependency.kind,
                    recordID: dependency.recordID
                )
            }
            guard dependency.fence <= incoming.fence else {
                throw AcceleratorStateRepositoryError.fenceConflict
            }
        }
    }

    static func validateDependencyShape(
        _ entry: AcceleratorStateRepositoryEntry
    ) throws {
        let required: Set<AcceleratorStateRepositoryKind>
        switch entry.kind {
        case .inventory:
            required = []
        case .claim:
            required = [.inventory]
        case .reservation:
            required = [.inventory, .claim]
        case .grant:
            required = [.inventory, .claim, .reservation]
        case .executionRequest:
            required = [.inventory, .claim, .reservation, .grant]
        case .executionResult:
            required = [.executionRequest, .grant, .reservation]
        case .usage, .provenance:
            required = [.executionRequest]
        case .cancellation:
            required = [.executionRequest]
        case .revocation:
            required = []
        case .xpcReplay:
            required = []
        }
        let actual = Set(entry.dependencies.map(\.kind))
        guard required.isSubset(of: actual) else {
            throw AcceleratorStateRepositoryError.invalidDependency
        }
    }

    static func validateFirstRecordDigest(
        _ entry: AcceleratorStateRepositoryEntry
    ) throws {
        let object = try parseJSONObject(
            Data(entry.recordJSON.utf8),
            requireCanonical: true
        )
        guard object["previousRecordDigest"] == nil
                || object["previousRecordDigest"] is NSNull else {
            throw AcceleratorStateRepositoryError.generationConflict
        }
    }

    static func validatePredecessorDigest(
        incoming: AcceleratorStateRepositoryEntry,
        current: AcceleratorStateRepositoryEntry
    ) throws {
        let incomingObject = try parseJSONObject(
            Data(incoming.recordJSON.utf8),
            requireCanonical: true
        )
        guard let previousValue = incomingObject["previousRecordDigest"] else {
            return
        }
        guard let previousDigest = previousValue as? String else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "previousRecordDigest"
            )
        }
        let currentObject = try parseJSONObject(
            Data(current.recordJSON.utf8),
            requireCanonical: true
        )
        guard currentObject["recordDigest"] as? String == previousDigest else {
            throw AcceleratorStateRepositoryError.fenceConflict
        }
    }

    static func loadByMutation(
        mutationID: String,
        on connection: SQLiteConnection
    ) throws -> AcceleratorStateRepositoryEntry? {
        let rows = try connection.query(
            entrySelect + " AND id = ? ORDER BY rowid ASC LIMIT 1",
            bindings: [.text(eventID(for: mutationID))]
        )
        let entries = try rows.map(entry(from:))
        guard entries.count <= 1 else {
            throw AcceleratorStateRepositoryError.transactionInvariantViolation
        }
        return entries.first
    }

    static func loadLog(
        kind: AcceleratorStateRepositoryKind,
        on connection: SQLiteConnection
    ) throws -> [AcceleratorStateRepositoryEntry] {
        let rows = try connection.query(
            entrySelect + " AND type = ? ORDER BY rowid ASC LIMIT ?",
            bindings: [
                .text(eventType(for: kind)),
                .int(maximumJournalEntries + 1)
            ]
        )
        guard rows.count <= maximumJournalEntries else {
            throw AcceleratorStateRepositoryError.historyLimitExceeded
        }
        let entries = try rows.map(entry(from:))
        try validateLog(entries, on: connection)
        return entries
    }

    static func loadEntry(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil,
        on connection: SQLiteConnection
    ) throws -> AcceleratorStateRepositoryEntry? {
        let rows = try connection.query(
            currentSelect + " AND type = ? AND record_id = ? AND project_id IS ? LIMIT 2",
            bindings: [
                .text(eventType(for: kind)),
                .text(recordID),
                scopeKey.map(SQLiteValue.text) ?? .null
            ]
        )
        guard rows.count <= 1 else {
            throw AcceleratorStateRepositoryError.duplicateRecordID
        }
        guard let row = rows.first else { return nil }
        let entry = try entry(from: row)
        guard entry.recordID == recordID else {
            throw AcceleratorStateRepositoryError.transactionInvariantViolation
        }
        return entry
    }

    static func loadHistoricalEntry(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String?,
        generation: Int64,
        fence: AcceleratorStateRepositoryFence,
        on connection: SQLiteConnection
    ) throws -> AcceleratorStateRepositoryEntry? {
        let rows = try connection.query(
            entrySelect
                + " AND type = ? AND project_id IS ? "
                + "AND json_extract(payload_json_redacted, '$.recordID') = ? "
                + "AND json_extract(payload_json_redacted, '$.generation') = ? "
                + "ORDER BY rowid ASC LIMIT ?",
            bindings: [
                .text(eventType(for: kind)),
                scopeKey.map(SQLiteValue.text) ?? .null,
                .text(recordID),
                .int64(generation),
                .int(2)
            ]
        )
        let decodedEntries = try rows.map { row in
            try entry(from: row)
        }
        let entries = decodedEntries.filter {
            $0.recordID == recordID
                && $0.scopeKey == scopeKey
                && $0.generation == generation
                && $0.fence == fence
        }
        guard entries.count <= 1 else {
            throw AcceleratorStateRepositoryError.transactionInvariantViolation
        }
        return entries.first
    }

    static func loadCurrent(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil,
        on connection: SQLiteConnection
    ) throws -> AcceleratorStateRepositoryEntry? {
        try loadEntry(
            kind: kind,
            recordID: recordID,
            scopeKey: scopeKey,
            on: connection
        )
    }

    static func historyCount(
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String?,
        on connection: SQLiteConnection
    ) throws -> Int {
        let rows = try connection.query(
            "SELECT COUNT(*) FROM accelerator_state_journal "
                + "WHERE source = ? AND type = ? AND "
                + "json_extract(payload_json_redacted, '$.recordID') = ? "
                + "AND project_id IS ?",
            bindings: [
                .text(eventSource),
                .text(eventType(for: kind)),
                .text(recordID),
                scopeKey.map(SQLiteValue.text) ?? .null
            ]
        )
        guard let raw = rows.first?.first.flatMap({ $0 }),
              let count = Int(raw), count >= 0 else {
            throw AcceleratorStateRepositoryError.transactionInvariantViolation
        }
        return count
    }

    static func validateLog(
        _ entries: [AcceleratorStateRepositoryEntry],
        on connection: SQLiteConnection
    ) throws {
        let histories = Dictionary(grouping: entries) {
            $0.recordID + "\u{0}" + ($0.scopeKey ?? "")
        }
        for history in histories.values {
            guard history.count <= maximumHistoryPerRecord else {
                throw AcceleratorStateRepositoryError.historyLimitExceeded
            }
            for (index, entry) in history.enumerated() {
                guard entry.generation == Int64(index + 1) else {
                    throw AcceleratorStateRepositoryError.generationConflict
                }
                if index == 0 {
                    try validateFirstRecordDigest(entry)
                } else {
                    let predecessor = history[index - 1]
                    guard entry.fence >= predecessor.fence,
                          entry.observedAt >= predecessor.observedAt else {
                        throw AcceleratorStateRepositoryError.fenceConflict
                    }
                    try validatePredecessorDigest(
                        incoming: entry,
                        current: predecessor
                    )
                }
                try validateDependencyShape(entry)
                for dependency in entry.dependencies {
                    guard let dependencyEntry = try loadHistoricalEntry(
                        kind: dependency.kind,
                        recordID: dependency.recordID,
                        scopeKey: dependency.scopeKey,
                        generation: dependency.generation,
                        fence: dependency.fence,
                        on: connection
                    ),
                    dependencyEntry.generation == dependency.generation,
                    dependencyEntry.fence == dependency.fence,
                    dependencyEntry.scopeKey == dependency.scopeKey,
                    dependencyEntry.generation < entry.generation
                        || dependency.kind != entry.kind else {
                        throw AcceleratorStateRepositoryError.dependencyChanged(
                            kind: dependency.kind,
                            recordID: dependency.recordID
                        )
                    }
                    guard dependency.fence <= entry.fence else {
                        throw AcceleratorStateRepositoryError.fenceConflict
                    }
                }
            }
        }
    }

    static func journalCount(on connection: SQLiteConnection) throws -> Int {
        let rows = try connection.query(
            "SELECT COUNT(*) FROM accelerator_state_journal WHERE source = ?",
            bindings: [.text(eventSource)]
        )
        guard let raw = rows.first?.first.flatMap({ $0 }),
              let count = Int(raw), count >= 0 else {
            throw AcceleratorStateRepositoryError.transactionInvariantViolation
        }
        return count
    }

    static func entry(from row: [String?]) throws -> AcceleratorStateRepositoryEntry {
        guard row.count == 11,
              let rowID = row[0],
              let rowIDValue = Int64(rowID),
              rowIDValue > 0,
              let eventIdentifier = row[1],
              row[2] != nil,
              row[3] == StateEventSeverity.info.rawValue,
              let type = row[4],
              let source = row[5],
              row[7] == nil,
              row[8] == nil,
              row[9] == eventMessage,
              let payload = row[10],
              source == eventSource,
              type.hasPrefix(eventTypePrefix) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "event"
            )
        }
        let kindRaw = String(type.dropFirst(eventTypePrefix.count))
        guard let kind = AcceleratorStateRepositoryKind(rawValue: kindRaw) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "kind"
            )
        }
        let object = try parseJSONObject(
            Data(payload.utf8),
            requireCanonical: true
        )
        let expectedKeys: Set<String> = [
            "envelopeVersion", "kind", "recordID", "scopeKey", "generation",
            "fence", "mutationID", "observedAt", "dependencies",
            "recordSHA256", "record"
        ]
        guard Set(object.keys) == expectedKeys else {
            let unknown = Set(object.keys).subtracting(expectedKeys).sorted().first
            throw unknown.map { AcceleratorStateRepositoryError.unknownKey(field: $0) }
                ?? AcceleratorStateRepositoryError.malformedPersistedRecord(field: "envelope")
        }
        guard integer(object["envelopeVersion"]) == Int64(currentEnvelopeVersion) else {
            throw AcceleratorStateRepositoryError.unsupportedPersistedVersion
        }
        guard object["kind"] as? String == kind.rawValue,
              let recordID = object["recordID"] as? String,
              let mutationID = object["mutationID"] as? String,
              eventIdentifier == eventID(for: mutationID) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(field: "identity")
        }
        let scopeKey = try optionalString(object["scopeKey"], field: "scopeKey")
        guard row[6] == scopeKey else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "scopeKey"
            )
        }
        guard let generation = integer(object["generation"]), generation >= 1,
              let observedText = object["observedAt"] as? String,
              let observedAt = timestampDate(observedText) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(field: "ordering")
        }
        guard row[2] == timestampString(observedAt) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "timestamp"
            )
        }
        let fence = try decodeFence(object["fence"], field: "fence")
        let dependencies = try decodeDependencies(object["dependencies"])
        guard let recordObject = object["record"] as? [String: Any] else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(field: "record")
        }
        let recordData: Data
        do {
            recordData = try JSONSerialization.data(
                withJSONObject: recordObject,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(field: "record")
        }
        guard recordData.count <= maximumPayloadBytes else {
            throw AcceleratorStateRepositoryError.payloadTooLarge
        }
        let recordJSON = String(decoding: recordData, as: UTF8.self)
        let computedRecordSHA256 = digest(recordData)
        guard let recordSHA256 = object["recordSHA256"] as? String,
              recordSHA256 == computedRecordSHA256,
              recordSHA256.count == 64,
              recordSHA256.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57)
                      || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "recordSHA256"
            )
        }
        try validateMutationIdentity(
            kind: kind,
            recordID: recordID,
            scopeKey: scopeKey,
            generation: generation,
            observedAt: observedAt,
            mutationID: mutationID,
            dependencies: dependencies
        )
        let entry = try makeEntry(
            eventID: eventIdentifier,
            mutationID: mutationID,
            kind: kind,
            recordID: recordID,
            scopeKey: scopeKey,
            generation: generation,
            fence: fence,
            observedAt: observedAt,
            dependencies: dependencies,
            recordJSON: recordJSON,
            recordSHA256: recordSHA256
        )
        try validateDependencyShape(entry)
        return entry
    }

    static func decodeFence(
        _ value: Any?,
        field: String
    ) throws -> AcceleratorStateRepositoryFence {
        guard let object = value as? [String: Any],
              Set(object.keys) == ["nodeEpoch", "reservationSequence"],
              let nodeEpoch = integer(object["nodeEpoch"]),
              let reservationSequence = integer(object["reservationSequence"]) else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(field: field)
        }
        do {
            return try AcceleratorStateRepositoryFence(
                nodeEpoch: nodeEpoch,
                reservationSequence: reservationSequence
            )
        } catch {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(field: field)
        }
    }

    static func decodeDependencies(
        _ value: Any?
    ) throws -> [AcceleratorStateRepositoryDependency] {
        guard let objects = value as? [[String: Any]],
              objects.count <= maximumDependencies else {
            throw AcceleratorStateRepositoryError.invalidDependency
        }
        var dependencies: [AcceleratorStateRepositoryDependency] = []
        for object in objects {
            guard Set(object.keys) == [
                "kind", "recordID", "scopeKey", "generation", "fence"
            ],
                  let kindRaw = object["kind"] as? String,
                  let kind = AcceleratorStateRepositoryKind(rawValue: kindRaw),
                  let recordID = object["recordID"] as? String,
                  let generation = integer(object["generation"]) else {
                throw AcceleratorStateRepositoryError.invalidDependency
            }
            let scopeKey = try optionalString(
                object["scopeKey"],
                field: "dependency.scopeKey"
            )
            let fence = try decodeFence(object["fence"], field: "dependency.fence")
            dependencies.append(
                try AcceleratorStateRepositoryDependency(
                    kind: kind,
                    recordID: recordID,
                    scopeKey: scopeKey,
                    generation: generation,
                    fence: fence
                )
            )
        }
        let sorted = dependencies.sorted { $0.orderingKey < $1.orderingKey }
        guard dependencies == sorted else {
            throw AcceleratorStateRepositoryError.invalidDependency
        }
        for index in dependencies.indices.dropFirst() {
            guard dependencies[index] != dependencies[index - 1] else {
                throw AcceleratorStateRepositoryError.duplicateKey
            }
        }
        return dependencies
    }

    static func parseJSONObject(
        _ data: Data,
        requireCanonical: Bool
    ) throws -> [String: Any] {
        guard data.count <= maximumPayloadBytes else {
            throw AcceleratorStateRepositoryError.payloadTooLarge
        }
        var scanner = JSONBudgetScanner(bytes: Array(data))
        do {
            try scanner.scan()
        } catch JSONBudgetScanner.Error.nodeBudget {
            throw AcceleratorStateRepositoryError.nodeBudgetExceeded
        } catch JSONBudgetScanner.Error.duplicateKey {
            throw AcceleratorStateRepositoryError.duplicateKey
        } catch {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "json"
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "json"
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "json-object"
            )
        }
        guard requireCanonical else { return dictionary }
        let canonical: Data
        do {
            canonical = try JSONSerialization.data(
                withJSONObject: dictionary,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "json-canonical"
            )
        }
        guard canonical == data else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(
                field: "json-canonical"
            )
        }
        return dictionary
    }

    static func optionalString(_ value: Any?, field: String) throws -> String? {
        if value is NSNull { return nil }
        guard let string = value as? String else {
            throw AcceleratorStateRepositoryError.malformedPersistedRecord(field: field)
        }
        try AcceleratorStateRepositoryValidation.scopeKey(string, field: field)
        return string
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= Double(Int64.min), double < Double(Int64.max) else {
            return nil
        }
        return Int64(double)
    }

    static func eventID(for mutationID: String) -> String {
        "accelerator.state:" + mutationID
    }

    static func eventType(for kind: AcceleratorStateRepositoryKind) -> String {
        eventTypePrefix + kind.rawValue
    }

    static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter.string(from: date)
    }

    static func timestampDate(_ value: String) -> Date? {
        if let interval = Double(value), interval.isFinite {
            return Date(timeIntervalSince1970: interval)
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter.date(from: value)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resolvedScopeKey<Payload: AcceleratorStatePayload>(
        for payload: Payload,
        explicit: String?
    ) throws -> String? {
        let derived: String?
        switch Payload.stateRecordKind {
        case .inventory:
            guard explicit == nil else {
                throw AcceleratorStateRepositoryError.invalidInput(field: "scopeKey")
            }
            derived = nil
        case .claim:
            derived = (payload as? AcceleratorClaim)?.scope.stableKey
        case .reservation:
            derived = (payload as? AcceleratorReservation)?.scope.stableKey
        case .grant:
            derived = (payload as? AcceleratorGrant)?.scope.stableKey
        case .executionRequest:
            derived = (payload as? AcceleratorExecutionRequest)?.scope.stableKey
        case .executionResult:
            derived = (payload as? AcceleratorExecutionResult)?.scope.stableKey
        case .cancellation:
            derived = (payload as? AcceleratorCancellationRecord)?.scope.stableKey
        case .revocation:
            derived = (payload as? AcceleratorRevocationRecord)?.scope?.stableKey
        case .xpcReplay:
            guard explicit == nil else {
                throw AcceleratorStateRepositoryError.invalidInput(field: "scopeKey")
            }
            derived = nil
        case .usage, .provenance:
            guard explicit != nil else {
                throw AcceleratorStateRepositoryError.invalidInput(field: "scopeKey")
            }
            derived = nil
        }

        if let derived {
            if let explicit, explicit != derived {
                throw AcceleratorStateRepositoryError.invalidInput(field: "scopeKey")
            }
            return derived
        }
        return explicit
    }

    static func repositoryKind(_ payloadKey: String) throws
        -> AcceleratorStateRepositoryKind
    {
        switch payloadKey {
        case "inventory":
            return .inventory
        case "claim":
            return .claim
        case "reservation":
            return .reservation
        case "grant":
            return .grant
        case "execution":
            return .executionRequest
        case "result":
            return .executionResult
        case "usage":
            return .usage
        case "provenance":
            return .provenance
        case "cancellation":
            return .cancellation
        case "revocation":
            return .revocation
        case "xpcReplay":
            return .xpcReplay
        default:
            throw AcceleratorStateRepositoryError.invalidInput(
                field: "payloadKey"
            )
        }
    }
}

private struct JSONBudgetScanner {
    enum Error: Swift.Error {
        case malformed
        case duplicateKey
        case nodeBudget
        case depth
    }

    let bytes: [UInt8]
    var index = 0
    var nodeCount = 0

    mutating func scan() throws {
        try value(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw Error.malformed }
    }

    mutating func value(depth: Int) throws {
        guard depth <= AcceleratorStateRepository.maximumJSONDepth else {
            throw Error.depth
        }
        nodeCount += 1
        guard nodeCount <= AcceleratorStateRepository.maximumJSONNodes else {
            throw Error.nodeBudget
        }
        skipWhitespace()
        guard index < bytes.count else { throw Error.malformed }
        switch bytes[index] {
        case 0x7B:
            try object(depth: depth + 1)
        case 0x5B:
            try array(depth: depth + 1)
        case 0x22:
            _ = try string()
        case 0x74:
            try literal("true")
        case 0x66:
            try literal("false")
        case 0x6E:
            try literal("null")
        case 0x2D, 0x30...0x39:
            try number()
        default:
            throw Error.malformed
        }
    }

    mutating func object(depth: Int) throws {
        index += 1
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7D) { return }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw Error.malformed
            }
            let key = try string()
            guard keys.insert(key).inserted else { throw Error.duplicateKey }
            skipWhitespace()
            guard consume(0x3A) else { throw Error.malformed }
            try value(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw Error.malformed }
        }
    }

    mutating func array(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try value(depth: depth)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw Error.malformed }
        }
    }

    mutating func string() throws -> String {
        let start = index
        guard consume(0x22) else { throw Error.malformed }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let data = Data(bytes[start..<index])
                guard let value = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                ) as? String else {
                    throw Error.malformed
                }
                return value
            }
            if byte < 0x20 { throw Error.malformed }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw Error.malformed }
            }
            index += 1
        }
        throw Error.malformed
    }

    mutating func literal(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard self.bytes[index...].starts(with: bytes) else {
            throw Error.malformed
        }
        index += bytes.count
    }

    mutating func number() throws {
        let start = index
        while index < bytes.count,
              (bytes[index] == 0x2D || bytes[index] == 0x2B
               || bytes[index] == 0x2E || bytes[index] == 0x45
               || bytes[index] == 0x65 || (0x30...0x39).contains(bytes[index])) {
            index += 1
        }
        guard start < index,
              Double(String(decoding: bytes[start..<index], as: UTF8.self)) != nil else {
            throw Error.malformed
        }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }
}
