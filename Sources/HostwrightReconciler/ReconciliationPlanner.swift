import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

public struct ReconciliationPlanner: Sendable {
    public init() {}

    public func reconcile(_ input: PlanningInput) -> ReconciliationPlan {
        DriftDetector.detect(input)
    }

    public func plan(
        manifest: HostwrightManifest,
        observedState: ObservedRuntimeState? = nil,
        policy: PlanningPolicy = .default,
        restartPolicyStates: [RuntimeServiceIdentity: RestartPolicyStateRecord] = [:],
        currentTimestamp: String? = nil
    ) -> ReconciliationPlan {
        let mapping = ManifestRuntimeMapper.map(manifest, policy: policy)
        return reconcile(
            PlanningInput(
                desiredState: mapping.desiredState,
                observedState: observedState,
                policy: policy,
                additionalIssues: mapping.issues,
                restartPolicyStates: restartPolicyStates,
                currentTimestamp: currentTimestamp
            )
        )
    }

    public func plan(desired: DesiredRuntimeState, observed: ObservedRuntimeState) -> RuntimePlan {
        let observedByIdentity = Dictionary(uniqueKeysWithValues: observed.services.map { ($0.identity, $0) })
        let desiredByIdentity = Dictionary(uniqueKeysWithValues: desired.services.map { ($0.identity, $0) })

        let createActions = desired.services
            .filter { observedByIdentity[$0.identity] == nil }
            .sorted { $0.identity.displayName < $1.identity.displayName }
            .map { service in
                PlannedRuntimeAction(
                    kind: .create,
                    identity: service.identity,
                    resourceIdentifier: service.identity.managedResourceIdentifier,
                    isDestructive: false,
                    summary: "Would create missing service \(service.identity.displayName).",
                    desiredService: service
                )
            }

        let unmanagedObserved = observed.services
            .filter { desiredByIdentity[$0.identity] == nil }
            .sorted { $0.identity.displayName < $1.identity.displayName }
            .map { "Observed service '\($0.identity.displayName)' is not in desired state; Hostwright planning does not remove it." }

        let unhealthyObserved = observed.services
            .filter { desiredByIdentity[$0.identity] != nil && $0.healthState == .unhealthy }
            .sorted { $0.identity.displayName < $1.identity.displayName }
            .map { "Observed service '\($0.identity.displayName)' is unhealthy; bounded health results require operator review." }

        return RuntimePlan(
            actions: createActions,
            warnings: unmanagedObserved + unhealthyObserved,
            capabilitySHA256: observed.capabilitySHA256
        )
    }
}

public struct ReconcilerScaffold: Sendable {
    public let stateStoreDescription: StateStoreDescription

    public init(stateStoreDescription: StateStoreDescription) {
        self.stateStoreDescription = stateStoreDescription
    }
}

public struct ManifestDryRunPlan: Equatable, Sendable {
    public let project: String
    public let services: [ManifestDryRunService]
    public let runtimeObservation: String

    public init(project: String, services: [ManifestDryRunService], runtimeObservation: String) {
        self.project = project
        self.services = services
        self.runtimeObservation = runtimeObservation
    }

    public var mutatesRuntime: Bool {
        false
    }
}

public struct ManifestDryRunService: Equatable, Sendable {
    public let name: String
    public let image: String
    public let ports: [String]

    public init(name: String, image: String, ports: [String]) {
        self.name = name
        self.image = image
        self.ports = ports
    }
}

public enum ManifestDryRunPlanner {
    public static let unavailableRuntimeObservation = "Runtime observation is not connected for CLI planning; no Apple container state was inspected."

    public static func plan(for manifest: HostwrightManifest) -> ManifestDryRunPlan {
        ManifestDryRunPlan(
            project: manifest.project ?? "<missing>",
            services: manifest.services.map { service in
                ManifestDryRunService(
                    name: service.name,
                    image: service.image ?? "<missing>",
                    ports: service.ports
                )
            },
            runtimeObservation: unavailableRuntimeObservation
        )
    }

    public static func reconciliationPlan(for manifest: HostwrightManifest, policy: PlanningPolicy = .default) -> ReconciliationPlan {
        ReconciliationPlanner().plan(manifest: manifest, observedState: nil, policy: policy)
    }
}
