import Foundation
import HostwrightCore
import HostwrightRuntime

public enum DaemonReconciliationStatus: String, Codable, Equatable, Sendable {
    case converged
    case mutated
    case compensated
    case interrupted
    case safeHold = "safe-hold"

    public var isSuccessfulIteration: Bool {
        self == .converged || self == .mutated
    }
}

public enum DaemonReconciliationReasonCode: String, Codable, Equatable, Sendable {
    case converged = "daemon.reconcile.converged"
    case mutationVerified = "daemon.reconcile.mutated"
    case compensated = "daemon.reconcile.compensated"
    case interrupted = "daemon.reconcile.interrupted"
    case safeHold = "daemon.reconcile.safe-hold"
}

public struct DaemonReconciliationRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let manifestPath: String
    public let manifestSHA256: String
    public let stateDatabasePath: String
    public let projectID: String
    public let maximumParallelism: Int

    public init(
        schemaVersion: Int = 1,
        manifestPath: String,
        manifestSHA256: String,
        stateDatabasePath: String,
        projectID: String,
        maximumParallelism: Int
    ) throws {
        guard schemaVersion == 1,
              !manifestPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifestSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              projectID.range(
                  of: "^project-[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$",
                  options: .regularExpression
              ) != nil,
              (1...32).contains(maximumParallelism) else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Unattended reconciliation requires schema v1, exact paths and digest, one bounded project identity, and parallelism from 1 through 32."
            )
        }
        self.schemaVersion = schemaVersion
        self.manifestPath = manifestPath
        self.manifestSHA256 = manifestSHA256
        self.stateDatabasePath = stateDatabasePath
        self.projectID = projectID
        self.maximumParallelism = maximumParallelism
    }
}

public struct DaemonReconciliationResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: DaemonReconciliationStatus
    public let reasonCode: DaemonReconciliationReasonCode
    public let planSHA256: String
    public let nodeCount: Int
    public let completedNodeCount: Int
    public let runtimeMutationAttempted: Bool
    public let operationID: String?
    public let groupID: String?
    public let checkpoint: String
    public let recoveryHintRedacted: String

    public init(
        schemaVersion: Int = 1,
        status: DaemonReconciliationStatus,
        reasonCode: DaemonReconciliationReasonCode,
        planSHA256: String,
        nodeCount: Int,
        completedNodeCount: Int,
        runtimeMutationAttempted: Bool,
        operationID: String? = nil,
        groupID: String? = nil,
        checkpoint: String,
        recoveryHintRedacted: String = ""
    ) throws {
        guard schemaVersion == 1,
              planSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              nodeCount >= 0,
              completedNodeCount >= 0,
              completedNodeCount <= nodeCount,
              !checkpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              operationID.map(HostwrightResourceUUID.isValid) ?? true,
              groupID.map(HostwrightResourceUUID.isValid) ?? true else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Unattended reconciliation returned an invalid versioned result."
            )
        }
        guard (status == .converged) == !runtimeMutationAttempted,
              nodeCount == 0 || operationID != nil,
              nodeCount == 0 || groupID != nil,
              nodeCount > 0 || operationID == nil,
              nodeCount > 0 || groupID == nil,
              status != .mutated || completedNodeCount == nodeCount,
              reasonCode == Self.reasonCode(for: status) else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Unattended reconciliation returned inconsistent convergence or lifecycle evidence."
            )
        }
        self.schemaVersion = schemaVersion
        self.status = status
        self.reasonCode = reasonCode
        self.planSHA256 = planSHA256
        self.nodeCount = nodeCount
        self.completedNodeCount = completedNodeCount
        self.runtimeMutationAttempted = runtimeMutationAttempted
        self.operationID = operationID?.lowercased()
        self.groupID = groupID?.lowercased()
        self.checkpoint = checkpoint
        self.recoveryHintRedacted = RuntimeRedactionPolicy.default.redact(
            recoveryHintRedacted
        )
    }

    private static func reasonCode(
        for status: DaemonReconciliationStatus
    ) -> DaemonReconciliationReasonCode {
        switch status {
        case .converged: .converged
        case .mutated: .mutationVerified
        case .compensated: .compensated
        case .interrupted: .interrupted
        case .safeHold: .safeHold
        }
    }
}

public protocol DaemonReconciliationDriving: Sendable {
    func reconcile(
        request: DaemonReconciliationRequest
    ) async throws -> DaemonReconciliationResult
}
