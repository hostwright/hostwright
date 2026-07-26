import CryptoKit
import Foundation

public struct StorageReclaimEngine: Sendable {
    public init() {}

    public func preview(
        _ request: StorageReclaimRequest
    ) throws -> StorageReclaimPlan {
        let changesPolicy =
            request.currentPolicy != request.requestedPolicy
        let destructive = request.requestedPolicy != .retain

        if changesPolicy || destructive {
            guard request.activeAttachmentIDs.isEmpty else {
                throw failure(
                    .activeAttachment,
                    "Reclaim is refused while an attachment is active."
                )
            }
            guard request.activeHoldIDs.isEmpty else {
                throw failure(
                    .activeHold,
                    "Reclaim is refused while a retention or operator hold is active."
                )
            }
            guard !request.ownershipAmbiguous else {
                throw failure(
                    .ambiguousOwnership,
                    "Reclaim requires unambiguous Hostwright ownership."
                )
            }
            guard request.ownershipProofSHA256 != nil else {
                throw failure(
                    .missingOwnershipProof,
                    "Reclaim requires exact ownership proof."
                )
            }
        }

        switch request.requestedPolicy {
        case .snapshotBeforeDelete:
            guard request.snapshotCapability.available else {
                throw failure(
                    .prerequisiteUnavailable,
                    "Snapshot-before-delete is unavailable for this provider."
                )
            }
        case .backupBeforeDelete:
            guard request.backupCapability.available else {
                throw failure(
                    .prerequisiteUnavailable,
                    "Backup-before-delete is unavailable for this provider."
                )
            }
        case .retain, .delete, .recycle:
            break
        }

        let actions = actions(for: request.requestedPolicy)
        let requestSHA256 = try digest(request)
        let confirmationSHA256 = try digest(
            ConfirmationInput(
                domain: "hostwright.storage.reclaim.v1",
                requestSHA256: requestSHA256,
                actions: actions
            )
        )
        return StorageReclaimPlan(
            operationID: request.operationID,
            idempotencySHA256: request.idempotencySHA256,
            volumeID: request.volumeID,
            generation: request.generation,
            requestedPolicy: request.requestedPolicy,
            requestSHA256: requestSHA256,
            actions: actions,
            destructive: destructive,
            confirmationSHA256: confirmationSHA256,
            redactedSummary:
                "volume=\(request.volumeID) generation=\(request.generation) policy=\(request.requestedPolicy.rawValue) actions=\(actions.count)"
        )
    }

    public func nextAction(
        request: StorageReclaimRequest,
        plan: StorageReclaimPlan,
        confirmationSHA256: String,
        checkpoint: StorageReclaimCheckpoint
    ) throws -> StorageReclaimDecision {
        let currentPlan = try preview(request)
        guard currentPlan == plan else {
            throw failure(
                .stalePlan,
                "Reclaim plan no longer matches current generation, policy, ownership, or capability evidence."
            )
        }
        guard confirmationSHA256 ==
                currentPlan.confirmationSHA256 else {
            throw failure(
                .confirmationMismatch,
                "Reclaim requires the exact current confirmation digest."
            )
        }
        guard checkpoint.operationID == request.operationID,
              checkpoint.idempotencySHA256 ==
                request.idempotencySHA256,
              checkpoint.confirmationSHA256 ==
                currentPlan.confirmationSHA256 else {
            throw failure(
                .invalidCheckpoint,
                "Reclaim checkpoint does not belong to this operation and plan."
            )
        }
        guard checkpoint.completedActions ==
                Array(
                    plan.actions.prefix(
                        checkpoint.completedActions.count
                    )
                ) else {
            throw failure(
                .invalidCheckpoint,
                "Reclaim checkpoint is not an exact action prefix."
            )
        }

        switch checkpoint.interruption {
        case .none:
            break
        case .cancelledBeforeEffect:
            return decision(
                request: request,
                disposition: .cancelled,
                action: nil,
                retryClass: .never,
                recovery: .none,
                summary: "Reclaim cancelled before an external effect."
            )
        case .cancelledAfterPossibleEffect, .timedOut,
                .ambiguousEffect:
            return decision(
                request: request,
                disposition: .recoveryRequired,
                action: nil,
                retryClass: .safeAfterObservation,
                recovery: .reobserve,
                summary:
                    "Reclaim effect is uncertain; exact observation is required before resume."
            )
        }

        guard checkpoint.completedActions.count <
                plan.actions.count else {
            return decision(
                request: request,
                disposition: .alreadySatisfied,
                action: nil,
                retryClass: .never,
                recovery: .none,
                summary: "Reclaim plan is already satisfied."
            )
        }

        let action =
            plan.actions[checkpoint.completedActions.count]
        if action == .verifySnapshot || action == .delete &&
            request.requestedPolicy == .snapshotBeforeDelete {
            try validatePrerequisiteProof(
                checkpoint.prerequisiteProof,
                kind: .snapshot,
                request: request
            )
        }
        if action == .verifyBackup || action == .delete &&
            request.requestedPolicy == .backupBeforeDelete {
            try validatePrerequisiteProof(
                checkpoint.prerequisiteProof,
                kind: .backup,
                request: request
            )
        }

        return decision(
            request: request,
            disposition: .perform,
            action: action,
            retryClass: .resumeFromCheckpoint,
            recovery: .resume,
            summary:
                "Authorized reclaim action=\(action.rawValue) volume=\(request.volumeID)."
        )
    }

    private func actions(
        for policy: StorageReclaimMode
    ) -> [StorageReclaimAction] {
        switch policy {
        case .retain:
            [.retain]
        case .delete:
            [.delete]
        case .snapshotBeforeDelete:
            [.createSnapshot, .verifySnapshot, .delete]
        case .backupBeforeDelete:
            [.createBackup, .verifyBackup, .delete]
        case .recycle:
            [.recycle, .verifyRecycle]
        }
    }

    private func validatePrerequisiteProof(
        _ proof: StorageReclaimPrerequisiteProof?,
        kind: StorageReclaimPrerequisiteKind,
        request: StorageReclaimRequest
    ) throws {
        guard let proof else {
            throw failure(
                .missingPrerequisiteProof,
                "Reclaim prerequisite must be durably verified before continuing."
            )
        }
        guard proof.verified,
              proof.kind == kind,
              proof.volumeID == request.volumeID,
              proof.generation == request.generation,
              proof.fencingToken == request.fencingToken,
              proof.ownershipProofSHA256 ==
                request.ownershipProofSHA256 else {
            throw failure(
                .mismatchedPrerequisiteProof,
                "Reclaim prerequisite proof does not match exact volume ownership and fencing."
            )
        }
    }

    private func decision(
        request: StorageReclaimRequest,
        disposition: StorageReclaimDisposition,
        action: StorageReclaimAction?,
        retryClass: StorageSemanticRetryClass,
        recovery: StorageProviderRecoveryDisposition,
        summary: String
    ) -> StorageReclaimDecision {
        StorageReclaimDecision(
            operationID: request.operationID,
            idempotencySHA256: request.idempotencySHA256,
            disposition: disposition,
            action: action,
            retryClass: retryClass,
            recoveryDisposition: recovery,
            redactedSummary: summary
        )
    }

    private func failure(
        _ code: StorageReclaimErrorCode,
        _ message: String
    ) -> StorageReclaimError {
        StorageReclaimError(
            code: code,
            retryClass: .never,
            recoveryDisposition: .none,
            message: message
        )
    }

    private func digest<Value: Encodable>(
        _ value: Value
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct ConfirmationInput: Encodable {
        let domain: String
        let requestSHA256: String
        let actions: [StorageReclaimAction]
    }
}
