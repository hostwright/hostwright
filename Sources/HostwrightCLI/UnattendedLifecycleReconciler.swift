import CryptoKit
import Foundation
import HostwrightCore
import HostwrightDaemonCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

public struct SchedulerLifecycleReservationHandoff: Sendable {
    public let reservation: SchedulerReservationRecord
    public let preemptionIntent: SchedulerPreemptionIntentRecord?

    public init(
        reservation: SchedulerReservationRecord,
        preemptionIntent: SchedulerPreemptionIntentRecord? = nil
    ) throws {
        guard reservation.status == .pending,
              reservation.fencingToken.nodeEpoch >= 1,
              reservation.fencingToken.reservationSequence >= 1 else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "lifecycle-reservation-status"
            )
        }
        if let preemptionIntent {
            guard preemptionIntent.proposal.targetWorkloadID ==
                    reservation.workloadID,
                  preemptionIntent.projectID == reservation.projectUUID else {
                throw SchedulerAdmissionError.invalidBinding(
                    field: "lifecycle-preemption-binding"
                )
            }
        }
        self.reservation = reservation
        self.preemptionIntent = preemptionIntent
    }

    fileprivate func validate(
        manifest: HostwrightManifest,
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws {
        guard !options.dryRun,
              options.command == .up,
              preparation.projectResourceUUID == reservation.projectUUID,
              preparation.manifestSHA256 == reservation.lifecyclePlanDigest,
              compiled.plan.nodes.isEmpty == false else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "A scheduler reservation was not bound to the prepared lifecycle plan."
            )
        }
        guard let manifestProject = manifest.project,
              "project-\(manifestProject)" == preparation.projectID else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The scheduler reservation no longer matches the authoritative project lifecycle snapshot."
            )
        }
    }
}

public struct SchedulerLifecycleVictimHandoff: Sendable {
    public let intent: SchedulerPreemptionIntentRecord
    public let reservations: [SchedulerReservationRecord]

    public init(
        intent: SchedulerPreemptionIntentRecord,
        reservations: [SchedulerReservationRecord]
    ) throws {
        let ordered = reservations.sorted {
            $0.workloadID.uuidString.lowercased() <
                $1.workloadID.uuidString.lowercased()
        }
        guard !ordered.isEmpty,
              ordered.count == intent.proposal.victims.count,
              Set(ordered.map(\.workloadID)).count == ordered.count,
              Set(ordered.map(\.workloadID)) ==
                  Set(intent.proposal.victims.map(\.workloadID)),
              ordered.allSatisfy({
                  $0.status.reservesCapacity &&
                      $0.projectUUID == intent.projectID
              }),
              intent.proposal.victims.allSatisfy({ victim in
                  ordered.contains {
                      $0.workloadID == victim.workloadID &&
                          $0.nodeID == victim.nodeID &&
                          $0.resources == victim.allocation &&
                          $0.ownerSubjectID == victim.subjectID &&
                          $0.projectUUID == victim.projectID
                  }
              }) else {
            throw SchedulerAdmissionError.invalidBinding(
                field: "lifecycle-victim-binding"
            )
        }
        self.intent = intent
        self.reservations = ordered
    }

    fileprivate func validate(
        manifest: HostwrightManifest,
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws {
        guard !options.dryRun,
              options.command == .down,
              preparation.projectResourceUUID == intent.projectID,
              preparation.manifestSHA256 == reservations[0].lifecyclePlanDigest,
              compiled.plan.nodes.isEmpty == false else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Preemption victims were not bound to the prepared lifecycle plan."
            )
        }
        guard let manifestProject = manifest.project,
              reservations.allSatisfy({
                  $0.lifecyclePlanDigest == reservations[0].lifecyclePlanDigest
              }),
              "project-\(manifestProject)" == preparation.projectID else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Preemption victims no longer match the authoritative project lifecycle snapshot."
            )
        }
    }
}

private typealias SchedulerLifecycleAuthorityCheck = @Sendable (
    HostwrightManifest,
    LifecycleCompiledCommand,
    LifecycleCommandPreparation,
    LifecycleCLIOptions
) throws -> Void

public struct UnattendedLifecycleReconciler: DaemonReconciliationDriving {
    private let readManifest: @Sendable (String) throws -> String
    private let readConfiguration: @Sendable (
        String,
        DaemonConfigurationTargetKind,
        DaemonConfigurationTarget?
    ) throws -> DaemonConfigurationSnapshot
    private let makeDriver: @Sendable (
        LifecycleCLIOptions
    ) -> any LifecycleCommandDriving
    private let makeAuthorizedDriver: @Sendable (
        LifecycleCLIOptions,
        @escaping SchedulerLifecycleAuthorityCheck
    ) -> any LifecycleCommandDriving
    private let now: @Sendable () -> Date

    public init(environment: CLIEnvironment = .live) {
        self.readManifest = { path in
            try environment.readTextFile(path)
        }
        self.readConfiguration = SecureDaemonConfigurationReader.read
        self.makeDriver = { options in
            LifecycleLiveDriver(environment: environment, options: options)
        }
        self.makeAuthorizedDriver = { options, check in
            LifecycleLiveDriver(
                environment: environment,
                options: options,
                schedulerAuthorityValidator: check
            )
        }
        self.now = Date.init
    }

    init(
        readManifest: @escaping @Sendable (String) throws -> String,
        readConfiguration: (@Sendable (
            String,
            DaemonConfigurationTargetKind,
            DaemonConfigurationTarget?
        ) throws -> DaemonConfigurationSnapshot)? = nil,
        makeDriver: @escaping @Sendable (
            LifecycleCLIOptions
        ) -> any LifecycleCommandDriving,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.readManifest = readManifest
        self.readConfiguration = readConfiguration ?? { path, kind, expected in
            let text = try readManifest(path)
            let data = Data(text.utf8)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            let target = try DaemonConfigurationTarget(
                kind: kind,
                path: URL(fileURLWithPath: path).standardizedFileURL.path,
                contentSHA256: digest,
                byteCount: expected?.byteCount ?? data.count,
                device: expected?.device ?? 1,
                inode: expected?.inode ?? 1
            )
            if let expected, target != expected {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "A watched daemon configuration target changed after validation."
                )
            }
            return DaemonConfigurationSnapshot(target: target, text: text)
        }
        self.makeDriver = makeDriver
        self.makeAuthorizedDriver = { options, _ in makeDriver(options) }
        self.now = now
    }

    public func reconcile(
        request: DaemonReconciliationRequest
    ) async throws -> DaemonReconciliationResult {
        try await reconcile(
            request: request,
            command: .up,
            authorityCheck: nil
        )
    }

    public func executeAuthorizedSchedulerReservation(
        manifestPath: String,
        stateDatabasePath: String,
        reservation: SchedulerReservationRecord,
        preemptionIntent: SchedulerPreemptionIntentRecord?,
        maximumParallelism: Int
    ) async throws -> DaemonReconciliationResult {
        let handoff = try SchedulerLifecycleReservationHandoff(
            reservation: reservation,
            preemptionIntent: preemptionIntent
        )
        let request = try makeSchedulerRequest(
            manifestPath: manifestPath,
            stateDatabasePath: stateDatabasePath,
            workloadIDs: [reservation.workloadID],
            subjectID: reservation.ownerSubjectID,
            operationSeed: [
                "scheduler-up",
                reservation.decisionID.uuidString.lowercased(),
                reservation.reservationID.uuidString.lowercased(),
                reservation.fencingToken.stableKey,
            ].joined(separator: "|"),
            maximumParallelism: maximumParallelism
        )
        return try await reconcile(
            request: request,
            command: .up,
            authorityCheck: handoff.validate
        )
    }

    public func executeAuthorizedSchedulerVictims(
        manifestPath: String,
        stateDatabasePath: String,
        intent: SchedulerPreemptionIntentRecord,
        reservations: [SchedulerReservationRecord],
        maximumParallelism: Int
    ) async throws -> DaemonReconciliationResult {
        let handoff = try SchedulerLifecycleVictimHandoff(
            intent: intent,
            reservations: reservations
        )
        let request = try makeSchedulerRequest(
            manifestPath: manifestPath,
            stateDatabasePath: stateDatabasePath,
            workloadIDs: handoff.reservations.map(\.workloadID),
            subjectID: handoff.reservations[0].ownerSubjectID,
            operationSeed: [
                "scheduler-down",
                intent.intentID.uuidString.lowercased(),
                handoff.reservations.map {
                    "\($0.reservationID.uuidString.lowercased()):\($0.fencingToken.stableKey)"
                }.joined(separator: ","),
            ].joined(separator: "|"),
            maximumParallelism: maximumParallelism
        )
        return try await reconcile(
            request: request,
            command: .down,
            authorityCheck: handoff.validate
        )
    }

    private func reconcile(
        request: DaemonReconciliationRequest,
        command: LifecycleCommandKind,
        authorityCheck: SchedulerLifecycleAuthorityCheck?
    ) async throws -> DaemonReconciliationResult {
        try Task.checkCancellation()
        try requireExpectedConfiguration(request)

        let planningOptions = LifecycleCLIOptions(
            command: command,
            manifestPath: request.manifestPath,
            serviceNames: request.selectedServiceNames ?? [],
            stateDatabasePath: request.stateDatabasePath,
            confirmationPlanSHA256: nil,
            dryRun: true,
            parallelism: request.maximumParallelism,
            output: .json
        )
        let planningDriver: any LifecycleCommandDriving
        if let authorityCheck {
            planningDriver = makeAuthorizedDriver(planningOptions, authorityCheck)
        } else {
            planningDriver = makeDriver(planningOptions)
        }
        let compiler = LifecycleCommandPlanCompiler()
        let initialPreparation = try planningDriver.prepare(
            options: planningOptions
        )
        guard initialPreparation.projectID == request.projectID else {
            throw HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "The validated daemon project identity changed before lifecycle planning. No mutation was attempted."
            )
        }
        if request.selectedServiceNames?.isEmpty == true {
            return try DaemonReconciliationResult(
                status: .deferred,
                reasonCode: .restartBudgetDeferred,
                planSHA256: request.configurationSetSHA256,
                nodeCount: 0,
                completedNodeCount: 0,
                runtimeMutationAttempted: false,
                attemptedServiceNames: [],
                checkpoint: "restart-budget-deferred"
            )
        }
        let initialCompiled = try compiler.compile(
            options: planningOptions,
            preparation: initialPreparation
        )
        let preparation = try LifecycleImageLockBinder.bind(
            preparation: initialPreparation,
            initialCompiled: initialCompiled,
            options: planningOptions,
            resolve: planningDriver.localImageEvidence
        )
        let compiled = try compiler.compile(
            options: planningOptions,
            preparation: preparation
        )

        if compiled.plan.nodes.isEmpty {
            try Task.checkCancellation()
            try requireExpectedConfiguration(request)
            return try DaemonReconciliationResult(
                status: .converged,
                reasonCode: .converged,
                planSHA256: compiled.plan.planSHA256,
                nodeCount: 0,
                completedNodeCount: 0,
                runtimeMutationAttempted: false,
                attemptedServiceNames: [],
                checkpoint: "observed-converged"
            )
        }

        let executionOptions = LifecycleCLIOptions(
            command: command,
            manifestPath: request.manifestPath,
            serviceNames: request.selectedServiceNames ?? [],
            stateDatabasePath: request.stateDatabasePath,
            confirmationPlanSHA256: compiled.plan.planSHA256,
            dryRun: false,
            parallelism: request.maximumParallelism,
            output: .json,
            operationIdempotencyKeySHA256:
                request.operationIdempotencyKeySHA256
        )
        let executionDriver: any LifecycleCommandDriving
        if let authorityCheck {
            executionDriver = makeAuthorizedDriver(executionOptions, authorityCheck)
        } else {
            executionDriver = makeDriver(executionOptions)
        }
        try Task.checkCancellation()
        try requireExpectedConfiguration(request)
        try executionDriver.revalidate(
            compiled: compiled,
            preparation: preparation
        )
        try requireExpectedConfiguration(request)
        try requireMaintenanceAdmission(request)
        try Task.checkCancellation()
        let result: LifecycleSagaExecutionResult
        do {
            result = try executionDriver.execute(
                compiled: compiled,
                preparation: preparation,
                options: executionOptions
            )
        } catch {
            let groupID = HostwrightResourceUUID.legacy(
                kind: "lifecycle-group",
                identifier: request.operationIdempotencyKeySHA256 ??
                    compiled.plan.planSHA256
            )
            let store = SQLiteStateStore(path: request.stateDatabasePath)
            guard let group = try? store.operationGroups.load(id: groupID) else {
                throw error
            }
            let steps = (try? store.operationGroupSteps.load(groupID: groupID)) ?? []
            let planNodeKeys = Set(compiled.plan.nodes.map(\.key))
            let completedPlanNodeKeys = Set(
                steps.filter { $0.status == .succeeded }.map(\.stepKey)
            ).intersection(planNodeKeys)
            let attemptedServiceNames = attemptedMutationServiceNames(
                compiled: compiled,
                steps: steps,
                completedNodeKeys: completedPlanNodeKeys
            )
            return try DaemonReconciliationResult(
                status: .interrupted,
                reasonCode: .interrupted,
                planSHA256: compiled.plan.planSHA256,
                nodeCount: compiled.plan.nodes.count,
                completedNodeCount: completedPlanNodeKeys.count,
                runtimeMutationAttempted: !attemptedServiceNames.isEmpty,
                attemptedServiceNames: attemptedServiceNames,
                operationID: group.operationID,
                groupID: group.id,
                checkpoint: group.checkpoint,
                recoveryHintRedacted: group.manualRecoveryHintRedacted.isEmpty
                    ? "Inspect the exact durable lifecycle group before retry."
                    : group.manualRecoveryHintRedacted
            )
        }
        try Task.checkCancellation()

        let steps: [OperationGroupStepRecord]
        switch result.status {
        case .succeeded, .alreadySucceeded:
            steps = []
        case .compensated, .interrupted, .safeHold:
            let store = SQLiteStateStore(path: request.stateDatabasePath)
            steps = try store.operationGroupSteps.load(groupID: result.groupID)
        }
        let attemptedServiceNames = attemptedMutationServiceNames(
            compiled: compiled,
            steps: steps,
            completedNodeKeys: Set(result.completedNodeKeys)
        )
        let runtimeMutationAttempted = !attemptedServiceNames.isEmpty

        let status: DaemonReconciliationStatus
        let reason: DaemonReconciliationReasonCode
        switch result.status {
        case .succeeded, .alreadySucceeded:
            status = runtimeMutationAttempted ? .mutated : .converged
            reason = runtimeMutationAttempted ? .mutationVerified : .converged
        case .compensated:
            status = .compensated
            reason = .compensated
        case .interrupted:
            status = .interrupted
            reason = .interrupted
        case .safeHold:
            status = .safeHold
            reason = .safeHold
        }
        return try DaemonReconciliationResult(
            status: status,
            reasonCode: reason,
            planSHA256: result.planSHA256,
            nodeCount: compiled.plan.nodes.count,
            completedNodeCount: result.completedNodeKeys.count,
            runtimeMutationAttempted: runtimeMutationAttempted,
            attemptedServiceNames: attemptedServiceNames,
            operationID: result.operationID,
            groupID: result.groupID,
            checkpoint: result.checkpoint,
            recoveryHintRedacted: result.recoveryHintRedacted
        )
    }

    private func makeSchedulerRequest(
        manifestPath: String,
        stateDatabasePath: String,
        workloadIDs: [UUID],
        subjectID: String,
        operationSeed: String,
        maximumParallelism: Int
    ) throws -> DaemonReconciliationRequest {
        let normalizedManifestPath = URL(
            fileURLWithPath: manifestPath
        ).standardizedFileURL.path
        let manifestSnapshot = try readConfiguration(
            normalizedManifestPath,
            .manifest,
            nil
        )
        let manifest = try ManifestValidator.validated(manifestSnapshot.text)
        guard let projectName = manifest.project,
              !projectName.isEmpty else {
            throw HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "Scheduler lifecycle execution requires one authoritative manifest project."
            )
        }
        let projectID = "project-\(projectName)"
        let admissions = try ManifestSchedulerAdmissionBridge.map(
            manifest: manifest,
            subjectID: subjectID
        )
        let selected = admissions.filter {
            workloadIDs.contains($0.workloadID)
        }
        guard selected.count == workloadIDs.count,
              Set(selected.map(\.workloadID)) == Set(workloadIDs) else {
            throw HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "The scheduler workload is not present in the current manifest; no runtime mutation was attempted."
            )
        }
        let configurationTargets = try DaemonConfigurationTargetResolver.paths(
            manifestPath: normalizedManifestPath,
            manifest: manifest
        ).map { kind, path in
            if kind == .manifest && path == manifestSnapshot.target.path {
                return manifestSnapshot.target
            }
            return try readConfiguration(path, kind, nil).target
        }.sorted {
            ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path)
        }
        let operationKey = SHA256.hash(data: Data(operationSeed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try DaemonReconciliationRequest(
            manifestPath: normalizedManifestPath,
            manifestSHA256: try lifecycleManifestSHA256(
                text: manifestSnapshot.text,
                manifest: manifest
            ),
            configurationSetSHA256: DaemonConfigurationSetDigest.sha256(
                configurationTargets
            ),
            configurationTargets: configurationTargets,
            stateDatabasePath: stateDatabasePath,
            projectID: projectID,
            maximumParallelism: min(max(maximumParallelism, 1), 32),
            selectedServiceNames: selected.map(\.serviceName).sorted(),
            operationIdempotencyKeySHA256: operationKey
        )
    }

    private func attemptedMutationServiceNames(
        compiled: LifecycleCompiledCommand,
        steps: [OperationGroupStepRecord],
        completedNodeKeys: Set<String>
    ) -> [String] {
        let startedKeys = completedNodeKeys.union(steps.compactMap { step -> String? in
            step.direction == .forward && step.status == .started
                ? step.stepKey
                : nil
        })
        return Set(compiled.plan.nodes.compactMap { node -> String? in
            guard startedKeys.contains(node.key), node.action.mutatesRuntime else {
                return nil
            }
            return compiled.desiredServicesByNodeKey[node.key]?.logicalServiceName
                ?? node.serviceName
        }).sorted()
    }

    private func requireExpectedConfiguration(
        _ request: DaemonReconciliationRequest
    ) throws {
        for target in request.configurationTargets {
            do {
                let snapshot = try readConfiguration(target.path, target.kind, target)
                guard snapshot.target == target else {
                    throw HostwrightDiagnostic(
                        code: .confirmationMismatch,
                        message: "A watched daemon configuration target changed after validation."
                    )
                }
            } catch {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "A watched daemon configuration target changed during unattended reconciliation. A fresh level-triggered iteration is required; no stale plan was admitted."
                )
            }
        }
    }

    private func requireMaintenanceAdmission(
        _ request: DaemonReconciliationRequest
    ) throws {
        guard let admission = request.maintenanceAdmission else { return }
        let manifestText = try readManifest(request.manifestPath)
        let manifest = try ManifestValidator.validated(manifestText)
        guard let policy = manifest.maintenance,
              MaintenanceWindowEvaluator.policySHA256(policy) == admission.policySHA256 else {
            throw HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "The maintenance policy changed before lifecycle execution. No stale admission was used."
            )
        }
        let store = SQLiteStateStore(path: request.stateDatabasePath)
        if admission.reason == MaintenanceAdmissionReason.safetyRecovery.rawValue {
            guard try store.operationGroups.loadAll().contains(where: {
                $0.projectID == request.projectID && $0.status == .active
            }) else {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "The exact durable recovery group is no longer active. A fresh maintenance decision is required."
                )
            }
            return
        }
        let latest = try store.maintenanceDeferrals.latest(projectID: request.projectID)
        if admission.reason == MaintenanceAdmissionReason.emergencyOverride.rawValue {
            guard let latest,
                  latest.state == .overrideAuthorized,
                  latest.confirmationToken == admission.confirmationToken,
                  latest.planSHA256 == admission.reconciliationPlanSHA256,
                  latest.policySHA256 == admission.policySHA256,
                  latest.actionClasses.map(\.rawValue) == admission.actionClasses else {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "The exact emergency maintenance override is absent, cancelled, consumed, or stale. No mutation was attempted."
                )
            }
            let decision = MaintenanceWindowEvaluator.evaluate(
                policy: policy,
                actions: latest.actionClasses,
                now: now(),
                deferredAt: ISO8601DateFormatter().date(from: latest.firstDeferredAt),
                emergencyOverrideAuthorized: true
            )
            guard decision.admitted, decision.reason == .emergencyOverride else {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "The emergency maintenance override reached its hard deferral deadline. A stale plan was not executed."
                )
            }
            return
        }
        guard admission.reason == MaintenanceAdmissionReason.activeWindow.rawValue,
              let startsAt = admission.windowStartsAt,
              let endsAt = admission.windowEndsAt,
              let start = ISO8601DateFormatter().date(from: startsAt),
              let end = ISO8601DateFormatter().date(from: endsAt) else {
            throw HostwrightDiagnostic(code: .confirmationMismatch, message: "Maintenance admission is incomplete.")
        }
        let actionClasses = admission.actionClasses.compactMap(
            HostwrightMaintenanceActionClass.init(rawValue:)
        )
        guard actionClasses.count == admission.actionClasses.count else {
            throw HostwrightDiagnostic(code: .confirmationMismatch, message: "Maintenance admission actions are invalid.")
        }
        let pending = admission.confirmationToken.flatMap { token in
            latest?.confirmationToken == token ? latest : nil
        }
        let instant = now()
        let decision = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: actionClasses,
            now: instant,
            deferredAt: pending.flatMap { ISO8601DateFormatter().date(from: $0.firstDeferredAt) },
            cancelled: pending?.state == .cancelled
        )
        guard instant >= start, instant < end,
              decision.admitted,
              decision.reason == .activeWindow,
              decision.activeWindow?.windowID == admission.windowID,
              decision.activeWindow?.startsAt == startsAt,
              decision.activeWindow?.endsAt == endsAt else {
            throw HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "The admitted maintenance window closed, expired, or changed before the runtime effect boundary. No mutation was attempted."
            )
        }
        if let token = admission.confirmationToken {
            guard let latest,
                  latest.confirmationToken == token,
                  latest.state == .deferred,
                  latest.planSHA256 == admission.reconciliationPlanSHA256,
                  latest.policySHA256 == admission.policySHA256,
                  latest.actionClasses.map(\.rawValue) == admission.actionClasses else {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "The pending maintenance plan was cancelled, superseded, or changed before execution."
                )
            }
        }
    }
}
