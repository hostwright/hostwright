import HostwrightPolicy
import HostwrightRuntime

public struct PlanningPolicy: Equatable, Sendable {
    public let requireHealthyServices: Bool
    public let warnOnPrivilegedHostPorts: Bool
    public let privilegedHostPortThreshold: Int
    public let blockedBindAddresses: [String]
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(
        requireHealthyServices: Bool = true,
        warnOnPrivilegedHostPorts: Bool = true,
        privilegedHostPortThreshold: Int = 1_024,
        blockedBindAddresses: [String] = ["0.0.0.0", "::"],
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.requireHealthyServices = requireHealthyServices
        self.warnOnPrivilegedHostPorts = warnOnPrivilegedHostPorts
        self.privilegedHostPortThreshold = privilegedHostPortThreshold
        self.blockedBindAddresses = blockedBindAddresses
        self.redactionPolicy = redactionPolicy
    }

    public static let `default` = PlanningPolicy()

    public func evaluate(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState? = nil) -> [PlanIssue] {
        LocalPolicyEvaluator(configuration: localPolicyConfiguration)
            .evaluate(desiredState: desiredState, observedState: observedState)
            .compactMap(PlanIssue.init(policyDecision:))
            .sorted { $0.orderingKey < $1.orderingKey }
    }

    public var localPolicyConfiguration: LocalPolicyConfiguration {
        LocalPolicyConfiguration(
            requireHealthyServices: requireHealthyServices,
            warnOnPrivilegedHostPorts: warnOnPrivilegedHostPorts,
            privilegedHostPortThreshold: privilegedHostPortThreshold,
            blockedBindAddresses: blockedBindAddresses,
            redactionPolicy: redactionPolicy
        )
    }
}

private extension PlanIssue {
    init?(policyDecision: PolicyDecision) {
        guard let kind = PlanIssueKind(policyReasonCode: policyDecision.reasonCode),
              let severity = DriftSeverity(policySeverity: policyDecision.severity) else {
            return nil
        }

        self.init(
            kind: kind,
            severity: severity,
            identity: policyDecision.identity,
            message: policyDecision.message,
            stableDetailKey: policyDecision.stableDetailKey
        )
    }
}

private extension PlanIssueKind {
    init?(policyReasonCode: PolicyReasonCode) {
        switch policyReasonCode {
        case .invalidDesiredIdentity:
            self = .invalidDesiredIdentity
        case .duplicateDesiredHostPort:
            self = .duplicateDesiredHostPort
        case .observedHostPortConflict:
            self = .hostPortConflict
        case .unsafeExposure:
            self = .unsafeExposure
        case .privilegedHostPort:
            self = .privilegedHostPort
        case .ambiguousMountReference:
            self = .ambiguousVolumeReference
        case .unsafeMountSource:
            self = .unsafeVolumePath
        case .secretValueRedacted:
            self = .secretRedacted
        case .imageReferenceURLUnsupported,
             .imageDigestRequired,
             .imageDigestInvalid,
             .secretReferenceUnavailable,
             .cleanupIdentityBindingMismatch,
             .cleanupEligible,
             .cleanupNotEligible,
             .cleanupWrongResourceType,
             .cleanupWrongProject,
             .cleanupUnmanagedIdentifier,
             .cleanupMissingServiceName,
             .cleanupRuntimeAdapterUnavailable,
             .cleanupRuntimeAdapterMismatch,
             .cleanupStale,
             .cleanupAmbiguous,
             .cleanupObservedServiceMismatch,
             .cleanupRunning,
             .cleanupUnknownLifecycle,
             .cleanupMissingRuntimeResource,
             .cleanupFailedLifecycle,
             .cleanupUnownedObservedResource,
             .lifecycleSupported,
             .lifecycleUnsupported,
             .untrustedManifestUnsupportedField,
             .secureExposureUnsupported,
             .acceleratorUnsupported,
             .extensionDeclared,
             .extensionMissingIdentity,
             .extensionNoCapabilities,
             .extensionUnsupportedAPIVersion,
             .extensionUntrusted,
             .extensionBoundaryMissing,
             .extensionRuntimeMutationUnsupported,
             .extensionStateWriteUnsupported,
             .extensionNetworkingUnsupported,
             .extensionTunnelUnsupported,
             .extensionSecretResolutionUnsupported,
             .extensionAcceleratorUnsupported,
             .teamProfileDeclared,
             .teamProfileMissingIdentity,
             .teamProfileNotOptIn,
             .teamProfileUnsupportedVersion,
             .teamProfileInvalidKind,
             .teamProfileInvalidDisplayName,
             .teamProfileMissingRequiredGate,
             .teamProfileDuplicateGate,
             .teamProfileDuplicateRequirement,
             .teamRequirementDeclared,
             .teamApprovalMissingIdentity,
             .teamApprovalUnsupportedVersion,
             .teamApprovalInvalidKind,
             .teamApprovalRejected,
             .teamApprovalScopeMismatch,
             .teamApprovalInvalidTimestamp,
             .teamApprovalBindingMismatch,
             .teamApprovalRecorded:
            return nil
        }
    }
}

private extension DriftSeverity {
    init?(policySeverity: PolicyDecisionSeverity) {
        switch policySeverity {
        case .blocker:
            self = .blocker
        case .warning:
            self = .warning
        case .allow:
            return nil
        }
    }
}
