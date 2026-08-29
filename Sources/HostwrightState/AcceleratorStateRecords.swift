import CryptoKit
import Foundation
import HostwrightAccelerator

public enum AcceleratorStateSchema {
    public static let currentVersion = 23
    public static let schemaVersion = currentVersion
    public static let recordVersion = 1
    public static let maxCanonicalRecordBytes = 1_048_576
    public static let maxRecordBytes = maxCanonicalRecordBytes
    public static let maxRecordSequence: Int64 = 128
    public static let maxRecordsPerLog = 128
    public static let maxArrayCount = maxRecordsPerLog
    public static let maxSnapshotRecords = 1_024
}

public enum AcceleratorStateRecordKind: String, Codable, CaseIterable, Sendable {
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

public enum AcceleratorStateRecordErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case invalidVersion = "invalid-version"
    case unknownField = "unknown-field"
    case invalidIdentifier = "invalid-identifier"
    case invalidDigest = "invalid-digest"
    case invalidTimestamp = "invalid-timestamp"
    case invalidOrdering = "invalid-ordering"
    case invalidBinding = "invalid-binding"
    case invalidState = "invalid-state"
    case oversizedRecord = "oversized-record"
    case futureVersion = "future-version"
}

public struct AcceleratorStateRecordValidationError:
    Error,
    Codable,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    public let code: AcceleratorStateRecordErrorCode
    public let field: String

    public init(code: AcceleratorStateRecordErrorCode, field: String) {
        self.code = code
        self.field = field
    }

    public var description: String {
        "\(code.rawValue):\(field)"
    }
}

private enum AcceleratorStateValidation {
    static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    static func fail(
        _ code: AcceleratorStateRecordErrorCode,
        _ field: String
    ) -> AcceleratorStateRecordValidationError {
        AcceleratorStateRecordValidationError(code: code, field: field)
    }

    static func version(_ value: Int, field: String) throws {
        guard value == AcceleratorStateSchema.currentVersion else {
            throw fail(
                value > AcceleratorStateSchema.currentVersion ? .futureVersion : .invalidVersion,
                field
            )
        }
    }

    static func recordVersion(_ value: Int) throws {
        guard value == AcceleratorStateSchema.recordVersion else {
            throw fail(
                value > AcceleratorStateSchema.recordVersion ? .futureVersion : .invalidVersion,
                "recordVersion"
            )
        }
    }

    static func uuid(_ value: UUID, field: String) throws {
        guard value != zeroUUID else {
            throw fail(.invalidIdentifier, field)
        }
    }

    static func digest(_ value: AcceleratorDigest, field: String) throws {
        guard value.value.utf8.count == 64 else {
            throw fail(.invalidDigest, field)
        }
    }

    static func date(_ value: Date, field: String) throws {
        guard value.timeIntervalSince1970.isFinite else {
            throw fail(.invalidTimestamp, field)
        }
    }

    static func bounded<T>(_ values: [T], field: String) throws {
        guard values.count <= AcceleratorStateSchema.maxRecordsPerLog else {
            throw fail(.invalidOrdering, field)
        }
    }

    static func kind(for payloadKey: String) -> AcceleratorStateRecordKind? {
        switch payloadKey {
        case "inventory": .inventory
        case "claim": .claim
        case "reservation": .reservation
        case "grant": .grant
        case "execution": .executionRequest
        case "result": .executionResult
        case "usage": .usage
        case "provenance": .provenance
        case "cancellation": .cancellation
        case "revocation": .revocation
        case "xpcReplay": .xpcReplay
        default: nil
        }
    }
}

private struct AcceleratorStateCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum AcceleratorStateDecoding {
    static func exact<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        allowed: Set<String>,
        allowMissing: Bool = false
    ) throws {
        let actual = Set(container.allKeys.map(\.stringValue))
        guard allowMissing ? actual.isSubset(of: allowed) : actual == allowed else {
            throw AcceleratorStateRecordValidationError(
                code: .unknownField,
                field: "keys"
            )
        }
    }
}

public protocol AcceleratorStatePayload:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static var statePayloadKey: String { get }
    static var statePayloadKeys: Set<String>? { get }
}

public extension AcceleratorStatePayload {
    static var statePayloadKeys: Set<String>? { nil }

    static var stateRecordKind: AcceleratorStateRecordKind {
        switch statePayloadKey {
        case "inventory": .inventory
        case "claim": .claim
        case "reservation": .reservation
        case "grant": .grant
        case "execution": .executionRequest
        case "result": .executionResult
        case "usage": .usage
        case "provenance": .provenance
        case "cancellation": .cancellation
        case "revocation": .revocation
        case "xpcReplay": .xpcReplay
        default: .inventory
        }
    }
}

extension AcceleratorInventorySnapshot: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .inventory }
    public static var statePayloadKey: String { "inventory" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "snapshotID", "hostID", "observedAt", "observedGeneration", "modeEvidence", "budgets"]
    }
}

extension AcceleratorClaim: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .claim }
    public static var statePayloadKey: String { "claim" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "claimID", "scope", "allowedModes", "modelHash", "quota", "inventorySnapshotID", "inventoryGeneration", "issuer", "issuedAt", "expiresAt"]
    }
}

extension AcceleratorReservation: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .reservation }
    public static var statePayloadKey: String { "reservation" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "reservationID", "claimID", "scope", "mode", "modelHash", "budget", "inventorySnapshotID", "inventoryGeneration", "fence", "owner", "createdAt", "expiresAt", "state", "lastTransitionAt"]
    }
}

extension AcceleratorGrant: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .grant }
    public static var statePayloadKey: String { "grant" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "grantID", "claimID", "reservationID", "scope", "granteeSubjectID", "mode", "modelHash", "quota", "inventorySnapshotID", "inventoryGeneration", "fence", "issuer", "issuedAt", "expiresAt"]
    }
}

extension AcceleratorExecutionRequest: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .executionRequest }
    public static var statePayloadKey: String { "execution" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "requestID", "grantID", "reservationID", "scope", "mode", "modelHash", "inputDigest", "inputBytes", "outputLimitBytes", "timeoutMilliseconds", "budget", "fence", "authentication", "requestedAt"]
    }
}

extension AcceleratorExecutionResult: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .executionResult }
    public static var statePayloadKey: String { "result" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "requestID", "grantID", "reservationID", "scope", "mode", "modelHash", "fence", "outcome", "outputBytes", "outputDigest", "usage", "provenance", "completedAt", "authenticatedBy", "errorCode"]
    }
}

extension AcceleratorMeasuredUsage: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .usage }
    public static var statePayloadKey: String { "usage" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "budget", "source", "observedGeneration", "authenticatedBy", "observedAt"]
    }
}

extension AcceleratorExecutionProvenance: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .provenance }
    public static var statePayloadKey: String { "provenance" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "requestID", "mode", "modelHash", "inventorySnapshotID", "inventoryGeneration", "evidenceDigest", "source", "authenticatedBy", "recordedAt"]
    }
}

extension AcceleratorCancellationRecord: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .cancellation }
    public static var statePayloadKey: String { "cancellation" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "cancellationID", "requestID", "grantID", "reservationID", "scope", "fence", "actor", "reason", "requestedAt", "state", "effectiveAt"]
    }
}

extension AcceleratorRevocationRecord: AcceleratorStatePayload {
    public static var stateRecordKind: AcceleratorStateRecordKind { .revocation }
    public static var statePayloadKey: String { "revocation" }
    public static var statePayloadKeys: Set<String>? {
        ["contractVersion", "revocationID", "targetKind", "targetIdentifier", "scope", "fence", "actor", "reason", "evidenceDigest", "revokedAt"]
    }
}

private struct AcceleratorStateDigestInput<Payload: Encodable>: Encodable {
    let schemaVersion: Int
    let recordVersion: Int
    let kind: AcceleratorStateRecordKind
    let recordID: UUID
    let sequence: Int64
    let previousRecordDigest: AcceleratorDigest?
    let payload: Payload
}

private enum AcceleratorStateDigest {
    static func make<Payload: Encodable>(
        schemaVersion: Int,
        recordVersion: Int,
        kind: AcceleratorStateRecordKind,
        recordID: UUID,
        sequence: Int64,
        previousRecordDigest: AcceleratorDigest?,
        payload: Payload
    ) throws -> AcceleratorDigest {
        let input = AcceleratorStateDigestInput(
            schemaVersion: schemaVersion,
            recordVersion: recordVersion,
            kind: kind,
            recordID: recordID,
            sequence: sequence,
            previousRecordDigest: previousRecordDigest,
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(input)
        } catch {
            throw AcceleratorStateValidation.fail(.invalidDigest, "recordDigest")
        }
        guard data.count <= AcceleratorStateSchema.maxRecordBytes else {
            throw AcceleratorStateValidation.fail(.oversizedRecord, "recordBytes")
        }
        return try AcceleratorDigest(
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }
}

public struct AcceleratorStateRecord<Payload: AcceleratorStatePayload>:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let schemaVersion: Int
    public let recordVersion: Int
    public let kind: AcceleratorStateRecordKind
    public let recordID: UUID
    public let sequence: Int64
    public let previousRecordDigest: AcceleratorDigest?
    public let recordDigest: AcceleratorDigest
    public let payload: Payload

    public init(
        recordID: UUID,
        sequence: Int64,
        previousRecordDigest: AcceleratorDigest?,
        payload: Payload,
        schemaVersion: Int = AcceleratorStateSchema.currentVersion,
        recordVersion: Int = AcceleratorStateSchema.recordVersion
    ) throws {
        try AcceleratorStateValidation.version(schemaVersion, field: "schemaVersion")
        try AcceleratorStateValidation.recordVersion(recordVersion)
        guard let payloadKind = AcceleratorStateValidation.kind(for: Payload.statePayloadKey),
              payloadKind == Payload.stateRecordKind else {
            throw AcceleratorStateValidation.fail(.invalidBinding, "payloadKey")
        }
        try AcceleratorStateValidation.uuid(recordID, field: "recordID")
        guard (1...Int64(AcceleratorStateSchema.maxRecordsPerLog)).contains(sequence) else {
            throw AcceleratorStateValidation.fail(.invalidOrdering, "sequence")
        }
        if sequence == 1 {
            guard previousRecordDigest == nil else {
                throw AcceleratorStateValidation.fail(.invalidOrdering, "previousRecordDigest")
            }
        } else {
            guard let previousRecordDigest else {
                throw AcceleratorStateValidation.fail(.invalidOrdering, "previousRecordDigest")
            }
            try AcceleratorStateValidation.digest(previousRecordDigest, field: "previousRecordDigest")
        }
        let digest = try AcceleratorStateDigest.make(
            schemaVersion: schemaVersion,
            recordVersion: recordVersion,
            kind: Payload.stateRecordKind,
            recordID: recordID,
            sequence: sequence,
            previousRecordDigest: previousRecordDigest,
            payload: payload
        )
        self.schemaVersion = schemaVersion
        self.recordVersion = recordVersion
        self.kind = Payload.stateRecordKind
        self.recordID = recordID
        self.sequence = sequence
        self.previousRecordDigest = previousRecordDigest
        self.recordDigest = digest
        self.payload = payload
    }

    public func validate() throws {
        try AcceleratorStateValidation.version(schemaVersion, field: "schemaVersion")
        try AcceleratorStateValidation.recordVersion(recordVersion)
        guard let payloadKind = AcceleratorStateValidation.kind(for: Payload.statePayloadKey),
              payloadKind == Payload.stateRecordKind else {
            throw AcceleratorStateValidation.fail(.invalidBinding, "payloadKey")
        }
        try AcceleratorStateValidation.uuid(recordID, field: "recordID")
        guard kind == Payload.stateRecordKind else {
            throw AcceleratorStateValidation.fail(.invalidBinding, "kind")
        }
        guard (1...Int64(AcceleratorStateSchema.maxRecordsPerLog)).contains(sequence) else {
            throw AcceleratorStateValidation.fail(.invalidOrdering, "sequence")
        }
        if sequence == 1 {
            guard previousRecordDigest == nil else {
                throw AcceleratorStateValidation.fail(.invalidOrdering, "previousRecordDigest")
            }
        } else if let previousRecordDigest {
            try AcceleratorStateValidation.digest(previousRecordDigest, field: "previousRecordDigest")
        } else {
            throw AcceleratorStateValidation.fail(.invalidOrdering, "previousRecordDigest")
        }
        try AcceleratorStateValidation.digest(recordDigest, field: "recordDigest")
        let expected = try AcceleratorStateDigest.make(
            schemaVersion: schemaVersion,
            recordVersion: recordVersion,
            kind: kind,
            recordID: recordID,
            sequence: sequence,
            previousRecordDigest: previousRecordDigest,
            payload: payload
        )
        guard expected == recordDigest else {
            throw AcceleratorStateValidation.fail(.invalidDigest, "recordDigest")
        }
    }

    public func validate(after predecessor: Self) throws {
        try predecessor.validate()
        try validate()
        guard sequence == predecessor.sequence + 1,
              previousRecordDigest == predecessor.recordDigest else {
            throw AcceleratorStateValidation.fail(.invalidOrdering, "appendOnly")
        }
    }

    public var stableKey: String {
        String(format: "%020lld:%@", sequence, recordID.uuidString.lowercased())
    }

    public static func validateAppendOnly(_ records: [Self]) throws {
        try AcceleratorStateValidation.bounded(records, field: Payload.statePayloadKey)
        var recordIDs = Set<UUID>()
        for (index, record) in records.enumerated() {
            try record.validate()
            guard recordIDs.insert(record.recordID).inserted else {
                throw AcceleratorStateValidation.fail(.invalidOrdering, "recordID")
            }
            guard record.sequence == Int64(index + 1) else {
                throw AcceleratorStateValidation.fail(.invalidOrdering, "sequence")
            }
            if index == 0 {
                guard record.previousRecordDigest == nil else {
                    throw AcceleratorStateValidation.fail(.invalidOrdering, "previousRecordDigest")
                }
            } else {
                guard record.previousRecordDigest == records[index - 1].recordDigest else {
                    throw AcceleratorStateValidation.fail(.invalidOrdering, "previousRecordDigest")
                }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AcceleratorStateCodingKey.self)
        try container.encode(schemaVersion, forKey: Self.key("schemaVersion"))
        try container.encode(recordVersion, forKey: Self.key("recordVersion"))
        try container.encode(kind, forKey: Self.key("kind"))
        try container.encode(recordID, forKey: Self.key("recordID"))
        try container.encode(sequence, forKey: Self.key("sequence"))
        try container.encode(previousRecordDigest, forKey: Self.key("previousRecordDigest"))
        try container.encode(recordDigest, forKey: Self.key("recordDigest"))
        try container.encode(payload, forKey: Self.key(Payload.statePayloadKey))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AcceleratorStateCodingKey.self)
        try AcceleratorStateDecoding.exact(container, allowed: [
            "schemaVersion", "recordVersion", "kind", "recordID", "sequence",
            "previousRecordDigest", "recordDigest", Payload.statePayloadKey
        ])
        let schemaVersion = try container.decode(Int.self, forKey: Self.key("schemaVersion"))
        let recordVersion = try container.decode(Int.self, forKey: Self.key("recordVersion"))
        let kind = try container.decode(
            AcceleratorStateRecordKind.self,
            forKey: Self.key("kind")
        )
        guard kind == Payload.stateRecordKind else {
            throw AcceleratorStateValidation.fail(.invalidBinding, "kind")
        }
        let recordID = try container.decode(UUID.self, forKey: Self.key("recordID"))
        let sequence = try container.decode(Int64.self, forKey: Self.key("sequence"))
        let previous = try container.decodeIfPresent(
            AcceleratorDigest.self,
            forKey: Self.key("previousRecordDigest")
        )
        let recordDigest = try container.decode(
            AcceleratorDigest.self,
            forKey: Self.key("recordDigest")
        )
        let payloadDecoder = try container.superDecoder(
            forKey: Self.key(Payload.statePayloadKey)
        )
        if let allowedPayloadKeys = Payload.statePayloadKeys {
            let payloadContainer = try payloadDecoder.container(
                keyedBy: AcceleratorStateCodingKey.self
            )
            try AcceleratorStateDecoding.exact(
                payloadContainer,
                allowed: allowedPayloadKeys,
                allowMissing: true
            )
        }
        let payload = try Payload(from: payloadDecoder)
        self.schemaVersion = schemaVersion
        self.recordVersion = recordVersion
        self.kind = kind
        self.recordID = recordID
        self.sequence = sequence
        self.previousRecordDigest = previous
        self.recordDigest = recordDigest
        self.payload = payload
        try validate()
    }

    private static func key(_ value: String) throws -> AcceleratorStateCodingKey {
        guard let key = AcceleratorStateCodingKey(stringValue: value) else {
            throw AcceleratorStateValidation.fail(.unknownField, value)
        }
        return key
    }
}

public typealias AcceleratorInventoryStateRecord = AcceleratorStateRecord<AcceleratorInventorySnapshot>
public typealias AcceleratorClaimStateRecord = AcceleratorStateRecord<AcceleratorClaim>
public typealias AcceleratorReservationStateRecord = AcceleratorStateRecord<AcceleratorReservation>
public typealias AcceleratorGrantStateRecord = AcceleratorStateRecord<AcceleratorGrant>
public typealias AcceleratorExecutionStateRecord = AcceleratorStateRecord<AcceleratorExecutionRequest>
public typealias AcceleratorExecutionResultStateRecord = AcceleratorStateRecord<AcceleratorExecutionResult>
public typealias AcceleratorUsageStateRecord = AcceleratorStateRecord<AcceleratorMeasuredUsage>
public typealias AcceleratorProvenanceStateRecord = AcceleratorStateRecord<AcceleratorExecutionProvenance>
public typealias AcceleratorCancellationStateRecord = AcceleratorStateRecord<AcceleratorCancellationRecord>
public typealias AcceleratorRevocationStateRecord = AcceleratorStateRecord<AcceleratorRevocationRecord>
public struct AcceleratorStateSnapshot: Codable, Equatable, Hashable, Sendable {
    public let schemaVersion: Int
    public let inventories: [AcceleratorInventoryStateRecord]
    public let claims: [AcceleratorClaimStateRecord]
    public let reservations: [AcceleratorReservationStateRecord]
    public let grants: [AcceleratorGrantStateRecord]
    public let executions: [AcceleratorExecutionStateRecord]
    public let results: [AcceleratorExecutionResultStateRecord]
    public let usages: [AcceleratorUsageStateRecord]
    public let provenances: [AcceleratorProvenanceStateRecord]
    public let cancellations: [AcceleratorCancellationStateRecord]
    public let revocations: [AcceleratorRevocationStateRecord]

    public init(
        inventories: [AcceleratorInventoryStateRecord] = [],
        claims: [AcceleratorClaimStateRecord] = [],
        reservations: [AcceleratorReservationStateRecord] = [],
        grants: [AcceleratorGrantStateRecord] = [],
        executions: [AcceleratorExecutionStateRecord] = [],
        results: [AcceleratorExecutionResultStateRecord] = [],
        usages: [AcceleratorUsageStateRecord] = [],
        provenances: [AcceleratorProvenanceStateRecord] = [],
        cancellations: [AcceleratorCancellationStateRecord] = [],
        revocations: [AcceleratorRevocationStateRecord] = [],
        schemaVersion: Int = AcceleratorStateSchema.currentVersion
    ) throws {
        self.schemaVersion = schemaVersion
        self.inventories = inventories
        self.claims = claims
        self.reservations = reservations
        self.grants = grants
        self.executions = executions
        self.results = results
        self.usages = usages
        self.provenances = provenances
        self.cancellations = cancellations
        self.revocations = revocations
        try validate()
    }

    public func validate() throws {
        try AcceleratorStateValidation.version(schemaVersion, field: "schemaVersion")
        try AcceleratorInventoryStateRecord.validateAppendOnly(inventories)
        try AcceleratorClaimStateRecord.validateAppendOnly(claims)
        try AcceleratorReservationStateRecord.validateAppendOnly(reservations)
        try AcceleratorGrantStateRecord.validateAppendOnly(grants)
        try AcceleratorExecutionStateRecord.validateAppendOnly(executions)
        try AcceleratorExecutionResultStateRecord.validateAppendOnly(results)
        try AcceleratorUsageStateRecord.validateAppendOnly(usages)
        try AcceleratorProvenanceStateRecord.validateAppendOnly(provenances)
        try AcceleratorCancellationStateRecord.validateAppendOnly(cancellations)
        try AcceleratorRevocationStateRecord.validateAppendOnly(revocations)
        let total = inventories.count + claims.count + reservations.count + grants.count
            + executions.count + results.count + usages.count + provenances.count
            + cancellations.count + revocations.count
        guard total <= AcceleratorStateSchema.maxSnapshotRecords else {
            throw AcceleratorStateValidation.fail(.invalidOrdering, "snapshot.records")
        }
        try validateAuthorityBindings()
    }

    private func validateAuthorityBindings() throws {
        let inventoriesByID = try latestUnique(
            inventories,
            field: "inventory.snapshotID",
            key: { $0.payload.snapshotID },
            value: { $0.payload }
        )
        let claimsByID = try latestUnique(
            claims,
            field: "claim.claimID",
            key: { $0.payload.claimID },
            value: { $0.payload }
        )
        let reservationHistories = Dictionary(grouping: reservations) {
            $0.payload.reservationID
        }
        for history in reservationHistories.values {
            try validateReservationHistory(history)
        }
        let reservationsByID = try latestUnique(
            reservations,
            field: "reservation.reservationID",
            key: { $0.payload.reservationID },
            value: { $0.payload }
        )
        let grantsByID = try latestUnique(
            grants,
            field: "grant.grantID",
            key: { $0.payload.grantID },
            value: { $0.payload }
        )
        let executionsByID = try latestUnique(
            executions,
            field: "execution.requestID",
            key: { $0.payload.requestID },
            value: { $0.payload }
        )

        for claim in claimsByID.values {
            guard let inventory = inventoriesByID[claim.inventorySnapshotID],
                  inventory.observedGeneration == claim.inventoryGeneration else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "claim.inventory")
            }
        }
        for reservation in reservationsByID.values {
            guard let claim = claimsByID[reservation.claimID],
                  claim.scope.contains(reservation.scope),
                  claim.modelHash == reservation.modelHash || claim.modelHash == nil,
                  claim.allowedModes.contains(reservation.mode),
                  reservation.budget.fits(in: claim.quota.budget),
                  let inventory = inventoriesByID[reservation.inventorySnapshotID],
                  inventory.observedGeneration == reservation.inventoryGeneration else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "reservation.authority")
            }
        }
        for grant in grantsByID.values {
            guard let claim = claimsByID[grant.claimID],
                  let reservation = reservationsByID[grant.reservationID],
                  grant.scope == reservation.scope,
                  grant.mode == reservation.mode,
                  grant.modelHash == reservation.modelHash,
                  grant.fence == reservation.fence,
                  grant.inventorySnapshotID == reservation.inventorySnapshotID,
                  grant.inventoryGeneration == reservation.inventoryGeneration,
                  grant.granteeSubjectID == reservation.owner.subjectID,
                  grant.quota.budget.fits(in: claim.quota.budget) else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "grant.authority")
            }
        }
        for request in executionsByID.values {
            guard let grant = grantsByID[request.grantID],
                  let reservation = reservationsByID[request.reservationID],
                  request.scope == grant.scope,
                  request.scope == reservation.scope,
                  request.mode == grant.mode,
                  request.mode == reservation.mode,
                  request.modelHash == grant.modelHash,
                  request.modelHash == reservation.modelHash,
                  request.fence == grant.fence,
                  request.fence == reservation.fence,
                  request.authentication == grant.issuer,
                  request.budget.fits(in: grant.quota.budget),
                  request.budget.fits(in: reservation.budget),
                  request.requestedAt <= grant.expiresAt else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "execution.authority")
            }
        }
        try validateResults(executionsByID)
        try validateUsageAndProvenance(executionsByID)
        try validateCancellations(executionsByID)
        try validateRevocations(claimsByID, reservationsByID, grantsByID)
    }

    private func latestUnique<Record, Key: Hashable, Value>(
        _ records: [Record],
        field: String,
        key: (Record) -> Key,
        value: (Record) -> Value
    ) throws -> [Key: Value] {
        var result: [Key: Value] = [:]
        for record in records {
            let recordKey = key(record)
            guard result[recordKey] == nil else {
                throw AcceleratorStateValidation.fail(.invalidBinding, field)
            }
            result[recordKey] = value(record)
        }
        return result
    }

    private func validateReservationHistory(
        _ history: [AcceleratorReservationStateRecord]
    ) throws {
        let ordered = history.sorted { $0.sequence < $1.sequence }
        guard let first = ordered.first, first.payload.state == .reserved else {
            throw AcceleratorStateValidation.fail(.invalidState, "reservation.history")
        }
        for pair in zip(ordered, ordered.dropFirst()) {
            let previous = pair.0.payload
            let next = pair.1.payload
            guard previous.reservationID == next.reservationID,
                  previous.claimID == next.claimID,
                  previous.scope == next.scope,
                  previous.mode == next.mode,
                  previous.modelHash == next.modelHash,
                  previous.budget == next.budget,
                  previous.inventorySnapshotID == next.inventorySnapshotID,
                  previous.inventoryGeneration == next.inventoryGeneration,
                  previous.fence == next.fence,
                  previous.owner == next.owner,
                  previous.createdAt == next.createdAt,
                  previous.expiresAt == next.expiresAt,
                  next.lastTransitionAt > previous.lastTransitionAt else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "reservation.history")
            }
            let validTransition: Bool = switch (previous.state, next.state) {
            case (.reserved, .committed), (.reserved, .cancelled), (.reserved, .revoked):
                true
            case (.committed, .released), (.committed, .cancelled), (.committed, .revoked):
                true
            default:
                false
            }
            guard validTransition else {
                throw AcceleratorStateValidation.fail(.invalidState, "reservation.transition")
            }
        }
    }

    private func validateResults(
        _ executions: [UUID: AcceleratorExecutionRequest]
    ) throws {
        for record in results {
            let result = record.payload
            guard let request = executions[result.requestID],
                  result.grantID == request.grantID,
                  result.reservationID == request.reservationID,
                  result.scope == request.scope,
                  result.mode == request.mode,
                  result.modelHash == request.modelHash,
                  result.fence == request.fence,
                  result.authenticatedBy == request.authentication,
                  result.completedAt >= request.requestedAt else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "result.authority")
            }
        }
    }

    private func validateUsageAndProvenance(
        _ executions: [UUID: AcceleratorExecutionRequest]
    ) throws {
        for record in usages {
            let usage = record.payload
            guard let request = executions[record.recordID],
                  usage.authenticatedBy == request.authentication,
                  usage.budget.fits(in: request.budget),
                  usage.observedAt >= request.requestedAt else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "usage.authority")
            }
        }
        for record in provenances {
            let provenance = record.payload
            guard let request = executions[provenance.requestID],
                  provenance.mode == request.mode,
                  provenance.modelHash == request.modelHash,
                  provenance.authenticatedBy == request.authentication,
                  provenance.recordedAt >= request.requestedAt else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "provenance.authority")
            }
        }
    }

    private func validateCancellations(
        _ executions: [UUID: AcceleratorExecutionRequest]
    ) throws {
        for record in cancellations {
            let cancellation = record.payload
            guard let request = executions[cancellation.requestID],
                  cancellation.grantID == request.grantID,
                  cancellation.reservationID == request.reservationID,
                  cancellation.scope == request.scope,
                  cancellation.fence == request.fence,
                  cancellation.actor == request.authentication else {
                throw AcceleratorStateValidation.fail(.invalidBinding, "cancellation.authority")
            }
        }
    }

    private func validateRevocations(
        _ claims: [UUID: AcceleratorClaim],
        _ reservations: [UUID: AcceleratorReservation],
        _ grants: [UUID: AcceleratorGrant]
    ) throws {
        for record in revocations {
            let revocation = record.payload
            switch revocation.targetKind {
            case .claim:
                guard let claim = UUID(uuidString: revocation.targetIdentifier),
                      let target = claims[claim],
                      revocation.scope == target.scope,
                      revocation.actor == target.issuer else {
                    throw AcceleratorStateValidation.fail(.invalidBinding, "revocation.claim")
                }
            case .reservation:
                guard let reservationID = UUID(uuidString: revocation.targetIdentifier),
                      let target = reservations[reservationID],
                      revocation.scope == target.scope,
                      revocation.fence == target.fence,
                      revocation.actor == target.owner else {
                    throw AcceleratorStateValidation.fail(.invalidBinding, "revocation.reservation")
                }
            case .grant:
                guard let grantID = UUID(uuidString: revocation.targetIdentifier),
                      let target = grants[grantID],
                      revocation.scope == target.scope,
                      revocation.fence == target.fence,
                      revocation.actor == target.issuer else {
                    throw AcceleratorStateValidation.fail(.invalidBinding, "revocation.grant")
                }
            case .session:
                break
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case inventories
        case claims
        case reservations
        case grants
        case executions
        case results
        case usages
        case provenances
        case cancellations
        case revocations
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(inventories, forKey: .inventories)
        try container.encode(claims, forKey: .claims)
        try container.encode(reservations, forKey: .reservations)
        try container.encode(grants, forKey: .grants)
        try container.encode(executions, forKey: .executions)
        try container.encode(results, forKey: .results)
        try container.encode(usages, forKey: .usages)
        try container.encode(provenances, forKey: .provenances)
        try container.encode(cancellations, forKey: .cancellations)
        try container.encode(revocations, forKey: .revocations)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorStateDecoding.exact(container, allowed: [
            "schemaVersion", "inventories", "claims", "reservations", "grants",
            "executions", "results", "usages", "provenances", "cancellations", "revocations"
        ])
        try self.init(
            inventories: container.decode([AcceleratorInventoryStateRecord].self, forKey: .inventories),
            claims: container.decode([AcceleratorClaimStateRecord].self, forKey: .claims),
            reservations: container.decode([AcceleratorReservationStateRecord].self, forKey: .reservations),
            grants: container.decode([AcceleratorGrantStateRecord].self, forKey: .grants),
            executions: container.decode([AcceleratorExecutionStateRecord].self, forKey: .executions),
            results: container.decode([AcceleratorExecutionResultStateRecord].self, forKey: .results),
            usages: container.decode([AcceleratorUsageStateRecord].self, forKey: .usages),
            provenances: container.decode([AcceleratorProvenanceStateRecord].self, forKey: .provenances),
            cancellations: container.decode([AcceleratorCancellationStateRecord].self, forKey: .cancellations),
            revocations: container.decode([AcceleratorRevocationStateRecord].self, forKey: .revocations),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
        )
    }
}

public typealias AcceleratorStateSnapshotRecord = AcceleratorStateSnapshot
