import HostwrightRuntime
import HostwrightState

public enum DriftDetector {
    public static func detect(_ input: PlanningInput) -> ReconciliationPlan {
        var issues = input.additionalIssues + input.policy.evaluate(desiredState: input.desiredState)
        var drift: [DriftRecord] = []
        var actions: [PlannedAction] = []

        guard let observedState = input.observedState else {
            issues.append(
                PlanIssue(
                    kind: .observationUnavailable,
                    severity: .warning,
                    identity: nil,
                    message: "Runtime observation is not connected for this plan; drift detection is incomplete."
                )
            )
            drift.append(
                DriftRecord(
                    kind: .observationUnavailable,
                    severity: .warning,
                    identity: nil,
                    reason: "No observed runtime state was supplied."
                )
            )
            return ReconciliationPlan(
                projectName: input.desiredState.projectName,
                observationConnected: false,
                issues: issues,
                drift: drift,
                actions: actions
            )
        }

        let desiredByIdentity = Dictionary(uniqueKeysWithValues: input.desiredState.services.map { ($0.identity, $0) })
        let observedGroups = Dictionary(grouping: observedState.services, by: \.identity)

        let duplicateIdentities = Set(observedGroups.filter { $0.value.count > 1 }.map(\.key))

        for (identity, services) in observedGroups where services.count > 1 {
            issues.append(
                PlanIssue(
                    kind: .duplicateObservedIdentity,
                    severity: .blocker,
                    identity: identity,
                    message: "Multiple observed services map to \(identity.displayName); Hostwright will not guess which one is authoritative.",
                    stableDetailKey: "\(services.count)"
                )
            )
            drift.append(
                DriftRecord(
                    kind: .duplicateObservedIdentity,
                    severity: .blocker,
                    identity: identity,
                    reason: "Observed runtime state contains duplicate identities.",
                    stableDetailKey: "\(services.count)"
                )
            )
        }

        let observedByIdentity = observedGroups.compactMapValues { services in
            services.count == 1 ? services[0] : nil
        }

        detectUnsupportedObservedState(observedByIdentity: observedByIdentity, issues: &issues, drift: &drift)
        detectUnmanagedObservedServices(desiredByIdentity: desiredByIdentity, observedByIdentity: observedByIdentity, drift: &drift, actions: &actions)
        detectDesiredServiceDrift(
            input.desiredState.services,
            observedByIdentity: observedByIdentity,
            duplicateObservedIdentities: duplicateIdentities,
            policy: input.policy,
            restartPolicyStates: input.restartPolicyStates,
            currentTimestamp: input.currentTimestamp,
            issues: &issues,
            drift: &drift,
            actions: &actions
        )

        return ReconciliationPlan(
            projectName: input.desiredState.projectName,
            observationConnected: true,
            issues: issues,
            drift: drift,
            actions: actions
        )
    }

    private static func detectUnsupportedObservedState(
        observedByIdentity: [RuntimeServiceIdentity: ObservedRuntimeService],
        issues: inout [PlanIssue],
        drift: inout [DriftRecord]
    ) {
        for service in observedByIdentity.values where service.lifecycleState == .unknown {
            issues.append(
                PlanIssue(
                    kind: .unsupportedObservedState,
                    severity: .warning,
                    identity: service.identity,
                    message: "Observed lifecycle state is unknown; Hostwright records drift without guessing a runtime action."
                )
            )
            drift.append(
                DriftRecord(
                    kind: .unsupportedObservedState,
                    severity: .warning,
                    identity: service.identity,
                    reason: "Observed lifecycle state is unknown."
                )
            )
        }
    }

    private static func detectUnmanagedObservedServices(
        desiredByIdentity: [RuntimeServiceIdentity: DesiredRuntimeService],
        observedByIdentity: [RuntimeServiceIdentity: ObservedRuntimeService],
        drift: inout [DriftRecord],
        actions: inout [PlannedAction]
    ) {
        for observed in observedByIdentity.values where desiredByIdentity[observed.identity] == nil {
            drift.append(
                DriftRecord(
                    kind: .unmanagedObservedService,
                    severity: .warning,
                    identity: observed.identity,
                    reason: "Observed service is not declared in desired state."
                )
            )
            actions.append(
                PlannedAction(
                    kind: .flagUnmanagedService,
                    identity: observed.identity,
                    reason: "Observed service is unmanaged; cleanup is not available from this plan.",
                    driftKind: .unmanagedObservedService
                )
            )
        }
    }

    private static func detectDesiredServiceDrift(
        _ desiredServices: [DesiredRuntimeService],
        observedByIdentity: [RuntimeServiceIdentity: ObservedRuntimeService],
        duplicateObservedIdentities: Set<RuntimeServiceIdentity>,
        policy: PlanningPolicy,
        restartPolicyStates: [RuntimeServiceIdentity: RestartPolicyStateRecord],
        currentTimestamp: String?,
        issues: inout [PlanIssue],
        drift: inout [DriftRecord],
        actions: inout [PlannedAction]
    ) {
        for desired in desiredServices {
            if duplicateObservedIdentities.contains(desired.identity) {
                continue
            }

            guard let observed = observedByIdentity[desired.identity] else {
                drift.append(
                    DriftRecord(
                        kind: .missingDesiredService,
                        severity: .warning,
                        identity: desired.identity,
                        reason: "Desired service is missing from observed runtime state."
                    )
                )
                actions.append(
                    PlannedAction(
                        kind: .createMissingService,
                        identity: desired.identity,
                        reason: "Desired service is missing; confirmed apply can create exactly one missing service.",
                        driftKind: .missingDesiredService,
                        executionAvailability: .availableForCreateMissingService
                    )
                )
                continue
            }

            detectLifecycleDrift(
                desired: desired,
                observed: observed,
                restartPolicyState: restartPolicyState(for: desired.identity, in: restartPolicyStates),
                currentTimestamp: currentTimestamp,
                issues: &issues,
                drift: &drift,
                actions: &actions
            )
            detectImageDrift(desired: desired, observed: observed, drift: &drift, actions: &actions)
            detectPortDrift(desired: desired, observed: observed, drift: &drift, actions: &actions)
            detectMountDrift(desired: desired, observed: observed, drift: &drift, actions: &actions)
            detectHealthDrift(observed, policy: policy, drift: &drift, actions: &actions)
        }
    }

    private static func detectLifecycleDrift(
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService,
        restartPolicyState: RestartPolicyStateRecord?,
        currentTimestamp: String?,
        issues: inout [PlanIssue],
        drift: inout [DriftRecord],
        actions: inout [PlannedAction]
    ) {
        switch observed.lifecycleState {
        case .running:
            return
        case .stopped, .exited, .created:
            let decision = RestartPolicyEvaluator.decision(
                desired: desired,
                state: restartPolicyState,
                currentTimestamp: currentTimestamp
            )
            drift.append(
                DriftRecord(
                    kind: .stoppedService,
                    severity: .warning,
                    identity: observed.identity,
                    reason: "Observed service lifecycle is \(observed.lifecycleState.rawValue).",
                    stableDetailKey: observed.lifecycleState.rawValue
                )
            )
            if decision.isBlocked {
                issues.append(
                    PlanIssue(
                        kind: .restartPolicyBlocked,
                        severity: .warning,
                        identity: desired.identity,
                        message: decision.reason,
                        stableDetailKey: restartPolicyState?.status.rawValue ?? "blocked"
                    )
                )
            }
            actions.append(
                PlannedAction(
                    kind: .proposeStartStoppedService,
                    identity: observed.identity,
                    reason: decision.reason,
                    driftKind: .stoppedService,
                    stableDetailKey: observed.lifecycleState.rawValue,
                    executionAvailability: decision.executionAvailability
                )
            )
        case .failed:
            drift.append(
                DriftRecord(
                    kind: .failedService,
                    severity: .error,
                    identity: observed.identity,
                    reason: "Observed service lifecycle is failed."
                )
            )
            actions.append(
                PlannedAction(
                    kind: .investigateFailedService,
                    identity: observed.identity,
                    reason: "Observed service failed; managed start is not available for failed lifecycle state.",
                    driftKind: .failedService
                )
            )
        case .missing:
            drift.append(
                DriftRecord(
                    kind: .missingDesiredService,
                    severity: .warning,
                    identity: observed.identity,
                    reason: "Observed service lifecycle reports missing."
                )
            )
            actions.append(
                PlannedAction(
                    kind: .createMissingService,
                    identity: observed.identity,
                    reason: "Observed service is missing; confirmed apply can create exactly one missing service.",
                    driftKind: .missingDesiredService,
                    executionAvailability: .availableForCreateMissingService
                )
            )
        case .unknown:
            return
        }
    }

    private static func detectImageDrift(
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService,
        drift: inout [DriftRecord],
        actions: inout [PlannedAction]
    ) {
        guard let observedImage = observed.image, observedImage != desired.image else {
            return
        }

        let detail = "\(desired.image)<-\(observedImage)"
        drift.append(
            DriftRecord(
                kind: .imageMismatch,
                severity: .warning,
                identity: desired.identity,
                reason: "Observed image differs from desired image.",
                stableDetailKey: detail
            )
        )
        actions.append(
            PlannedAction(
                kind: .replaceForImageDrift,
                identity: desired.identity,
                reason: "Image drift detected; replacement execution is not available.",
                driftKind: .imageMismatch,
                stableDetailKey: detail
            )
        )
    }

    private static func detectPortDrift(
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService,
        drift: inout [DriftRecord],
        actions: inout [PlannedAction]
    ) {
        let desiredPorts = Set(desired.ports.map(stablePortKey))
        let observedPorts = Set(observed.ports.map(stablePortKey))
        guard desiredPorts != observedPorts else {
            return
        }

        let detail = "desired=\(desiredPorts.sorted().joined(separator: ","));observed=\(observedPorts.sorted().joined(separator: ","))"
        drift.append(
            DriftRecord(
                kind: .portMismatch,
                severity: .warning,
                identity: desired.identity,
                reason: "Observed port set differs from desired port set.",
                stableDetailKey: detail
            )
        )
        actions.append(
            PlannedAction(
                kind: .reconcilePortDrift,
                identity: desired.identity,
                reason: "Port drift detected; port mutation is not available.",
                driftKind: .portMismatch,
                stableDetailKey: detail
            )
        )
    }

    private static func detectMountDrift(
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService,
        drift: inout [DriftRecord],
        actions: inout [PlannedAction]
    ) {
        let desiredMounts = Set(desired.mounts.map(stableMountKey))
        let observedMounts = Set(observed.mounts.map(stableMountKey))
        guard desiredMounts != observedMounts else {
            return
        }

        let detail = "desired=\(desiredMounts.sorted().joined(separator: ","));observed=\(observedMounts.sorted().joined(separator: ","))"
        drift.append(
            DriftRecord(
                kind: .mountMismatch,
                severity: .warning,
                identity: desired.identity,
                reason: "Observed mount set differs from desired mount set.",
                stableDetailKey: detail
            )
        )
        actions.append(
            PlannedAction(
                kind: .reconcileMountDrift,
                identity: desired.identity,
                reason: "Mount drift detected; mount mutation is not available.",
                driftKind: .mountMismatch,
                stableDetailKey: detail
            )
        )
    }

    private static func detectHealthDrift(
        _ observed: ObservedRuntimeService,
        policy: PlanningPolicy,
        drift: inout [DriftRecord],
        actions: inout [PlannedAction]
    ) {
        guard policy.requireHealthyServices else {
            return
        }

        guard observed.healthState == .unhealthy || observed.healthState == .unknown else {
            return
        }

        drift.append(
            DriftRecord(
                kind: .unhealthyService,
                severity: observed.healthState == .unhealthy ? .warning : .info,
                identity: observed.identity,
                reason: "Observed health state is \(observed.healthState.rawValue).",
                stableDetailKey: observed.healthState.rawValue
            )
        )
        actions.append(
            PlannedAction(
                kind: .investigateUnhealthyService,
                identity: observed.identity,
                reason: "Health drift detected; bounded health results are recorded for operator review.",
                driftKind: .unhealthyService,
                stableDetailKey: observed.healthState.rawValue
            )
        )
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

    private static func restartPolicyState(
        for identity: RuntimeServiceIdentity,
        in states: [RuntimeServiceIdentity: RestartPolicyStateRecord]
    ) -> RestartPolicyStateRecord? {
        states[RuntimeServiceIdentity(projectName: identity.projectName, serviceName: identity.serviceName)]
    }
}
