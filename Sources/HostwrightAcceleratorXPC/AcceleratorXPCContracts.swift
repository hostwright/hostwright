import CryptoKit
import Foundation
import HostwrightAccelerator
@preconcurrency import XPC

public enum AcceleratorXPCContract {
    public static let currentVersion = 1
    public static let maxRawDataBytes = max(
        AcceleratorLimits.maxInputBytes,
        AcceleratorLimits.maxOutputBytes
    )
    public static let maxEncodedDataBytes = ((maxRawDataBytes + 2) / 3) * 4
    public static let maxEnvelopeMetadataBytes = 2 * 1024 * 1024
    public static let maxPayloadBytes = maxEncodedDataBytes + maxEnvelopeMetadataBytes
    public static let maxMessageBytes = maxPayloadBytes + maxEnvelopeMetadataBytes
    public static let maxJSONNodeCount = 4_096
    public static let maxModelBytes = 64 * 1024 * 1024
    public static let maxErrorMessageBytes = 512

    internal static func validateEncodedEnvelope(dataByteCounts: [Int]) throws {
        var total = 0
        for count in dataByteCounts {
            guard count >= 0, count <= maxPayloadBytes else {
                throw AcceleratorXPCValidationError(code: .payloadTooLarge, field: "message")
            }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else {
                throw AcceleratorXPCValidationError(code: .payloadTooLarge, field: "message")
            }
            total = next
        }
        guard total <= maxMessageBytes else {
            throw AcceleratorXPCValidationError(code: .payloadTooLarge, field: "message")
        }
    }
}

public enum AcceleratorXPCOperation: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case inventory
    case status
    case execute
    case cancel
    case revoke
}

public enum AcceleratorXPCResponseStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case completed
    case unavailable
    case rejected
    case cancelled
    case revoked
    case timedOut = "timed-out"
}

extension AcceleratorXPCResponseStatus {
    func accepts(_ code: AcceleratorXPCErrorCode) -> Bool {
        switch self {
        case .completed:
            false
        case .unavailable:
            switch code {
            case .identityUnavailable, .serviceUnavailable, .backendUnavailable, .backendUnsupported:
                true
            default:
                false
            }
        case .rejected:
            switch code {
            case .invalidMessage, .unsupportedVersion, .invalidOperation, .invalidPayload,
                 .duplicateField, .unknownField, .payloadTooLarge, .inputDigestMismatch,
                 .requestMismatch, .inventoryMismatch, .fenceMismatch, .authenticationFailed,
                 .replayDetected, .idempotencyConflict, .concurrencyLimitExceeded, .invalidResponse:
                true
            default:
                false
            }
        case .cancelled:
            code == .cancelled
        case .revoked:
            code == .revoked
        case .timedOut:
            code == .timeout
        }
    }
}

public enum AcceleratorXPCErrorCode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case invalidMessage = "invalid-message"
    case unsupportedVersion = "unsupported-version"
    case invalidOperation = "invalid-operation"
    case invalidPayload = "invalid-payload"
    case duplicateField = "duplicate-field"
    case unknownField = "unknown-field"
    case payloadTooLarge = "payload-too-large"
    case inputDigestMismatch = "input-digest-mismatch"
    case requestMismatch = "request-mismatch"
    case inventoryMismatch = "inventory-mismatch"
    case fenceMismatch = "fence-mismatch"
    case authenticationFailed = "authentication-failed"
    case identityUnavailable = "identity-unavailable"
    case serviceUnavailable = "service-unavailable"
    case backendUnavailable = "backend-unavailable"
    case backendUnsupported = "backend-unsupported"
    case replayDetected = "replay-detected"
    case idempotencyConflict = "idempotency-conflict"
    case concurrencyLimitExceeded = "concurrency-limit-exceeded"
    case timeout = "timed-out"
    case cancelled
    case revoked
    case connectionInvalidated = "connection-invalidated"
    case invalidResponse = "invalid-response"
}

public struct AcceleratorXPCValidationError:
    Error,
    Codable,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    public let code: AcceleratorXPCErrorCode
    public let field: String

    public init(code: AcceleratorXPCErrorCode, field: String = "message") {
        self.code = code
        self.field = field
    }

    public var description: String {
        "\(code.rawValue):\(field)"
    }
}

public struct AcceleratorXPCError:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let code: AcceleratorXPCErrorCode
    public let message: String

    public init(
        code: AcceleratorXPCErrorCode,
        message: String = "Accelerator XPC request rejected."
    ) throws {
        guard (1...AcceleratorXPCContract.maxErrorMessageBytes).contains(
            message.utf8.count
        ), message.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "message")
        }
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(["code", "message"]) else {
            throw AcceleratorXPCValidationError(code: .unknownField, field: "error")
        }
        try self.init(
            code: container.decode(AcceleratorXPCErrorCode.self, forKey: .code),
            message: container.decode(String.self, forKey: .message)
        )
    }
}

internal enum AcceleratorXPCValidation {
    static func version(_ value: Int) throws {
        guard value == AcceleratorXPCContract.currentVersion else {
            throw AcceleratorXPCValidationError(code: .unsupportedVersion, field: "contractVersion")
        }
    }

    static func uuid(_ value: UUID, field: String) throws {
        guard value != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: field)
        }
    }

    static func identifier(_ value: String, field: String, maximum: Int = 128) throws {
        guard (1...maximum).contains(value.utf8.count), value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 58, 95:
                return true
            default:
                return false
            }
        }) else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: field)
        }
    }

    static func date(_ value: Date, field: String) throws {
        guard value.timeIntervalSince1970.isFinite else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: field)
        }
    }

    static func digest(_ value: AcceleratorDigest, field: String) throws {
        guard value.value.utf8.count == 64 else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: field)
        }
    }

    static func exactKeys(
        _ keys: Set<String>,
        expected: Set<String>,
        field: String
    ) throws {
        guard keys == expected else {
            let code: AcceleratorXPCErrorCode = keys.subtracting(expected).isEmpty
                ? .invalidPayload
                : .unknownField
            throw AcceleratorXPCValidationError(code: code, field: field)
        }
    }

    static func executionBinding(
        request: AcceleratorExecutionRequest,
        claim: AcceleratorClaim,
        grant: AcceleratorGrant,
        reservation: AcceleratorReservation,
        inventory: AcceleratorInventorySnapshot,
        observedAt: Date
    ) throws {
        try date(observedAt, field: "observedAt")
        guard observedAt >= request.requestedAt else {
            throw AcceleratorXPCValidationError(code: .requestMismatch, field: "observedAt")
        }
        do {
            try AcceleratorExecutionContract.validate(
                request: request,
                claim: claim,
                grant: grant,
                reservation: reservation,
                inventory: inventory,
                observedAt: request.requestedAt
            )
        } catch let error as AcceleratorValidationError {
            let code: AcceleratorXPCErrorCode
            switch error.code {
            case .inventoryMismatch:
                code = .inventoryMismatch
            case .authenticationExpired, .invalidAuthentication:
                code = .authenticationFailed
            case .staleNodeEpoch, .staleReservationSequence:
                code = .fenceMismatch
            default:
                code = .requestMismatch
            }
            throw AcceleratorXPCValidationError(
                code: code,
                field: "executionBinding.\(error.field)"
            )
        } catch {
            throw AcceleratorXPCValidationError(code: .requestMismatch, field: "executionBinding")
        }
    }

    static func revocationAuthority(
        revocation: AcceleratorRevocationRecord,
        claim: AcceleratorClaim?,
        grant: AcceleratorGrant?,
        reservation: AcceleratorReservation?,
        observedAt: Date
    ) throws {
        try date(observedAt, field: "observedAt")
        guard revocation.actor.isActive(at: observedAt) else {
            throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
        }
        switch revocation.targetKind {
        case .claim:
            guard let claim,
                  grant == nil,
                  reservation == nil,
                  revocation.actor == claim.issuer else {
                throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
            }
        case .grant:
            guard let grant,
                  reservation == nil,
                  claim?.claimID == grant.claimID,
                  claim?.scope.contains(grant.scope) ?? true,
                  revocation.actor == grant.issuer else {
                throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
            }
        case .reservation:
            guard let reservation,
                  claim?.claimID == reservation.claimID,
                  grant?.reservationID == reservation.reservationID,
                  revocation.actor == reservation.owner else {
                throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
            }
        case .session:
            guard claim == nil,
                  grant == nil,
                  reservation == nil,
                  revocation.actor.sessionID == revocation.targetIdentifier else {
                throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
            }
        }
    }
}

public struct AcceleratorXPCInventoryQuery: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let hostID: UUID
    public let requester: AcceleratorAuthenticationContext
    public let observedAt: Date

    public init(
        hostID: UUID,
        requester: AcceleratorAuthenticationContext,
        observedAt: Date,
        contractVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(contractVersion)
        try AcceleratorXPCValidation.uuid(hostID, field: "hostID")
        try AcceleratorXPCValidation.date(observedAt, field: "observedAt")
        try requester.validateActive(at: observedAt)
        self.contractVersion = contractVersion
        self.hostID = hostID
        self.requester = requester
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case hostID
        case requester
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorXPCValidation.exactKeys(
            Set(container.allKeys.map(\.stringValue)),
            expected: ["contractVersion", "hostID", "requester", "observedAt"],
            field: "inventory"
        )
        try self.init(
            hostID: container.decode(UUID.self, forKey: .hostID),
            requester: container.decode(AcceleratorAuthenticationContext.self, forKey: .requester),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorXPCStatusQuery: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let hostID: UUID
    public let inventorySnapshotID: UUID
    public let inventoryGeneration: Int64
    public let requester: AcceleratorAuthenticationContext
    public let observedAt: Date

    public init(
        hostID: UUID,
        inventorySnapshotID: UUID,
        inventoryGeneration: Int64,
        requester: AcceleratorAuthenticationContext,
        observedAt: Date,
        contractVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(contractVersion)
        try AcceleratorXPCValidation.uuid(hostID, field: "hostID")
        try AcceleratorXPCValidation.uuid(
            inventorySnapshotID,
            field: "inventorySnapshotID"
        )
        guard inventoryGeneration >= 1 else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "inventoryGeneration")
        }
        try AcceleratorXPCValidation.date(observedAt, field: "observedAt")
        try requester.validateActive(at: observedAt)
        self.contractVersion = contractVersion
        self.hostID = hostID
        self.inventorySnapshotID = inventorySnapshotID
        self.inventoryGeneration = inventoryGeneration
        self.requester = requester
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case hostID
        case inventorySnapshotID
        case inventoryGeneration
        case requester
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorXPCValidation.exactKeys(
            Set(container.allKeys.map(\.stringValue)),
            expected: [
                "contractVersion", "hostID", "inventorySnapshotID", "inventoryGeneration",
                "requester", "observedAt"
            ],
            field: "status"
        )
        try self.init(
            hostID: container.decode(UUID.self, forKey: .hostID),
            inventorySnapshotID: container.decode(UUID.self, forKey: .inventorySnapshotID),
            inventoryGeneration: container.decode(Int64.self, forKey: .inventoryGeneration),
            requester: container.decode(AcceleratorAuthenticationContext.self, forKey: .requester),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorXPCExecutePayload: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let request: AcceleratorExecutionRequest
    public let claim: AcceleratorClaim
    public let grant: AcceleratorGrant
    public let reservation: AcceleratorReservation
    public let inventory: AcceleratorInventorySnapshot
    public let inputPayload: Data
    public let observedAt: Date

    public init(
        request: AcceleratorExecutionRequest,
        claim: AcceleratorClaim,
        grant: AcceleratorGrant,
        reservation: AcceleratorReservation,
        inventory: AcceleratorInventorySnapshot,
        inputPayload: Data,
        observedAt: Date,
        contractVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(contractVersion)
        guard inputPayload.count == request.inputBytes,
              inputPayload.count <= AcceleratorLimits.maxInputBytes else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "inputPayload")
        }
        try AcceleratorXPCValidation.date(observedAt, field: "observedAt")
        let inputDigest = try AcceleratorXPCDigest.sha256(inputPayload)
        guard inputDigest == request.inputDigest else {
            throw AcceleratorXPCValidationError(code: .inputDigestMismatch, field: "inputPayload")
        }
        try AcceleratorExecutionContract.validate(
            request: request,
            claim: claim,
            grant: grant,
            reservation: reservation,
            inventory: inventory,
            observedAt: observedAt
        )
        self.contractVersion = contractVersion
        self.request = request
        self.claim = claim
        self.grant = grant
        self.reservation = reservation
        self.inventory = inventory
        self.inputPayload = inputPayload
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case request
        case claim
        case grant
        case reservation
        case inventory
        case inputPayload
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorXPCValidation.exactKeys(
            Set(container.allKeys.map(\.stringValue)),
            expected: [
                "contractVersion", "request", "claim", "grant", "reservation",
                "inventory", "inputPayload", "observedAt"
            ],
            field: "execute"
        )
        try self.init(
            request: container.decode(AcceleratorExecutionRequest.self, forKey: .request),
            claim: container.decode(AcceleratorClaim.self, forKey: .claim),
            grant: container.decode(AcceleratorGrant.self, forKey: .grant),
            reservation: container.decode(AcceleratorReservation.self, forKey: .reservation),
            inventory: container.decode(AcceleratorInventorySnapshot.self, forKey: .inventory),
            inputPayload: container.decode(Data.self, forKey: .inputPayload),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

internal struct AcceleratorXPCExecutionBinding: Equatable, Hashable, Sendable {
    let request: AcceleratorExecutionRequest
    let claim: AcceleratorClaim
    let grant: AcceleratorGrant
    let reservation: AcceleratorReservation
    let inventory: AcceleratorInventorySnapshot

    init(
        request: AcceleratorExecutionRequest,
        claim: AcceleratorClaim,
        grant: AcceleratorGrant,
        reservation: AcceleratorReservation,
        inventory: AcceleratorInventorySnapshot
    ) {
        self.request = request
        self.claim = claim
        self.grant = grant
        self.reservation = reservation
        self.inventory = inventory
    }
}

public struct AcceleratorXPCCancelPayload: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let executionRequest: AcceleratorExecutionRequest
    public let cancellation: AcceleratorCancellationRecord
    public let claim: AcceleratorClaim
    public let grant: AcceleratorGrant
    public let reservation: AcceleratorReservation
    public let inventory: AcceleratorInventorySnapshot
    public let observedAt: Date

    public init(
        executionRequest: AcceleratorExecutionRequest,
        cancellation: AcceleratorCancellationRecord,
        claim: AcceleratorClaim,
        grant: AcceleratorGrant,
        reservation: AcceleratorReservation,
        inventory: AcceleratorInventorySnapshot,
        observedAt: Date,
        contractVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(contractVersion)
        try AcceleratorXPCValidation.date(observedAt, field: "observedAt")
        guard cancellation.state == .requested,
              cancellation.effectiveAt == nil,
              cancellation.requestID == executionRequest.requestID,
              cancellation.grantID == executionRequest.grantID,
              cancellation.reservationID == executionRequest.reservationID,
              cancellation.scope == executionRequest.scope,
              cancellation.fence == executionRequest.fence,
              cancellation.requestedAt <= observedAt,
              executionRequest.grantID == grant.grantID,
              executionRequest.reservationID == reservation.reservationID,
              executionRequest.scope == grant.scope,
              executionRequest.scope == reservation.scope,
              executionRequest.mode == grant.mode,
              executionRequest.mode == reservation.mode,
              grant.modelHash == Optional(executionRequest.modelHash),
              reservation.modelHash == Optional(executionRequest.modelHash),
              executionRequest.fence == grant.fence,
              executionRequest.fence == reservation.fence else {
            throw AcceleratorXPCValidationError(code: .requestMismatch, field: "cancellation")
        }
        guard claim.claimID == grant.claimID,
              reservation.claimID == claim.claimID,
              grant.reservationID == reservation.reservationID,
              claim.inventorySnapshotID == inventory.snapshotID,
              grant.inventorySnapshotID == inventory.snapshotID,
              reservation.inventorySnapshotID == inventory.snapshotID,
              claim.inventoryGeneration == inventory.observedGeneration,
              grant.inventoryGeneration == inventory.observedGeneration,
              reservation.inventoryGeneration == inventory.observedGeneration else {
            throw AcceleratorXPCValidationError(code: .inventoryMismatch, field: "inventory")
        }
        guard cancellation.actor == executionRequest.authentication else {
            throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
        }
        guard cancellation.actor.isActive(at: observedAt) else {
            throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
        }
        try AcceleratorXPCValidation.executionBinding(
            request: executionRequest,
            claim: claim,
            grant: grant,
            reservation: reservation,
            inventory: inventory,
            observedAt: observedAt
        )
        self.contractVersion = contractVersion
        self.executionRequest = executionRequest
        self.cancellation = cancellation
        self.claim = claim
        self.grant = grant
        self.reservation = reservation
        self.inventory = inventory
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case executionRequest
        case cancellation
        case claim
        case grant
        case reservation
        case inventory
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorXPCValidation.exactKeys(
            Set(container.allKeys.map(\.stringValue)),
            expected: [
                "contractVersion", "executionRequest", "cancellation", "claim", "grant",
                "reservation", "inventory", "observedAt"
            ],
            field: "cancel"
        )
        try self.init(
            executionRequest: container.decode(AcceleratorExecutionRequest.self, forKey: .executionRequest),
            cancellation: container.decode(AcceleratorCancellationRecord.self, forKey: .cancellation),
            claim: container.decode(AcceleratorClaim.self, forKey: .claim),
            grant: container.decode(AcceleratorGrant.self, forKey: .grant),
            reservation: container.decode(AcceleratorReservation.self, forKey: .reservation),
            inventory: container.decode(AcceleratorInventorySnapshot.self, forKey: .inventory),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorXPCRevokePayload: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let revocation: AcceleratorRevocationRecord
    public let claim: AcceleratorClaim?
    public let grant: AcceleratorGrant?
    public let reservation: AcceleratorReservation?
    public let observedAt: Date

    public init(
        revocation: AcceleratorRevocationRecord,
        claim: AcceleratorClaim? = nil,
        grant: AcceleratorGrant? = nil,
        reservation: AcceleratorReservation? = nil,
        observedAt: Date,
        contractVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(contractVersion)
        try AcceleratorXPCValidation.date(observedAt, field: "observedAt")
        guard revocation.actor.isActive(at: observedAt) else {
            throw AcceleratorXPCValidationError(code: .authenticationFailed, field: "actor")
        }
        switch revocation.targetKind {
        case .claim:
            guard let claim,
                  revocation.targetIdentifier == claim.claimID.uuidString.lowercased(),
                  revocation.scope == claim.scope,
                  grant == nil,
                  reservation == nil else {
                throw AcceleratorXPCValidationError(code: .requestMismatch, field: "claim")
            }
        case .grant:
            guard let grant,
                  revocation.targetIdentifier == grant.grantID.uuidString.lowercased(),
                  revocation.scope == grant.scope,
                  revocation.fence == grant.fence,
                  claim?.claimID == grant.claimID,
                  reservation == nil else {
                throw AcceleratorXPCValidationError(code: .requestMismatch, field: "grant")
            }
        case .reservation:
            guard let reservation,
                  revocation.targetIdentifier == reservation.reservationID.uuidString.lowercased(),
                  revocation.scope == reservation.scope,
                  revocation.fence == reservation.fence,
                  claim?.claimID == reservation.claimID,
                  grant?.reservationID == reservation.reservationID else {
                throw AcceleratorXPCValidationError(code: .requestMismatch, field: "reservation")
            }
        case .session:
            guard claim == nil, grant == nil, reservation == nil else {
                throw AcceleratorXPCValidationError(code: .requestMismatch, field: "session")
            }
        }
        try AcceleratorXPCValidation.revocationAuthority(
            revocation: revocation,
            claim: claim,
            grant: grant,
            reservation: reservation,
            observedAt: observedAt
        )
        self.contractVersion = contractVersion
        self.revocation = revocation
        self.claim = claim
        self.grant = grant
        self.reservation = reservation
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case revocation
        case claim
        case grant
        case reservation
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        var expected: Set<String> = ["contractVersion", "revocation", "observedAt"]
        if keys.contains("claim") { expected.insert("claim") }
        if keys.contains("grant") { expected.insert("grant") }
        if keys.contains("reservation") { expected.insert("reservation") }
        try AcceleratorXPCValidation.exactKeys(keys, expected: expected, field: "revoke")
        try self.init(
            revocation: container.decode(AcceleratorRevocationRecord.self, forKey: .revocation),
            claim: container.decodeIfPresent(AcceleratorClaim.self, forKey: .claim),
            grant: container.decodeIfPresent(AcceleratorGrant.self, forKey: .grant),
            reservation: container.decodeIfPresent(AcceleratorReservation.self, forKey: .reservation),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorXPCRequestPayload: Codable, Equatable, Sendable {
    case inventory(AcceleratorXPCInventoryQuery)
    case status(AcceleratorXPCStatusQuery)
    case execute(AcceleratorXPCExecutePayload)
    case cancel(AcceleratorXPCCancelPayload)
    case revoke(AcceleratorXPCRevokePayload)

    private enum CodingKeys: String, CodingKey {
        case kind
        case inventory
        case status
        case execute
        case cancel
        case revoke
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case AcceleratorXPCOperation.inventory.rawValue:
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "inventory"], field: "payload")
            self = .inventory(try container.decode(AcceleratorXPCInventoryQuery.self, forKey: .inventory))
        case AcceleratorXPCOperation.status.rawValue:
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "status"], field: "payload")
            self = .status(try container.decode(AcceleratorXPCStatusQuery.self, forKey: .status))
        case AcceleratorXPCOperation.execute.rawValue:
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "execute"], field: "payload")
            self = .execute(try container.decode(AcceleratorXPCExecutePayload.self, forKey: .execute))
        case AcceleratorXPCOperation.cancel.rawValue:
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "cancel"], field: "payload")
            self = .cancel(try container.decode(AcceleratorXPCCancelPayload.self, forKey: .cancel))
        case AcceleratorXPCOperation.revoke.rawValue:
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "revoke"], field: "payload")
            self = .revoke(try container.decode(AcceleratorXPCRevokePayload.self, forKey: .revoke))
        default:
            throw AcceleratorXPCValidationError(code: .invalidOperation, field: "kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inventory(let value):
            try container.encode(AcceleratorXPCOperation.inventory.rawValue, forKey: .kind)
            try container.encode(value, forKey: .inventory)
        case .status(let value):
            try container.encode(AcceleratorXPCOperation.status.rawValue, forKey: .kind)
            try container.encode(value, forKey: .status)
        case .execute(let value):
            try container.encode(AcceleratorXPCOperation.execute.rawValue, forKey: .kind)
            try container.encode(value, forKey: .execute)
        case .cancel(let value):
            try container.encode(AcceleratorXPCOperation.cancel.rawValue, forKey: .kind)
            try container.encode(value, forKey: .cancel)
        case .revoke(let value):
            try container.encode(AcceleratorXPCOperation.revoke.rawValue, forKey: .kind)
            try container.encode(value, forKey: .revoke)
        }
    }

    var operation: AcceleratorXPCOperation {
        switch self {
        case .inventory: .inventory
        case .status: .status
        case .execute: .execute
        case .cancel: .cancel
        case .revoke: .revoke
        }
    }

    var targetRequestID: UUID? {
        switch self {
        case .inventory, .status:
            nil
        case .execute(let value):
            value.request.requestID
        case .cancel(let value):
            value.cancellation.cancellationID
        case .revoke(let value):
            value.revocation.revocationID
        }
    }
}

public struct AcceleratorXPCRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operation: AcceleratorXPCOperation
    public let requestID: UUID
    public let timeoutMilliseconds: Int
    public let idempotencyDigest: AcceleratorDigest
    public let payload: AcceleratorXPCRequestPayload

    public init(
        operation: AcceleratorXPCOperation,
        requestID: UUID,
        timeoutMilliseconds: Int,
        payload: AcceleratorXPCRequestPayload,
        idempotencyDigest: AcceleratorDigest? = nil,
        protocolVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(protocolVersion)
        try AcceleratorXPCValidation.uuid(requestID, field: "requestID")
        guard (1...AcceleratorLimits.maxTimeoutMilliseconds).contains(timeoutMilliseconds) else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "timeoutMilliseconds")
        }
        guard operation == payload.operation else {
            throw AcceleratorXPCValidationError(code: .invalidOperation, field: "operation")
        }
        if let targetRequestID = payload.targetRequestID {
            guard targetRequestID == requestID else {
                throw AcceleratorXPCValidationError(code: .requestMismatch, field: "requestID")
            }
        }
        let payloadData = try AcceleratorXPCWireJSON.encode(payload)
        let expected = try AcceleratorXPCDigest.request(
            operation: operation,
            timeoutMilliseconds: timeoutMilliseconds,
            payload: payloadData
        )
        if let idempotencyDigest {
            guard idempotencyDigest == expected else {
                throw AcceleratorXPCValidationError(code: .idempotencyConflict, field: "idempotencyDigest")
            }
        }
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.requestID = requestID
        self.timeoutMilliseconds = timeoutMilliseconds
        self.idempotencyDigest = expected
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case operation
        case requestID
        case timeoutMilliseconds
        case idempotencyDigest
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        try AcceleratorXPCValidation.exactKeys(
            keys,
            expected: ["protocolVersion", "operation", "requestID", "timeoutMilliseconds", "idempotencyDigest", "payload"],
            field: "request"
        )
        let requestID = try container.decode(UUID.self, forKey: .requestID)
        try self.init(
            operation: container.decode(AcceleratorXPCOperation.self, forKey: .operation),
            requestID: requestID,
            timeoutMilliseconds: container.decode(Int.self, forKey: .timeoutMilliseconds),
            payload: container.decode(AcceleratorXPCRequestPayload.self, forKey: .payload),
            idempotencyDigest: container.decode(AcceleratorDigest.self, forKey: .idempotencyDigest),
            protocolVersion: container.decode(Int.self, forKey: .protocolVersion)
        )
    }
}

public struct AcceleratorXPCStatusSnapshot: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let hostID: UUID
    public let inventorySnapshotID: UUID
    public let inventoryGeneration: Int64
    public let observedAt: Date
    public let availability: AcceleratorXPCAvailability

    public init(
        hostID: UUID,
        inventorySnapshotID: UUID,
        inventoryGeneration: Int64,
        observedAt: Date,
        availability: AcceleratorXPCAvailability,
        contractVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(contractVersion)
        try AcceleratorXPCValidation.uuid(hostID, field: "hostID")
        try AcceleratorXPCValidation.uuid(inventorySnapshotID, field: "inventorySnapshotID")
        guard inventoryGeneration >= 1 else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "inventoryGeneration")
        }
        try AcceleratorXPCValidation.date(observedAt, field: "observedAt")
        self.contractVersion = contractVersion
        self.hostID = hostID
        self.inventorySnapshotID = inventorySnapshotID
        self.inventoryGeneration = inventoryGeneration
        self.observedAt = observedAt
        self.availability = availability
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case hostID
        case inventorySnapshotID
        case inventoryGeneration
        case observedAt
        case availability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorXPCValidation.exactKeys(
            Set(container.allKeys.map(\.stringValue)),
            expected: [
                "contractVersion", "hostID", "inventorySnapshotID", "inventoryGeneration",
                "observedAt", "availability"
            ],
            field: "status"
        )
        try self.init(
            hostID: container.decode(UUID.self, forKey: .hostID),
            inventorySnapshotID: container.decode(UUID.self, forKey: .inventorySnapshotID),
            inventoryGeneration: container.decode(Int64.self, forKey: .inventoryGeneration),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            availability: container.decode(AcceleratorXPCAvailability.self, forKey: .availability),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorXPCAvailability: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case available
    case unavailable
    case unsupported
}

public struct AcceleratorXPCMutationAcknowledgement: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let operation: AcceleratorXPCOperation
    public let targetIdentifier: String
    public let observedAt: Date
    public let fence: AcceleratorFence?

    public init(
        operation: AcceleratorXPCOperation,
        targetIdentifier: String,
        observedAt: Date,
        fence: AcceleratorFence? = nil,
        contractVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(contractVersion)
        guard operation == .cancel || operation == .revoke else {
            throw AcceleratorXPCValidationError(code: .invalidOperation, field: "operation")
        }
        try AcceleratorXPCValidation.identifier(targetIdentifier, field: "targetIdentifier")
        try AcceleratorXPCValidation.date(observedAt, field: "observedAt")
        self.contractVersion = contractVersion
        self.operation = operation
        self.targetIdentifier = targetIdentifier
        self.observedAt = observedAt
        self.fence = fence
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case operation
        case targetIdentifier
        case observedAt
        case fence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        var expected: Set<String> = ["contractVersion", "operation", "targetIdentifier", "observedAt"]
        if keys.contains("fence") { expected.insert("fence") }
        try AcceleratorXPCValidation.exactKeys(keys, expected: expected, field: "acknowledgement")
        try self.init(
            operation: container.decode(AcceleratorXPCOperation.self, forKey: .operation),
            targetIdentifier: container.decode(String.self, forKey: .targetIdentifier),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            fence: container.decodeIfPresent(AcceleratorFence.self, forKey: .fence),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorXPCResponsePayload: Codable, Equatable, Sendable {
    case inventory(AcceleratorInventorySnapshot)
    case status(AcceleratorXPCStatusSnapshot)
    case execution(AcceleratorExecutionResult)
    case acknowledgement(AcceleratorXPCMutationAcknowledgement)

    private enum CodingKeys: String, CodingKey {
        case kind
        case inventory
        case status
        case execution
        case acknowledgement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "inventory":
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "inventory"], field: "response.payload")
            self = .inventory(try container.decode(AcceleratorInventorySnapshot.self, forKey: .inventory))
        case "status":
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "status"], field: "response.payload")
            self = .status(try container.decode(AcceleratorXPCStatusSnapshot.self, forKey: .status))
        case "execution":
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "execution"], field: "response.payload")
            self = .execution(try container.decode(AcceleratorExecutionResult.self, forKey: .execution))
        case "acknowledgement":
            try AcceleratorXPCValidation.exactKeys(keys, expected: ["kind", "acknowledgement"], field: "response.payload")
            self = .acknowledgement(try container.decode(AcceleratorXPCMutationAcknowledgement.self, forKey: .acknowledgement))
        default:
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "response.payload.kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inventory(let value):
            try container.encode("inventory", forKey: .kind)
            try container.encode(value, forKey: .inventory)
        case .status(let value):
            try container.encode("status", forKey: .kind)
            try container.encode(value, forKey: .status)
        case .execution(let value):
            try container.encode("execution", forKey: .kind)
            try container.encode(value, forKey: .execution)
        case .acknowledgement(let value):
            try container.encode("acknowledgement", forKey: .kind)
            try container.encode(value, forKey: .acknowledgement)
        }
    }
}

public struct AcceleratorXPCResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operation: AcceleratorXPCOperation
    public let requestID: UUID
    public let status: AcceleratorXPCResponseStatus
    public let idempotencyDigest: AcceleratorDigest
    public let serviceProof: AcceleratorXPCCodeIdentityProof
    public let payload: AcceleratorXPCResponsePayload?
    public let error: AcceleratorXPCError?
    public let replayed: Bool

    public init(
        operation: AcceleratorXPCOperation,
        requestID: UUID,
        status: AcceleratorXPCResponseStatus,
        idempotencyDigest: AcceleratorDigest,
        serviceProof: AcceleratorXPCCodeIdentityProof,
        payload: AcceleratorXPCResponsePayload? = nil,
        error: AcceleratorXPCError? = nil,
        replayed: Bool = false,
        protocolVersion: Int = AcceleratorXPCContract.currentVersion
    ) throws {
        try AcceleratorXPCValidation.version(protocolVersion)
        try AcceleratorXPCValidation.uuid(requestID, field: "requestID")
        try AcceleratorXPCValidation.digest(idempotencyDigest, field: "idempotencyDigest")
        try serviceProof.validate(as: .service)
        switch status {
        case .completed:
            guard payload != nil, error == nil else {
                throw AcceleratorXPCValidationError(code: .invalidPayload, field: "response")
            }
            guard let payload,
                  (operation == .inventory && Self.isInventory(payload))
                    || (operation == .status && Self.isStatus(payload))
                    || (operation == .execute && Self.isExecution(payload))
                    || ((operation == .cancel || operation == .revoke) && Self.isAcknowledgement(payload)) else {
                throw AcceleratorXPCValidationError(code: .requestMismatch, field: "response.payload")
            }
        case .unavailable, .rejected, .cancelled, .revoked, .timedOut:
            guard payload == nil, let error else {
                throw AcceleratorXPCValidationError(code: .invalidPayload, field: "response")
            }
            guard status.accepts(error.code) else {
                throw AcceleratorXPCValidationError(code: .invalidPayload, field: "response.error.code")
            }
        }
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.requestID = requestID
        self.status = status
        self.idempotencyDigest = idempotencyDigest
        self.serviceProof = serviceProof
        self.payload = payload
        self.error = error
        self.replayed = replayed
    }

    private static func isInventory(_ payload: AcceleratorXPCResponsePayload) -> Bool {
        if case .inventory = payload { return true }
        return false
    }

    private static func isStatus(_ payload: AcceleratorXPCResponsePayload) -> Bool {
        if case .status = payload { return true }
        return false
    }

    private static func isExecution(_ payload: AcceleratorXPCResponsePayload) -> Bool {
        if case .execution = payload { return true }
        return false
    }

    private static func isAcknowledgement(_ payload: AcceleratorXPCResponsePayload) -> Bool {
        if case .acknowledgement = payload { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case operation
        case requestID
        case status
        case idempotencyDigest
        case serviceProof
        case payload
        case error
        case replayed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let hasPayload = keys.contains("payload")
        let hasError = keys.contains("error")
        var expected: Set<String> = [
            "protocolVersion", "operation", "requestID", "status",
            "idempotencyDigest", "serviceProof", "replayed"
        ]
        if hasPayload { expected.insert("payload") }
        if hasError { expected.insert("error") }
        try AcceleratorXPCValidation.exactKeys(keys, expected: expected, field: "response")
        try self.init(
            operation: container.decode(AcceleratorXPCOperation.self, forKey: .operation),
            requestID: container.decode(UUID.self, forKey: .requestID),
            status: container.decode(AcceleratorXPCResponseStatus.self, forKey: .status),
            idempotencyDigest: container.decode(AcceleratorDigest.self, forKey: .idempotencyDigest),
            serviceProof: container.decode(AcceleratorXPCCodeIdentityProof.self, forKey: .serviceProof),
            payload: container.decodeIfPresent(AcceleratorXPCResponsePayload.self, forKey: .payload),
            error: container.decodeIfPresent(AcceleratorXPCError.self, forKey: .error),
            replayed: container.decode(Bool.self, forKey: .replayed),
            protocolVersion: container.decode(Int.self, forKey: .protocolVersion)
        )
    }
}

internal enum AcceleratorXPCDigest {
    static func sha256(_ data: Data) throws -> AcceleratorDigest {
        let hash = SHA256.hash(data: data)
        let value = hash.map { String(format: "%02x", $0) }.joined()
        return try AcceleratorDigest(value)
    }

    static func request(
        operation: AcceleratorXPCOperation,
        timeoutMilliseconds: Int,
        payload: Data
    ) throws -> AcceleratorDigest {
        var preimage = Data("accelerator-xpc-v1\n".utf8)
        preimage.append(contentsOf: operation.rawValue.utf8)
        preimage.append(0x0A)
        preimage.append(contentsOf: String(timeoutMilliseconds).utf8)
        preimage.append(0x0A)
        preimage.append(payload)
        return try sha256(preimage)
    }
}

internal enum AcceleratorXPCWireJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try encoder().encode(value)
        guard data.count <= AcceleratorXPCContract.maxPayloadBytes else {
            throw AcceleratorXPCValidationError(code: .payloadTooLarge, field: "payload")
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= AcceleratorXPCContract.maxPayloadBytes else {
            throw AcceleratorXPCValidationError(code: .payloadTooLarge, field: "payload")
        }
        try AcceleratorXPCDuplicateKeyScanner.validate(data)
        if type == AcceleratorXPCRequestPayload.self {
            try AcceleratorXPCWireSchema.validateRequestPayload(data)
        } else if type == AcceleratorXPCResponsePayload.self {
            try AcceleratorXPCWireSchema.validateResponsePayload(data)
        } else if type == AcceleratorXPCResponse.self {
            try AcceleratorXPCWireSchema.validateResponse(data)
        }
        return try decoder().decode(type, from: data)
    }
}

private enum AcceleratorXPCDuplicateKeyScanner {
    private enum ScanError: Error { case malformed, duplicate, depth, nodeLimit }

    static func validate(_ data: Data) throws {
        do {
            var scanner = Scanner(bytes: Array(data))
            try scanner.value(depth: 0)
            scanner.whitespace()
            guard scanner.index == scanner.bytes.count else { throw ScanError.malformed }
        } catch let error as ScanError {
            switch error {
            case .malformed:
                throw AcceleratorXPCValidationError(code: .invalidMessage, field: "payload")
            case .duplicate:
                throw AcceleratorXPCValidationError(code: .duplicateField, field: "payload")
            case .depth:
                throw AcceleratorXPCValidationError(code: .invalidPayload, field: "payload.depth")
            case .nodeLimit:
                throw AcceleratorXPCValidationError(code: .payloadTooLarge, field: "payload.nodes")
            }
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var nodeCount = 0

        mutating func whitespace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
                index += 1
            }
        }

        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw ScanError.depth }
            nodeCount += 1
            guard nodeCount <= AcceleratorXPCContract.maxJSONNodeCount else {
                throw ScanError.nodeLimit
            }
            whitespace()
            guard index < bytes.count else { throw ScanError.malformed }
            switch bytes[index] {
            case 0x7B: try object(depth: depth + 1)
            case 0x5B: try array(depth: depth + 1)
            case 0x22: _ = try string()
            case 0x74: try literal("true")
            case 0x66: try literal("false")
            case 0x6E: try literal("null")
            case 0x2D, 0x30...0x39: try number()
            default: throw ScanError.malformed
            }
        }

        mutating func object(depth: Int) throws {
            index += 1
            whitespace()
            var keys = Set<String>()
            if index < bytes.count, bytes[index] == 0x7D {
                index += 1
                return
            }
            while true {
                whitespace()
                guard index < bytes.count, bytes[index] == 0x22 else { throw ScanError.malformed }
                let key = try string()
                guard keys.insert(key).inserted else { throw ScanError.duplicate }
                whitespace()
                guard index < bytes.count, bytes[index] == 0x3A else { throw ScanError.malformed }
                index += 1
                try value(depth: depth)
                whitespace()
                guard index < bytes.count else { throw ScanError.malformed }
                if bytes[index] == 0x7D {
                    index += 1
                    return
                }
                guard bytes[index] == 0x2C else { throw ScanError.malformed }
                index += 1
            }
        }

        mutating func array(depth: Int) throws {
            index += 1
            whitespace()
            if index < bytes.count, bytes[index] == 0x5D {
                index += 1
                return
            }
            while true {
                try value(depth: depth)
                whitespace()
                guard index < bytes.count else { throw ScanError.malformed }
                if bytes[index] == 0x5D {
                    index += 1
                    return
                }
                guard bytes[index] == 0x2C else { throw ScanError.malformed }
                index += 1
            }
        }

        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == 0x22 else { throw ScanError.malformed }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                } else if byte < 0x20 {
                    throw ScanError.malformed
                }
            }
            throw ScanError.malformed
        }

        mutating func literal(_ value: String) throws {
            let bytes = Array(value.utf8)
            guard self.bytes[index...].starts(with: bytes) else { throw ScanError.malformed }
            index += bytes.count
        }

        mutating func number() throws {
            let start = index
            while index < bytes.count,
                  bytes[index] == 0x2D || bytes[index] == 0x2B
                    || bytes[index] == 0x2E || bytes[index] == 0x45
                    || bytes[index] == 0x65 || (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
            guard index > start else { throw ScanError.malformed }
        }
    }
}

public enum AcceleratorXPCMessageCodec {
    private static let protocolKey = "protocolVersion"
    private static let operationKey = "operation"
    private static let requestIDKey = "requestID"
    private static let timeoutKey = "timeoutMilliseconds"
    private static let digestKey = "idempotencyDigest"
    private static let payloadKey = "payload"
    private static let statusKey = "status"
    private static let serviceProofKey = "serviceProof"
    private static let errorKey = "error"
    private static let replayedKey = "replayed"

    public static func encodeRequest(_ request: AcceleratorXPCRequest) throws -> xpc_object_t {
        let payload = try AcceleratorXPCWireJSON.encode(request.payload)
        try AcceleratorXPCContract.validateEncodedEnvelope(dataByteCounts: [payload.count])
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, protocolKey, UInt64(request.protocolVersion))
        xpc_dictionary_set_string(message, operationKey, request.operation.rawValue)
        xpc_dictionary_set_string(message, requestIDKey, request.requestID.uuidString.lowercased())
        xpc_dictionary_set_uint64(message, timeoutKey, UInt64(request.timeoutMilliseconds))
        xpc_dictionary_set_string(message, digestKey, request.idempotencyDigest.value)
        payload.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, payloadKey, bytes.baseAddress, bytes.count)
        }
        return message
    }

    public static func decodeRequest(_ message: xpc_object_t) throws -> AcceleratorXPCRequest {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            throw AcceleratorXPCValidationError(code: .invalidMessage, field: "message")
        }
        let keys = try keys(of: message, maximum: 6)
        guard keys == [protocolKey, operationKey, requestIDKey, timeoutKey, digestKey, payloadKey].sorted() else {
            throw AcceleratorXPCValidationError(code: .unknownField, field: "message")
        }
        guard let version = uint(message, protocolKey), version <= UInt64(Int.max),
              let operationText = string(message, operationKey, maximumBytes: 32),
              let operation = AcceleratorXPCOperation(rawValue: operationText),
              let requestIDText = string(message, requestIDKey, maximumBytes: 64),
              let requestID = canonicalUUID(requestIDText),
              let timeout = uint(message, timeoutKey), timeout <= UInt64(Int.max),
              let digestText = string(message, digestKey, maximumBytes: 64),
              let digest = try? AcceleratorDigest(digestText),
              let payloadValue = data(message, payloadKey) else {
            throw AcceleratorXPCValidationError(code: .invalidMessage, field: "message")
        }
        try AcceleratorXPCContract.validateEncodedEnvelope(dataByteCounts: [payloadValue.count])
        let payload = try AcceleratorXPCWireJSON.decode(
            AcceleratorXPCRequestPayload.self,
            from: payloadValue
        )
        return try AcceleratorXPCRequest(
            operation: operation,
            requestID: requestID,
            timeoutMilliseconds: Int(timeout),
            payload: payload,
            idempotencyDigest: digest,
            protocolVersion: Int(version)
        )
    }

    public static func encodeResponse(_ response: AcceleratorXPCResponse) throws -> xpc_object_t {
        let proof = try AcceleratorXPCWireJSON.encode(response.serviceProof)
        let payloadData = try response.payload.map(AcceleratorXPCWireJSON.encode)
        let errorData = try response.error.map(AcceleratorXPCWireJSON.encode)
        try AcceleratorXPCContract.validateEncodedEnvelope(
            dataByteCounts: [proof.count] + [payloadData, errorData].compactMap { $0?.count }
        )
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, protocolKey, UInt64(response.protocolVersion))
        xpc_dictionary_set_string(message, operationKey, response.operation.rawValue)
        xpc_dictionary_set_string(message, requestIDKey, response.requestID.uuidString.lowercased())
        xpc_dictionary_set_string(message, statusKey, response.status.rawValue)
        xpc_dictionary_set_string(message, digestKey, response.idempotencyDigest.value)
        xpc_dictionary_set_bool(message, replayedKey, response.replayed)
        proof.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, serviceProofKey, bytes.baseAddress, bytes.count)
        }
        if let payloadData {
            payloadData.withUnsafeBytes { bytes in
                xpc_dictionary_set_data(message, payloadKey, bytes.baseAddress, bytes.count)
            }
        }
        if let errorData {
            errorData.withUnsafeBytes { bytes in
                xpc_dictionary_set_data(message, errorKey, bytes.baseAddress, bytes.count)
            }
        }
        return message
    }

    public static func decodeResponse(_ message: xpc_object_t) throws -> AcceleratorXPCResponse {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            throw AcceleratorXPCValidationError(code: .invalidMessage, field: "response")
        }
        let keys = try keys(of: message, maximum: 10)
        guard let statusText = string(message, statusKey, maximumBytes: 32),
              let status = AcceleratorXPCResponseStatus(rawValue: statusText),
              let operationText = string(message, operationKey, maximumBytes: 32),
              let operation = AcceleratorXPCOperation(rawValue: operationText),
              let version = uint(message, protocolKey), version <= UInt64(Int.max),
              let requestIDText = string(message, requestIDKey, maximumBytes: 64),
              let requestID = canonicalUUID(requestIDText),
              let digestText = string(message, digestKey, maximumBytes: 64),
              let digest = try? AcceleratorDigest(digestText),
              let serviceProofData = data(message, serviceProofKey),
              let replayed = bool(message, replayedKey) else {
            throw AcceleratorXPCValidationError(code: .invalidMessage, field: "response")
        }
        var expected = [protocolKey, operationKey, requestIDKey, statusKey, digestKey, serviceProofKey, replayedKey]
        if status == .completed { expected.append(payloadKey) } else { expected.append(errorKey) }
        guard keys == expected.sorted() else {
            throw AcceleratorXPCValidationError(code: .unknownField, field: "response")
        }
        let serviceProof = try AcceleratorXPCWireJSON.decode(
            AcceleratorXPCCodeIdentityProof.self,
            from: serviceProofData
        )
        let payload: AcceleratorXPCResponsePayload?
        let error: AcceleratorXPCError?
        if status == .completed {
            guard let payloadData = data(message, payloadKey) else {
                throw AcceleratorXPCValidationError(code: .invalidMessage, field: payloadKey)
            }
            try AcceleratorXPCContract.validateEncodedEnvelope(
                dataByteCounts: [serviceProofData.count, payloadData.count]
            )
            payload = try AcceleratorXPCWireJSON.decode(
                AcceleratorXPCResponsePayload.self,
                from: payloadData
            )
            error = nil
        } else {
            guard let errorData = data(message, errorKey) else {
                throw AcceleratorXPCValidationError(code: .invalidMessage, field: errorKey)
            }
            try AcceleratorXPCContract.validateEncodedEnvelope(
                dataByteCounts: [serviceProofData.count, errorData.count]
            )
            error = try AcceleratorXPCWireJSON.decode(AcceleratorXPCError.self, from: errorData)
            payload = nil
        }
        return try AcceleratorXPCResponse(
            operation: operation,
            requestID: requestID,
            status: status,
            idempotencyDigest: digest,
            serviceProof: serviceProof,
            payload: payload,
            error: error,
            replayed: replayed,
            protocolVersion: Int(version)
        )
    }

    private static func keys(of message: xpc_object_t, maximum: Int) throws -> [String] {
        var values = [String]()
        var valid = true
        xpc_dictionary_apply(message) { key, _ in
            guard values.count < maximum else {
                valid = false
                return false
            }
            values.append(String(cString: key))
            return true
        }
        guard valid, Set(values).count == values.count else {
            throw AcceleratorXPCValidationError(code: .invalidMessage, field: "keys")
        }
        return values.sorted()
    }

    private static func string(
        _ message: xpc_object_t,
        _ key: String,
        maximumBytes: Int
    ) -> String? {
        guard let value = xpc_dictionary_get_value(message, key),
              xpc_get_type(value) == XPC_TYPE_STRING,
              xpc_string_get_length(value) <= maximumBytes,
              let pointer = xpc_string_get_string_ptr(value) else {
            return nil
        }
        return String(cString: pointer)
    }

    private static func uint(_ message: xpc_object_t, _ key: String) -> UInt64? {
        guard let value = xpc_dictionary_get_value(message, key),
              xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
        return xpc_uint64_get_value(value)
    }

    private static func bool(_ message: xpc_object_t, _ key: String) -> Bool? {
        guard let value = xpc_dictionary_get_value(message, key),
              xpc_get_type(value) == XPC_TYPE_BOOL else { return nil }
        return xpc_bool_get_value(value)
    }

    private static func data(_ message: xpc_object_t, _ key: String) -> Data? {
        guard let value = xpc_dictionary_get_value(message, key),
              xpc_get_type(value) == XPC_TYPE_DATA,
              xpc_data_get_length(value) <= AcceleratorXPCContract.maxMessageBytes else {
            return nil
        }
        var data = Data(count: xpc_data_get_length(value))
        if !data.isEmpty {
            data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                _ = xpc_data_get_bytes(value, baseAddress, 0, bytes.count)
            }
        }
        return data
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value,
              uuid != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            return nil
        }
        return uuid
    }
}
