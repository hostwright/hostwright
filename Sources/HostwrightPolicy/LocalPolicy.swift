import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightNetworking
import HostwrightRuntime

public enum PolicyDecisionSeverity: String, Comparable, Equatable, Sendable {
    case blocker
    case warning
    case allow

    fileprivate var sortIndex: Int {
        switch self {
        case .blocker: 0
        case .warning: 1
        case .allow: 2
        }
    }

    public static func < (lhs: PolicyDecisionSeverity, rhs: PolicyDecisionSeverity) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }
}

public enum PolicyDecisionCategory: String, Equatable, Sendable {
    case identity
    case port
    case exposure
    case mount
    case image
    case environment
    case secret
    case cleanup
    case lifecycle
    case untrustedManifest
    case accelerator
    case `extension`
}

public enum PolicyReasonCode: String, Equatable, Sendable {
    case invalidDesiredIdentity
    case duplicateDesiredHostPort
    case observedHostPortConflict
    case privilegedHostPort
    case unsafeExposure
    case ambiguousMountReference
    case unsafeMountSource
    case secretValueRedacted
    case imageReferenceURLUnsupported
    case imageDigestRequired
    case imageDigestInvalid
    case secretReferenceUnavailable
    case cleanupEligible
    case cleanupNotEligible
    case cleanupWrongResourceType
    case cleanupWrongProject
    case cleanupUnmanagedIdentifier
    case cleanupMissingServiceName
    case cleanupRuntimeAdapterUnavailable
    case cleanupRuntimeAdapterMismatch
    case cleanupStale
    case cleanupAmbiguous
    case cleanupObservedServiceMismatch
    case cleanupRunning
    case cleanupUnknownLifecycle
    case cleanupMissingRuntimeResource
    case cleanupFailedLifecycle
    case cleanupUnownedObservedResource
    case lifecycleSupported
    case lifecycleUnsupported
    case untrustedManifestUnsupportedField
    case secureExposureUnsupported
    case acceleratorUnsupported
    case extensionDeclared
    case extensionMissingIdentity
    case extensionNoCapabilities
    case extensionUnsupportedAPIVersion
    case extensionUntrusted
    case extensionBoundaryMissing
    case extensionRuntimeMutationUnsupported
    case extensionStateWriteUnsupported
    case extensionNetworkingUnsupported
    case extensionTunnelUnsupported
    case extensionSecretResolutionUnsupported
    case extensionAcceleratorUnsupported
}

public struct PolicyDecision: Equatable, Sendable {
    public let category: PolicyDecisionCategory
    public let reasonCode: PolicyReasonCode
    public let severity: PolicyDecisionSeverity
    public let identity: RuntimeServiceIdentity?
    public let subject: String
    public let message: String
    public let remediation: String
    public let stableDetailKey: String

    public init(
        category: PolicyDecisionCategory,
        reasonCode: PolicyReasonCode,
        severity: PolicyDecisionSeverity,
        identity: RuntimeServiceIdentity? = nil,
        subject: String = "",
        message: String,
        remediation: String,
        stableDetailKey: String = ""
    ) {
        self.category = category
        self.reasonCode = reasonCode
        self.severity = severity
        self.identity = identity
        self.subject = subject
        self.message = message
        self.remediation = remediation
        self.stableDetailKey = stableDetailKey
    }

    public var orderingKey: String {
        [
            identity?.projectName ?? "",
            identity?.serviceName ?? "",
            String(format: "%03d", severity.sortIndex),
            category.rawValue,
            reasonCode.rawValue,
            stableDetailKey,
            subject
        ].joined(separator: "|")
    }
}

public struct LocalPolicyConfiguration: Equatable, Sendable {
    public let requireHealthyServices: Bool
    public let warnOnPrivilegedHostPorts: Bool
    public let privilegedHostPortThreshold: Int
    public let blockedBindAddresses: [String]
    public let redactionPolicy: RuntimeRedactionPolicy
    public let imagePolicy: HostwrightImagePolicy

    public init(
        requireHealthyServices: Bool = true,
        warnOnPrivilegedHostPorts: Bool = true,
        privilegedHostPortThreshold: Int = 1_024,
        blockedBindAddresses: [String] = ["0.0.0.0", "::"],
        redactionPolicy: RuntimeRedactionPolicy = .default,
        imagePolicy: HostwrightImagePolicy = .allowTags
    ) {
        self.requireHealthyServices = requireHealthyServices
        self.warnOnPrivilegedHostPorts = warnOnPrivilegedHostPorts
        self.privilegedHostPortThreshold = privilegedHostPortThreshold
        self.blockedBindAddresses = blockedBindAddresses
        self.redactionPolicy = redactionPolicy
        self.imagePolicy = imagePolicy
    }

    public static let `default` = LocalPolicyConfiguration()
}

public enum CleanupPolicyClassification: String, Equatable, Sendable {
    case eligible
    case ambiguous
    case stale
    case running
    case unknown
    case blocked
    case neverDelete = "never-delete"
}

public struct CleanupOwnershipPolicyInput: Equatable, Sendable {
    public let cleanupEligible: Bool
    public let resourceType: String
    public let ownershipProjectID: String?
    public let expectedProjectID: String
    public let resourceIdentifier: String
    public let serviceName: String?
    public let ownershipRuntimeAdapter: String
    public let observedAdapterName: String?
    public let observedServices: [ObservedRuntimeService]

    public init(
        cleanupEligible: Bool,
        resourceType: String,
        ownershipProjectID: String?,
        expectedProjectID: String,
        resourceIdentifier: String,
        serviceName: String?,
        ownershipRuntimeAdapter: String,
        observedAdapterName: String?,
        observedServices: [ObservedRuntimeService]
    ) {
        self.cleanupEligible = cleanupEligible
        self.resourceType = resourceType
        self.ownershipProjectID = ownershipProjectID
        self.expectedProjectID = expectedProjectID
        self.resourceIdentifier = resourceIdentifier
        self.serviceName = serviceName
        self.ownershipRuntimeAdapter = ownershipRuntimeAdapter
        self.observedAdapterName = observedAdapterName
        self.observedServices = observedServices
    }
}

public struct CleanupPolicyDecision: Equatable, Sendable {
    public let classification: CleanupPolicyClassification
    public let reason: String
    public let decision: PolicyDecision

    public init(classification: CleanupPolicyClassification, reason: String, decision: PolicyDecision) {
        self.classification = classification
        self.reason = reason
        self.decision = decision
    }
}

public struct LocalPolicyEvaluator: Equatable, Sendable {
    public let configuration: LocalPolicyConfiguration

    public init(configuration: LocalPolicyConfiguration = .default) {
        self.configuration = configuration
    }

    public static let `default` = LocalPolicyEvaluator()

    public func evaluate(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState? = nil) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []
        decisions.append(contentsOf: evaluateDesiredIdentities(desiredState))
        decisions.append(contentsOf: evaluatePorts(desiredState, observedState: observedState))
        decisions.append(contentsOf: evaluateMounts(desiredState))
        decisions.append(contentsOf: evaluateEnvironment(desiredState))
        return decisions.sorted { $0.orderingKey < $1.orderingKey }
    }

    public func evaluateImageReference(_ image: String, serviceName: String, policy: HostwrightImagePolicy? = nil) -> [PolicyDecision] {
        ImageReferencePolicy.validate(image, serviceName: serviceName, policy: policy ?? configuration.imagePolicy)
            .map { issue in
                PolicyDecision(
                    category: .image,
                    reasonCode: imageReasonCode(for: issue.message),
                    severity: .blocker,
                    subject: serviceName,
                    message: issue.message,
                    remediation: "Use an OCI image reference accepted by the configured image policy.",
                    stableDetailKey: serviceName
                )
            }
    }

    public func evaluateSecretReference(
        name: String,
        reference: String,
        isResolved: Bool,
        identity: RuntimeServiceIdentity? = nil
    ) -> [PolicyDecision] {
        guard !isResolved else {
            return []
        }

        return [
            PolicyDecision(
                category: .secret,
                reasonCode: .secretReferenceUnavailable,
                severity: .blocker,
                identity: identity,
                subject: name,
                message: "Secret reference for \(name) is unavailable; runtime mutation must fail closed.",
                remediation: "Provide an approved local secret backend or remove the secret reference before confirmed mutation.",
                stableDetailKey: name
            )
        ]
    }

    public func evaluateCleanupOwnership(_ input: CleanupOwnershipPolicyInput) -> CleanupPolicyDecision {
        if !input.cleanupEligible {
            return cleanupDecision(.neverDelete, reasonCode: .cleanupNotEligible, reason: "ownership record is not cleanup-eligible", resourceIdentifier: input.resourceIdentifier)
        }
        if input.resourceType != "container" {
            return cleanupDecision(.neverDelete, reasonCode: .cleanupWrongResourceType, reason: "resource type '\(input.resourceType)' is outside cleanup scope", resourceIdentifier: input.resourceIdentifier)
        }
        if input.ownershipProjectID != input.expectedProjectID {
            return cleanupDecision(.neverDelete, reasonCode: .cleanupWrongProject, reason: "ownership record belongs to a different project", resourceIdentifier: input.resourceIdentifier)
        }
        if !input.resourceIdentifier.hasPrefix("hostwright-") {
            return cleanupDecision(.neverDelete, reasonCode: .cleanupUnmanagedIdentifier, reason: "resource identifier is not Hostwright-managed", resourceIdentifier: input.resourceIdentifier)
        }
        guard let expectedServiceName = input.serviceName else {
            return cleanupDecision(.blocked, reasonCode: .cleanupMissingServiceName, reason: "ownership record has no service name", resourceIdentifier: input.resourceIdentifier)
        }
        guard let observedAdapterName = input.observedAdapterName else {
            return cleanupDecision(.blocked, reasonCode: .cleanupRuntimeAdapterUnavailable, reason: "runtime adapter metadata is unavailable", resourceIdentifier: input.resourceIdentifier)
        }
        if input.ownershipRuntimeAdapter != observedAdapterName {
            return cleanupDecision(.blocked, reasonCode: .cleanupRuntimeAdapterMismatch, reason: "runtime adapter mismatch: ownership=\(input.ownershipRuntimeAdapter) observed=\(observedAdapterName)", resourceIdentifier: input.resourceIdentifier)
        }
        if input.observedServices.isEmpty {
            return cleanupDecision(.stale, reasonCode: .cleanupStale, reason: "ownership record has no matching observed container", resourceIdentifier: input.resourceIdentifier)
        }
        guard input.observedServices.count == 1, let observedService = input.observedServices.first else {
            return cleanupDecision(.ambiguous, reasonCode: .cleanupAmbiguous, reason: "multiple observed containers match this resource identifier", resourceIdentifier: input.resourceIdentifier)
        }
        if observedService.identity.serviceName != expectedServiceName {
            return cleanupDecision(.blocked, reasonCode: .cleanupObservedServiceMismatch, reason: "observed service name does not match ownership record", resourceIdentifier: input.resourceIdentifier)
        }

        switch observedService.lifecycleState {
        case .created, .stopped, .exited:
            return cleanupDecision(.eligible, reasonCode: .cleanupEligible, reason: "exact Hostwright-owned non-running container", resourceIdentifier: input.resourceIdentifier)
        case .running:
            return cleanupDecision(.running, reasonCode: .cleanupRunning, reason: "running containers are never deleted by cleanup", resourceIdentifier: input.resourceIdentifier)
        case .unknown:
            return cleanupDecision(.unknown, reasonCode: .cleanupUnknownLifecycle, reason: "runtime lifecycle is unknown", resourceIdentifier: input.resourceIdentifier)
        case .missing:
            return cleanupDecision(.stale, reasonCode: .cleanupMissingRuntimeResource, reason: "runtime reports the resource as missing", resourceIdentifier: input.resourceIdentifier)
        case .failed:
            return cleanupDecision(.blocked, reasonCode: .cleanupFailedLifecycle, reason: "failed lifecycle is not cleanup-eligible until observed stopped or exited", resourceIdentifier: input.resourceIdentifier)
        }
    }

    public func evaluateObservedOnlyCleanup(resourceIdentifier: String, observedServices: [ObservedRuntimeService]) -> CleanupPolicyDecision {
        guard observedServices.count == 1 else {
            return cleanupDecision(
                .ambiguous,
                reasonCode: .cleanupAmbiguous,
                reason: "multiple observed containers share this resource identifier without a Hostwright ownership record",
                resourceIdentifier: resourceIdentifier
            )
        }

        return cleanupDecision(
            .neverDelete,
            reasonCode: .cleanupUnownedObservedResource,
            reason: "observed container has no Hostwright ownership record",
            resourceIdentifier: resourceIdentifier
        )
    }

    public func evaluateLifecycleRequest(
        action: String,
        isSupportedNarrowPath: Bool,
        identity: RuntimeServiceIdentity? = nil
    ) -> PolicyDecision {
        if isSupportedNarrowPath {
            return PolicyDecision(
                category: .lifecycle,
                reasonCode: .lifecycleSupported,
                severity: .allow,
                identity: identity,
                subject: action,
                message: "\(action) is allowed only through its existing narrow Hostwright-owned policy gate.",
                remediation: "Continue to require exact ownership, live observation, explicit state path, and operation ledgers.",
                stableDetailKey: action
            )
        }

        return PolicyDecision(
            category: .lifecycle,
            reasonCode: .lifecycleUnsupported,
            severity: .blocker,
            identity: identity,
            subject: action,
            message: "\(action) is outside the supported local lifecycle policy.",
            remediation: "Use the existing create, managed-start, managed-restart, or cleanup gates only.",
            stableDetailKey: action
        )
    }

    public func evaluateUntrustedManifestUnsupportedField(field: String, context: String) -> PolicyDecision {
        PolicyDecision(
            category: .untrustedManifest,
            reasonCode: .untrustedManifestUnsupportedField,
            severity: .blocker,
            subject: field,
            message: "Unsupported manifest field '\(field)' in \(context) is rejected by local policy.",
            remediation: "Remove the field or use a separately approved Hostwright manifest feature.",
            stableDetailKey: "\(context).\(field)"
        )
    }

    public func evaluateSecureExposureRequest(scope: String) -> PolicyDecision {
        PolicyDecision(
            category: .exposure,
            reasonCode: .secureExposureUnsupported,
            severity: .blocker,
            subject: scope,
            message: "Secure exposure scope '\(scope)' is not implemented in current local policy.",
            remediation: "Keep services localhost-scoped or defer to a separately approved exposure design.",
            stableDetailKey: scope
        )
    }

    public func evaluateAcceleratorRequest(feature: String) -> PolicyDecision {
        PolicyDecision(
            category: .accelerator,
            reasonCode: .acceleratorUnsupported,
            severity: .blocker,
            subject: feature,
            message: "Accelerator feature '\(feature)' is not supported by current local policy.",
            remediation: "Defer until a separate implementation issue, proof path, threat model, and maintainer approval exist.",
            stableDetailKey: feature
        )
    }

    private func evaluateDesiredIdentities(_ desiredState: DesiredRuntimeState) -> [PolicyDecision] {
        desiredState.services.compactMap { service in
            guard service.identity.projectName.isEmpty || service.identity.serviceName.isEmpty else {
                return nil
            }

            return PolicyDecision(
                category: .identity,
                reasonCode: .invalidDesiredIdentity,
                severity: .blocker,
                identity: service.identity,
                message: "Desired service identity must include a project and service name.",
                remediation: "Set non-empty project and service names before planning or mutation."
            )
        }
    }

    private func evaluatePorts(_ desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState?) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []
        var hostPortOwners: [String: RuntimeServiceIdentity] = [:]

        for service in desiredState.services {
            for port in service.ports {
                guard let hostPort = port.hostPort else {
                    continue
                }

                let key = NetworkBindAddressPolicy.hostPortKey(
                    bindAddress: port.bindAddress,
                    hostPort: hostPort,
                    protocolName: port.protocolName.rawValue
                )
                if let owner = hostPortOwners[key], owner != service.identity {
                    decisions.append(
                        PolicyDecision(
                            category: .port,
                            reasonCode: .duplicateDesiredHostPort,
                            severity: .blocker,
                            identity: service.identity,
                            subject: key,
                            message: "Desired host port \(hostPort) conflicts with \(owner.displayName).",
                            remediation: "Use a different host port or remove one conflicting publish.",
                            stableDetailKey: key
                        )
                    )
                } else {
                    hostPortOwners[key] = service.identity
                }

                if configuration.warnOnPrivilegedHostPorts && hostPort < configuration.privilegedHostPortThreshold {
                    decisions.append(
                        PolicyDecision(
                            category: .port,
                            reasonCode: .privilegedHostPort,
                            severity: .warning,
                            identity: service.identity,
                            subject: key,
                            message: "Desired host port \(hostPort) is privileged; confirmed create rejects privileged host ports.",
                            remediation: "Use a non-privileged host port.",
                            stableDetailKey: key
                        )
                    )
                }

                if configuration.blockedBindAddresses.contains(NetworkBindAddressPolicy.normalizedBindAddress(port.bindAddress)) {
                    decisions.append(
                        PolicyDecision(
                            category: .exposure,
                            reasonCode: .unsafeExposure,
                            severity: .blocker,
                            identity: service.identity,
                            subject: key,
                            message: "Desired bind address is broader than the first-release policy allows.",
                            remediation: "Bind the service to localhost.",
                            stableDetailKey: key
                        )
                    )
                }
            }
        }

        if let observedState {
            decisions.append(contentsOf: evaluateObservedHostPortConflicts(desiredState: desiredState, observedState: observedState))
        }

        return decisions
    }

    private func evaluateObservedHostPortConflicts(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []

        for desired in desiredState.services {
            for desiredPort in desired.ports {
                guard desiredPort.hostPort != nil else {
                    continue
                }

                for observed in observedState.services where observed.identity != desired.identity {
                    guard let conflictingPort = observed.ports.first(where: { observedPort in
                        NetworkBindAddressPolicy.hostPortsConflict(
                            lhsBindAddress: desiredPort.bindAddress,
                            lhsHostPort: desiredPort.hostPort,
                            lhsProtocolName: desiredPort.protocolName.rawValue,
                            rhsBindAddress: observedPort.bindAddress,
                            rhsHostPort: observedPort.hostPort,
                            rhsProtocolName: observedPort.protocolName.rawValue
                        )
                    }) else {
                        continue
                    }

                    let desiredHostPort = desiredPort.hostPort ?? 0
                    let detail = NetworkBindAddressPolicy.hostPortKey(
                        bindAddress: desiredPort.bindAddress,
                        hostPort: desiredHostPort,
                        protocolName: desiredPort.protocolName.rawValue
                    )
                    let observedBind = NetworkBindAddressPolicy.normalizedBindAddress(conflictingPort.bindAddress)
                    decisions.append(
                        PolicyDecision(
                            category: .port,
                            reasonCode: .observedHostPortConflict,
                            severity: .blocker,
                            identity: desired.identity,
                            subject: detail,
                            message: "Desired host port \(desiredHostPort) conflicts with observed \(observed.identity.displayName) on \(observedBind).",
                            remediation: "Free the observed host port or choose another desired host port before mutation.",
                            stableDetailKey: "\(detail)<-\(observed.identity.displayName)"
                        )
                    )
                }
            }
        }

        return decisions
    }

    private func evaluateMounts(_ desiredState: DesiredRuntimeState) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []

        for service in desiredState.services {
            for mount in service.mounts {
                if mount.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    mount.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    decisions.append(
                        PolicyDecision(
                            category: .mount,
                            reasonCode: .ambiguousMountReference,
                            severity: .blocker,
                            identity: service.identity,
                            subject: mount.target,
                            message: "Desired mount source and target must be explicit.",
                            remediation: "Provide an explicit source and target path.",
                            stableDetailKey: mount.target
                        )
                    )
                }

                if HostwrightPathPolicy.isHostRootMountSource(mount.source) ||
                    HostwrightPathPolicy.containsParentDirectoryTraversal(mount.source) {
                    decisions.append(
                        PolicyDecision(
                            category: .mount,
                            reasonCode: .unsafeMountSource,
                            severity: .blocker,
                            identity: service.identity,
                            subject: mount.target,
                            message: "Unsafe host mount source is blocked by planning policy.",
                            remediation: "Use an explicit non-root host path without parent-directory traversal.",
                            stableDetailKey: mount.target
                        )
                    )
                }
            }
        }

        return decisions
    }

    private func evaluateEnvironment(_ desiredState: DesiredRuntimeState) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []

        for service in desiredState.services {
            for value in service.environment where value.isSensitive || configuration.redactionPolicy.isSensitiveKey(value.name) {
                decisions.append(
                    PolicyDecision(
                        category: .environment,
                        reasonCode: .secretValueRedacted,
                        severity: .warning,
                        identity: service.identity,
                        subject: value.name,
                        message: "Desired environment value for \(value.name) is treated as sensitive and redacted from plans.",
                        remediation: "Use secretEnv for secret values and keep raw values out of display/state surfaces.",
                        stableDetailKey: value.name
                    )
                )
            }
        }

        return decisions
    }

    private func cleanupDecision(
        _ classification: CleanupPolicyClassification,
        reasonCode: PolicyReasonCode,
        reason: String,
        resourceIdentifier: String
    ) -> CleanupPolicyDecision {
        CleanupPolicyDecision(
            classification: classification,
            reason: reason,
            decision: PolicyDecision(
                category: .cleanup,
                reasonCode: reasonCode,
                severity: classification == .eligible ? .allow : .blocker,
                subject: resourceIdentifier,
                message: reason,
                remediation: cleanupRemediation(for: classification),
                stableDetailKey: resourceIdentifier
            )
        )
    }

    private func cleanupRemediation(for classification: CleanupPolicyClassification) -> String {
        switch classification {
        case .eligible:
            return "Proceed only through cleanup dry-run and matching confirmation token."
        case .ambiguous:
            return "Resolve duplicate runtime matches before cleanup."
        case .stale:
            return "Review state and runtime observation before attempting cleanup again."
        case .running:
            return "Stop through an approved managed path before cleanup can become eligible."
        case .unknown:
            return "Refresh observation until lifecycle is known before cleanup."
        case .blocked, .neverDelete:
            return "Do not delete this resource through Hostwright cleanup."
        }
    }

    private func imageReasonCode(for message: String) -> PolicyReasonCode {
        if message.contains("not a URL") {
            return .imageReferenceURLUnsupported
        }
        if message.contains("require-digest") {
            return .imageDigestRequired
        }
        return .imageDigestInvalid
    }
}
