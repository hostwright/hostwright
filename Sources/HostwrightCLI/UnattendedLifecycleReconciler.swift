import CryptoKit
import Foundation
import HostwrightCore
import HostwrightDaemonCore
import HostwrightReconciler
import HostwrightState

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

    public init(environment: CLIEnvironment = .live) {
        self.readManifest = { path in
            try environment.readTextFile(path)
        }
        self.readConfiguration = SecureDaemonConfigurationReader.read
        self.makeDriver = { options in
            LifecycleLiveDriver(environment: environment, options: options)
        }
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
        ) -> any LifecycleCommandDriving
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
    }

    public func reconcile(
        request: DaemonReconciliationRequest
    ) async throws -> DaemonReconciliationResult {
        try Task.checkCancellation()
        try requireExpectedConfiguration(request)

        let planningOptions = LifecycleCLIOptions(
            command: .up,
            manifestPath: request.manifestPath,
            serviceNames: request.selectedServiceNames ?? [],
            stateDatabasePath: request.stateDatabasePath,
            confirmationPlanSHA256: nil,
            dryRun: true,
            parallelism: request.maximumParallelism,
            output: .json
        )
        let planningDriver = makeDriver(planningOptions)
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
            command: .up,
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
        let executionDriver = makeDriver(executionOptions)
        try Task.checkCancellation()
        try requireExpectedConfiguration(request)
        try executionDriver.revalidate(
            compiled: compiled,
            preparation: preparation
        )
        try requireExpectedConfiguration(request)
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
}
