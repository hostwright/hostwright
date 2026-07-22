import CryptoKit
import Foundation
import HostwrightCore

public enum RuntimeProviderMigrationCheckpoint: Int, Codable, CaseIterable, Comparable, Sendable {
    case intentPersisted
    case sourceQuiesced
    case sourceVerified
    case targetCreated
    case targetVerified
    case targetRunningRestored
    case bindingCommitted
    case sourceRetired

    public static func < (
        lhs: RuntimeProviderMigrationCheckpoint,
        rhs: RuntimeProviderMigrationCheckpoint
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum RuntimeProviderMigrationEffectKind: String, Codable, Sendable {
    case quiesceSource = "quiesce-source"
    case createTarget = "create-target"
    case restoreTargetRunningState = "restore-target-running-state"
    case commitProviderBinding = "commit-provider-binding"
    case retireSource = "retire-source"
}

public struct RuntimeProviderMigrationEffect: Codable, Equatable, Sendable {
    public let kind: RuntimeProviderMigrationEffectKind
    public let providerID: RuntimeProviderID
    public let resourceUUID: String?

    public init(
        kind: RuntimeProviderMigrationEffectKind,
        providerID: RuntimeProviderID,
        resourceUUID: String? = nil
    ) {
        self.kind = kind
        self.providerID = providerID
        self.resourceUUID = resourceUUID
    }
}

public enum RuntimeProviderMigrationRollbackKind: String, Codable, Sendable {
    case removeVerifiedTarget = "remove-verified-target"
    case restoreSourceRunningState = "restore-source-running-state"
}

public struct RuntimeProviderMigrationRollbackAction: Codable, Equatable, Sendable {
    public let kind: RuntimeProviderMigrationRollbackKind
    public let providerID: RuntimeProviderID
    public let resourceUUID: String

    public init(
        kind: RuntimeProviderMigrationRollbackKind,
        providerID: RuntimeProviderID,
        resourceUUID: String
    ) {
        self.kind = kind
        self.providerID = providerID
        self.resourceUUID = resourceUUID
    }
}

public struct RuntimeProviderMigrationImageRequirement: Codable, Equatable, Sendable {
    public let reference: String
    public let descriptorDigest: String
    public let variantDigest: String
    public let architecture: String
    public let operatingSystem: String

    public init(evidence: RuntimeLocalImageEvidence) {
        self.reference = evidence.reference
        self.descriptorDigest = evidence.descriptorDigest
        self.variantDigest = evidence.variantDigest
        self.architecture = evidence.architecture
        self.operatingSystem = evidence.operatingSystem
    }
}

public struct RuntimeProviderMigrationResource: Equatable, Sendable {
    public let desiredService: DesiredRuntimeService
    public let ownership: RuntimeInventoryOwnershipEvidence

    public init(
        desiredService: DesiredRuntimeService,
        ownership: RuntimeInventoryOwnershipEvidence
    ) {
        self.desiredService = desiredService
        self.ownership = ownership
    }
}

public struct RuntimeProviderMigrationRequest: Equatable, Sendable {
    public let projectName: String
    public let projectUUID: String
    public let projectGeneration: Int
    public let sourceProviderID: RuntimeProviderID
    public let sourceProviderGeneration: Int
    public let targetProviderID: RuntimeProviderID
    public let resources: [RuntimeProviderMigrationResource]
    public let activeOperationIDs: [String]
    public let expectedSourceCapabilitySHA256: String?
    public let expectedTargetCapabilitySHA256: String?

    public init(
        projectName: String,
        projectUUID: String,
        projectGeneration: Int,
        sourceProviderID: RuntimeProviderID,
        sourceProviderGeneration: Int,
        targetProviderID: RuntimeProviderID,
        resources: [RuntimeProviderMigrationResource],
        activeOperationIDs: [String] = [],
        expectedSourceCapabilitySHA256: String? = nil,
        expectedTargetCapabilitySHA256: String? = nil
    ) {
        self.projectName = projectName
        self.projectUUID = projectUUID
        self.projectGeneration = projectGeneration
        self.sourceProviderID = sourceProviderID
        self.sourceProviderGeneration = sourceProviderGeneration
        self.targetProviderID = targetProviderID
        self.resources = resources
        self.activeOperationIDs = activeOperationIDs.sorted()
        self.expectedSourceCapabilitySHA256 = expectedSourceCapabilitySHA256
        self.expectedTargetCapabilitySHA256 = expectedTargetCapabilitySHA256
    }
}

public struct RuntimeProviderMigrationResourcePlan: Codable, Equatable, Sendable {
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let sourceFencingToken: String
    public let identity: String
    public let resourceIdentifier: String
    public let sourceRuntimeID: String
    public let imageReference: String
    public let wasRunning: Bool
    public let desiredSpecificationSHA256: String
}

public struct RuntimeProviderMigrationPlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let confirmationPrefix = "hostwright-migrate-v1:"

    public let schemaVersion: Int
    public let projectName: String
    public let projectUUID: String
    public let projectGeneration: Int
    public let sourceProviderID: RuntimeProviderID
    public let sourceProviderGeneration: Int
    public let targetProviderID: RuntimeProviderID
    public let targetProviderGeneration: Int
    public let sourceCapabilitySHA256: String
    public let targetCapabilitySHA256: String
    public let sourceObservationSHA256: String
    public let targetObservationSHA256: String
    public let targetDescriptor: RuntimeProviderDescriptor
    public let resources: [RuntimeProviderMigrationResourcePlan]
    public let requiredLocalImages: [RuntimeProviderMigrationImageRequirement]
    public let plannedEffects: [RuntimeProviderMigrationEffect]
    public let rollbackActions: [RuntimeProviderMigrationRollbackAction]
    public let confirmationToken: String

    fileprivate init(
        projectName: String,
        projectUUID: String,
        projectGeneration: Int,
        sourceProviderID: RuntimeProviderID,
        sourceProviderGeneration: Int,
        targetProviderID: RuntimeProviderID,
        sourceCapabilitySHA256: String,
        targetCapabilitySHA256: String,
        sourceObservationSHA256: String,
        targetObservationSHA256: String,
        targetDescriptor: RuntimeProviderDescriptor,
        resources: [RuntimeProviderMigrationResourcePlan],
        requiredLocalImages: [RuntimeProviderMigrationImageRequirement],
        plannedEffects: [RuntimeProviderMigrationEffect],
        rollbackActions: [RuntimeProviderMigrationRollbackAction],
        confirmationToken: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projectName = projectName
        self.projectUUID = projectUUID
        self.projectGeneration = projectGeneration
        self.sourceProviderID = sourceProviderID
        self.sourceProviderGeneration = sourceProviderGeneration
        self.targetProviderID = targetProviderID
        self.targetProviderGeneration = sourceProviderGeneration + 1
        self.sourceCapabilitySHA256 = sourceCapabilitySHA256
        self.targetCapabilitySHA256 = targetCapabilitySHA256
        self.sourceObservationSHA256 = sourceObservationSHA256
        self.targetObservationSHA256 = targetObservationSHA256
        self.targetDescriptor = targetDescriptor
        self.resources = resources
        self.requiredLocalImages = requiredLocalImages
        self.plannedEffects = plannedEffects
        self.rollbackActions = rollbackActions
        self.confirmationToken = confirmationToken
    }
}

public struct RuntimeProviderMigrationIntent: Equatable, Sendable {
    public let operationID: String
    public let fencingToken: String
    public let confirmationToken: String
    public let projectUUID: String
    public let projectGeneration: Int
    public let sourceProviderID: RuntimeProviderID
    public let sourceProviderGeneration: Int
    public let targetProviderID: RuntimeProviderID
    public let targetProviderGeneration: Int
}

public struct RuntimeProviderMigrationLease: Equatable, Sendable {
    public let operationID: String
    public let fencingToken: String
    public let confirmationToken: String
    public let checkpoint: RuntimeProviderMigrationCheckpoint

    public init(
        operationID: String,
        fencingToken: String,
        confirmationToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) {
        self.operationID = operationID
        self.fencingToken = fencingToken
        self.confirmationToken = confirmationToken
        self.checkpoint = checkpoint
    }
}

public enum RuntimeProviderMigrationAcquireResult: Equatable, Sendable {
    case acquired(RuntimeProviderMigrationLease)
    case resumed(RuntimeProviderMigrationLease)
    case conflict(activeOperationID: String)
}

public struct RuntimeProviderMigrationBindingCommit: Equatable, Sendable {
    public let operationID: String
    public let fencingToken: String
    public let projectUUID: String
    public let projectGeneration: Int
    public let expectedSourceProviderID: RuntimeProviderID
    public let expectedSourceProviderGeneration: Int
    public let targetProviderID: RuntimeProviderID
    public let targetProviderGeneration: Int
    public let confirmationToken: String
}

public enum RuntimeProviderMigrationBindingCommitResult: Equatable, Sendable {
    case committed
    case alreadyCommitted
}

public enum RuntimeProviderMigrationTerminalStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public protocol RuntimeProviderMigrationJournaling: Sendable {
    func beginOrResume(
        _ intent: RuntimeProviderMigrationIntent
    ) async throws -> RuntimeProviderMigrationAcquireResult

    func verifyFence(operationID: String, fencingToken: String) async throws -> Bool

    func recordCheckpoint(
        operationID: String,
        fencingToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws

    func commitProviderBinding(
        _ commit: RuntimeProviderMigrationBindingCommit
    ) async throws -> RuntimeProviderMigrationBindingCommitResult

    func finish(
        operationID: String,
        fencingToken: String,
        status: RuntimeProviderMigrationTerminalStatus,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws
}

public struct RuntimeProviderMigrationResult: Equatable, Sendable {
    public let operationID: String
    public let projectUUID: String
    public let providerID: RuntimeProviderID
    public let providerGeneration: Int
    public let checkpoint: RuntimeProviderMigrationCheckpoint
    public let resumed: Bool
}

public enum RuntimeProviderMigrationError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case activeOperations([String])
    case staleCapability(providerID: RuntimeProviderID, expected: String, current: String)
    case incompatibleProvider(providerID: RuntimeProviderID, findings: [RuntimeProviderCompatibilityFinding])
    case ambiguousOwnership(String)
    case targetCollision(String)
    case unsupportedOwnedResource(String)
    case missingLocalImage(String)
    case invalidLocalImageEvidence(String)
    case confirmationMismatch
    case planChanged
    case fencingConflict(activeOperationID: String)
    case fenceLost
    case observationChanged(providerID: RuntimeProviderID, expected: String, current: String)
    case providerFailure(providerID: RuntimeProviderID, checkpoint: RuntimeProviderMigrationCheckpoint)
    case unverifiedTargetResource(String)
    case compensationFailed
    case cancelledAfterCompensation
}

public actor RuntimeProviderMigrationEngine {
    private let journal: any RuntimeProviderMigrationJournaling

    public init(journal: any RuntimeProviderMigrationJournaling) {
        self.journal = journal
    }

    public func dryRun(
        request: RuntimeProviderMigrationRequest,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter
    ) async throws -> RuntimeProviderMigrationPlan {
        try Self.validate(request)
        guard request.activeOperationIDs.isEmpty else {
            throw RuntimeProviderMigrationError.activeOperations(request.activeOperationIDs)
        }

        let sourceSnapshot: RuntimeCapabilitySnapshot
        let sourceInventory: RuntimeInventory
        do {
            sourceSnapshot = try await source.capabilitySnapshot()
            sourceInventory = try await source.inventory()
        } catch {
            throw RuntimeProviderMigrationError.providerFailure(
                providerID: request.sourceProviderID,
                checkpoint: .intentPersisted
            )
        }
        let targetSnapshot: RuntimeCapabilitySnapshot
        let targetInventory: RuntimeInventory
        do {
            targetSnapshot = try await target.capabilitySnapshot()
            targetInventory = try await target.inventory()
        } catch {
            throw RuntimeProviderMigrationError.providerFailure(
                providerID: request.targetProviderID,
                checkpoint: .intentPersisted
            )
        }

        try Self.requireSnapshot(
            sourceSnapshot,
            providerID: request.sourceProviderID,
            expectedSHA256: request.expectedSourceCapabilitySHA256,
            requiredFeatures: [.observation, .lifecycle]
        )
        let sourceResources = try Self.validateSource(
            request: request,
            inventory: sourceInventory
        )
        let targetRequiredFeatures = Self.requiredTargetFeatures(request.resources)
        try Self.requireSnapshot(
            targetSnapshot,
            providerID: request.targetProviderID,
            expectedSHA256: request.expectedTargetCapabilitySHA256,
            requiredFeatures: targetRequiredFeatures
        )
        try Self.validateInitialTarget(
            request: request,
            inventory: targetInventory,
            sourceResources: sourceResources
        )
        try Self.validateTargetCreateSubset(request)

        var imageRequirements: [RuntimeProviderMigrationImageRequirement] = []
        for reference in Set(sourceResources.map(\.container.imageReference)).sorted() {
            let evidence: RuntimeLocalImageEvidence
            do {
                evidence = try await target.localImageEvidence(for: reference)
            } catch {
                throw RuntimeProviderMigrationError.missingLocalImage(reference)
            }
            guard evidence.reference == reference,
                  Self.validDigest(evidence.descriptorDigest),
                  Self.validDigest(evidence.variantDigest),
                  !evidence.architecture.isEmpty,
                  !evidence.operatingSystem.isEmpty else {
                throw RuntimeProviderMigrationError.invalidLocalImageEvidence(reference)
            }
            imageRequirements.append(RuntimeProviderMigrationImageRequirement(evidence: evidence))
        }

        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        let resourcePlans = try sourceResources.map { sourceResource in
            guard let requested = requestByUUID[sourceResource.ownership.resourceUUID] else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(sourceResource.container.name)
            }
            return RuntimeProviderMigrationResourcePlan(
                resourceUUID: sourceResource.ownership.resourceUUID,
                resourceGeneration: sourceResource.ownership.resourceGeneration,
                sourceFencingToken: sourceResource.ownership.fencingToken,
                identity: requested.desiredService.identity.displayName,
                resourceIdentifier: requested.desiredService.identity.managedResourceIdentifier,
                sourceRuntimeID: sourceResource.container.runtimeID,
                imageReference: sourceResource.container.imageReference,
                wasRunning: sourceResource.container.lifecycle == .running,
                desiredSpecificationSHA256: Self.desiredSpecificationSHA256(requested.desiredService)
            )
        }.sorted { $0.resourceUUID < $1.resourceUUID }

        let effects = Self.effects(
            resources: resourcePlans,
            sourceProviderID: request.sourceProviderID,
            targetProviderID: request.targetProviderID
        )
        let rollback = Self.rollbackActions(
            resources: resourcePlans,
            sourceProviderID: request.sourceProviderID,
            targetProviderID: request.targetProviderID
        )
        let sourceObservationSHA256 = try Self.migrationObservationSHA256(sourceInventory)
        let targetObservationSHA256 = try Self.migrationObservationSHA256(targetInventory)
        let token = Self.confirmationToken(
            request: request,
            sourceSnapshot: sourceSnapshot,
            targetSnapshot: targetSnapshot,
            sourceObservationSHA256: sourceObservationSHA256,
            targetObservationSHA256: targetObservationSHA256,
            resources: resourcePlans,
            images: imageRequirements,
            effects: effects,
            rollback: rollback
        )
        return RuntimeProviderMigrationPlan(
            projectName: request.projectName,
            projectUUID: request.projectUUID,
            projectGeneration: request.projectGeneration,
            sourceProviderID: request.sourceProviderID,
            sourceProviderGeneration: request.sourceProviderGeneration,
            targetProviderID: request.targetProviderID,
            sourceCapabilitySHA256: sourceSnapshot.canonicalSHA256,
            targetCapabilitySHA256: targetSnapshot.canonicalSHA256,
            sourceObservationSHA256: sourceObservationSHA256,
            targetObservationSHA256: targetObservationSHA256,
            targetDescriptor: targetSnapshot.descriptor,
            resources: resourcePlans,
            requiredLocalImages: imageRequirements,
            plannedEffects: effects,
            rollbackActions: rollback,
            confirmationToken: token
        )
    }

    public func execute(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        confirmationToken: String,
        operationID: String,
        fencingToken: String,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter
    ) async throws -> RuntimeProviderMigrationResult {
        try Self.validateExecution(
            plan: plan,
            request: request,
            confirmationToken: confirmationToken,
            operationID: operationID,
            fencingToken: fencingToken
        )
        let intent = RuntimeProviderMigrationIntent(
            operationID: operationID,
            fencingToken: fencingToken,
            confirmationToken: plan.confirmationToken,
            projectUUID: plan.projectUUID,
            projectGeneration: plan.projectGeneration,
            sourceProviderID: plan.sourceProviderID,
            sourceProviderGeneration: plan.sourceProviderGeneration,
            targetProviderID: plan.targetProviderID,
            targetProviderGeneration: plan.targetProviderGeneration
        )
        let acquired = try await journal.beginOrResume(intent)
        let lease: RuntimeProviderMigrationLease
        let resumed: Bool
        switch acquired {
        case .acquired(let value):
            lease = value
            resumed = false
        case .resumed(let value):
            lease = value
            resumed = true
        case .conflict(let activeOperationID):
            throw RuntimeProviderMigrationError.fencingConflict(activeOperationID: activeOperationID)
        }
        guard lease.operationID == operationID,
              lease.fencingToken == fencingToken,
              lease.confirmationToken == plan.confirmationToken else {
            throw RuntimeProviderMigrationError.fenceLost
        }

        var checkpoint = lease.checkpoint
        var mutationStarted = checkpoint > .intentPersisted
        var bindingCommitted = checkpoint >= .bindingCommitted
        do {
            try await requireFence(operationID: operationID, fencingToken: fencingToken)
            try await Self.requireFreshCapabilities(
                plan: plan,
                source: source,
                target: target
            )
            if checkpoint == .intentPersisted {
                let initialSource = try await Self.inventory(
                    from: source,
                    providerID: plan.sourceProviderID,
                    checkpoint: checkpoint
                )
                let initialTarget = try await Self.inventory(
                    from: target,
                    providerID: plan.targetProviderID,
                    checkpoint: checkpoint
                )
                let sourceObservationSHA256 = try Self.migrationObservationSHA256(initialSource)
                let targetObservationSHA256 = try Self.migrationObservationSHA256(initialTarget)
                guard sourceObservationSHA256 == plan.sourceObservationSHA256 else {
                    throw RuntimeProviderMigrationError.observationChanged(
                        providerID: plan.sourceProviderID,
                        expected: plan.sourceObservationSHA256,
                        current: sourceObservationSHA256
                    )
                }
                guard targetObservationSHA256 == plan.targetObservationSHA256 else {
                    throw RuntimeProviderMigrationError.observationChanged(
                        providerID: plan.targetProviderID,
                        expected: plan.targetObservationSHA256,
                        current: targetObservationSHA256
                    )
                }
                mutationStarted = true
                try await quiesceSource(
                    plan: plan,
                    request: request,
                    operationID: operationID,
                    fencingToken: fencingToken,
                    source: source
                )
                try await record(
                    operationID: operationID,
                    fencingToken: fencingToken,
                    checkpoint: .sourceQuiesced,
                    verificationSHA256: try await source.inventory().semanticSHA256
                )
                checkpoint = .sourceQuiesced
            }

            if checkpoint < .bindingCommitted {
                let sourceInventory = try await Self.inventory(
                    from: source,
                    providerID: plan.sourceProviderID,
                    checkpoint: checkpoint
                )
                try Self.verifySourceQuiesced(
                    plan: plan,
                    request: request,
                    inventory: sourceInventory
                )
                if checkpoint < .sourceVerified {
                    try await record(
                        operationID: operationID,
                        fencingToken: fencingToken,
                        checkpoint: .sourceVerified,
                        verificationSHA256: sourceInventory.semanticSHA256
                    )
                    checkpoint = .sourceVerified
                }

                try await Self.requireFreshTargetCapability(plan: plan, target: target)
                if checkpoint < .targetCreated {
                    try await createTarget(
                        plan: plan,
                        request: request,
                        operationID: operationID,
                        fencingToken: fencingToken,
                        target: target
                    )
                    let inventory = try await target.inventory()
                    try await record(
                        operationID: operationID,
                        fencingToken: fencingToken,
                        checkpoint: .targetCreated,
                        verificationSHA256: inventory.semanticSHA256
                    )
                    checkpoint = .targetCreated
                }

                let targetInventory = try await Self.inventory(
                    from: target,
                    providerID: plan.targetProviderID,
                    checkpoint: checkpoint
                )
                try Self.verifyTargetContinuity(
                    plan: plan,
                    inventory: targetInventory,
                    fencingToken: fencingToken,
                    requireRunningState: false
                )
                if checkpoint < .targetVerified {
                    try await record(
                        operationID: operationID,
                        fencingToken: fencingToken,
                        checkpoint: .targetVerified,
                        verificationSHA256: targetInventory.semanticSHA256
                    )
                    checkpoint = .targetVerified
                }

                if checkpoint < .targetRunningRestored {
                    try await restoreTargetRunningState(
                        plan: plan,
                        request: request,
                        operationID: operationID,
                        fencingToken: fencingToken,
                        target: target
                    )
                    let inventory = try await target.inventory()
                    try Self.verifyTargetContinuity(
                        plan: plan,
                        inventory: inventory,
                        fencingToken: fencingToken,
                        requireRunningState: true
                    )
                    try await record(
                        operationID: operationID,
                        fencingToken: fencingToken,
                        checkpoint: .targetRunningRestored,
                        verificationSHA256: inventory.semanticSHA256
                    )
                    checkpoint = .targetRunningRestored
                }

                let runningTargetInventory = try await Self.inventory(
                    from: target,
                    providerID: plan.targetProviderID,
                    checkpoint: checkpoint
                )
                try Self.verifyTargetContinuity(
                    plan: plan,
                    inventory: runningTargetInventory,
                    fencingToken: fencingToken,
                    requireRunningState: true
                )

                try await Self.requireFreshCapabilities(
                    plan: plan,
                    source: source,
                    target: target
                )
                try await requireFence(operationID: operationID, fencingToken: fencingToken)
                _ = try await journal.commitProviderBinding(
                    RuntimeProviderMigrationBindingCommit(
                        operationID: operationID,
                        fencingToken: fencingToken,
                        projectUUID: plan.projectUUID,
                        projectGeneration: plan.projectGeneration,
                        expectedSourceProviderID: plan.sourceProviderID,
                        expectedSourceProviderGeneration: plan.sourceProviderGeneration,
                        targetProviderID: plan.targetProviderID,
                        targetProviderGeneration: plan.targetProviderGeneration,
                        confirmationToken: plan.confirmationToken
                    )
                )
                bindingCommitted = true
                try await record(
                    operationID: operationID,
                    fencingToken: fencingToken,
                    checkpoint: .bindingCommitted,
                    verificationSHA256: plan.confirmationToken
                )
                checkpoint = .bindingCommitted
            }

            let authoritativeTarget = try await Self.inventory(
                from: target,
                providerID: plan.targetProviderID,
                checkpoint: checkpoint
            )
            try Self.verifyTargetContinuity(
                plan: plan,
                inventory: authoritativeTarget,
                fencingToken: fencingToken,
                requireRunningState: true
            )
            if checkpoint < .sourceRetired {
                try await retireSource(
                    plan: plan,
                    request: request,
                    operationID: operationID,
                    fencingToken: fencingToken,
                    source: source
                )
                let retiredSource = try await source.inventory()
                try Self.verifySourceRetired(plan: plan, inventory: retiredSource)
                try await record(
                    operationID: operationID,
                    fencingToken: fencingToken,
                    checkpoint: .sourceRetired,
                    verificationSHA256: retiredSource.semanticSHA256
                )
                checkpoint = .sourceRetired
            }
            try await journal.finish(
                operationID: operationID,
                fencingToken: fencingToken,
                status: .succeeded,
                checkpoint: .sourceRetired
            )
            return RuntimeProviderMigrationResult(
                operationID: operationID,
                projectUUID: plan.projectUUID,
                providerID: plan.targetProviderID,
                providerGeneration: plan.targetProviderGeneration,
                checkpoint: .sourceRetired,
                resumed: resumed
            )
        } catch {
            let status: RuntimeProviderMigrationTerminalStatus = error is CancellationError
                ? .cancelled
                : .failed
            if !mutationStarted {
                if let migrationError = error as? RuntimeProviderMigrationError,
                   migrationError == .fenceLost {
                    throw error
                }
                do {
                    try await journal.finish(
                        operationID: operationID,
                        fencingToken: fencingToken,
                        status: status,
                        checkpoint: .intentPersisted
                    )
                } catch {
                    throw RuntimeProviderMigrationError.compensationFailed
                }
                throw error
            }
            guard !bindingCommitted else { throw error }
            do {
                try await Task.detached {
                    try await Self.compensate(
                        journal: self.journal,
                        plan: plan,
                        request: request,
                        operationID: operationID,
                        fencingToken: fencingToken,
                        source: source,
                        target: target
                    )
                    try await self.journal.finish(
                        operationID: operationID,
                        fencingToken: fencingToken,
                        status: status,
                        checkpoint: checkpoint
                    )
                }.value
            } catch {
                throw RuntimeProviderMigrationError.compensationFailed
            }
            if status == .cancelled {
                throw RuntimeProviderMigrationError.cancelledAfterCompensation
            }
            throw error
        }
    }

    private func quiesceSource(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        operationID: String,
        fencingToken: String,
        source: any RuntimeAdapter
    ) async throws {
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        for resource in plan.resources where resource.wasRunning {
            try Task.checkCancellation()
            try await requireFence(operationID: operationID, fencingToken: fencingToken)
            let inventory = try await source.inventory()
            guard let container = Self.container(
                resourceUUID: resource.resourceUUID,
                in: inventory
            ) else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(resource.resourceIdentifier)
            }
            guard let requested = requestByUUID[resource.resourceUUID] else {
                throw RuntimeProviderMigrationError.planChanged
            }
            guard container.ownership == requested.ownership,
                  container.name == resource.resourceIdentifier,
                  container.imageReference == resource.imageReference else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(resource.resourceIdentifier)
            }
            if container.lifecycle != .running { continue }
            try await Self.execute(
                adapter: source,
                action: PlannedRuntimeAction(
                    kind: .stop,
                    identity: requested.desiredService.identity,
                    resourceIdentifier: resource.resourceIdentifier,
                    isDestructive: true,
                    summary: "Quiesce the source provider for migration.",
                    desiredService: requested.desiredService
                ),
                context: Self.context(
                    operationID: operationID,
                    capabilitySHA256: plan.sourceCapabilitySHA256,
                    providerID: plan.sourceProviderID,
                    ownership: requested.ownership,
                    providerGeneration: plan.sourceProviderGeneration,
                    fencingToken: requested.ownership.fencingToken
                ),
                planHash: plan.confirmationToken,
                providerID: plan.sourceProviderID,
                checkpoint: .intentPersisted
            )
        }
    }

    private func createTarget(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        operationID: String,
        fencingToken: String,
        target: any RuntimeAdapter
    ) async throws {
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        for resource in plan.resources {
            try Task.checkCancellation()
            try await requireFence(operationID: operationID, fencingToken: fencingToken)
            let inventory = try await target.inventory()
            if let existing = Self.container(resourceUUID: resource.resourceUUID, in: inventory) {
                try Self.requireTargetOwnership(
                    existing,
                    plan: plan,
                    fencingToken: fencingToken
                )
                continue
            }
            if inventory.containers.contains(where: { $0.name == resource.resourceIdentifier }) {
                throw RuntimeProviderMigrationError.targetCollision(resource.resourceIdentifier)
            }
            guard let requested = requestByUUID[resource.resourceUUID] else {
                throw RuntimeProviderMigrationError.planChanged
            }
            let context = Self.context(
                operationID: operationID,
                capabilitySHA256: plan.targetCapabilitySHA256,
                providerID: plan.targetProviderID,
                ownership: requested.ownership,
                providerGeneration: plan.targetProviderGeneration,
                fencingToken: fencingToken
            )
            try await Self.execute(
                adapter: target,
                action: PlannedRuntimeAction(
                    kind: .create,
                    identity: requested.desiredService.identity,
                    resourceIdentifier: resource.resourceIdentifier,
                    isDestructive: false,
                    summary: "Create the fenced migration target.",
                    desiredService: requested.desiredService
                ),
                context: context,
                planHash: plan.confirmationToken,
                providerID: plan.targetProviderID,
                checkpoint: .sourceVerified
            )
        }
    }

    private func restoreTargetRunningState(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        operationID: String,
        fencingToken: String,
        target: any RuntimeAdapter
    ) async throws {
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        for resource in plan.resources where resource.wasRunning {
            try Task.checkCancellation()
            try await requireFence(operationID: operationID, fencingToken: fencingToken)
            let inventory = try await target.inventory()
            guard let container = Self.container(resourceUUID: resource.resourceUUID, in: inventory) else {
                throw RuntimeProviderMigrationError.unverifiedTargetResource(resource.resourceIdentifier)
            }
            try Self.requireTargetOwnership(container, plan: plan, fencingToken: fencingToken)
            if container.lifecycle == .running { continue }
            guard let requested = requestByUUID[resource.resourceUUID] else {
                throw RuntimeProviderMigrationError.planChanged
            }
            try await Self.execute(
                adapter: target,
                action: PlannedRuntimeAction(
                    kind: .start,
                    identity: requested.desiredService.identity,
                    resourceIdentifier: resource.resourceIdentifier,
                    isDestructive: false,
                    summary: "Restore the migrated workload running state.",
                    desiredService: requested.desiredService
                ),
                context: Self.context(
                    operationID: operationID,
                    capabilitySHA256: plan.targetCapabilitySHA256,
                    providerID: plan.targetProviderID,
                    ownership: requested.ownership,
                    providerGeneration: plan.targetProviderGeneration,
                    fencingToken: fencingToken
                ),
                planHash: plan.confirmationToken,
                providerID: plan.targetProviderID,
                checkpoint: .targetVerified
            )
        }
    }

    private func retireSource(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        operationID: String,
        fencingToken: String,
        source: any RuntimeAdapter
    ) async throws {
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        for resource in plan.resources {
            try Task.checkCancellation()
            try await requireFence(operationID: operationID, fencingToken: fencingToken)
            let inventory = try await source.inventory()
            guard let container = Self.container(
                resourceUUID: resource.resourceUUID,
                in: inventory
            ) else {
                continue
            }
            guard let requested = requestByUUID[resource.resourceUUID],
                  container.ownership == requested.ownership,
                  container.name == resource.resourceIdentifier,
                  container.imageReference == resource.imageReference,
                  container.lifecycle != .running else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(
                    resource.resourceIdentifier
                )
            }
            try await Self.execute(
                adapter: source,
                action: PlannedRuntimeAction(
                    kind: .remove,
                    identity: requested.desiredService.identity,
                    resourceIdentifier: resource.resourceIdentifier,
                    isDestructive: true,
                    summary: "Retire the verified source resource after provider binding commit.",
                    desiredService: requested.desiredService
                ),
                context: Self.context(
                    operationID: operationID,
                    capabilitySHA256: plan.sourceCapabilitySHA256,
                    providerID: plan.sourceProviderID,
                    ownership: requested.ownership,
                    providerGeneration: plan.sourceProviderGeneration,
                    fencingToken: requested.ownership.fencingToken
                ),
                planHash: plan.confirmationToken,
                providerID: plan.sourceProviderID,
                checkpoint: .bindingCommitted
            )
        }
    }

    private func requireFence(operationID: String, fencingToken: String) async throws {
        guard try await journal.verifyFence(
            operationID: operationID,
            fencingToken: fencingToken
        ) else {
            throw RuntimeProviderMigrationError.fenceLost
        }
    }

    private func record(
        operationID: String,
        fencingToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws {
        try await requireFence(operationID: operationID, fencingToken: fencingToken)
        try await journal.recordCheckpoint(
            operationID: operationID,
            fencingToken: fencingToken,
            checkpoint: checkpoint,
            verificationSHA256: verificationSHA256
        )
    }

    private static func compensate(
        journal: any RuntimeProviderMigrationJournaling,
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        operationID: String,
        fencingToken: String,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter
    ) async throws {
        guard try await journal.verifyFence(
            operationID: operationID,
            fencingToken: fencingToken
        ) else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        for resource in plan.resources.reversed() {
            let inventory = try await target.inventory()
            guard let container = container(resourceUUID: resource.resourceUUID, in: inventory) else {
                if inventory.containers.contains(where: { $0.name == resource.resourceIdentifier }) {
                    throw RuntimeProviderMigrationError.unverifiedTargetResource(resource.resourceIdentifier)
                }
                continue
            }
            try requireTargetOwnership(container, plan: plan, fencingToken: fencingToken)
            guard try await journal.verifyFence(
                operationID: operationID,
                fencingToken: fencingToken
            ), let requested = requestByUUID[resource.resourceUUID] else {
                throw RuntimeProviderMigrationError.fenceLost
            }
            try await execute(
                adapter: target,
                action: PlannedRuntimeAction(
                    kind: .remove,
                    identity: requested.desiredService.identity,
                    resourceIdentifier: resource.resourceIdentifier,
                    isDestructive: true,
                    summary: "Remove the verified migration target during compensation.",
                    desiredService: requested.desiredService
                ),
                context: context(
                    operationID: operationID,
                    capabilitySHA256: plan.targetCapabilitySHA256,
                    providerID: plan.targetProviderID,
                    ownership: requested.ownership,
                    providerGeneration: plan.targetProviderGeneration,
                    fencingToken: fencingToken
                ),
                planHash: plan.confirmationToken,
                providerID: plan.targetProviderID,
                checkpoint: .targetCreated
            )
        }

        for resource in plan.resources where resource.wasRunning {
            guard try await journal.verifyFence(
                operationID: operationID,
                fencingToken: fencingToken
            ), let requested = requestByUUID[resource.resourceUUID] else {
                throw RuntimeProviderMigrationError.fenceLost
            }
            let inventory = try await source.inventory()
            guard let container = container(resourceUUID: resource.resourceUUID, in: inventory),
                  container.ownership == requested.ownership else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(resource.resourceIdentifier)
            }
            if container.lifecycle == .running { continue }
            try await execute(
                adapter: source,
                action: PlannedRuntimeAction(
                    kind: .start,
                    identity: requested.desiredService.identity,
                    resourceIdentifier: resource.resourceIdentifier,
                    isDestructive: false,
                    summary: "Restore the source provider during migration compensation.",
                    desiredService: requested.desiredService
                ),
                context: context(
                    operationID: operationID,
                    capabilitySHA256: plan.sourceCapabilitySHA256,
                    providerID: plan.sourceProviderID,
                    ownership: requested.ownership,
                    providerGeneration: plan.sourceProviderGeneration,
                    fencingToken: requested.ownership.fencingToken
                ),
                planHash: plan.confirmationToken,
                providerID: plan.sourceProviderID,
                checkpoint: .sourceQuiesced
            )
        }
    }
}

private extension RuntimeProviderMigrationEngine {
    struct SourceResource {
        let container: RuntimeInventoryContainer
        let ownership: RuntimeInventoryOwnershipEvidence
    }

    static func validate(_ request: RuntimeProviderMigrationRequest) throws {
        guard !request.projectName.isEmpty,
              request.projectName.utf8.count <= 128,
              canonicalUUID(request.projectUUID),
              request.projectGeneration > 0,
              request.sourceProviderGeneration > 0,
              request.sourceProviderID != request.targetProviderID,
              RuntimeProviderID.knownValues.contains(request.sourceProviderID),
              RuntimeProviderID.knownValues.contains(request.targetProviderID),
              !request.resources.isEmpty,
              request.activeOperationIDs.allSatisfy({
                  !$0.isEmpty &&
                      $0.utf8.count <= 256 &&
                      $0.rangeOfCharacter(from: .controlCharacters) == nil
              }),
              Set(request.activeOperationIDs).count == request.activeOperationIDs.count else {
            throw RuntimeProviderMigrationError.invalidRequest("Migration request is incomplete or invalid.")
        }
        let resourceUUIDs = request.resources.map(\.ownership.resourceUUID)
        let identities = request.resources.map(\.desiredService.identity)
        guard Set(resourceUUIDs).count == resourceUUIDs.count,
              Set(identities).count == identities.count else {
            throw RuntimeProviderMigrationError.invalidRequest("Migration resources must be unique.")
        }
        for resource in request.resources {
            let ownership = resource.ownership
            guard canonicalUUID(ownership.resourceUUID),
                  ownership.projectUUID == request.projectUUID,
                  ownership.projectGeneration == request.projectGeneration,
                  ownership.providerID == request.sourceProviderID,
                  ownership.providerGeneration == request.sourceProviderGeneration,
                  canonicalUUID(ownership.fencingToken),
                  ownership.resourceGeneration > 0,
                  resource.desiredService.identity.managedResourceIdentifier.utf8.count <= 63 else {
                throw RuntimeProviderMigrationError.invalidRequest(
                    "Migration resource ownership does not match the project binding."
                )
            }
        }
        try validateOptionalDigest(request.expectedSourceCapabilitySHA256)
        try validateOptionalDigest(request.expectedTargetCapabilitySHA256)
    }

    static func validateOptionalDigest(_ value: String?) throws {
        guard let value else { return }
        guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw RuntimeProviderMigrationError.invalidRequest("Expected capability digest is invalid.")
        }
    }

    static func validateExecution(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        confirmationToken: String,
        operationID: String,
        fencingToken: String
    ) throws {
        try validate(request)
        guard request.activeOperationIDs.isEmpty else {
            throw RuntimeProviderMigrationError.activeOperations(request.activeOperationIDs)
        }
        guard confirmationToken == plan.confirmationToken else {
            throw RuntimeProviderMigrationError.confirmationMismatch
        }
        guard plan.schemaVersion == RuntimeProviderMigrationPlan.currentSchemaVersion,
              operationID.utf8.count <= 256,
              !operationID.isEmpty,
              operationID.rangeOfCharacter(from: .controlCharacters) == nil,
              canonicalUUID(fencingToken),
              plan.confirmationToken.hasPrefix(RuntimeProviderMigrationPlan.confirmationPrefix),
              Self.confirmationToken(for: plan) == plan.confirmationToken,
              plan.projectName == request.projectName,
              plan.projectUUID == request.projectUUID,
              plan.projectGeneration == request.projectGeneration,
              plan.sourceProviderID == request.sourceProviderID,
              plan.sourceProviderGeneration == request.sourceProviderGeneration,
              plan.targetProviderID == request.targetProviderID,
              plan.targetProviderGeneration == request.sourceProviderGeneration + 1 else {
            throw RuntimeProviderMigrationError.planChanged
        }
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        guard Set(plan.resources.map(\.resourceUUID)) == Set(requestByUUID.keys) else {
            throw RuntimeProviderMigrationError.planChanged
        }
        for resource in plan.resources {
            guard let requested = requestByUUID[resource.resourceUUID],
                  resource.identity == requested.desiredService.identity.displayName,
                  resource.resourceIdentifier == requested.desiredService.identity.managedResourceIdentifier,
                  resource.resourceGeneration == requested.ownership.resourceGeneration,
                  resource.sourceFencingToken == requested.ownership.fencingToken,
                  resource.imageReference == requested.desiredService.image,
                  resource.desiredSpecificationSHA256 == desiredSpecificationSHA256(requested.desiredService) else {
                throw RuntimeProviderMigrationError.planChanged
            }
        }
    }

    static func requireSnapshot(
        _ snapshot: RuntimeCapabilitySnapshot,
        providerID: RuntimeProviderID,
        expectedSHA256: String?,
        requiredFeatures: [RuntimeProviderFeature]
    ) throws {
        if let expectedSHA256, expectedSHA256 != snapshot.canonicalSHA256 {
            throw RuntimeProviderMigrationError.staleCapability(
                providerID: providerID,
                expected: expectedSHA256,
                current: snapshot.canonicalSHA256
            )
        }
        let report = RuntimeProviderCapabilityNegotiator.negotiate(
            snapshot,
            expectedProviderID: providerID,
            requiredFeatures: requiredFeatures
        )
        guard report.state == .available else {
            throw RuntimeProviderMigrationError.incompatibleProvider(
                providerID: providerID,
                findings: report.findings
            )
        }
    }

    static func validateSource(
        request: RuntimeProviderMigrationRequest,
        inventory: RuntimeInventory
    ) throws -> [SourceResource] {
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        let expectedNames = Set(request.resources.map {
            $0.desiredService.identity.managedResourceIdentifier
        })
        var result: [SourceResource] = []
        for container in inventory.containers {
            let managed = container.labels.contains {
                $0.key == RuntimeManagedResourceIdentity.managedLabel && $0.value == "true"
            }
            if managed && container.ownership == nil && expectedNames.contains(container.name) {
                throw RuntimeProviderMigrationError.ambiguousOwnership(container.name)
            }
            guard let ownership = container.ownership,
                  ownership.projectUUID == request.projectUUID else {
                if expectedNames.contains(container.name) {
                    throw RuntimeProviderMigrationError.ambiguousOwnership(container.name)
                }
                continue
            }
            guard ownership.providerID == request.sourceProviderID,
                  ownership.projectGeneration == request.projectGeneration,
                  ownership.providerGeneration == request.sourceProviderGeneration,
                  let requested = requestByUUID[ownership.resourceUUID],
                  requested.ownership == ownership,
                  container.name == requested.desiredService.identity.managedResourceIdentifier,
                  container.imageReference == requested.desiredService.image else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(container.name)
            }
            result.append(SourceResource(container: container, ownership: ownership))
        }
        guard Set(result.map(\.ownership.resourceUUID)) == Set(requestByUUID.keys) else {
            throw RuntimeProviderMigrationError.ambiguousOwnership(request.projectName)
        }
        for network in inventory.networks where network.ownership?.projectUUID == request.projectUUID {
            throw RuntimeProviderMigrationError.unsupportedOwnedResource(network.name)
        }
        for volume in inventory.volumes where volume.ownership?.projectUUID == request.projectUUID {
            throw RuntimeProviderMigrationError.unsupportedOwnedResource(volume.name)
        }
        for image in inventory.images where image.ownership?.projectUUID == request.projectUUID {
            throw RuntimeProviderMigrationError.unsupportedOwnedResource(image.runtimeID)
        }
        return result.sorted { $0.ownership.resourceUUID < $1.ownership.resourceUUID }
    }

    static func validateInitialTarget(
        request: RuntimeProviderMigrationRequest,
        inventory: RuntimeInventory,
        sourceResources: [SourceResource]
    ) throws {
        let resourceUUIDs = Set(sourceResources.map(\.ownership.resourceUUID))
        let names = Set(sourceResources.map(\.container.name))
        for container in inventory.containers {
            if names.contains(container.name) ||
                container.ownership.map({ resourceUUIDs.contains($0.resourceUUID) }) == true ||
                container.ownership?.projectUUID == request.projectUUID {
                throw RuntimeProviderMigrationError.targetCollision(container.name)
            }
        }
        if let network = inventory.networks.first(where: {
            $0.ownership?.projectUUID == request.projectUUID
        }) {
            throw RuntimeProviderMigrationError.targetCollision(network.name)
        }
        if let volume = inventory.volumes.first(where: {
            $0.ownership?.projectUUID == request.projectUUID
        }) {
            throw RuntimeProviderMigrationError.targetCollision(volume.name)
        }
        if let image = inventory.images.first(where: {
            $0.ownership?.projectUUID == request.projectUUID
        }) {
            throw RuntimeProviderMigrationError.targetCollision(image.runtimeID)
        }
    }

    static func validateTargetCreateSubset(
        _ request: RuntimeProviderMigrationRequest
    ) throws {
        for resource in request.resources.sorted(by: {
            $0.desiredService.identity.displayName < $1.desiredService.identity.displayName
        }) {
            do {
                try RuntimeCreateSubsetPolicy.validate(
                    resource.desiredService,
                    providerID: request.targetProviderID
                )
            } catch {
                throw RuntimeProviderMigrationError.unsupportedOwnedResource(
                    resource.desiredService.identity.managedResourceIdentifier
                )
            }
        }
    }

    static func requiredTargetFeatures(
        _ resources: [RuntimeProviderMigrationResource]
    ) -> [RuntimeProviderFeature] {
        var required: Set<RuntimeProviderFeature> = [
            .observation,
            .lifecycle,
            .cleanup
        ]
        for resource in resources {
            if !resource.desiredService.mounts.isEmpty { required.insert(.storage) }
        }
        return required.sorted { $0.rawValue < $1.rawValue }
    }

    static func migrationObservationSHA256(_ inventory: RuntimeInventory) throws -> String {
        let containers = inventory.containers.map {
            RuntimeInventoryContainer(
                runtimeID: $0.runtimeID,
                name: $0.name,
                imageID: $0.imageID,
                imageReference: $0.imageReference,
                lifecycle: $0.lifecycle,
                health: $0.health,
                labels: $0.labels,
                ownership: $0.ownership,
                initConfiguration: $0.initConfiguration,
                ports: $0.ports,
                mounts: $0.mounts,
                networks: $0.networks,
                allocation: $0.allocation,
                usage: nil,
                services: $0.services
            )
        }
        return try RuntimeInventoryBuilder.build(
            machine: inventory.machine,
            containers: containers,
            images: inventory.images,
            networks: inventory.networks,
            volumes: inventory.volumes
        ).semanticSHA256
    }

    static func effects(
        resources: [RuntimeProviderMigrationResourcePlan],
        sourceProviderID: RuntimeProviderID,
        targetProviderID: RuntimeProviderID
    ) -> [RuntimeProviderMigrationEffect] {
        var result = resources.filter(\.wasRunning).map {
            RuntimeProviderMigrationEffect(
                kind: .quiesceSource,
                providerID: sourceProviderID,
                resourceUUID: $0.resourceUUID
            )
        }
        result += resources.map {
            RuntimeProviderMigrationEffect(
                kind: .createTarget,
                providerID: targetProviderID,
                resourceUUID: $0.resourceUUID
            )
        }
        result += resources.filter(\.wasRunning).map {
            RuntimeProviderMigrationEffect(
                kind: .restoreTargetRunningState,
                providerID: targetProviderID,
                resourceUUID: $0.resourceUUID
            )
        }
        result.append(
            RuntimeProviderMigrationEffect(
                kind: .commitProviderBinding,
                providerID: targetProviderID
            )
        )
        result += resources.map {
            RuntimeProviderMigrationEffect(
                kind: .retireSource,
                providerID: sourceProviderID,
                resourceUUID: $0.resourceUUID
            )
        }
        return result
    }

    static func rollbackActions(
        resources: [RuntimeProviderMigrationResourcePlan],
        sourceProviderID: RuntimeProviderID,
        targetProviderID: RuntimeProviderID
    ) -> [RuntimeProviderMigrationRollbackAction] {
        resources.reversed().map {
            RuntimeProviderMigrationRollbackAction(
                kind: .removeVerifiedTarget,
                providerID: targetProviderID,
                resourceUUID: $0.resourceUUID
            )
        } + resources.filter(\.wasRunning).map {
            RuntimeProviderMigrationRollbackAction(
                kind: .restoreSourceRunningState,
                providerID: sourceProviderID,
                resourceUUID: $0.resourceUUID
            )
        }
    }

    static func confirmationToken(
        request: RuntimeProviderMigrationRequest,
        sourceSnapshot: RuntimeCapabilitySnapshot,
        targetSnapshot: RuntimeCapabilitySnapshot,
        sourceObservationSHA256: String,
        targetObservationSHA256: String,
        resources: [RuntimeProviderMigrationResourcePlan],
        images: [RuntimeProviderMigrationImageRequirement],
        effects: [RuntimeProviderMigrationEffect],
        rollback: [RuntimeProviderMigrationRollbackAction]
    ) -> String {
        confirmationToken(
            projectName: request.projectName,
            projectUUID: request.projectUUID,
            projectGeneration: request.projectGeneration,
            sourceProviderID: request.sourceProviderID,
            sourceProviderGeneration: request.sourceProviderGeneration,
            targetProviderID: request.targetProviderID,
            sourceCapabilitySHA256: sourceSnapshot.canonicalSHA256,
            targetCapabilitySHA256: targetSnapshot.canonicalSHA256,
            sourceObservationSHA256: sourceObservationSHA256,
            targetObservationSHA256: targetObservationSHA256,
            resources: resources,
            images: images,
            effects: effects,
            rollback: rollback
        )
    }

    static func confirmationToken(for plan: RuntimeProviderMigrationPlan) -> String {
        confirmationToken(
            projectName: plan.projectName,
            projectUUID: plan.projectUUID,
            projectGeneration: plan.projectGeneration,
            sourceProviderID: plan.sourceProviderID,
            sourceProviderGeneration: plan.sourceProviderGeneration,
            targetProviderID: plan.targetProviderID,
            sourceCapabilitySHA256: plan.sourceCapabilitySHA256,
            targetCapabilitySHA256: plan.targetCapabilitySHA256,
            sourceObservationSHA256: plan.sourceObservationSHA256,
            targetObservationSHA256: plan.targetObservationSHA256,
            resources: plan.resources,
            images: plan.requiredLocalImages,
            effects: plan.plannedEffects,
            rollback: plan.rollbackActions
        )
    }

    static func confirmationToken(
        projectName: String,
        projectUUID: String,
        projectGeneration: Int,
        sourceProviderID: RuntimeProviderID,
        sourceProviderGeneration: Int,
        targetProviderID: RuntimeProviderID,
        sourceCapabilitySHA256: String,
        targetCapabilitySHA256: String,
        sourceObservationSHA256: String,
        targetObservationSHA256: String,
        resources: [RuntimeProviderMigrationResourcePlan],
        images: [RuntimeProviderMigrationImageRequirement],
        effects: [RuntimeProviderMigrationEffect],
        rollback: [RuntimeProviderMigrationRollbackAction]
    ) -> String {
        var canonical = MigrationCanonicalEncoder()
        canonical.append("hostwright.runtime-provider-migration.v1")
        canonical.append(projectName)
        canonical.append(projectUUID)
        canonical.append(projectGeneration)
        canonical.append(sourceProviderID.rawValue)
        canonical.append(sourceProviderGeneration)
        canonical.append(targetProviderID.rawValue)
        canonical.append(sourceCapabilitySHA256)
        canonical.append(targetCapabilitySHA256)
        canonical.append(sourceObservationSHA256)
        canonical.append(targetObservationSHA256)
        canonical.append(resources.count)
        for resource in resources {
            canonical.append(resource.resourceUUID)
            canonical.append(resource.resourceGeneration)
            canonical.append(resource.sourceFencingToken)
            canonical.append(resource.identity)
            canonical.append(resource.resourceIdentifier)
            canonical.append(resource.sourceRuntimeID)
            canonical.append(resource.imageReference)
            canonical.append(resource.wasRunning ? 1 : 0)
            canonical.append(resource.desiredSpecificationSHA256)
        }
        canonical.append(images.count)
        for image in images {
            canonical.append(image.reference)
            canonical.append(image.descriptorDigest)
            canonical.append(image.variantDigest)
            canonical.append(image.architecture)
            canonical.append(image.operatingSystem)
        }
        canonical.append(effects.count)
        for effect in effects {
            canonical.append(effect.kind.rawValue)
            canonical.append(effect.providerID.rawValue)
            canonical.append(effect.resourceUUID ?? "")
        }
        canonical.append(rollback.count)
        for action in rollback {
            canonical.append(action.kind.rawValue)
            canonical.append(action.providerID.rawValue)
            canonical.append(action.resourceUUID)
        }
        let digest = SHA256.hash(data: canonical.data)
            .map { String(format: "%02x", $0) }
            .joined()
        return RuntimeProviderMigrationPlan.confirmationPrefix + digest
    }

    static func desiredSpecificationSHA256(_ service: DesiredRuntimeService) -> String {
        var canonical = MigrationCanonicalEncoder()
        canonical.append(service.identity.projectName)
        canonical.append(service.identity.serviceName)
        canonical.append(service.identity.instanceName ?? "")
        canonical.append(service.image)
        canonical.append(service.command.count)
        for argument in service.command { canonical.append(argument) }
        let environment = service.environment.sorted { $0.name < $1.name }
        canonical.append(environment.count)
        for entry in environment {
            canonical.append(entry.name)
            canonical.append(entry.value)
            canonical.append(entry.isSensitive ? 1 : 0)
            canonical.append(entry.secretReference?.rawValue ?? "")
        }
        let ports = service.ports.sorted {
            ($0.hostPort ?? -1, $0.containerPort, $0.protocolName.rawValue, $0.bindAddress ?? "") <
                ($1.hostPort ?? -1, $1.containerPort, $1.protocolName.rawValue, $1.bindAddress ?? "")
        }
        canonical.append(ports.count)
        for port in ports {
            canonical.append(port.hostPort ?? -1)
            canonical.append(port.containerPort)
            canonical.append(port.protocolName.rawValue)
            canonical.append(port.bindAddress ?? "")
        }
        let mounts = service.mounts.sorted { ($0.target, $0.source) < ($1.target, $1.source) }
        canonical.append(mounts.count)
        for mount in mounts {
            canonical.append(mount.source)
            canonical.append(mount.target)
            canonical.append(mount.access.rawValue)
        }
        if let health = service.healthCheck {
            canonical.append(1)
            canonical.append(health.command.count)
            for value in health.command { canonical.append(value) }
            canonical.append(health.intervalSeconds)
            canonical.append(health.timeout.seconds)
        } else {
            canonical.append(0)
        }
        canonical.append(service.restartPolicy.rawValue)
        return SHA256.hash(data: canonical.data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func requireFreshCapabilities(
        plan: RuntimeProviderMigrationPlan,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter
    ) async throws {
        let sourceSnapshot: RuntimeCapabilitySnapshot
        let targetSnapshot: RuntimeCapabilitySnapshot
        do {
            sourceSnapshot = try await source.capabilitySnapshot()
            targetSnapshot = try await target.capabilitySnapshot()
        } catch {
            throw RuntimeProviderMigrationError.providerFailure(
                providerID: plan.sourceProviderID,
                checkpoint: .intentPersisted
            )
        }
        guard sourceSnapshot.canonicalSHA256 == plan.sourceCapabilitySHA256 else {
            throw RuntimeProviderMigrationError.staleCapability(
                providerID: plan.sourceProviderID,
                expected: plan.sourceCapabilitySHA256,
                current: sourceSnapshot.canonicalSHA256
            )
        }
        guard targetSnapshot.canonicalSHA256 == plan.targetCapabilitySHA256,
              targetSnapshot.descriptor == plan.targetDescriptor else {
            throw RuntimeProviderMigrationError.staleCapability(
                providerID: plan.targetProviderID,
                expected: plan.targetCapabilitySHA256,
                current: targetSnapshot.canonicalSHA256
            )
        }
    }

    static func requireFreshTargetCapability(
        plan: RuntimeProviderMigrationPlan,
        target: any RuntimeAdapter
    ) async throws {
        let snapshot: RuntimeCapabilitySnapshot
        do {
            snapshot = try await target.capabilitySnapshot()
        } catch {
            throw RuntimeProviderMigrationError.providerFailure(
                providerID: plan.targetProviderID,
                checkpoint: .sourceVerified
            )
        }
        guard snapshot.canonicalSHA256 == plan.targetCapabilitySHA256,
              snapshot.descriptor == plan.targetDescriptor else {
            throw RuntimeProviderMigrationError.staleCapability(
                providerID: plan.targetProviderID,
                expected: plan.targetCapabilitySHA256,
                current: snapshot.canonicalSHA256
            )
        }
    }

    static func inventory(
        from adapter: any RuntimeAdapter,
        providerID: RuntimeProviderID,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws -> RuntimeInventory {
        do {
            return try await adapter.inventory()
        } catch {
            throw RuntimeProviderMigrationError.providerFailure(
                providerID: providerID,
                checkpoint: checkpoint
            )
        }
    }

    static func verifySourceQuiesced(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        inventory: RuntimeInventory
    ) throws {
        let requestByUUID = Dictionary(uniqueKeysWithValues: request.resources.map {
            ($0.ownership.resourceUUID, $0)
        })
        for resource in plan.resources {
            guard let requested = requestByUUID[resource.resourceUUID],
                  let container = container(resourceUUID: resource.resourceUUID, in: inventory),
                  container.ownership == requested.ownership,
                  container.name == resource.resourceIdentifier else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(resource.resourceIdentifier)
            }
            if resource.wasRunning && container.lifecycle == .running {
                throw RuntimeProviderMigrationError.providerFailure(
                    providerID: plan.sourceProviderID,
                    checkpoint: .sourceQuiesced
                )
            }
        }
    }

    static func verifyTargetContinuity(
        plan: RuntimeProviderMigrationPlan,
        inventory: RuntimeInventory,
        fencingToken: String,
        requireRunningState: Bool
    ) throws {
        let plannedUUIDs = Set(plan.resources.map(\.resourceUUID))
        for resource in plan.resources {
            guard let container = container(resourceUUID: resource.resourceUUID, in: inventory) else {
                throw RuntimeProviderMigrationError.unverifiedTargetResource(resource.resourceIdentifier)
            }
            try requireTargetOwnership(container, plan: plan, fencingToken: fencingToken)
            guard container.name == resource.resourceIdentifier,
                  container.imageReference == resource.imageReference else {
                throw RuntimeProviderMigrationError.unverifiedTargetResource(resource.resourceIdentifier)
            }
            if requireRunningState && resource.wasRunning && container.lifecycle != .running {
                throw RuntimeProviderMigrationError.unverifiedTargetResource(resource.resourceIdentifier)
            }
        }
        let unexpected = inventory.containers.first {
            $0.ownership?.projectUUID == plan.projectUUID &&
                $0.ownership?.providerID == plan.targetProviderID &&
                !plannedUUIDs.contains($0.ownership?.resourceUUID ?? "")
        }
        if let unexpected {
            throw RuntimeProviderMigrationError.targetCollision(unexpected.name)
        }
    }

    static func verifySourceRetired(
        plan: RuntimeProviderMigrationPlan,
        inventory: RuntimeInventory
    ) throws {
        let plannedUUIDs = Set(plan.resources.map(\.resourceUUID))
        let plannedNames = Set(plan.resources.map(\.resourceIdentifier))
        if let remaining = inventory.containers.first(where: { container in
            plannedNames.contains(container.name) ||
                container.ownership.map({ ownership in
                    plannedUUIDs.contains(ownership.resourceUUID) &&
                        ownership.projectUUID == plan.projectUUID &&
                        ownership.providerID == plan.sourceProviderID &&
                        ownership.providerGeneration == plan.sourceProviderGeneration
                }) == true
        }) {
            throw RuntimeProviderMigrationError.ambiguousOwnership(remaining.name)
        }
    }

    static func requireTargetOwnership(
        _ container: RuntimeInventoryContainer,
        plan: RuntimeProviderMigrationPlan,
        fencingToken: String
    ) throws {
        guard let ownership = container.ownership,
              ownership.projectUUID == plan.projectUUID,
              ownership.projectGeneration == plan.projectGeneration,
              ownership.providerID == plan.targetProviderID,
              ownership.providerGeneration == plan.targetProviderGeneration,
              ownership.fencingToken == fencingToken else {
            throw RuntimeProviderMigrationError.unverifiedTargetResource(container.name)
        }
    }

    static func container(
        resourceUUID: String,
        in inventory: RuntimeInventory
    ) -> RuntimeInventoryContainer? {
        inventory.containers.first { $0.ownership?.resourceUUID == resourceUUID }
    }

    static func context(
        operationID: String,
        capabilitySHA256: String,
        providerID: RuntimeProviderID,
        ownership: RuntimeInventoryOwnershipEvidence,
        providerGeneration: Int,
        fencingToken: String
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: providerID,
            capabilitySHA256: capabilitySHA256,
            operationID: operationID,
            resourceUUID: ownership.resourceUUID,
            resourceGeneration: ownership.resourceGeneration,
            projectResourceUUID: ownership.projectUUID,
            projectGeneration: ownership.projectGeneration,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken
        )
    }

    static func execute(
        adapter: any RuntimeAdapter,
        action: PlannedRuntimeAction,
        context: RuntimeMutationContext,
        planHash: String,
        providerID: RuntimeProviderID,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws {
        do {
            _ = try await adapter.execute(
                action,
                confirmation: RuntimeMutationConfirmation(
                    confirmed: true,
                    reason: "Confirmed provider migration.",
                    planHash: planHash,
                    context: context
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RuntimeProviderMigrationError.providerFailure(
                providerID: providerID,
                checkpoint: checkpoint
            )
        }
    }

    static func validDigest(_ value: String) -> Bool {
        value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    static func canonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

private struct MigrationCanonicalEncoder {
    private(set) var data = Data()

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        data.append(Data(String(bytes.count).utf8))
        data.append(0x3a)
        data.append(bytes)
    }

    mutating func append(_ value: Int) {
        append(String(value))
    }
}
