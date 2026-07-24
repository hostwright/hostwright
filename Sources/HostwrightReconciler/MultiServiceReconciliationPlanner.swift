import Foundation
import HostwrightCore
import HostwrightRuntime

public enum MultiServiceReconciliationMode: String, Equatable, Sendable {
    case up
    case down
    case remove
}

public enum MultiServiceReconciliationError: Error, Equatable, Sendable {
    case invalidParallelism(Int)
    case projectMismatch(expected: String, actual: String)
    case duplicateDesiredIdentity(String)
    case invalidReplicaSet(String)
    case inconsistentReplicaDependencies(String)
    case duplicateDependency(service: String, dependency: String)
    case missingDependency(service: String, dependency: String)
    case dependencyCycle([String])
    case duplicateObservedIdentity(String)
    case duplicateObservedResourceIdentifier(String)
    case unmanagedResourceCollision(String)
    case ownershipRequired(String)
    case desiredSpecificationDriftRequiresUpdate([String])
    case unsafeObservedState(identity: String, state: RuntimeLifecycleState)
    case unsatisfiedDependency(service: String, dependency: String, condition: RuntimeDependencyCondition)
    case duplicatePlanNode(String)
    case invalidPlanDependency(node: String, dependency: String)
    case internalPlanCycle([String])
}

public struct MultiServiceLifecycleNodeDraft: Equatable, Sendable {
    public let key: String
    public let action: LifecyclePlanAction
    public let identity: RuntimeServiceIdentity
    public let resourceIdentifier: String
    public let desiredService: DesiredRuntimeService?
    public let dependencies: [String]
    public let preconditions: [LifecyclePlanCondition]
    public let postconditions: [LifecyclePlanCondition]
    public let requiresReobservationAfter: Bool

    public init(
        key: String,
        action: LifecyclePlanAction,
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        desiredService: DesiredRuntimeService?,
        dependencies: [String] = [],
        preconditions: [LifecyclePlanCondition] = [],
        postconditions: [LifecyclePlanCondition] = [],
        requiresReobservationAfter: Bool = true
    ) {
        self.key = key
        self.action = action
        self.identity = identity
        self.resourceIdentifier = resourceIdentifier
        self.desiredService = desiredService
        self.dependencies = dependencies.sorted()
        self.preconditions = preconditions.sorted { $0.orderingKey < $1.orderingKey }
        self.postconditions = postconditions.sorted { $0.orderingKey < $1.orderingKey }
        self.requiresReobservationAfter = requiresReobservationAfter
    }
}

public struct MultiServiceReconciliationWave: Equatable, Sendable {
    public let index: Int
    public let nodes: [MultiServiceLifecycleNodeDraft]
    public let requiresReobservationAfter: Bool

    public init(index: Int, nodes: [MultiServiceLifecycleNodeDraft]) {
        self.index = index
        self.nodes = nodes.sorted { $0.key < $1.key }
        self.requiresReobservationAfter = !nodes.isEmpty
    }
}

public struct MultiServiceReconciliationPlan: Equatable, Sendable {
    public let mode: MultiServiceReconciliationMode
    public let waves: [MultiServiceReconciliationWave]
    public let untouchedObservedResourceIdentifiers: [String]

    public init(
        mode: MultiServiceReconciliationMode,
        waves: [MultiServiceReconciliationWave],
        untouchedObservedResourceIdentifiers: [String]
    ) {
        self.mode = mode
        self.waves = waves
        self.untouchedObservedResourceIdentifiers = untouchedObservedResourceIdentifiers.sorted()
    }

    public var nodes: [MultiServiceLifecycleNodeDraft] {
        waves.flatMap(\.nodes)
    }

    public var mutatesRuntime: Bool {
        nodes.contains { $0.action.mutatesRuntime }
    }
}

public struct MultiServiceReconciliationPlanner: Sendable {
    public static let maximumParallelism = 32

    public let parallelism: Int

    public init(parallelism: Int = 4) throws {
        guard (1...Self.maximumParallelism).contains(parallelism) else {
            throw MultiServiceReconciliationError.invalidParallelism(parallelism)
        }
        self.parallelism = parallelism
    }

    public func plan(
        desired: DesiredRuntimeState,
        observed: ObservedRuntimeState,
        previousDesired: DesiredRuntimeState? = nil,
        mode: MultiServiceReconciliationMode = .up,
        unmanagedResourceIdentifiers: Set<String> = []
    ) throws -> MultiServiceReconciliationPlan {
        guard observed.projectName == desired.projectName else {
            throw MultiServiceReconciliationError.projectMismatch(
                expected: desired.projectName,
                actual: observed.projectName
            )
        }
        if let previousDesired, previousDesired.projectName != desired.projectName {
            throw MultiServiceReconciliationError.projectMismatch(
                expected: desired.projectName,
                actual: previousDesired.projectName
            )
        }

        let desiredTopology = try Self.validateTopology(desired)
        let previousTopology = try previousDesired.map {
            try Self.validateTopology($0, allowsEphemeralRuns: true)
        }
        let teardownTopology = Self.mergedTopology(
            current: desiredTopology,
            previous: previousTopology
        )
        let observedByIdentity = try Self.validateObservation(observed)
        let currentByIdentity = try Self.uniqueServices(desired.services)
        let previousByIdentity = try previousDesired.map {
            try Self.uniqueServices($0.services)
        } ?? [:]
        let expectedByIdentity = previousByIdentity.merging(currentByIdentity) { _, current in current }
        var expectedByResourceIdentifier: [String: RuntimeServiceIdentity] = [:]
        for service in expectedByIdentity.values {
            let resourceIdentifier = service.identity.managedResourceIdentifier
            if let existing = expectedByResourceIdentifier[resourceIdentifier],
               existing != service.identity {
                throw MultiServiceReconciliationError.unmanagedResourceCollision(
                    resourceIdentifier
                )
            }
            expectedByResourceIdentifier[resourceIdentifier] = service.identity
        }

        try Self.rejectResourceCollisions(
            observed: observed.services,
            expectedByIdentity: expectedByIdentity,
            expectedByResourceIdentifier: expectedByResourceIdentifier,
            unmanagedResourceIdentifiers: unmanagedResourceIdentifiers,
            desiredStates: [desired, previousDesired].compactMap { $0 }
        )
        if mode == .up {
            try Self.rejectUpDesiredSpecificationDrift(
                desired: currentByIdentity,
                previous: previousByIdentity,
                observed: observedByIdentity
            )
        }

        var specs: [String: NodeSpec] = [:]
        switch mode {
        case .up:
            try appendUpNodes(
                desired: desired,
                previousDesired: previousDesired,
                desiredTopology: desiredTopology,
                previousTopology: previousTopology,
                observedByIdentity: observedByIdentity,
                specs: &specs
            )
        case .down:
            let targetServices = Self.mergedServices(
                current: currentByIdentity,
                previous: previousByIdentity
            )
            let targets = targetServices.values.compactMap { service -> TeardownTarget? in
                guard let observed = observedByIdentity[service.identity],
                      observed.lifecycleState != .missing else {
                    return nil
                }
                return TeardownTarget(observed: observed, desiredService: service)
            }
            try appendTeardownNodes(
                targets: targets,
                topology: teardownTopology,
                desiredStates: [desired, previousDesired].compactMap { $0 },
                deletesResources: false,
                baseDependencies: [],
                specs: &specs
            )
        case .remove:
            let targetServices = Self.mergedServices(
                current: currentByIdentity,
                previous: previousByIdentity
            )
            let targets = targetServices.values.compactMap { service -> TeardownTarget? in
                guard let observed = observedByIdentity[service.identity],
                      observed.lifecycleState != .missing else {
                    return nil
                }
                return TeardownTarget(observed: observed, desiredService: service)
            }
            try appendTeardownNodes(
                targets: targets,
                topology: teardownTopology,
                desiredStates: [desired, previousDesired].compactMap { $0 },
                deletesResources: true,
                baseDependencies: [],
                specs: &specs
            )
        }

        let referencedIdentities = Set(expectedByIdentity.keys)
            .union(specs.values.map(\.observedIdentity))
        let untouchedObserved = observed.services
            .filter { !referencedIdentities.contains($0.identity) }
            .map(\.resourceIdentifier)
        let untouched = Set(untouchedObserved).union(unmanagedResourceIdentifiers).sorted()

        return MultiServiceReconciliationPlan(
            mode: mode,
            waves: try makeWaves(specs),
            untouchedObservedResourceIdentifiers: untouched
        )
    }

    private func appendUpNodes(
        desired: DesiredRuntimeState,
        previousDesired: DesiredRuntimeState?,
        desiredTopology: ServiceTopology,
        previousTopology: ServiceTopology?,
        observedByIdentity: [RuntimeServiceIdentity: ObservedRuntimeService],
        specs: inout [String: NodeSpec]
    ) throws {
        let orderedDesired = desired.services.sorted(by: Self.serviceOrdering)
        let completionServices = Set(
            orderedDesired.flatMap(\.dependencies)
                .filter { $0.condition == .completed }
                .map(\.serviceName)
        )
        var createKeyByIdentity: [RuntimeServiceIdentity: String] = [:]
        var startKeyByIdentity: [RuntimeServiceIdentity: String] = [:]
        var readinessPrerequisiteByIdentity: [RuntimeServiceIdentity: String] = [:]
        var readinessKeyByIdentity: [RuntimeServiceIdentity: String] = [:]

        for service in orderedDesired {
            let observed = observedByIdentity[service.identity]
            let needsCreate: Bool
            let needsStart: Bool

            switch observed?.lifecycleState {
            case nil, .missing:
                needsCreate = true
                needsStart = true
            case .created, .stopped:
                try Self.requireOwnership(
                    observed: observed!,
                    desiredStates: [desired, previousDesired].compactMap { $0 }
                )
                needsCreate = false
                needsStart = true
            case .exited:
                try Self.requireOwnership(
                    observed: observed!,
                    desiredStates: [desired, previousDesired].compactMap { $0 }
                )
                needsCreate = false
                needsStart = !completionServices.contains(service.logicalServiceName)
            case .running:
                try Self.requireOwnership(
                    observed: observed!,
                    desiredStates: [desired, previousDesired].compactMap { $0 }
                )
                needsCreate = false
                needsStart = false
            case .failed, .unknown:
                throw MultiServiceReconciliationError.unsafeObservedState(
                    identity: service.identity.displayName,
                    state: observed!.lifecycleState
                )
            }

            if needsCreate {
                let key = Self.nodeKey(action: "create", identity: service.identity)
                createKeyByIdentity[service.identity] = key
                try Self.add(
                    NodeSpec(
                        key: key,
                        action: .create,
                        desiredService: service,
                        dependencies: [],
                        preconditions: [
                            Self.condition(
                                kind: "resource-absent",
                                identity: service.identity,
                                expectedValue: "true"
                            )
                        ],
                        postconditions: [
                            Self.condition(
                                kind: "resource-present",
                                identity: service.identity,
                                expectedValue: "true"
                            )
                        ]
                    ),
                    to: &specs
                )
            }
            var probeDependency: String?
            if needsStart {
                let key = Self.nodeKey(action: "start", identity: service.identity)
                startKeyByIdentity[service.identity] = key
                let createDependency = createKeyByIdentity[service.identity].map { Set([$0]) } ?? []
                let expectedLifecycle: RuntimeLifecycleState =
                    completionServices.contains(service.logicalServiceName)
                        ? .exited
                        : .running
                try Self.add(
                    NodeSpec(
                        key: key,
                        action: .start,
                        desiredService: service,
                        dependencies: createDependency,
                        preconditions: [],
                        postconditions: [
                            Self.condition(
                                kind: "lifecycle",
                                identity: service.identity,
                                expectedValue: expectedLifecycle.rawValue
                            )
                        ]
                    ),
                    to: &specs
                )

                probeDependency = key
                if service.hooks.postStart != nil {
                    let hookKey = Self.nodeKey(
                        action: "poststart",
                        identity: service.identity
                    )
                    try Self.add(
                        NodeSpec(
                            key: hookKey,
                            action: .runHook,
                            desiredService: service,
                            dependencies: probeDependency.map { [$0] } ?? [],
                            preconditions: [],
                            postconditions: [
                                Self.condition(
                                    kind: "hook-completed",
                                    identity: service.identity,
                                    expectedValue: "postStart"
                                )
                            ]
                        ),
                        to: &specs
                    )
                    probeDependency = hookKey
                }
            }
            if service.probes.startup != nil {
                let startupKey = Self.nodeKey(
                    action: "verify-startup",
                    identity: service.identity
                )
                try Self.add(
                    NodeSpec(
                        key: startupKey,
                        action: .verify,
                        desiredService: service,
                        dependencies: probeDependency.map { [$0] } ?? [],
                        preconditions: [],
                        postconditions: [
                            Self.condition(
                                kind: "probe-startup",
                                identity: service.identity,
                                expectedValue: "succeeded"
                            )
                        ]
                    ),
                    to: &specs
                )
                probeDependency = startupKey
            }
            readinessPrerequisiteByIdentity[service.identity] = probeDependency

            // Liveness must run before readiness so an unready workload can still
            // exercise the bounded restart policy. Serializing the two checks also
            // preserves their single durable per-resource probe checkpoint.
            if service.probes.liveness != nil {
                let livenessKey = Self.nodeKey(
                    action: "verify-liveness",
                    identity: service.identity
                )
                try Self.add(
                    NodeSpec(
                        key: livenessKey,
                        action: .verify,
                        desiredService: service,
                        dependencies: probeDependency.map { [$0] } ?? [],
                        preconditions: [],
                        postconditions: [
                            Self.condition(
                                kind: "probe-liveness",
                                identity: service.identity,
                                expectedValue: "healthy"
                            )
                        ]
                    ),
                    to: &specs
                )
                probeDependency = livenessKey
            }
            if service.probes.readiness != nil {
                let readinessKey = Self.nodeKey(
                    action: "verify-ready",
                    identity: service.identity
                )
                try Self.add(
                    NodeSpec(
                        key: readinessKey,
                        action: .verify,
                        desiredService: service,
                        dependencies: probeDependency.map { [$0] } ?? [],
                        preconditions: [],
                        postconditions: [
                            Self.condition(
                                kind: "probe-readiness",
                                identity: service.identity,
                                expectedValue: "ready"
                            )
                        ]
                    ),
                    to: &specs
                )
                readinessKeyByIdentity[service.identity] = readinessKey
            }
        }

        for service in orderedDesired {
            guard let startKey = startKeyByIdentity[service.identity] else {
                continue
            }
            var startSpec = specs[startKey]!
            for dependency in service.dependencies.sorted(by: Self.dependencyOrdering) {
                let dependencyReplicas = desiredTopology.servicesByName[dependency.serviceName] ?? []
                for dependencyService in dependencyReplicas {
                    let gate = Self.condition(
                        kind: "dependency-\(dependency.condition.rawValue)",
                        identity: dependencyService.identity,
                        expectedValue: "true"
                    )
                    startSpec.preconditions.append(gate)
                    if Self.satisfies(
                        dependency.condition,
                        desired: dependencyService,
                        observed: observedByIdentity[dependencyService.identity]
                    ) {
                        continue
                    }

                    switch dependency.condition {
                    case .started:
                        guard let dependencyStartKey = startKeyByIdentity[dependencyService.identity] else {
                            throw MultiServiceReconciliationError.unsatisfiedDependency(
                                service: service.logicalServiceName,
                                dependency: dependency.serviceName,
                                condition: dependency.condition
                            )
                        }
                        startSpec.dependencies.insert(dependencyStartKey)
                    case .ready, .completed:
                        let verifyKey = dependency.condition == .ready
                            ? readinessKeyByIdentity[dependencyService.identity] ??
                                Self.nodeKey(
                                    action: "verify-ready",
                                    identity: dependencyService.identity
                                )
                            : Self.nodeKey(
                                action: "verify-completed",
                                identity: dependencyService.identity
                            )
                        if specs[verifyKey] == nil {
                            var verifyDependencies: Set<String> = []
                            if dependency.condition == .ready,
                               let readinessPrerequisite =
                                readinessPrerequisiteByIdentity[dependencyService.identity] {
                                verifyDependencies.insert(readinessPrerequisite)
                            } else if let dependencyStartKey =
                                startKeyByIdentity[dependencyService.identity] {
                                verifyDependencies.insert(dependencyStartKey)
                            }
                            try Self.add(
                                NodeSpec(
                                    key: verifyKey,
                                    action: .verify,
                                    desiredService: dependencyService,
                                    dependencies: verifyDependencies,
                                    preconditions: [],
                                    postconditions: [gate]
                                ),
                                to: &specs
                            )
                        }
                        startSpec.dependencies.insert(verifyKey)
                    }
                }
            }
            specs[startKey] = startSpec
        }

        let currentIdentities = Set(desired.services.map(\.identity))
        let explicitPreviousScaleDown = previousDesired?.services
            .filter { !currentIdentities.contains($0.identity) } ?? []
        var scaleDownTargets: [TeardownTarget] = explicitPreviousScaleDown.compactMap { service in
            observedByIdentity[service.identity].map {
                TeardownTarget(observed: $0, desiredService: service)
            }
        }

        if previousDesired == nil {
            let currentServiceNames = Set(desired.services.map(\.logicalServiceName))
            let inferred = observedByIdentity.values
                .filter {
                    !currentIdentities.contains($0.identity) &&
                        currentServiceNames.contains($0.identity.serviceName)
                }
                .map {
                    TeardownTarget(
                        observed: $0,
                        desiredService: nil,
                        logicalServiceName: $0.identity.serviceName
                    )
                }
            scaleDownTargets.append(contentsOf: inferred)
        }

        let uniqueTargets = Dictionary(
            scaleDownTargets.map { ($0.observed.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            $0.observed.identity.displayName < $1.observed.identity.displayName
        }
        if !uniqueTargets.isEmpty {
            let convergenceDependencies = Set(specs.keys)
            try appendTeardownNodes(
                targets: uniqueTargets,
                topology: previousTopology ?? desiredTopology,
                desiredStates: [desired, previousDesired].compactMap { $0 },
                deletesResources: true,
                baseDependencies: convergenceDependencies,
                specs: &specs
            )
        }
    }

    private func appendTeardownNodes(
        targets: [TeardownTarget],
        topology: ServiceTopology,
        desiredStates: [DesiredRuntimeState],
        deletesResources: Bool,
        baseDependencies: Set<String>,
        specs: inout [String: NodeSpec]
    ) throws {
        var stopKeysByService: [String: [String]] = [:]
        var stopEntryKeysByService: [String: [String]] = [:]
        var deleteKeysByService: [String: [String]] = [:]

        for target in targets.sorted(by: {
            $0.observed.identity.displayName < $1.observed.identity.displayName
        }) {
            try Self.requireOwnership(observed: target.observed, desiredStates: desiredStates)
            switch target.observed.lifecycleState {
            case .unknown:
                throw MultiServiceReconciliationError.unsafeObservedState(
                    identity: target.observed.identity.displayName,
                    state: target.observed.lifecycleState
                )
            case .missing:
                continue
            case .running:
                let stopKey = Self.nodeKey(action: "stop", identity: target.observed.identity)
                var stopDependencies = baseDependencies
                var stopEntryKey = stopKey
                if target.desiredService?.hooks.preStop != nil {
                    let preStopKey = Self.nodeKey(
                        action: "prestop",
                        identity: target.observed.identity
                    )
                    try Self.add(
                        NodeSpec(
                            key: preStopKey,
                            action: .runHook,
                            desiredService: target.desiredService,
                            observedIdentity: target.observed.identity,
                            resourceIdentifier: target.observed.resourceIdentifier,
                            dependencies: baseDependencies,
                            preconditions: [
                                Self.condition(
                                    kind: "resource-owned",
                                    identity: target.observed.identity,
                                    expectedValue: "true"
                                )
                            ],
                            postconditions: [
                                Self.condition(
                                    kind: "hook-completed",
                                    identity: target.observed.identity,
                                    expectedValue: "preStop"
                                )
                            ]
                        ),
                        to: &specs
                    )
                    stopDependencies = [preStopKey]
                    stopEntryKey = preStopKey
                }
                try Self.add(
                    NodeSpec(
                        key: stopKey,
                        action: .stop,
                        desiredService: target.desiredService,
                        observedIdentity: target.observed.identity,
                        resourceIdentifier: target.observed.resourceIdentifier,
                        dependencies: stopDependencies,
                        preconditions: [
                            Self.condition(
                                kind: "resource-owned",
                                identity: target.observed.identity,
                                expectedValue: "true"
                            )
                        ],
                        postconditions: [
                            Self.condition(
                                kind: "lifecycle",
                                identity: target.observed.identity,
                                expectedValue: RuntimeLifecycleState.stopped.rawValue
                            )
                        ]
                    ),
                    to: &specs
                )
                stopKeysByService[target.logicalServiceName, default: []].append(stopKey)
                stopEntryKeysByService[target.logicalServiceName, default: []]
                    .append(stopEntryKey)
            case .created, .stopped, .exited, .failed:
                break
            }

            if deletesResources {
                let deleteKey = Self.nodeKey(action: "delete", identity: target.observed.identity)
                var dependencies = baseDependencies
                let stopKey = Self.nodeKey(action: "stop", identity: target.observed.identity)
                if specs[stopKey] != nil {
                    dependencies.insert(stopKey)
                }
                try Self.add(
                    NodeSpec(
                        key: deleteKey,
                        action: .delete,
                        desiredService: target.desiredService,
                        observedIdentity: target.observed.identity,
                        resourceIdentifier: target.observed.resourceIdentifier,
                        dependencies: dependencies,
                        preconditions: [
                            Self.condition(
                                kind: "resource-owned",
                                identity: target.observed.identity,
                                expectedValue: "true"
                            )
                        ],
                        postconditions: [
                            Self.condition(
                                kind: "resource-absent",
                                identity: target.observed.identity,
                                expectedValue: "true"
                            )
                        ]
                    ),
                    to: &specs
                )
                deleteKeysByService[target.logicalServiceName, default: []].append(deleteKey)
            }
        }

        for (dependentService, dependencies) in topology.dependenciesByService {
            for dependency in dependencies {
                for key in stopEntryKeysByService[dependency.serviceName] ?? [] {
                    var spec = specs[key]!
                    spec.dependencies.formUnion(stopKeysByService[dependentService] ?? [])
                    specs[key] = spec
                }
                for key in deleteKeysByService[dependency.serviceName] ?? [] {
                    var spec = specs[key]!
                    spec.dependencies.formUnion(deleteKeysByService[dependentService] ?? [])
                    specs[key] = spec
                }
            }
        }
    }

    private func makeWaves(
        _ specs: [String: NodeSpec]
    ) throws -> [MultiServiceReconciliationWave] {
        for spec in specs.values {
            for dependency in spec.dependencies where specs[dependency] == nil {
                throw MultiServiceReconciliationError.invalidPlanDependency(
                    node: spec.key,
                    dependency: dependency
                )
            }
        }

        var remaining = Dictionary(
            uniqueKeysWithValues: specs.map { ($0.key, $0.value.dependencies) }
        )
        var waves: [MultiServiceReconciliationWave] = []
        while !remaining.isEmpty {
            let ready = remaining
                .filter { $0.value.isEmpty }
                .map(\.key)
                .sorted()
            guard !ready.isEmpty else {
                throw MultiServiceReconciliationError.internalPlanCycle(remaining.keys.sorted())
            }
            let selected = Array(ready.prefix(parallelism))
            let nodes = selected.map { specs[$0]!.draft }
            waves.append(MultiServiceReconciliationWave(index: waves.count, nodes: nodes))
            for key in selected {
                remaining.removeValue(forKey: key)
            }
            let selectedSet = Set(selected)
            for key in remaining.keys {
                remaining[key]?.subtract(selectedSet)
            }
        }
        return waves
    }

    private static func validateTopology(
        _ state: DesiredRuntimeState,
        allowsEphemeralRuns: Bool = false
    ) throws -> ServiceTopology {
        let servicesByIdentity = try uniqueServices(state.services)
        let topologyServices = try servicesByIdentity.values.filter { service in
            guard allowsEphemeralRuns,
                  let instanceName = service.identity.instanceName,
                  instanceName.range(
                      of: "^run-[a-f0-9]{12}$",
                      options: .regularExpression
                  ) != nil else {
                return true
            }
            guard service.replicaIndex == 0,
                  service.identity.projectName == state.projectName,
                  service.identity.serviceName == service.logicalServiceName,
                  service.dependencies.isEmpty else {
                throw MultiServiceReconciliationError.invalidReplicaSet(
                    service.logicalServiceName
                )
            }
            return false
        }
        let grouped = Dictionary(
            grouping: topologyServices,
            by: \.logicalServiceName
        )
        var dependenciesByService: [String: [RuntimeServiceDependency]] = [:]

        for (serviceName, replicas) in grouped {
            let sortedReplicas = replicas.sorted(by: serviceOrdering)
            guard !serviceName.isEmpty,
                  sortedReplicas.allSatisfy({
                      $0.logicalServiceName == serviceName &&
                          $0.identity.projectName == state.projectName &&
                          $0.identity.serviceName == serviceName &&
                          $0.identity.instanceName == (
                              $0.replicaIndex == 0
                                  ? nil
                                  : "replica-\($0.replicaIndex)"
                          ) &&
                          $0.replicaIndex >= 0
                  }),
                  sortedReplicas.map(\.replicaIndex) == Array(0..<sortedReplicas.count) else {
                throw MultiServiceReconciliationError.invalidReplicaSet(serviceName)
            }

            let canonicalDependencies = sortedReplicas[0].dependencies.sorted(by: dependencyOrdering)
            guard sortedReplicas.dropFirst().allSatisfy({
                $0.dependencies.sorted(by: dependencyOrdering) == canonicalDependencies
            }) else {
                throw MultiServiceReconciliationError.inconsistentReplicaDependencies(serviceName)
            }
            let dependencyNames = canonicalDependencies.map(\.serviceName)
            if let duplicate = Dictionary(grouping: dependencyNames, by: { $0 })
                .first(where: { $0.value.count > 1 })?.key {
                throw MultiServiceReconciliationError.duplicateDependency(
                    service: serviceName,
                    dependency: duplicate
                )
            }
            dependenciesByService[serviceName] = canonicalDependencies
        }

        for (serviceName, dependencies) in dependenciesByService {
            for dependency in dependencies where grouped[dependency.serviceName] == nil {
                throw MultiServiceReconciliationError.missingDependency(
                    service: serviceName,
                    dependency: dependency.serviceName
                )
            }
        }
        try validateAcyclic(dependenciesByService)

        return ServiceTopology(
            servicesByName: grouped.mapValues { $0.sorted(by: serviceOrdering) },
            dependenciesByService: dependenciesByService
        )
    }

    private static func mergedTopology(
        current: ServiceTopology,
        previous: ServiceTopology?
    ) -> ServiceTopology {
        guard let previous else {
            return current
        }
        return ServiceTopology(
            servicesByName: previous.servicesByName.merging(current.servicesByName) {
                _, current in current
            },
            dependenciesByService: previous.dependenciesByService.merging(
                current.dependenciesByService
            ) {
                _, current in current
            }
        )
    }

    private static func validateAcyclic(
        _ dependenciesByService: [String: [RuntimeServiceDependency]]
    ) throws {
        var remaining = dependenciesByService.mapValues {
            Set($0.map(\.serviceName))
        }
        while !remaining.isEmpty {
            let ready = remaining
                .filter { $0.value.isEmpty }
                .map(\.key)
                .sorted()
            guard !ready.isEmpty else {
                throw MultiServiceReconciliationError.dependencyCycle(remaining.keys.sorted())
            }
            let readySet = Set(ready)
            for key in ready {
                remaining.removeValue(forKey: key)
            }
            for key in remaining.keys {
                remaining[key]?.subtract(readySet)
            }
        }
    }

    private static func validateObservation(
        _ observed: ObservedRuntimeState
    ) throws -> [RuntimeServiceIdentity: ObservedRuntimeService] {
        let byIdentity = Dictionary(grouping: observed.services, by: \.identity)
        if let duplicate = byIdentity.first(where: { $0.value.count > 1 })?.key {
            throw MultiServiceReconciliationError.duplicateObservedIdentity(
                duplicate.displayName
            )
        }
        let byResource = Dictionary(grouping: observed.services, by: \.resourceIdentifier)
        if let duplicate = byResource.first(where: { $0.value.count > 1 })?.key {
            throw MultiServiceReconciliationError.duplicateObservedResourceIdentifier(
                duplicate
            )
        }
        return byIdentity.mapValues { $0[0] }
    }

    private static func uniqueServices(
        _ services: [DesiredRuntimeService]
    ) throws -> [RuntimeServiceIdentity: DesiredRuntimeService] {
        let grouped = Dictionary(grouping: services, by: \.identity)
        if let duplicate = grouped.first(where: { $0.value.count > 1 })?.key {
            throw MultiServiceReconciliationError.duplicateDesiredIdentity(
                duplicate.displayName
            )
        }
        return grouped.mapValues { $0[0] }
    }

    private static func rejectResourceCollisions(
        observed: [ObservedRuntimeService],
        expectedByIdentity: [RuntimeServiceIdentity: DesiredRuntimeService],
        expectedByResourceIdentifier: [String: RuntimeServiceIdentity],
        unmanagedResourceIdentifiers: Set<String>,
        desiredStates: [DesiredRuntimeState]
    ) throws {
        if let collision = Set(expectedByResourceIdentifier.keys)
            .intersection(unmanagedResourceIdentifiers)
            .sorted()
            .first {
            throw MultiServiceReconciliationError.unmanagedResourceCollision(collision)
        }

        for service in observed {
            if let expectedIdentity = expectedByResourceIdentifier[service.resourceIdentifier],
               expectedIdentity != service.identity {
                throw MultiServiceReconciliationError.unmanagedResourceCollision(
                    service.resourceIdentifier
                )
            }
            if expectedByIdentity[service.identity] != nil {
                guard hasExactOwnershipHint(
                        for: service,
                        desiredStates: desiredStates
                      ) else {
                    throw MultiServiceReconciliationError.unmanagedResourceCollision(
                        service.resourceIdentifier
                    )
                }
            }
        }
    }

    private static func hasExactOwnershipHint(
        for observed: ObservedRuntimeService,
        desiredStates: [DesiredRuntimeState]
    ) -> Bool {
        desiredStates
            .flatMap(\.ownedResourceHints)
            .contains { hint in
                guard hint.identity == observed.identity,
                      hint.resourceIdentifier == observed.resourceIdentifier,
                      let ownership = hint.ownership else {
                    return false
                }
                return HostwrightResourceUUID.isValid(ownership.resourceUUID) &&
                    HostwrightResourceUUID.isValid(ownership.projectUUID) &&
                    HostwrightResourceUUID.isValid(ownership.fencingToken) &&
                    ownership.resourceGeneration > 0 &&
                    ownership.projectGeneration > 0 &&
                    ownership.providerGeneration > 0 &&
                    RuntimeProviderID.knownValues.contains(ownership.providerID)
            }
    }

    private static func requireOwnership(
        observed: ObservedRuntimeService,
        desiredStates: [DesiredRuntimeState]
    ) throws {
        let hint = desiredStates
            .flatMap(\.ownedResourceHints)
            .first {
                $0.identity == observed.identity &&
                    $0.resourceIdentifier == observed.resourceIdentifier
            }
        guard let ownership = hint?.ownership,
              HostwrightResourceUUID.isValid(ownership.resourceUUID),
              HostwrightResourceUUID.isValid(ownership.projectUUID),
              HostwrightResourceUUID.isValid(ownership.fencingToken),
              ownership.resourceGeneration > 0,
              ownership.projectGeneration > 0,
              ownership.providerGeneration > 0,
              RuntimeProviderID.knownValues.contains(ownership.providerID) else {
            throw MultiServiceReconciliationError.ownershipRequired(
                observed.resourceIdentifier
            )
        }
    }

    private static func rejectUpDesiredSpecificationDrift(
        desired: [RuntimeServiceIdentity: DesiredRuntimeService],
        previous: [RuntimeServiceIdentity: DesiredRuntimeService],
        observed: [RuntimeServiceIdentity: ObservedRuntimeService]
    ) throws {
        var drifted = Set<String>()
        for service in desired.values.sorted(by: serviceOrdering) {
            guard let current = observed[service.identity] else { continue }
            switch current.lifecycleState {
            case .created, .stopped, .running, .exited:
                break
            case .missing, .failed, .unknown:
                continue
            }

            if let prior = previous[service.identity],
               try LifecycleRevisionCodec.revisionSHA256(for: prior) !=
                LifecycleRevisionCodec.revisionSHA256(for: service) {
                drifted.insert(service.identity.displayName)
                continue
            }

            if let image = current.image, image != service.image {
                drifted.insert(service.identity.displayName)
                continue
            }
            if Set(current.ports.map(stablePortKey)) !=
                Set(service.ports.map(stablePortKey)) {
                drifted.insert(service.identity.displayName)
                continue
            }
            if Set(current.mounts.map(stableMountKey)) !=
                Set(service.mounts.map(stableMountKey)) {
                drifted.insert(service.identity.displayName)
            }
        }

        let services = drifted.sorted()
        guard services.isEmpty else {
            throw MultiServiceReconciliationError
                .desiredSpecificationDriftRequiresUpdate(services)
        }
    }

    private static func stablePortKey(_ port: RuntimePortMapping) -> String {
        [
            port.bindAddress ?? "localhost",
            port.hostPort.map(String.init) ?? "",
            String(port.containerPort),
            port.protocolName.rawValue
        ].joined(separator: ":")
    }

    private static func stableMountKey(_ mount: RuntimeMountReference) -> String {
        [mount.source, mount.target, mount.access.rawValue].joined(separator: ":")
    }

    private static func satisfies(
        _ condition: RuntimeDependencyCondition,
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService?
    ) -> Bool {
        guard let observed else {
            return false
        }
        switch condition {
        case .started:
            return observed.lifecycleState == .running
        case .ready:
            guard observed.lifecycleState == .running else {
                return false
            }
            if desired.probes.readiness != nil {
                return false
            }
            if desired.healthCheck != nil {
                return observed.healthState == .healthy
            }
            return observed.healthState == .healthy ||
                observed.healthState == .notConfigured
        case .completed:
            return false
        }
    }

    private static func mergedServices(
        current: [RuntimeServiceIdentity: DesiredRuntimeService],
        previous: [RuntimeServiceIdentity: DesiredRuntimeService]
    ) -> [RuntimeServiceIdentity: DesiredRuntimeService] {
        previous.merging(current) { _, current in current }
    }

    private static func add(
        _ spec: NodeSpec,
        to specs: inout [String: NodeSpec]
    ) throws {
        guard specs.updateValue(spec, forKey: spec.key) == nil else {
            throw MultiServiceReconciliationError.duplicatePlanNode(spec.key)
        }
    }

    private static func nodeKey(
        action: String,
        identity: RuntimeServiceIdentity
    ) -> String {
        "\(action)-\(identity.managedResourceIdentifier)"
    }

    private static func condition(
        kind: String,
        identity: RuntimeServiceIdentity,
        expectedValue: String
    ) -> LifecyclePlanCondition {
        LifecyclePlanCondition(
            kind: kind,
            subject: identity.managedResourceIdentifier,
            expectedValue: expectedValue
        )
    }

    private static func serviceOrdering(
        _ lhs: DesiredRuntimeService,
        _ rhs: DesiredRuntimeService
    ) -> Bool {
        if lhs.logicalServiceName != rhs.logicalServiceName {
            return lhs.logicalServiceName < rhs.logicalServiceName
        }
        if lhs.replicaIndex != rhs.replicaIndex {
            return lhs.replicaIndex < rhs.replicaIndex
        }
        return lhs.identity.displayName < rhs.identity.displayName
    }

    private static func dependencyOrdering(
        _ lhs: RuntimeServiceDependency,
        _ rhs: RuntimeServiceDependency
    ) -> Bool {
        if lhs.serviceName != rhs.serviceName {
            return lhs.serviceName < rhs.serviceName
        }
        return lhs.condition.rawValue < rhs.condition.rawValue
    }
}

private struct ServiceTopology {
    let servicesByName: [String: [DesiredRuntimeService]]
    let dependenciesByService: [String: [RuntimeServiceDependency]]
}

private struct TeardownTarget {
    let observed: ObservedRuntimeService
    let desiredService: DesiredRuntimeService?
    let logicalServiceName: String

    init(
        observed: ObservedRuntimeService,
        desiredService: DesiredRuntimeService?,
        logicalServiceName: String? = nil
    ) {
        self.observed = observed
        self.desiredService = desiredService
        self.logicalServiceName = logicalServiceName ??
            desiredService?.logicalServiceName ??
            observed.identity.serviceName
    }
}

private struct NodeSpec {
    let key: String
    let action: LifecyclePlanAction
    let desiredService: DesiredRuntimeService?
    let observedIdentity: RuntimeServiceIdentity
    let resourceIdentifier: String
    var dependencies: Set<String>
    var preconditions: [LifecyclePlanCondition]
    let postconditions: [LifecyclePlanCondition]

    init(
        key: String,
        action: LifecyclePlanAction,
        desiredService: DesiredRuntimeService?,
        observedIdentity: RuntimeServiceIdentity? = nil,
        resourceIdentifier: String? = nil,
        dependencies: Set<String>,
        preconditions: [LifecyclePlanCondition],
        postconditions: [LifecyclePlanCondition]
    ) {
        let identity = observedIdentity ?? desiredService!.identity
        self.key = key
        self.action = action
        self.desiredService = desiredService
        self.observedIdentity = identity
        self.resourceIdentifier = resourceIdentifier ?? identity.managedResourceIdentifier
        self.dependencies = dependencies
        self.preconditions = preconditions
        self.postconditions = postconditions
    }

    var draft: MultiServiceLifecycleNodeDraft {
        MultiServiceLifecycleNodeDraft(
            key: key,
            action: action,
            identity: observedIdentity,
            resourceIdentifier: resourceIdentifier,
            desiredService: desiredService,
            dependencies: Array(dependencies),
            preconditions: preconditions,
            postconditions: postconditions
        )
    }
}
