import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

public enum DaemonReconciliationStatus: String, Codable, Equatable, Sendable {
    case converged
    case deferred
    case mutated
    case compensated
    case interrupted
    case safeHold = "safe-hold"

    public var isSuccessfulIteration: Bool {
        self == .converged || self == .deferred || self == .mutated
    }
}

public enum DaemonReconciliationReasonCode: String, Codable, Equatable, Sendable {
    case converged = "daemon.reconcile.converged"
    case restartBudgetDeferred = "daemon.reconcile.restart-budget-deferred"
    case maintenanceDeferred = "daemon.reconcile.maintenance-deferred"
    case maintenanceDeadlineExpired = "daemon.reconcile.maintenance-deadline-expired"
    case maintenanceCancelled = "daemon.reconcile.maintenance-cancelled"
    case mutationVerified = "daemon.reconcile.mutated"
    case compensated = "daemon.reconcile.compensated"
    case interrupted = "daemon.reconcile.interrupted"
    case safeHold = "daemon.reconcile.safe-hold"
}

public struct DaemonMaintenanceAdmission: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let reconciliationPlanSHA256: String
    public let policySHA256: String
    public let actionClasses: [String]
    public let reason: String
    public let confirmationToken: String?
    public let windowID: String?
    public let windowStartsAt: String?
    public let windowEndsAt: String?

    public init(
        schemaVersion: Int = 1,
        reconciliationPlanSHA256: String,
        policySHA256: String,
        actionClasses: [String],
        reason: String,
        confirmationToken: String?,
        windowID: String?,
        windowStartsAt: String?,
        windowEndsAt: String?
    ) throws {
        let normalizedActions = actionClasses.sorted()
        let permittedReasons = ["active-window", "emergency-override", "safety-recovery"]
        let electiveActions = Set(["create", "start", "restart", "update", "remove"])
        guard schemaVersion == 1,
              Self.isSHA256(reconciliationPlanSHA256),
              Self.isSHA256(policySHA256),
              !normalizedActions.isEmpty,
              normalizedActions == actionClasses,
              Set(normalizedActions).count == normalizedActions.count,
              normalizedActions.allSatisfy({ ["create", "start", "restart", "update", "remove", "recovery", "security-stop"].contains($0) }),
              permittedReasons.contains(reason),
              confirmationToken.map(Self.isSHA256) ?? true,
              windowID.map({ $0.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil }) ?? true,
              (windowStartsAt == nil) == (windowEndsAt == nil),
              (reason == "active-window") == (windowID != nil),
              (reason == "active-window") == (windowStartsAt != nil),
              reason != "emergency-override" || confirmationToken != nil,
              reason == "safety-recovery"
                ? normalizedActions == ["recovery"] && confirmationToken == nil
                : normalizedActions.allSatisfy(electiveActions.contains) else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Daemon maintenance admission binding is invalid or incomplete."
            )
        }
        if let windowStartsAt, let windowEndsAt {
            let formatter = ISO8601DateFormatter()
            guard let start = formatter.date(from: windowStartsAt),
                  let end = formatter.date(from: windowEndsAt),
                  formatter.string(from: start) == windowStartsAt,
                  formatter.string(from: end) == windowEndsAt,
                  start < end else {
                throw HostwrightDiagnostic(code: .daemonInvalid, message: "Daemon maintenance window bounds are invalid.")
            }
        }
        self.schemaVersion = schemaVersion
        self.reconciliationPlanSHA256 = reconciliationPlanSHA256
        self.policySHA256 = policySHA256
        self.actionClasses = normalizedActions
        self.reason = reason
        self.confirmationToken = confirmationToken
        self.windowID = windowID
        self.windowStartsAt = windowStartsAt
        self.windowEndsAt = windowEndsAt
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

public struct DaemonReconciliationRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let manifestPath: String
    public let manifestSHA256: String
    public let configurationSetSHA256: String
    public let configurationTargets: [DaemonConfigurationTarget]
    public let stateDatabasePath: String
    public let projectID: String
    public let maximumParallelism: Int
    public let selectedServiceNames: [String]?
    public let operationIdempotencyKeySHA256: String?
    public let maintenanceAdmission: DaemonMaintenanceAdmission?
    public let schedulerAuthorityBinding: DaemonSchedulerAuthorityBinding?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case manifestPath
        case manifestSHA256
        case configurationSetSHA256
        case configurationTargets
        case stateDatabasePath
        case projectID
        case maximumParallelism
        case selectedServiceNames
        case operationIdempotencyKeySHA256
        case maintenanceAdmission
        case schedulerAuthorityBinding
    }

    public init(
        schemaVersion: Int = 1,
        manifestPath: String,
        manifestSHA256: String,
        configurationSetSHA256: String,
        configurationTargets: [DaemonConfigurationTarget],
        stateDatabasePath: String,
        projectID: String,
        maximumParallelism: Int,
        operationIdempotencyKeySHA256: String? = nil,
        schedulerAuthorityBinding: DaemonSchedulerAuthorityBinding? = nil
    ) throws {
        try self.init(
            schemaVersion: schemaVersion,
            manifestPath: manifestPath,
            manifestSHA256: manifestSHA256,
            configurationSetSHA256: configurationSetSHA256,
            configurationTargets: configurationTargets,
            stateDatabasePath: stateDatabasePath,
            projectID: projectID,
            maximumParallelism: maximumParallelism,
            selectedServiceNames: nil,
            operationIdempotencyKeySHA256: operationIdempotencyKeySHA256,
            schedulerAuthorityBinding: schedulerAuthorityBinding
        )
    }

    public init(
        schemaVersion: Int = 1,
        manifestPath: String,
        manifestSHA256: String,
        configurationSetSHA256: String,
        configurationTargets: [DaemonConfigurationTarget],
        stateDatabasePath: String,
        projectID: String,
        maximumParallelism: Int,
        selectedServiceNames: [String]?,
        operationIdempotencyKeySHA256: String? = nil,
        maintenanceAdmission: DaemonMaintenanceAdmission? = nil,
        schedulerAuthorityBinding: DaemonSchedulerAuthorityBinding? = nil
    ) throws {
        guard schemaVersion == 1,
              !manifestPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifestSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              configurationSetSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              !configurationTargets.isEmpty,
              configurationTargets == configurationTargets.sorted(by: {
                  ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path)
              }),
              Set(configurationTargets.map(\.path)).count == configurationTargets.count,
              configurationTargets.first(where: {
                  $0.kind == .manifest && $0.path == manifestPath &&
                      $0.contentSHA256 == manifestSHA256
              }) != nil,
              DaemonConfigurationSetDigest.sha256(configurationTargets) == configurationSetSHA256,
              !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              projectID.range(
                  of: "^project-[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$",
                  options: .regularExpression
              ) != nil,
              (1...32).contains(maximumParallelism),
              selectedServiceNames.map({ names in
                  names == names.sorted() && Set(names).count == names.count &&
                      names.allSatisfy {
                          $0.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil
                      }
              }) ?? true,
              operationIdempotencyKeySHA256.map({ digest in
                  digest.range(
                      of: "^[a-f0-9]{64}$",
                      options: .regularExpression
                  ) != nil
              }) ?? true,
              schedulerAuthorityBinding.map({ binding in
                  binding.reservations.allSatisfy {
                      $0.configDigest == manifestSHA256 &&
                          $0.lifecyclePlanDigest == manifestSHA256
                  }
              }) ?? true else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Unattended reconciliation requires schema v1, exact paths and digest, one bounded project identity, and parallelism from 1 through 32."
            )
        }
        self.schemaVersion = schemaVersion
        self.manifestPath = manifestPath
        self.manifestSHA256 = manifestSHA256
        self.configurationSetSHA256 = configurationSetSHA256
        self.configurationTargets = configurationTargets
        self.stateDatabasePath = stateDatabasePath
        self.projectID = projectID
        self.maximumParallelism = maximumParallelism
        self.selectedServiceNames = selectedServiceNames
        self.operationIdempotencyKeySHA256 = operationIdempotencyKeySHA256
        self.maintenanceAdmission = maintenanceAdmission
        self.schedulerAuthorityBinding = schedulerAuthorityBinding
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            manifestPath: values.decode(String.self, forKey: .manifestPath),
            manifestSHA256: values.decode(String.self, forKey: .manifestSHA256),
            configurationSetSHA256: values.decode(
                String.self,
                forKey: .configurationSetSHA256
            ),
            configurationTargets: values.decode(
                [DaemonConfigurationTarget].self,
                forKey: .configurationTargets
            ),
            stateDatabasePath: values.decode(
                String.self,
                forKey: .stateDatabasePath
            ),
            projectID: values.decode(String.self, forKey: .projectID),
            maximumParallelism: values.decode(
                Int.self,
                forKey: .maximumParallelism
            ),
            selectedServiceNames: values.decodeIfPresent(
                [String].self,
                forKey: .selectedServiceNames
            ),
            operationIdempotencyKeySHA256: values.decodeIfPresent(
                String.self,
                forKey: .operationIdempotencyKeySHA256
            ),
            maintenanceAdmission: values.decodeIfPresent(
                DaemonMaintenanceAdmission.self,
                forKey: .maintenanceAdmission
            ),
            schedulerAuthorityBinding: values.decodeIfPresent(
                DaemonSchedulerAuthorityBinding.self,
                forKey: .schedulerAuthorityBinding
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(manifestPath, forKey: .manifestPath)
        try values.encode(manifestSHA256, forKey: .manifestSHA256)
        try values.encode(configurationSetSHA256, forKey: .configurationSetSHA256)
        try values.encode(configurationTargets, forKey: .configurationTargets)
        try values.encode(stateDatabasePath, forKey: .stateDatabasePath)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(maximumParallelism, forKey: .maximumParallelism)
        try values.encodeIfPresent(selectedServiceNames, forKey: .selectedServiceNames)
        try values.encodeIfPresent(
            operationIdempotencyKeySHA256,
            forKey: .operationIdempotencyKeySHA256
        )
        try values.encodeIfPresent(maintenanceAdmission, forKey: .maintenanceAdmission)
        try values.encodeIfPresent(
            schedulerAuthorityBinding,
            forKey: .schedulerAuthorityBinding
        )
    }

    init(
        schemaVersion: Int = 1,
        manifestPath: String,
        manifestSHA256: String,
        stateDatabasePath: String,
        projectID: String,
        maximumParallelism: Int,
        operationIdempotencyKeySHA256: String? = nil
    ) throws {
        let normalizedPath = URL(fileURLWithPath: manifestPath).standardizedFileURL.path
        let target = try DaemonConfigurationTarget(
            kind: .manifest,
            path: normalizedPath,
            contentSHA256: manifestSHA256,
            byteCount: 0,
            device: 1,
            inode: 1
        )
        try self.init(
            schemaVersion: schemaVersion,
            manifestPath: normalizedPath,
            manifestSHA256: manifestSHA256,
            configurationSetSHA256: DaemonConfigurationSetDigest.sha256([target]),
            configurationTargets: [target],
            stateDatabasePath: stateDatabasePath,
            projectID: projectID,
            maximumParallelism: maximumParallelism,
            selectedServiceNames: nil,
            operationIdempotencyKeySHA256: operationIdempotencyKeySHA256
        )
    }
}

public struct DaemonSchedulerAuthorityBinding: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let projectResourceUUID: String
    public let reservations: [SchedulerReservationRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectResourceUUID
        case reservations
    }

    public init(
        schemaVersion: Int = 1,
        projectResourceUUID: String,
        reservations: [SchedulerReservationRecord]
    ) throws {
        let orderedReservations = reservations.sorted {
            $0.workloadID.uuidString.lowercased() <
                $1.workloadID.uuidString.lowercased()
        }
        guard schemaVersion == 1,
              HostwrightResourceUUID.isValid(projectResourceUUID),
              !orderedReservations.isEmpty,
              orderedReservations == reservations,
              Set(orderedReservations.map(\.workloadID)).count == orderedReservations.count,
              Set(orderedReservations.map(\.reservationID)).count == orderedReservations.count,
              orderedReservations.allSatisfy({
                  $0.projectUUID == projectResourceUUID.lowercased() &&
                      $0.status == .committed &&
                      Self.isSHA256($0.capacityDigest) &&
                      Self.isSHA256($0.inputDigest) &&
                      Self.isSHA256($0.configDigest) &&
                      Self.isSHA256($0.profileDigest) &&
                      Self.isSHA256($0.lifecyclePlanDigest) &&
                      !$0.ownerSubjectID.isEmpty &&
                      $0.ownerSubjectID == $0.ownerSubjectID.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ) &&
                      $0.fencingToken.nodeEpoch >= 1 &&
                      $0.fencingToken.reservationSequence >= 1
              }) else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Daemon scheduler authority binding is invalid or incomplete."
            )
        }
        self.schemaVersion = schemaVersion
        self.projectResourceUUID = projectResourceUUID.lowercased()
        self.reservations = orderedReservations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            projectResourceUUID: values.decode(
                String.self,
                forKey: .projectResourceUUID
            ),
            reservations: values.decode(
                [SchedulerReservationRecord].self,
                forKey: .reservations
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(projectResourceUUID, forKey: .projectResourceUUID)
        try values.encode(reservations, forKey: .reservations)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
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
    public let attemptedServiceNames: [String]?
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
        attemptedServiceNames: [String]? = nil,
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
              attemptedServiceNames.map({ names in
                  names == names.sorted() && Set(names).count == names.count &&
                      names.allSatisfy {
                          $0.range(
                              of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$",
                              options: .regularExpression
                          ) != nil
                      }
              }) ?? true,
              runtimeMutationAttempted == (attemptedServiceNames?.isEmpty == false),
              operationID.map(HostwrightResourceUUID.isValid) ?? true,
              groupID.map(HostwrightResourceUUID.isValid) ?? true else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "Unattended reconciliation returned an invalid versioned result."
            )
        }
        guard (!(status == .converged || status == .deferred) || !runtimeMutationAttempted),
              nodeCount == 0 || operationID != nil,
              nodeCount == 0 || groupID != nil,
              nodeCount > 0 || operationID == nil,
              nodeCount > 0 || groupID == nil,
              status != .mutated || runtimeMutationAttempted,
              status != .mutated || completedNodeCount == nodeCount,
              Self.reasonCode(reasonCode, isValidFor: status) else {
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
        self.attemptedServiceNames = attemptedServiceNames
        self.operationID = operationID?.lowercased()
        self.groupID = groupID?.lowercased()
        self.checkpoint = checkpoint
        self.recoveryHintRedacted = RuntimeRedactionPolicy.default.redact(
            recoveryHintRedacted
        )
    }

    private static func reasonCode(
        _ reason: DaemonReconciliationReasonCode,
        isValidFor status: DaemonReconciliationStatus
    ) -> Bool {
        switch status {
        case .converged: reason == .converged
        case .deferred:
            [.restartBudgetDeferred, .maintenanceDeferred, .maintenanceDeadlineExpired, .maintenanceCancelled].contains(reason)
        case .mutated: reason == .mutationVerified
        case .compensated: reason == .compensated
        case .interrupted: reason == .interrupted
        case .safeHold: reason == .safeHold
        }
    }
}

public protocol DaemonReconciliationDriving: Sendable {
    func reconcile(
        request: DaemonReconciliationRequest
    ) async throws -> DaemonReconciliationResult

    func reconcileAuthorized(
        request: DaemonReconciliationRequest,
        schedulerAuthorityBinding: DaemonSchedulerAuthorityBinding
    ) async throws -> DaemonReconciliationResult
}

public extension DaemonReconciliationDriving {
    func reconcileAuthorized(
        request: DaemonReconciliationRequest,
        schedulerAuthorityBinding: DaemonSchedulerAuthorityBinding
    ) async throws -> DaemonReconciliationResult {
        throw HostwrightDiagnostic(
            code: .unsafeExposure,
            message: "scheduler-authority-unavailable: this reconciliation driver cannot consume the exact daemon scheduler authority binding. No runtime mutation was attempted."
        )
    }
}
