import Foundation

public enum StorageReclaimMode:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case retain
    case delete
    case snapshotBeforeDelete = "snapshot-before-delete"
    case backupBeforeDelete = "backup-before-delete"
    case recycle
}

public enum StorageReclaimAction:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case retain
    case createSnapshot = "create-snapshot"
    case verifySnapshot = "verify-snapshot"
    case createBackup = "create-backup"
    case verifyBackup = "verify-backup"
    case delete
    case recycle
    case verifyRecycle = "verify-recycle"
}

public enum StorageReclaimPrerequisiteKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case snapshot
    case backup
}

public struct StorageReclaimPrerequisiteCapability:
    Codable,
    Equatable,
    Sendable
{
    public let available: Bool
    public let reasonCode: String?

    public init(
        available: Bool,
        reasonCode: String? = nil
    ) throws {
        guard (available && reasonCode == nil) ||
                (!available &&
                    reasonCode.map {
                        StorageReclaimValidation.validIdentifier(
                            $0,
                            maximumBytes: 128
                        )
                    } == true) else {
            throw StorageReclaimError.invalidArgument(
                "Prerequisite capability must have one bounded reason only when unavailable."
            )
        }
        self.available = available
        self.reasonCode = reasonCode
    }

    public static var supported:
        StorageReclaimPrerequisiteCapability
    {
        try! StorageReclaimPrerequisiteCapability(
            available: true
        )
    }
}

public struct StorageReclaimRequest:
    Codable,
    Equatable,
    Sendable
{
    public let operationID: String
    public let idempotencySHA256: String
    public let volumeID: String
    public let projectID: String
    public let providerID: String
    public let generation: Int64
    public let fencingToken: String
    public let currentPolicy: StorageReclaimMode
    public let requestedPolicy: StorageReclaimMode
    public let activeAttachmentIDs: [String]
    public let activeHoldIDs: [String]
    public let ownershipProofSHA256: String?
    public let ownershipAmbiguous: Bool
    public let snapshotCapability:
        StorageReclaimPrerequisiteCapability
    public let backupCapability:
        StorageReclaimPrerequisiteCapability

    public init(
        operationID: String,
        idempotencySHA256: String,
        volumeID: String,
        projectID: String,
        providerID: String,
        generation: Int64,
        fencingToken: String,
        currentPolicy: StorageReclaimMode,
        requestedPolicy: StorageReclaimMode,
        activeAttachmentIDs: [String] = [],
        activeHoldIDs: [String] = [],
        ownershipProofSHA256: String? = nil,
        ownershipAmbiguous: Bool = false,
        snapshotCapability:
            StorageReclaimPrerequisiteCapability = .supported,
        backupCapability:
            StorageReclaimPrerequisiteCapability = .supported
    ) throws {
        let attachments = activeAttachmentIDs.sorted()
        let holds = activeHoldIDs.sorted()
        guard StorageReclaimValidation.validUUID(operationID),
              StorageReclaimValidation.validSHA256(
                  idempotencySHA256
              ),
              StorageReclaimValidation.validUUID(volumeID),
              StorageReclaimValidation.validUUID(projectID),
              StorageReclaimValidation.validIdentifier(
                  providerID,
                  maximumBytes: 256
              ),
              generation > 0,
              StorageReclaimValidation.validUUID(fencingToken),
              attachments.count <=
                StorageSemanticLimits.maximumResources,
              holds.count <=
                StorageSemanticLimits.maximumResources,
              Set(attachments).count == attachments.count,
              Set(holds).count == holds.count,
              attachments.allSatisfy(
                  StorageReclaimValidation.validUUID
              ),
              holds.allSatisfy(
                  StorageReclaimValidation.validUUID
              ),
              ownershipProofSHA256 == nil ||
                StorageReclaimValidation.validSHA256(
                    ownershipProofSHA256!
                ) else {
            throw StorageReclaimError.invalidArgument(
                "Reclaim request is outside bounded identity, generation, or evidence limits."
            )
        }
        self.operationID = operationID
        self.idempotencySHA256 = idempotencySHA256
        self.volumeID = volumeID
        self.projectID = projectID
        self.providerID = providerID
        self.generation = generation
        self.fencingToken = fencingToken
        self.currentPolicy = currentPolicy
        self.requestedPolicy = requestedPolicy
        self.activeAttachmentIDs = attachments
        self.activeHoldIDs = holds
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.ownershipAmbiguous = ownershipAmbiguous
        self.snapshotCapability = snapshotCapability
        self.backupCapability = backupCapability
    }
}

public struct StorageReclaimPlan:
    Codable,
    Equatable,
    Sendable
{
    public let operationID: String
    public let idempotencySHA256: String
    public let volumeID: String
    public let generation: Int64
    public let requestedPolicy: StorageReclaimMode
    public let requestSHA256: String
    public let actions: [StorageReclaimAction]
    public let destructive: Bool
    public let confirmationSHA256: String
    public let redactedSummary: String
}

public struct StorageReclaimPrerequisiteProof:
    Codable,
    Equatable,
    Sendable
{
    public let kind: StorageReclaimPrerequisiteKind
    public let volumeID: String
    public let generation: Int64
    public let fencingToken: String
    public let ownershipProofSHA256: String
    public let artifactID: String
    public let artifactContentSHA256: String
    public let verified: Bool

    public init(
        kind: StorageReclaimPrerequisiteKind,
        volumeID: String,
        generation: Int64,
        fencingToken: String,
        ownershipProofSHA256: String,
        artifactID: String,
        artifactContentSHA256: String,
        verified: Bool
    ) throws {
        guard StorageReclaimValidation.validUUID(volumeID),
              generation > 0,
              StorageReclaimValidation.validUUID(fencingToken),
              StorageReclaimValidation.validSHA256(
                  ownershipProofSHA256
              ),
              StorageReclaimValidation.validUUID(artifactID),
              StorageReclaimValidation.validSHA256(
                  artifactContentSHA256
              ) else {
            throw StorageReclaimError.invalidArgument(
                "Reclaim prerequisite proof is outside bounded identity or evidence limits."
            )
        }
        self.kind = kind
        self.volumeID = volumeID
        self.generation = generation
        self.fencingToken = fencingToken
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.artifactID = artifactID
        self.artifactContentSHA256 = artifactContentSHA256
        self.verified = verified
    }
}

public enum StorageReclaimInterruption:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case none
    case cancelledBeforeEffect = "cancelled-before-effect"
    case cancelledAfterPossibleEffect =
        "cancelled-after-possible-effect"
    case timedOut = "timed-out"
    case ambiguousEffect = "ambiguous-effect"
}

public struct StorageReclaimCheckpoint:
    Codable,
    Equatable,
    Sendable
{
    public let operationID: String
    public let idempotencySHA256: String
    public let confirmationSHA256: String
    public let completedActions: [StorageReclaimAction]
    public let prerequisiteProof:
        StorageReclaimPrerequisiteProof?
    public let interruption: StorageReclaimInterruption

    public init(
        operationID: String,
        idempotencySHA256: String,
        confirmationSHA256: String,
        completedActions: [StorageReclaimAction] = [],
        prerequisiteProof:
            StorageReclaimPrerequisiteProof? = nil,
        interruption: StorageReclaimInterruption = .none
    ) throws {
        guard StorageReclaimValidation.validUUID(operationID),
              StorageReclaimValidation.validSHA256(
                  idempotencySHA256
              ),
              StorageReclaimValidation.validSHA256(
                  confirmationSHA256
              ),
              completedActions.count <= 8 else {
            throw StorageReclaimError.invalidArgument(
                "Reclaim checkpoint is outside bounded identity or action limits."
            )
        }
        self.operationID = operationID
        self.idempotencySHA256 = idempotencySHA256
        self.confirmationSHA256 = confirmationSHA256
        self.completedActions = completedActions
        self.prerequisiteProof = prerequisiteProof
        self.interruption = interruption
    }

    public static func initial(
        request: StorageReclaimRequest,
        plan: StorageReclaimPlan
    ) throws -> StorageReclaimCheckpoint {
        try StorageReclaimCheckpoint(
            operationID: request.operationID,
            idempotencySHA256: request.idempotencySHA256,
            confirmationSHA256: plan.confirmationSHA256
        )
    }
}

public enum StorageReclaimDisposition:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case perform
    case alreadySatisfied = "already-satisfied"
    case cancelled
    case recoveryRequired = "recovery-required"
}

public struct StorageReclaimDecision:
    Codable,
    Equatable,
    Sendable
{
    public let operationID: String
    public let idempotencySHA256: String
    public let disposition: StorageReclaimDisposition
    public let action: StorageReclaimAction?
    public let retryClass: StorageSemanticRetryClass
    public let recoveryDisposition:
        StorageProviderRecoveryDisposition
    public let redactedSummary: String

    public init(
        operationID: String,
        idempotencySHA256: String,
        disposition: StorageReclaimDisposition,
        action: StorageReclaimAction?,
        retryClass: StorageSemanticRetryClass,
        recoveryDisposition:
            StorageProviderRecoveryDisposition,
        redactedSummary: String
    ) {
        self.operationID = operationID
        self.idempotencySHA256 = idempotencySHA256
        self.disposition = disposition
        self.action = action
        self.retryClass = retryClass
        self.recoveryDisposition = recoveryDisposition
        self.redactedSummary =
            StorageReclaimValidation.bounded(
                redactedSummary,
                maximumBytes: 512
            )
    }
}

public enum StorageReclaimErrorCode:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case invalidArgument = "invalid-argument"
    case activeAttachment = "active-attachment"
    case activeHold = "active-hold"
    case ambiguousOwnership = "ambiguous-ownership"
    case missingOwnershipProof = "missing-ownership-proof"
    case prerequisiteUnavailable = "prerequisite-unavailable"
    case stalePlan = "stale-plan"
    case confirmationMismatch = "confirmation-mismatch"
    case missingPrerequisiteProof = "missing-prerequisite-proof"
    case mismatchedPrerequisiteProof =
        "mismatched-prerequisite-proof"
    case invalidCheckpoint = "invalid-checkpoint"
}

public struct StorageReclaimError:
    Error,
    Codable,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public let code: StorageReclaimErrorCode
    public let retryClass: StorageSemanticRetryClass
    public let recoveryDisposition:
        StorageProviderRecoveryDisposition
    public let message: String

    public init(
        code: StorageReclaimErrorCode,
        retryClass: StorageSemanticRetryClass,
        recoveryDisposition:
            StorageProviderRecoveryDisposition,
        message: String,
        sensitiveValues: [String] = []
    ) {
        self.code = code
        self.retryClass = retryClass
        self.recoveryDisposition = recoveryDisposition
        let redacted = sensitiveValues
            .filter { !$0.isEmpty }
            .reduce(message) { result, value in
                result.replacingOccurrences(
                    of: value,
                    with: "<redacted>"
                )
            }
        self.message = StorageReclaimValidation.bounded(
            redacted,
            maximumBytes: 512
        )
    }

    public var description: String {
        "\(code.rawValue) (\(retryClass.rawValue)): \(message)"
    }

    static func invalidArgument(
        _ message: String
    ) -> StorageReclaimError {
        StorageReclaimError(
            code: .invalidArgument,
            retryClass: .never,
            recoveryDisposition: .none,
            message: message
        )
    }
}

enum StorageReclaimValidation {
    static func validUUID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.allSatisfy {
                ("0"..."9").contains($0) ||
                    ("a"..."f").contains($0)
            }
    }

    static func validIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
                ).contains($0)
            }
    }

    static func bounded(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard value.utf8.count > maximumBytes else {
            return value
        }
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumBytes else {
                break
            }
            result = candidate
        }
        return result
    }
}
