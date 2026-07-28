import CryptoKit
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import HostwrightState

struct ProjectDNSLifecycleReconciliationResult: Sendable {
    let newlyCreatedDNSUUIDs: [String]
}

struct ProjectDNSHelperIdentity: Equatable, Sendable {
    let projectUUID: String
    let dnsUUID: String
    let generation: Int64
    let fencingToken: String
}

enum ProjectDNSHelperDisposition: Equatable, Sendable {
    case absent
    case active
    case conflicting
    case quarantined
}

struct ProjectDNSHelperObservation: Equatable, Sendable {
    let disposition: ProjectDNSHelperDisposition
    let corefilePath: String?
    let corefileSHA256: String?
    let hostAccessSHA256: String?
    let hostAccessActive: Bool

    init(
        disposition: ProjectDNSHelperDisposition,
        corefilePath: String?,
        corefileSHA256: String?,
        hostAccessSHA256: String? = nil,
        hostAccessActive: Bool = true
    ) {
        self.disposition = disposition
        self.corefilePath = corefilePath
        self.corefileSHA256 = corefileSHA256
        self.hostAccessSHA256 = hostAccessSHA256
        self.hostAccessActive = hostAccessActive
    }
}

protocol ProjectDNSHelperDriving: Sendable {
    func status(
        identity: ProjectDNSHelperIdentity
    ) async throws -> ProjectDNSHelperObservation

    func apply(
        identity: ProjectDNSHelperIdentity,
        corefile: String,
        hostAccessBindings: [ProjectDNSHostAccessBinding],
        predecessorFencingToken: String?
    ) async throws -> ProjectDNSHelperObservation

    func remove(
        identity: ProjectDNSHelperIdentity
    ) async throws -> ProjectDNSHelperObservation
}

enum ProjectDNSRuntimeMutation: Sendable {
    case create(
        service: DesiredRuntimeService,
        resourceIdentifier: String,
        context: RuntimeMutationContext,
        planSHA256: String
    )
    case start(
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        context: RuntimeMutationContext,
        planSHA256: String
    )
    case stop(
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        expectedOwnership: RuntimeInventoryOwnershipEvidence,
        context: RuntimeMutationContext,
        planSHA256: String
    )
    case remove(
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        expectedOwnership: RuntimeInventoryOwnershipEvidence,
        context: RuntimeMutationContext,
        planSHA256: String
    )
}

protocol ProjectDNSRuntimeDriving: Sendable {
    func currentCapabilitySHA256() async throws -> String
    func coreDNSImageEvidence()
        async throws -> CoreDNSInfrastructureImageEvidence
    func inventory() async throws -> RuntimeInventory
    func mutate(_ mutation: ProjectDNSRuntimeMutation) async throws
}

enum ProjectDNSLifecycleCoordinator {
    static func reconcile(
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        store: SQLiteStateStore,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws -> ProjectDNSLifecycleReconciliationResult {
        guard !preparation.desiredState.networks.isEmpty else {
            return ProjectDNSLifecycleReconciliationResult(
                newlyCreatedDNSUUIDs: []
            )
        }
        try validateProvider(preparation)
        try validateProjectNetworks(
            preparation: preparation,
            store: store
        )
        try await validatePreMutation(
            preparation: preparation,
            runtime: runtime
        )

        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID: preparation.projectResourceUUID,
            desiredState: preparation.desiredState,
            observedState: preparation.observedState,
            runtimeInventory: try await runtime.inventory()
        )
        let desiredSHA256 = try digest(
            ProjectDNSDesiredEvidence(
                plan: plan,
                networks: preparation.desiredState.networks
            )
        )
        let readySHA256 = try digest(plan.records)
        let dnsUUID = dnsUUID(
            projectUUID: preparation.projectResourceUUID
        )

        if let existing = try store.projectDNS.load(id: dnsUUID) {
            try validate(
                existing: existing,
                preparation: preparation
            )
            if existing.lifecycleState == .available,
               existing.finalizerState == .active {
                if existing.desiredSHA256 != desiredSHA256 ||
                    existing.lastReadyRecordSHA256 != readySHA256 {
                    try await refresh(
                        preparation: preparation,
                        observedState: preparation.observedState,
                        planSHA256: planSHA256,
                        store: store,
                        helper: helper,
                        runtime: runtime
                    )
                } else {
                    guard let exact = try await exactObservation(
                        record: existing,
                        preparation: preparation,
                        helper: helper,
                        runtime: runtime
                    ) else {
                        throw conflict(
                            "Available project DNS lost exact runtime or helper ownership."
                        )
                    }
                    try ProjectDNSHostAccessReservations
                        .requireActive(
                            bindings:
                                plan.hostAccessBindings,
                            helperSHA256:
                                exact.helper
                                    .hostAccessSHA256,
                            dnsUUID: existing.id,
                            preparation: preparation,
                            store: store
                        )
                }
                return ProjectDNSLifecycleReconciliationResult(
                    newlyCreatedDNSUUIDs: []
                )
            }
            guard existing.lifecycleState == .creating,
                  existing.finalizerState == .pending,
                  existing.desiredSHA256 == desiredSHA256 else {
                throw conflict(
                    "A prior project DNS operation requires exact recovery before mutation."
                )
            }
            let group = try resume(
                record: existing,
                preparation: preparation,
                store: store
            )
            let created = try await createOrRecover(
                plan: plan,
                readySHA256: readySHA256,
                creating: existing,
                group: group,
                preparation: preparation,
                planSHA256: planSHA256,
                helper: helper,
                runtime: runtime,
                store: store
            )
            return ProjectDNSLifecycleReconciliationResult(
                newlyCreatedDNSUUIDs: created ? [dnsUUID] : []
            )
        }

        let createGeneration = try nextCreateStateGeneration(
            preparation: preparation,
            store: store
        )
        let group = try acquireOperation(
            action: "create",
            desiredSHA256: desiredSHA256,
            stateGeneration: createGeneration,
            preparation: preparation,
            planSHA256: planSHA256,
            fencingToken: nil,
            store: store
        )
        let authority = try await mutationAuthority(
            group: group,
            preparation: preparation,
            runtime: runtime
        )
        let creating = ProjectDNSStateRecord(
            id: dnsUUID,
            projectUUID: preparation.projectResourceUUID,
            generation: createGeneration,
            providerID: preparation.providerID.rawValue,
            providerGeneration:
                Int64(preparation.providerGeneration),
            fencingToken: group.fencingToken,
            desiredSHA256: desiredSHA256,
            observedSHA256: nil,
            lifecycleState: .creating,
            finalizerState: .pending,
            lastReadyRecordSHA256: nil,
            operationGroupID: group.id
        )
        try store.projectDNS.save(
            creating,
            authority: authority
        )
        let created = try await createOrRecover(
            plan: plan,
            readySHA256: readySHA256,
            creating: creating,
            group: group,
            preparation: preparation,
            planSHA256: planSHA256,
            helper: helper,
            runtime: runtime,
            store: store
        )
        return ProjectDNSLifecycleReconciliationResult(
            newlyCreatedDNSUUIDs: created ? [dnsUUID] : []
        )
    }

    static func refresh(
        preparation: LifecycleCommandPreparation,
        observedState: ObservedRuntimeState,
        planSHA256: String,
        store: SQLiteStateStore,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws {
        try validateProvider(preparation)
        try validateProjectNetworks(
            preparation: preparation,
            store: store
        )
        try await validatePreMutation(
            preparation: preparation,
            runtime: runtime
        )
        let id = dnsUUID(
            projectUUID: preparation.projectResourceUUID
        )
        guard let existing = try store.projectDNS.load(id: id),
              existing.lifecycleState == .available,
              existing.finalizerState == .active else {
            throw conflict(
                "Project DNS refresh requires one exact available state record."
            )
        }
        try validate(
            existing: existing,
            preparation: preparation
        )
        guard let initialRuntime = try await exactRuntimeContainer(
            record: existing,
            preparation: preparation,
            runtime: runtime
        ) else {
            throw conflict(
                "Project DNS refresh requires exact runtime ownership."
            )
        }

        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID: preparation.projectResourceUUID,
            desiredState: preparation.desiredState,
            observedState: observedState,
            runtimeInventory: try await runtime.inventory()
        )
        let desiredSHA256 = try digest(
            ProjectDNSDesiredEvidence(
                plan: plan,
                networks: preparation.desiredState.networks
            )
        )
        let readySHA256 = try digest(plan.records)
        guard existing.desiredSHA256 != desiredSHA256 ||
                existing.lastReadyRecordSHA256 != readySHA256 else {
            return
        }

        let group = try acquireOperation(
            action: "refresh",
            desiredSHA256: desiredSHA256,
            stateGeneration: existing.generation + 1,
            preparation: preparation,
            planSHA256: planSHA256,
            fencingToken: nil,
            priorRecord: existing,
            store: store
        )
        let helperIdentity = ProjectDNSHelperIdentity(
            projectUUID: existing.projectUUID,
            dnsUUID: existing.id,
            generation: existing.generation + 1,
            fencingToken: group.fencingToken
        )
        let reservations =
            try ProjectDNSHostAccessReservations.prepare(
                bindings: plan.hostAccessBindings,
                dnsUUID: existing.id,
                group: group,
                preparation: preparation,
                store: store
            )
        do {
            let applied = try await helper.apply(
                identity: helperIdentity,
                corefile: plan.corefile,
                hostAccessBindings: plan.hostAccessBindings,
                predecessorFencingToken:
                    existing.fencingToken
            )
            try validateHelper(
                applied,
                expectedCorefileSHA256: try digest(plan.corefile),
                expectedHostAccessSHA256:
                    try hostAccessDigest(plan.hostAccessBindings)
            )
            guard let observed = try await exactRuntimeContainer(
                record: existing,
                preparation: preparation,
                runtime: runtime
            ) else {
                throw conflict(
                    "Project DNS runtime ownership changed during ready-record refresh."
                )
            }
            guard try runtimeDigest(observed) ==
                    runtimeDigest(initialRuntime) else {
                throw conflict(
                    "Project DNS runtime evidence changed during ready-record refresh."
                )
            }
            try ProjectDNSHostAccessReservations.commit(
                reservations,
                helperSHA256: applied.hostAccessSHA256,
                group: group,
                store: store
            )
            let authority = try await mutationAuthority(
                group: group,
                preparation: preparation,
                runtime: runtime
            )
            let refreshed = ProjectDNSStateRecord(
                id: existing.id,
                projectUUID: existing.projectUUID,
                generation: existing.generation + 1,
                providerID: existing.providerID,
                providerGeneration:
                    existing.providerGeneration,
                fencingToken: group.fencingToken,
                desiredSHA256: desiredSHA256,
                observedSHA256: try runtimeDigest(observed),
                lifecycleState: .available,
                finalizerState: .active,
                lastReadyRecordSHA256: readySHA256,
                operationGroupID: group.id
            )
            try store.projectDNS.save(
                refreshed,
                replacing: version(existing),
                authority: authority
            )
            try finish(
                group,
                status: .succeeded,
                checkpoint: "ready-records-committed",
                store: store
            )
        } catch {
            try? finish(
                group,
                status: .interrupted,
                checkpoint: "refresh-not-committed",
                store: store
            )
            throw error
        }
    }

    static func remove(
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        store: SQLiteStateStore,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws {
        try validateProvider(preparation)
        try await validatePreMutation(
            preparation: preparation,
            runtime: runtime
        )
        let id = dnsUUID(
            projectUUID: preparation.projectResourceUUID
        )
        guard let existing = try store.projectDNS.load(id: id) else {
            return
        }
        try validate(
            existing: existing,
            preparation: preparation
        )
        if existing.lifecycleState == .deleted,
           existing.finalizerState == .released {
            try finalizeTerminalDeletion(
                existing,
                preparation: preparation,
                store: store
            )
            return
        }
        if existing.lifecycleState == .deleting,
           existing.finalizerState == .releasing {
            let group = try resume(
                record: existing,
                preparation: preparation,
                store: store
            )
            let intent = try operationIntent(group)
            guard intent.action == "delete",
                  intent.stateGeneration == existing.generation,
                  let priorStateGeneration =
                    intent.priorStateGeneration,
                  let priorFence =
                    intent.priorFence,
                  let priorRuntimeGeneration =
                    intent.priorRuntimeGeneration,
                  let priorRuntimeFence =
                    intent.priorRuntimeFence,
                  priorStateGeneration >= 1,
                  priorRuntimeGeneration >= 1,
                  HostwrightResourceUUID.isValid(
                      priorFence
                  ),
                  HostwrightResourceUUID.isValid(
                      priorRuntimeFence
                  ) else {
                throw conflict(
                    "Interrupted project DNS deletion lost its prior helper ownership evidence."
                )
            }
            try await continueDeletion(
                deleting: existing,
                priorStateGeneration: priorStateGeneration,
                priorFence: priorFence,
                priorRuntimeGeneration:
                    priorRuntimeGeneration,
                priorRuntimeFence: priorRuntimeFence,
                group: group,
                preparation: preparation,
                planSHA256: planSHA256,
                store: store,
                helper: helper,
                runtime: runtime
            )
            return
        }
        guard existing.lifecycleState == .available,
              existing.finalizerState == .active,
              let observed = try await exactObservation(
                  record: existing,
                  preparation: preparation,
                  helper: helper,
                  runtime: runtime
              ) else {
            throw conflict(
                "Project DNS removal requires exact available runtime and helper ownership."
            )
        }

        guard let priorRuntimeOwnership =
                observed.container.ownership else {
            throw conflict(
                "Project DNS removal lost exact runtime ownership."
            )
        }
        let group = try acquireOperation(
            action: "delete",
            desiredSHA256: existing.desiredSHA256,
            stateGeneration: existing.generation + 1,
            preparation: preparation,
            planSHA256: planSHA256,
            fencingToken: nil,
            priorRecord: existing,
            priorRuntimeOwnership:
                priorRuntimeOwnership,
            store: store
        )
        let authority = try await mutationAuthority(
            group: group,
            preparation: preparation,
            runtime: runtime
        )
        let deleting = ProjectDNSStateRecord(
            id: existing.id,
            projectUUID: existing.projectUUID,
            generation: existing.generation + 1,
            providerID: existing.providerID,
            providerGeneration: existing.providerGeneration,
            fencingToken: group.fencingToken,
            desiredSHA256: existing.desiredSHA256,
            observedSHA256:
                try runtimeDigest(observed.container),
            lifecycleState: .deleting,
            finalizerState: .releasing,
            lastReadyRecordSHA256:
                existing.lastReadyRecordSHA256,
            operationGroupID: group.id
        )
        try store.projectDNS.save(
            deleting,
            replacing: version(existing),
            authority: authority
        )

        try await continueDeletion(
            deleting: deleting,
            priorStateGeneration: existing.generation,
            priorFence: existing.fencingToken,
            priorRuntimeGeneration:
                priorRuntimeOwnership.resourceGeneration,
            priorRuntimeFence:
                priorRuntimeOwnership.fencingToken,
            group: group,
            preparation: preparation,
            planSHA256: planSHA256,
            store: store,
            helper: helper,
            runtime: runtime
        )
    }

    private static func continueDeletion(
        deleting: ProjectDNSStateRecord,
        priorStateGeneration: Int64,
        priorFence: String,
        priorRuntimeGeneration: Int,
        priorRuntimeFence: String,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        store: SQLiteStateStore,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws {
        do {
            let priorOwnership =
                RuntimeInventoryOwnershipEvidence(
                    resourceUUID: deleting.id,
                    projectUUID: deleting.projectUUID,
                    resourceGeneration:
                        priorRuntimeGeneration,
                    projectGeneration:
                        preparation.projectGeneration,
                    providerID: preparation.providerID,
                    providerGeneration:
                        preparation.providerGeneration,
                    fencingToken: priorRuntimeFence
                )
            if let observed = try await exactRuntimeContainer(
                record: deleting,
                preparation: preparation,
                runtime: runtime,
                requireRunning: false,
                expectedOwnership: priorOwnership
            ) {
                try await stopThenRemove(
                    observed,
                    record: deleting,
                    group: group,
                    preparation: preparation,
                    planSHA256: planSHA256,
                    runtime: runtime
                )
            } else if try await matchingContainer(
                dnsUUID: deleting.id,
                preparation: preparation,
                runtime: runtime
            ) != nil {
                throw conflict(
                    "Project DNS deletion found conflicting runtime ownership."
                )
            }
            guard try await matchingContainer(
                dnsUUID: deleting.id,
                preparation: preparation,
                runtime: runtime
            ) == nil else {
                throw conflict(
                    "Project DNS runtime deletion did not produce verified absence."
                )
            }
            let helperIdentity = ProjectDNSHelperIdentity(
                projectUUID: deleting.projectUUID,
                dnsUUID: deleting.id,
                generation: priorStateGeneration,
                fencingToken: priorFence
            )
            let helperStatus = try await helper.status(
                identity: helperIdentity
            )
            switch helperStatus.disposition {
            case .active:
                let removed = try await helper.remove(
                    identity: helperIdentity
                )
                guard removed.disposition == .absent else {
                    throw conflict(
                        "Project DNS helper did not verify exact configuration removal."
                    )
                }
            case .absent:
                break
            case .conflicting, .quarantined:
                throw conflict(
                    "Project DNS deletion found conflicting or quarantined helper ownership."
                )
            }
            try ProjectDNSHostAccessReservations.releaseAll(
                dnsUUID: deleting.id,
                group: group,
                preparation: preparation,
                store: store
            )
            let authority = try await mutationAuthority(
                group: group,
                preparation: preparation,
                runtime: runtime
            )
            let deleted = ProjectDNSStateRecord(
                id: deleting.id,
                projectUUID: deleting.projectUUID,
                generation: deleting.generation + 1,
                providerID: deleting.providerID,
                providerGeneration: deleting.providerGeneration,
                fencingToken: deleting.fencingToken,
                desiredSHA256: deleting.desiredSHA256,
                observedSHA256:
                    try digest("absent:\(deleting.id)"),
                lifecycleState: .deleted,
                finalizerState: .released,
                lastReadyRecordSHA256:
                    deleting.lastReadyRecordSHA256,
                operationGroupID: group.id
            )
            try store.projectDNS.save(
                deleted,
                replacing: version(deleting),
                authority: authority
            )
            try finish(
                group,
                status: .succeeded,
                checkpoint: "state-committed",
                store: store
            )
            _ = try store.projectDNS.removeDeleted(
                id: deleted.id,
                expected: version(deleted)
            )
        } catch {
            try? finish(
                group,
                status: .interrupted,
                checkpoint: "delete-requires-reobservation",
                store: store
            )
            throw error
        }
    }

    static func compensateNewlyCreated(
        _ result: ProjectDNSLifecycleReconciliationResult,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        store: SQLiteStateStore,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws {
        let id = dnsUUID(
            projectUUID: preparation.projectResourceUUID
        )
        guard result.newlyCreatedDNSUUIDs == [id] else {
            return
        }
        try await remove(
            preparation: preparation,
            planSHA256: planSHA256,
            store: store,
            helper: helper,
            runtime: runtime
        )
    }

    private static func createOrRecover(
        plan: ProjectDNSPlan,
        readySHA256: String,
        creating: ProjectDNSStateRecord,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving,
        store: SQLiteStateStore
    ) async throws -> Bool {
        let (nextStateGeneration, generationOverflow) =
            creating.generation.addingReportingOverflow(1)
        guard !generationOverflow,
              let runtimeGeneration = Int(
                  exactly: nextStateGeneration
              ) else {
            throw conflict(
                "Project DNS generation cannot advance safely."
            )
        }
        let helperIdentity = ProjectDNSHelperIdentity(
            projectUUID: creating.projectUUID,
            dnsUUID: creating.id,
            generation: nextStateGeneration,
            fencingToken: creating.fencingToken
        )
        let expectedCorefileSHA256 = try digest(plan.corefile)
        let reservations =
            try ProjectDNSHostAccessReservations.prepare(
                bindings: plan.hostAccessBindings,
                dnsUUID: creating.id,
                group: group,
                preparation: preparation,
                store: store
            )
        var helperAppliedByExecution = false
        var runtimeCreatedByExecution = false
        do {
            let initialHelper = try await helper.status(
                identity: helperIdentity
            )
            let helperObservation:
                ProjectDNSHelperObservation
            switch initialHelper.disposition {
            case .active:
                try validateHelper(
                    initialHelper,
                    expectedCorefileSHA256:
                        expectedCorefileSHA256,
                    expectedHostAccessSHA256:
                        try hostAccessDigest(
                            plan.hostAccessBindings
                        ),
                    requireHostAccessActive: false
                )
                helperObservation = initialHelper
            case .absent:
                helperObservation = try await helper.apply(
                    identity: helperIdentity,
                    corefile: plan.corefile,
                    hostAccessBindings: plan.hostAccessBindings,
                    predecessorFencingToken: nil
                )
                helperAppliedByExecution = true
                try validateHelper(
                    helperObservation,
                    expectedCorefileSHA256:
                        expectedCorefileSHA256,
                    expectedHostAccessSHA256:
                        try hostAccessDigest(
                            plan.hostAccessBindings
                        ),
                    requireHostAccessActive: false
                )
            case .conflicting, .quarantined:
                try await quarantine(
                    creating,
                    group: group,
                    preparation: preparation,
                    runtime: runtime,
                    store: store
                )
                throw conflict(
                    "Project DNS helper recovery found conflicting or quarantined ownership."
                )
            }

            let current = try await matchingContainer(
                dnsUUID: creating.id,
                preparation: preparation,
                runtime: runtime
            )
            if let current {
                guard exactRuntimeContainer(
                    current,
                    record: creating,
                    preparation: preparation,
                    helperObservation: helperObservation,
                    requireRunning: false
                ) else {
                    try await quarantine(
                        creating,
                        group: group,
                        preparation: preparation,
                        runtime: runtime,
                        store: store
                    )
                    throw conflict(
                        "Project DNS recovery found a conflicting runtime owner."
                    )
                }
                if current.lifecycle != .running {
                    try await runtime.mutate(
                        .start(
                            identity: infrastructureIdentity(
                                preparation: preparation
                            ),
                            resourceIdentifier: current.runtimeID,
                            context: mutationContext(
                                group: group,
                                preparation: preparation,
                                resourceGeneration:
                                    runtimeGeneration
                            ),
                            planSHA256: planSHA256
                        )
                    )
                }
            } else {
                guard let corefilePath =
                        helperObservation.corefilePath else {
                    throw conflict(
                        "Project DNS helper omitted its active Corefile path."
                    )
                }
                let service = try infrastructureService(
                    preparation: preparation,
                    corefilePath: corefilePath
                )
                let resourceIdentifier =
                    service.identity.managedResourceIdentifier
                try await runtime.mutate(
                    .create(
                        service: service,
                        resourceIdentifier: resourceIdentifier,
                        context: mutationContext(
                            group: group,
                            preparation: preparation,
                            resourceGeneration:
                                runtimeGeneration
                        ),
                        planSHA256: planSHA256
                    )
                )
                runtimeCreatedByExecution = true
                try await runtime.mutate(
                    .start(
                        identity: service.identity,
                        resourceIdentifier: resourceIdentifier,
                        context: mutationContext(
                            group: group,
                            preparation: preparation,
                            resourceGeneration:
                                runtimeGeneration
                        ),
                        planSHA256: planSHA256
                    )
                )
            }

            guard let observed = try await exactObservation(
                record: creating,
                preparation: preparation,
                helper: helper,
                runtime: runtime
            ) else {
                throw conflict(
                    "Project DNS creation was not verified through exact structured runtime and helper observation."
                )
            }
            try ProjectDNSHostAccessReservations.commit(
                reservations,
                helperSHA256:
                    observed.helper.hostAccessSHA256,
                group: group,
                store: store
            )
            try await commitAvailable(
                creating: creating,
                group: group,
                readySHA256: readySHA256,
                observed: observed.container,
                preparation: preparation,
                runtime: runtime,
                store: store
            )
            return runtimeCreatedByExecution
        } catch {
            if runtimeCreatedByExecution {
                try? await compensateCreate(
                    creating: creating,
                    group: group,
                    preparation: preparation,
                    planSHA256: planSHA256,
                    helperIdentity: helperIdentity,
                    helper: helper,
                    runtime: runtime,
                    store: store
                )
            } else if helperAppliedByExecution {
                _ = try? await helper.remove(
                    identity: helperIdentity
                )
            }
            if (try? store.operationGroups.load(
                id: group.id
            )?.status) == .active {
                try? finish(
                    group,
                    status: .interrupted,
                    checkpoint: "effect-requires-reobservation",
                    store: store
                )
            }
            throw error
        }
    }

    private static func compensateCreate(
        creating: ProjectDNSStateRecord,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        helperIdentity: ProjectDNSHelperIdentity,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving,
        store: SQLiteStateStore
    ) async throws {
        guard let container = try await matchingContainer(
            dnsUUID: creating.id,
            preparation: preparation,
            runtime: runtime
        ),
        exactRuntimeContainer(
            container,
            record: creating,
            preparation: preparation,
            helperObservation: try await helper.status(
                identity: helperIdentity
            ),
            requireRunning: false
        ) else {
            return
        }
        try await stopThenRemove(
            container,
            record: creating,
            group: group,
            preparation: preparation,
            planSHA256: planSHA256,
            runtime: runtime
        )
        guard try await matchingContainer(
            dnsUUID: creating.id,
            preparation: preparation,
            runtime: runtime
        ) == nil else {
            return
        }
        let removed = try await helper.remove(
            identity: helperIdentity
        )
        guard removed.disposition == .absent else {
            return
        }
        try ProjectDNSHostAccessReservations.releaseAll(
            dnsUUID: creating.id,
            group: group,
            preparation: preparation,
            store: store
        )
        let authority = try await mutationAuthority(
            group: group,
            preparation: preparation,
            runtime: runtime
        )
        let deleting = ProjectDNSStateRecord(
            id: creating.id,
            projectUUID: creating.projectUUID,
            generation: creating.generation + 1,
            providerID: creating.providerID,
            providerGeneration: creating.providerGeneration,
            fencingToken: creating.fencingToken,
            desiredSHA256: creating.desiredSHA256,
            observedSHA256: nil,
            lifecycleState: .deleting,
            finalizerState: .releasing,
            lastReadyRecordSHA256: nil,
            operationGroupID: group.id
        )
        try store.projectDNS.save(
            deleting,
            replacing: version(creating),
            authority: authority
        )
        let deleted = ProjectDNSStateRecord(
            id: deleting.id,
            projectUUID: deleting.projectUUID,
            generation: deleting.generation + 1,
            providerID: deleting.providerID,
            providerGeneration: deleting.providerGeneration,
            fencingToken: deleting.fencingToken,
            desiredSHA256: deleting.desiredSHA256,
            observedSHA256: try digest("absent:\(deleting.id)"),
            lifecycleState: .deleted,
            finalizerState: .released,
            lastReadyRecordSHA256: nil,
            operationGroupID: group.id
        )
        try store.projectDNS.save(
            deleted,
            replacing: version(deleting),
            authority: authority
        )
        _ = try store.projectDNS.removeDeleted(
            id: deleted.id,
            expected: version(deleted)
        )
    }

    private static func stopThenRemove(
        _ observed: RuntimeInventoryContainer,
        record: ProjectDNSStateRecord,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws {
        var candidate = observed
        guard var expectedOwnership = candidate.ownership else {
            throw conflict(
                "Project DNS runtime observation lost exact ownership before deletion."
            )
        }
        if candidate.lifecycle == .running {
            try await runtime.mutate(
                .stop(
                    identity: infrastructureIdentity(
                        preparation: preparation
                    ),
                    resourceIdentifier: candidate.runtimeID,
                    expectedOwnership: expectedOwnership,
                    context: mutationContext(
                        group: group,
                        preparation: preparation,
                        expectedOwnership: expectedOwnership
                    ),
                    planSHA256: planSHA256
                )
            )
            guard let stopped = try await exactRuntimeContainer(
                record: record,
                preparation: preparation,
                runtime: runtime,
                requireRunning: false,
                expectedOwnership: expectedOwnership
            ),
            [.stopped, .exited].contains(stopped.lifecycle),
            let stoppedOwnership = stopped.ownership else {
                throw conflict(
                    "Project DNS runtime stop did not produce exact verified stopped or exited state."
                )
            }
            candidate = stopped
            expectedOwnership = stoppedOwnership
        }
        try await runtime.mutate(
            .remove(
                identity: infrastructureIdentity(
                    preparation: preparation
                ),
                resourceIdentifier: candidate.runtimeID,
                expectedOwnership: expectedOwnership,
                context: mutationContext(
                    group: group,
                    preparation: preparation,
                    expectedOwnership: expectedOwnership
                ),
                planSHA256: planSHA256
            )
        )
    }

    private static func commitAvailable(
        creating: ProjectDNSStateRecord,
        group: OperationGroupRecord,
        readySHA256: String,
        observed: RuntimeInventoryContainer,
        preparation: LifecycleCommandPreparation,
        runtime: any ProjectDNSRuntimeDriving,
        store: SQLiteStateStore
    ) async throws {
        let authority = try await mutationAuthority(
            group: group,
            preparation: preparation,
            runtime: runtime
        )
        let observedSHA256 = try runtimeDigest(observed)
        let available = ProjectDNSStateRecord(
            id: creating.id,
            projectUUID: creating.projectUUID,
            generation: creating.generation + 1,
            providerID: creating.providerID,
            providerGeneration: creating.providerGeneration,
            fencingToken: creating.fencingToken,
            desiredSHA256: creating.desiredSHA256,
            observedSHA256: observedSHA256,
            lifecycleState: .available,
            finalizerState: .active,
            lastReadyRecordSHA256: readySHA256,
            operationGroupID: group.id
        )
        try store.projectDNS.save(
            available,
            replacing: version(creating),
            authority: authority
        )
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: "runtime-helper-observed",
            verificationJSONRedacted:
                #"{"dnsUUID":"\#(creating.id)","observationSHA256":"\#(observedSHA256)","readyRecordSHA256":"\#(readySHA256)"}"#,
            updatedAt: hostwrightTimestamp()
        )
        try finish(
            group,
            status: .succeeded,
            checkpoint: "state-committed",
            store: store
        )
    }

    private static func exactObservation(
        record: ProjectDNSStateRecord,
        preparation: LifecycleCommandPreparation,
        helper: any ProjectDNSHelperDriving,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws -> (
        container: RuntimeInventoryContainer,
        helper: ProjectDNSHelperObservation
    )? {
        let helperObservation = try await helper.status(
            identity: ProjectDNSHelperIdentity(
                projectUUID: record.projectUUID,
                dnsUUID: record.id,
                generation:
                    record.lifecycleState == .creating
                        ? record.generation + 1
                        : record.generation,
                fencingToken: record.fencingToken
            )
        )
        guard helperObservation.disposition == .active,
              helperObservation.hostAccessActive,
              let container = try await exactRuntimeContainer(
                  record: record,
                  preparation: preparation,
                  runtime: runtime
              ),
              exactRuntimeContainer(
                  container,
                  record: record,
                  preparation: preparation,
                  helperObservation: helperObservation
              ) else {
            return nil
        }
        return (container, helperObservation)
    }

    private static func exactRuntimeContainer(
        record: ProjectDNSStateRecord,
        preparation: LifecycleCommandPreparation,
        runtime: any ProjectDNSRuntimeDriving,
        requireRunning: Bool = true,
        expectedOwnership:
            RuntimeInventoryOwnershipEvidence? = nil
    ) async throws -> RuntimeInventoryContainer? {
        guard let container = try await matchingContainer(
            dnsUUID: record.id,
            preparation: preparation,
            runtime: runtime
        ) else {
            return nil
        }
        let helperPath = container.mounts.first {
            $0.target == "/etc/coredns"
        }.map {
            URL(fileURLWithPath: $0.source)
                .appendingPathComponent("Corefile")
                .path
        }
        let observation = ProjectDNSHelperObservation(
            disposition: helperPath == nil ? .absent : .active,
            corefilePath: helperPath,
            corefileSHA256: nil
        )
        return exactRuntimeContainer(
            container,
            record: record,
            preparation: preparation,
            helperObservation: observation,
            requireRunning: requireRunning,
            expectedOwnership: expectedOwnership
        ) ? container : nil
    }

    private static func exactRuntimeContainer(
        _ container: RuntimeInventoryContainer,
        record: ProjectDNSStateRecord,
        preparation: LifecycleCommandPreparation,
        helperObservation: ProjectDNSHelperObservation,
        requireRunning: Bool = true,
        expectedOwnership:
            RuntimeInventoryOwnershipEvidence? = nil
    ) -> Bool {
        let validLifecycle =
            requireRunning
                ? container.lifecycle == .running
                : [
                    .created,
                    .running,
                    .stopped,
                    .exited,
                ].contains(container.lifecycle)
        guard helperObservation.disposition == .active,
              let corefilePath = helperObservation.corefilePath,
              let ownership = container.ownership,
              ownership.resourceUUID == record.id,
              ownership.projectUUID == record.projectUUID,
              ownership.projectGeneration ==
                preparation.projectGeneration,
              ownership.providerID == preparation.providerID,
              ownership.providerGeneration ==
                preparation.providerGeneration,
              validLifecycle,
              container.imageReference ==
                CoreDNSInfrastructureImage
                    .immutableLinuxARM64Reference,
              container.ports.isEmpty else {
            return false
        }
        let exactRuntimeAuthority =
            ownership == expectedOwnership ||
            ownership.fencingToken == record.fencingToken ||
            (
                record.observedSHA256 != nil &&
                (try? runtimeDigest(container)) ==
                    record.observedSHA256
            )
        let ownershipGeneration = Int64(
            ownership.resourceGeneration
        )
        let exactRuntimeGeneration: Bool
        if let expectedOwnership {
            exactRuntimeGeneration =
                ownership.resourceGeneration ==
                    expectedOwnership.resourceGeneration
        } else if record.lifecycleState == .creating {
            exactRuntimeGeneration =
                ownershipGeneration ==
                    record.generation + 1
        } else if ownership.fencingToken ==
                    record.fencingToken {
            exactRuntimeGeneration =
                ownershipGeneration ==
                    record.generation
        } else {
            exactRuntimeGeneration =
                record.observedSHA256 != nil &&
                ownershipGeneration >= 1 &&
                ownershipGeneration <=
                    record.generation
        }
        guard exactRuntimeAuthority,
              exactRuntimeGeneration else {
            return false
        }
        var labels: [String: String] = [:]
        for label in container.labels {
            guard labels.updateValue(
                label.value,
                forKey: label.key
            ) == nil else {
                return false
            }
        }
        guard (try? RuntimeProjectDNSContract.requirement(
            from: labels,
            projectUUID: record.projectUUID
        ))?.resourceUUID == record.id,
        RuntimeProjectDNSContract.isInfrastructure(labels) else {
            return false
        }
        let expectedNetworks = Set(
            preparation.desiredState.networks.map {
                $0.identity.runtimeIdentifier
            }
        )
        let exactObservedNetworks =
            Set(container.networks.map(\.networkID)) ==
                expectedNetworks &&
            container.networks.allSatisfy {
                !$0.addresses.isEmpty
            }
        let stoppedNetworkAddressesUnavailable =
            [.stopped, .exited].contains(container.lifecycle) &&
            expectedOwnership == ownership &&
            (
                container.networks.isEmpty ||
                Set(container.networks.map(\.networkID)) ==
                    expectedNetworks
            ) &&
            container.networks.allSatisfy {
                $0.addresses.isEmpty
            }
        guard exactObservedNetworks ||
                stoppedNetworkAddressesUnavailable else {
            return false
        }
        let corefileDirectory = URL(
            fileURLWithPath: corefilePath
        ).deletingLastPathComponent().path
        return container.mounts == [
            RuntimeInventoryMount(
                source: corefileDirectory,
                target: "/etc/coredns",
                kind: .bind,
                access: .readOnly
            ),
        ]
    }

    private static func matchingContainer(
        dnsUUID: String,
        preparation: LifecycleCommandPreparation,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws -> RuntimeInventoryContainer? {
        let identity = infrastructureIdentity(
            preparation: preparation
        )
        let runtimeName = identity.managedResourceIdentifier
        let matches = try await runtime.inventory().containers.filter {
            $0.runtimeID == runtimeName ||
                $0.name == runtimeName ||
                $0.ownership?.resourceUUID == dnsUUID
        }
        guard matches.count <= 1 else {
            throw conflict(
                "Project DNS observation found multiple runtime identity matches."
            )
        }
        return matches.first
    }

    private static func infrastructureService(
        preparation: LifecycleCommandPreparation,
        corefilePath: String
    ) throws -> DesiredRuntimeService {
        guard corefilePath.hasPrefix("/"),
              URL(fileURLWithPath: corefilePath)
                .standardizedFileURL.path == corefilePath else {
            throw conflict(
                "Project DNS helper returned an unsafe Corefile path."
            )
        }
        let attachments = try preparation.desiredState.networks
            .sorted {
                $0.identity.runtimeIdentifier <
                    $1.identity.runtimeIdentifier
            }.map {
                try RuntimeDesiredNetworkAttachment(
                    network: $0.identity
                )
            }
        let corefileDirectory = URL(
            fileURLWithPath: corefilePath
        ).deletingLastPathComponent().path
        return DesiredRuntimeService(
            identity: infrastructureIdentity(
                preparation: preparation
            ),
            logicalServiceName: "hostwright-dns",
            image:
                CoreDNSInfrastructureImage
                    .immutableLinuxARM64Reference,
            platformOperatingSystem: "linux",
            platformArchitecture: "arm64",
            command: [
                "-conf",
                "/etc/coredns/Corefile",
            ],
            labels:
                try RuntimeProjectDNSContract
                    .infrastructureLabels(
                        projectUUID:
                            preparation.projectResourceUUID
                    ),
            ports: [],
            networks: attachments,
            mounts: [
                RuntimeMountReference(
                    source: corefileDirectory,
                    target: "/etc/coredns",
                    kind: .bind,
                    access: .readOnly
                ),
            ],
            restartPolicy: .unlessStopped
        )
    }

    private static func infrastructureIdentity(
        preparation: LifecycleCommandPreparation
    ) -> RuntimeServiceIdentity {
        RuntimeServiceIdentity(
            projectName: preparation.desiredState.projectName,
            serviceName: "hostwright-dns"
        )
    }

    private static func validateProjectNetworks(
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws {
        let desired = Dictionary(
            uniqueKeysWithValues:
                preparation.desiredState.networks.map {
                    ($0.identity.resourceUUID, $0)
                }
        )
        let persisted = try store.networks.listNetworks(
            projectUUID: preparation.projectResourceUUID
        )
        let byID = Dictionary(
            uniqueKeysWithValues: persisted.map { ($0.id, $0) }
        )
        guard !desired.isEmpty,
              desired.allSatisfy({ id, network in
                  guard let record = byID[id] else {
                      return false
                  }
                  return record.projectUUID ==
                    preparation.projectResourceUUID &&
                    record.runtimeName ==
                    network.identity.runtimeIdentifier &&
                    record.providerID ==
                    preparation.providerID.rawValue &&
                    record.providerGeneration ==
                    Int64(preparation.providerGeneration) &&
                    record.lifecycleState == .available &&
                    record.finalizerState == .active
              }) else {
            throw conflict(
                "Project DNS requires every desired project network to exist with exact available ownership before mutation."
            )
        }
    }

    private static func validatePreMutation(
        preparation: LifecycleCommandPreparation,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws {
        guard try await runtime.currentCapabilitySHA256() ==
                preparation.capabilitySHA256 else {
            throw conflict(
                "Project DNS refused a stale runtime capability snapshot."
            )
        }
        let evidence = try await runtime.coreDNSImageEvidence()
        do {
            try CoreDNSInfrastructureImage.validate(evidence)
        } catch {
            throw conflict(
                "Project DNS requires exact local Phase-05-verified CoreDNS 1.14.6 linux/arm64 content before mutation."
            )
        }
    }

    private static func validateProvider(
        _ preparation: LifecycleCommandPreparation
    ) throws {
        guard preparation.providerID == .appleContainerCLI else {
            throw conflict(
                "Project DNS injection is unavailable for the selected provider; Containerization DNS injection is not yet proven."
            )
        }
    }

    private static func validate(
        existing: ProjectDNSStateRecord,
        preparation: LifecycleCommandPreparation
    ) throws {
        guard existing.projectUUID ==
                preparation.projectResourceUUID,
              existing.providerID ==
                preparation.providerID.rawValue,
              existing.providerGeneration ==
                Int64(preparation.providerGeneration) else {
            throw conflict(
                "Persisted project DNS identity conflicts with the selected project provider generation."
            )
        }
    }

    private static func validateHelper(
        _ observation: ProjectDNSHelperObservation,
        expectedCorefileSHA256: String,
        expectedHostAccessSHA256: String?,
        requireHostAccessActive: Bool = true
    ) throws {
        guard observation.disposition == .active,
              observation.corefileSHA256 ==
                expectedCorefileSHA256,
              observation.hostAccessSHA256 ==
                expectedHostAccessSHA256,
              (
                  !requireHostAccessActive ||
                      observation.hostAccessActive
              ),
              let path = observation.corefilePath,
              path.hasPrefix("/"),
              URL(fileURLWithPath: path)
                .standardizedFileURL.path == path else {
            throw conflict(
                "Project DNS helper did not return exact active Corefile evidence."
            )
        }
    }

    private static func hostAccessDigest(
        _ bindings: [ProjectDNSHostAccessBinding]
    ) throws -> String? {
        bindings.isEmpty ? nil : try digest(
            bindings.sorted(
                by: ProjectDNSHostAccessBinding.canonicalPrecedes
            )
        )
    }

    private static func quarantine(
        _ record: ProjectDNSStateRecord,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        runtime: any ProjectDNSRuntimeDriving,
        store: SQLiteStateStore
    ) async throws {
        let authority = try await mutationAuthority(
            group: group,
            preparation: preparation,
            runtime: runtime
        )
        _ = try store.projectDNS.quarantine(
            id: record.id,
            expected: version(record),
            authority: authority
        )
        try finish(
            group,
            status: .failed,
            checkpoint: "ownership-quarantined",
            store: store
        )
    }

    private static func resume(
        record: ProjectDNSStateRecord,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        guard let group = try store.operationGroups.load(
            id: record.operationGroupID
        ),
        group.projectID == preparation.projectID,
        group.fencingToken == record.fencingToken else {
            throw conflict(
                "Interrupted project DNS state lost its exact operation group."
            )
        }
        switch group.status {
        case .active:
            return group
        case .interrupted:
            return try store.operationGroups.resumeInterrupted(
                groupID: group.id,
                expectedFencingToken: group.fencingToken,
                lockOwner: "hostwright-cli",
                lockExpiresAt: hostwrightTimestampAdding(
                    seconds: 86_400,
                    to: hostwrightTimestamp()
                ),
                updatedAt: hostwrightTimestamp()
            )
        case .succeeded, .failed:
            throw conflict(
                "Terminal project DNS operation is missing authoritative committed state."
            )
        }
    }

    private static func operationIntent(
        _ group: OperationGroupRecord
    ) throws -> ProjectDNSOperationIntent {
        guard group.intentJSONRedacted.utf8.count <= 1_048_576,
              let data = group.intentJSONRedacted.data(using: .utf8),
              let intent = try? JSONDecoder().decode(
                  ProjectDNSOperationIntent.self,
                  from: data
              ),
              intent.schemaVersion == 1,
              HostwrightResourceUUID.isValid(
                  intent.projectUUID
              ),
              HostwrightResourceUUID.isValid(
                  intent.dnsUUID
              ) else {
            throw conflict(
                "Persisted project DNS operation intent is invalid."
            )
        }
        return intent
    }

    private static func finalizeTerminalDeletion(
        _ record: ProjectDNSStateRecord,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws {
        guard let persisted = try store.operationGroups.load(
            id: record.operationGroupID
        ),
        persisted.projectID == preparation.projectID,
        persisted.fencingToken == record.fencingToken else {
            throw conflict(
                "Terminal project DNS deletion lost its exact operation group."
            )
        }
        let group: OperationGroupRecord
        switch persisted.status {
        case .active:
            group = persisted
        case .interrupted:
            group = try store.operationGroups.resumeInterrupted(
                groupID: persisted.id,
                expectedFencingToken:
                    persisted.fencingToken,
                lockOwner: "hostwright-cli",
                lockExpiresAt: hostwrightTimestampAdding(
                    seconds: 86_400,
                    to: hostwrightTimestamp()
                ),
                updatedAt: hostwrightTimestamp()
            )
        case .succeeded:
            _ = try store.projectDNS.removeDeleted(
                id: record.id,
                expected: version(record)
            )
            return
        case .failed:
            throw conflict(
                "Terminal project DNS deletion has a failed operation group."
            )
        }
        try finish(
            group,
            status: .succeeded,
            checkpoint: "state-committed",
            store: store
        )
        _ = try store.projectDNS.removeDeleted(
            id: record.id,
            expected: version(record)
        )
    }

    private static func acquireOperation(
        action: String,
        desiredSHA256: String,
        stateGeneration: Int64,
        preparation: LifecycleCommandPreparation,
        planSHA256: String,
        fencingToken: String?,
        priorRecord: ProjectDNSStateRecord? = nil,
        priorRuntimeOwnership:
            RuntimeInventoryOwnershipEvidence? = nil,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let id = HostwrightResourceUUID.legacy(
            kind: "project-dns-operation",
            identifier:
                "\(planSHA256):\(action):\(stateGeneration):\(desiredSHA256)"
        )
        let fence = fencingToken ??
            HostwrightResourceUUID.legacy(
                kind: "project-dns-fence",
                identifier: id
            )
        let intent = ProjectDNSOperationIntent(
            schemaVersion: 1,
            action: action,
            projectUUID:
                preparation.projectResourceUUID,
            dnsUUID: dnsUUID(
                projectUUID:
                    preparation.projectResourceUUID
            ),
            stateGeneration: stateGeneration,
            providerID: preparation.providerID.rawValue,
            providerGeneration:
                preparation.providerGeneration,
            capabilitySHA256:
                preparation.capabilitySHA256,
            desiredSHA256: desiredSHA256,
            priorStateGeneration: priorRecord?.generation,
            priorFence: priorRecord?.fencingToken,
            priorRuntimeGeneration:
                priorRuntimeOwnership?.resourceGeneration,
            priorRuntimeFence:
                priorRuntimeOwnership?.fencingToken
        )
        let now = hostwrightTimestamp()
        let candidate = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "project-dns",
            projectID: preparation.projectID,
            serviceName: "hostwright-dns",
            plannedActionType: action,
            status: .active,
            groupIdempotencyKey: try digest(intent),
            planHash: planSHA256,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-cli",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: now
            ),
            rollbackAvailable: action != "delete",
            manualRecoveryHintRedacted:
                "Re-observe the exact UUID-owned project DNS runtime and helper state.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted:
                #"{"resource":"project-dns"}"#,
            fencingToken: fence,
            intentJSONRedacted: try encoded(intent),
            compensationJSONRedacted:
                action == "create"
                    ? #"["remove-created-project-dns"]"#
                    : "[]",
            verificationJSONRedacted: "{}"
        )
        if let existing = try store.operationGroups.load(id: id) {
            guard existing.groupIdempotencyKey ==
                    candidate.groupIdempotencyKey,
                  existing.planHash == candidate.planHash,
                  existing.fencingToken ==
                    candidate.fencingToken else {
                throw conflict(
                    "Project DNS operation identity was reused with different authority."
                )
            }
            switch existing.status {
            case .active:
                return existing
            case .interrupted:
                return try store.operationGroups
                    .resumeInterrupted(
                        groupID: existing.id,
                        expectedFencingToken:
                            existing.fencingToken,
                        lockOwner: "hostwright-cli",
                        lockExpiresAt:
                            candidate.lockExpiresAt,
                        updatedAt: now
                    )
            case .succeeded, .failed:
                throw conflict(
                    "Terminal project DNS operation cannot be replayed without matching state."
                )
            }
        }
        let acquired = try store.operationGroups.acquire(
            candidate,
            currentTimestamp: now
        )
        if let value = acquired.acquired {
            return value
        }
        guard let existing = acquired.existingActive,
              existing.id == candidate.id,
              existing.fencingToken ==
                candidate.fencingToken else {
            throw conflict(
                "Another active operation owns the project DNS fence."
            )
        }
        return existing
    }

    private static func nextCreateStateGeneration(
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws -> Int64 {
        let groups = try store.operationGroups.loadAll()
            .filter {
                $0.groupKind == "project-dns" &&
                    $0.projectID == preparation.projectID
            }
        guard !groups.isEmpty else {
            return 1
        }

        let expectedDNSUUID = dnsUUID(
            projectUUID: preparation.projectResourceUUID
        )
        var history: [
            (group: OperationGroupRecord, intent: ProjectDNSOperationIntent)
        ] = []
        for group in groups {
            let intent = try operationIntent(group)
            guard group.serviceName == "hostwright-dns",
                  intent.projectUUID ==
                    preparation.projectResourceUUID,
                  intent.dnsUUID == expectedDNSUUID,
                  intent.action == group.plannedActionType,
                  intent.providerID ==
                    preparation.providerID.rawValue,
                  intent.providerGeneration ==
                    preparation.providerGeneration else {
                throw conflict(
                    "Project DNS operation history has mismatched authority."
                )
            }
            history.append((group, intent))
        }

        guard let latest = history.last,
              latest.group.status == .succeeded,
              latest.group.checkpoint == "state-committed",
              latest.intent.action == "delete",
              let priorStateGeneration =
                latest.intent.priorStateGeneration,
              let priorFence = latest.intent.priorFence,
              priorStateGeneration >= 1,
              HostwrightResourceUUID.isValid(priorFence),
              priorStateGeneration + 1 ==
                latest.intent.stateGeneration else {
            throw conflict(
                "Missing project DNS state is not backed by one exact committed deletion."
            )
        }
        let (nextGeneration, overflow) =
            latest.intent.stateGeneration
                .addingReportingOverflow(2)
        guard !overflow else {
            throw conflict(
                "Project DNS generation cannot advance safely."
            )
        }
        return nextGeneration
    }

    private static func mutationAuthority(
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        runtime: any ProjectDNSRuntimeDriving
    ) async throws -> NetworkStateMutationAuthority {
        NetworkStateMutationAuthority(
            providerID: preparation.providerID.rawValue,
            providerGeneration:
                Int64(preparation.providerGeneration),
            operationGroupID: group.id,
            fencingToken: group.fencingToken,
            plannedCapabilitySHA256:
                preparation.capabilitySHA256,
            currentCapabilitySHA256:
                try await runtime
                    .currentCapabilitySHA256()
        )
    }

    private static func mutationContext(
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        resourceGeneration: Int? = nil,
        expectedOwnership:
            RuntimeInventoryOwnershipEvidence? = nil
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: preparation.providerID,
            capabilitySHA256:
                preparation.capabilitySHA256,
            operationID: group.operationID,
            resourceUUID: dnsUUID(
                projectUUID:
                    preparation.projectResourceUUID
            ),
            resourceGeneration:
                expectedOwnership?.resourceGeneration ??
                resourceGeneration ??
                2,
            projectResourceUUID:
                preparation.projectResourceUUID,
            projectGeneration:
                preparation.projectGeneration,
            providerGeneration:
                preparation.providerGeneration,
            fencingToken:
                expectedOwnership?.fencingToken ??
                group.fencingToken
        )
    }

    private static func finish(
        _ group: OperationGroupRecord,
        status: OperationGroupStatus,
        checkpoint: String,
        store: SQLiteStateStore
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: status,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted:
                status == .succeeded
                    ? "No manual recovery is required."
                    : "Re-observe the exact UUID-owned project DNS runtime and helper state.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"resource":"project-dns","result":"\#(status.rawValue)"}"#
        )
    }

    private static func dnsUUID(
        projectUUID: String
    ) -> String {
        HostwrightResourceUUID.legacy(
            kind: "project-dns",
            identifier: projectUUID
        )
    }

    private static func version(
        _ record: ProjectDNSStateRecord
    ) -> NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private static func encoded<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return String(
            decoding: try encoder.encode(value),
            as: UTF8.self
        )
    }

    private static func digest<T: Encodable>(
        _ value: T
    ) throws -> String {
        SHA256.hash(data: Data(try encoded(value).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func digest(
        _ value: String
    ) throws -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func runtimeDigest(
        _ container: RuntimeInventoryContainer
    ) throws -> String {
        try digest(
            ProjectDNSRuntimeEvidence(container: container)
        )
    }

    private static func conflict(
        _ message: String
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .runtimeUnavailable,
            message: message
        )
    }
}

private struct ProjectDNSDesiredEvidence:
    Codable,
    Sendable
{
    let plan: ProjectDNSPlan
    let networkRuntimeIdentifiers: [String]
    let networkResourceUUIDs: [String]
    let imageReference: String

    init(
        plan: ProjectDNSPlan,
        networks: [DesiredRuntimeNetwork]
    ) {
        self.plan = plan
        networkRuntimeIdentifiers = networks
            .map(\.identity.runtimeIdentifier)
            .sorted()
        networkResourceUUIDs = networks
            .map(\.identity.resourceUUID)
            .sorted()
        imageReference =
            CoreDNSInfrastructureImage
                .immutableLinuxARM64Reference
    }
}

private struct ProjectDNSOperationIntent:
    Codable,
    Sendable
{
    let schemaVersion: Int
    let action: String
    let projectUUID: String
    let dnsUUID: String
    let stateGeneration: Int64
    let providerID: String
    let providerGeneration: Int
    let capabilitySHA256: String
    let desiredSHA256: String
    let priorStateGeneration: Int64?
    let priorFence: String?
    let priorRuntimeGeneration: Int?
    let priorRuntimeFence: String?
}

private struct ProjectDNSRuntimeEvidence: Codable, Sendable {
    let runtimeID: String
    let name: String
    let imageReference: String
    let lifecycle: RuntimeInventoryLifecycleState
    let labels: [RuntimeInventoryLabel]
    let ownership: RuntimeInventoryOwnershipEvidence?
    let initConfiguration: RuntimeInventoryInitConfiguration
    let ports: [RuntimeInventoryPort]
    let mounts: [RuntimeInventoryMount]
    let networks: [RuntimeInventoryNetworkAttachment]

    init(container: RuntimeInventoryContainer) {
        runtimeID = container.runtimeID
        name = container.name
        imageReference = container.imageReference
        lifecycle = container.lifecycle
        labels = container.labels.sorted {
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.value < $1.value
        }
        ownership = container.ownership
        initConfiguration = container.initConfiguration
        ports = container.ports.sorted {
            [
                $0.hostAddress ?? "",
                $0.hostPort.map(String.init) ?? "",
                String($0.containerPort),
                $0.protocolName.rawValue,
            ].joined(separator: ":") <
                [
                    $1.hostAddress ?? "",
                    $1.hostPort.map(String.init) ?? "",
                    String($1.containerPort),
                    $1.protocolName.rawValue,
                ].joined(separator: ":")
        }
        mounts = container.mounts.sorted {
            [
                $0.target,
                $0.source,
                $0.kind.rawValue,
                $0.access.rawValue,
            ].joined(separator: ":") <
                [
                    $1.target,
                    $1.source,
                    $1.kind.rawValue,
                    $1.access.rawValue,
                ].joined(separator: ":")
        }
        networks = container.networks.sorted {
            $0.networkID < $1.networkID
        }
    }
}
