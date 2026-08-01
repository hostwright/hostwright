import CryptoKit
import Foundation
import HostwrightCore
import HostwrightDaemonCore
import HostwrightReconciler

public struct UnattendedLifecycleReconciler: DaemonReconciliationDriving {
    private let readManifest: @Sendable (String) throws -> String
    private let makeDriver: @Sendable (
        LifecycleCLIOptions
    ) -> any LifecycleCommandDriving

    public init(environment: CLIEnvironment = .live) {
        self.readManifest = { path in
            try environment.readTextFile(path)
        }
        self.makeDriver = { options in
            LifecycleLiveDriver(environment: environment, options: options)
        }
    }

    init(
        readManifest: @escaping @Sendable (String) throws -> String,
        makeDriver: @escaping @Sendable (
            LifecycleCLIOptions
        ) -> any LifecycleCommandDriving
    ) {
        self.readManifest = readManifest
        self.makeDriver = makeDriver
    }

    public func reconcile(
        request: DaemonReconciliationRequest
    ) async throws -> DaemonReconciliationResult {
        try Task.checkCancellation()
        try requireExpectedManifest(request)

        let planningOptions = LifecycleCLIOptions(
            command: .up,
            manifestPath: request.manifestPath,
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
            try requireExpectedManifest(request)
            return try DaemonReconciliationResult(
                status: .converged,
                reasonCode: .converged,
                planSHA256: compiled.plan.planSHA256,
                nodeCount: 0,
                completedNodeCount: 0,
                runtimeMutationAttempted: false,
                checkpoint: "observed-converged"
            )
        }

        let executionOptions = LifecycleCLIOptions(
            command: .up,
            manifestPath: request.manifestPath,
            stateDatabasePath: request.stateDatabasePath,
            confirmationPlanSHA256: compiled.plan.planSHA256,
            dryRun: false,
            parallelism: request.maximumParallelism,
            output: .json
        )
        let executionDriver = makeDriver(executionOptions)
        try Task.checkCancellation()
        try requireExpectedManifest(request)
        try executionDriver.revalidate(
            compiled: compiled,
            preparation: preparation
        )
        try requireExpectedManifest(request)
        try Task.checkCancellation()
        let result = try executionDriver.execute(
            compiled: compiled,
            preparation: preparation,
            options: executionOptions
        )
        try Task.checkCancellation()

        let mutatesRuntime = compiled.plan.nodes.contains {
            $0.action.mutatesRuntime
        }
        let status: DaemonReconciliationStatus
        let reason: DaemonReconciliationReasonCode
        switch result.status {
        case .succeeded, .alreadySucceeded:
            status = mutatesRuntime ? .mutated : .converged
            reason = mutatesRuntime ? .mutationVerified : .converged
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
            runtimeMutationAttempted: mutatesRuntime,
            operationID: result.operationID,
            groupID: result.groupID,
            checkpoint: result.checkpoint,
            recoveryHintRedacted: result.recoveryHintRedacted
        )
    }

    private func requireExpectedManifest(
        _ request: DaemonReconciliationRequest
    ) throws {
        let text = try readManifest(request.manifestPath)
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == request.manifestSHA256 else {
            throw HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "The daemon manifest bytes changed during unattended reconciliation. A fresh level-triggered iteration is required; no stale plan was admitted."
            )
        }
    }
}
