import Foundation

public enum HostwrightExtensionKind: String, Equatable, Sendable {
    case policyPack
    case controlSurfaceIntegration
    case diagnosticsIntegration
    case runtimeAdapter
    case networkingProvider
    case tunnelProvider
    case schedulerIntegration
    case future
}

public enum HostwrightExtensionTrust: String, Equatable, Sendable {
    case builtIn
    case reviewedLocal
    case thirdParty
    case untrusted
}

public enum HostwrightExtensionCapability: String, Equatable, Sendable {
    case policyEvaluation
    case controlSurfaceRead
    case diagnosticsRead
    case runtimeObservation
    case runtimeMutation
    case stateRead
    case stateWrite
    case networkingConfiguration
    case tunnelExposure
    case secretResolution
    case schedulerAdvice
    case acceleratorAccess
}

public enum HostwrightExtensionBoundary: String, Equatable, Sendable {
    case runtimeAdapter
    case stateStore
    case localPolicy
    case redaction
    case auditTrail
    case confirmationGate
    case ownershipGate
    case explicitStatePath
    case localOnlyNoUpload
    case noRuntimeMutation
}

public struct HostwrightExtensionCapabilityDeclaration: Equatable, Sendable {
    public let capability: HostwrightExtensionCapability
    public let purpose: String
    public let boundaries: [HostwrightExtensionBoundary]

    public init(
        capability: HostwrightExtensionCapability,
        purpose: String,
        boundaries: [HostwrightExtensionBoundary]
    ) {
        self.capability = capability
        self.purpose = purpose
        self.boundaries = boundaries
    }
}

public struct HostwrightExtensionDeclaration: Equatable, Sendable {
    public let identifier: String
    public let kind: HostwrightExtensionKind
    public let apiVersion: Int
    public let trust: HostwrightExtensionTrust
    public let capabilities: [HostwrightExtensionCapabilityDeclaration]

    public init(
        identifier: String,
        kind: HostwrightExtensionKind,
        apiVersion: Int = 1,
        trust: HostwrightExtensionTrust,
        capabilities: [HostwrightExtensionCapabilityDeclaration]
    ) {
        self.identifier = identifier
        self.kind = kind
        self.apiVersion = apiVersion
        self.trust = trust
        self.capabilities = capabilities
    }
}

public struct ExtensionPolicyEvaluator: Equatable, Sendable {
    public init() {}

    public static let `default` = ExtensionPolicyEvaluator()

    public func evaluate(_ declaration: HostwrightExtensionDeclaration) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []
        let identifier = declaration.identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if identifier.isEmpty {
            decisions.append(
                decision(
                    identifier: declaration.identifier,
                    capability: nil,
                    reasonCode: .extensionMissingIdentity,
                    severity: .blocker,
                    message: "Extension declarations must include a stable identifier.",
                    remediation: "Declare a stable reverse-DNS or package-scoped identifier before review.",
                    detail: "identity"
                )
            )
        }

        if declaration.apiVersion != 1 {
            decisions.append(
                decision(
                    identifier: declaration.identifier,
                    capability: nil,
                    reasonCode: .extensionUnsupportedAPIVersion,
                    severity: .blocker,
                    message: "Extension declaration API version \(declaration.apiVersion) is not supported.",
                    remediation: "Use extension declaration API version 1 until a later compatibility policy is approved.",
                    detail: "apiVersion:\(declaration.apiVersion)"
                )
            )
        }

        if declaration.trust == .thirdParty || declaration.trust == .untrusted {
            decisions.append(
                decision(
                    identifier: declaration.identifier,
                    capability: nil,
                    reasonCode: .extensionUntrusted,
                    severity: .blocker,
                    message: "Extension declarations from \(declaration.trust.rawValue) sources are not executable in current core scope.",
                    remediation: "Use built-in or reviewed-local declarations only; untrusted code execution and remote registries remain unsupported.",
                    detail: "trust:\(declaration.trust.rawValue)"
                )
            )
        }

        if declaration.capabilities.isEmpty {
            decisions.append(
                decision(
                    identifier: declaration.identifier,
                    capability: nil,
                    reasonCode: .extensionNoCapabilities,
                    severity: .blocker,
                    message: "Extension declarations must include at least one explicit capability.",
                    remediation: "Declare the narrow capability being reviewed, or keep the extension out of Hostwright core.",
                    detail: "capabilities"
                )
            )
        }

        let canAllowCapabilities = !decisions.contains { $0.severity == .blocker }
        for capability in declaration.capabilities {
            decisions.append(contentsOf: evaluateCapability(capability, identifier: identifier, kind: declaration.kind, canAllow: canAllowCapabilities))
        }

        return decisions.sorted { $0.orderingKey < $1.orderingKey }
    }

    private func evaluateCapability(
        _ declaration: HostwrightExtensionCapabilityDeclaration,
        identifier: String,
        kind: HostwrightExtensionKind,
        canAllow: Bool
    ) -> [PolicyDecision] {
        var decisions: [PolicyDecision] = []
        let capability = declaration.capability

        if let unsupported = unsupportedDecision(for: capability, identifier: identifier) {
            decisions.append(unsupported)
        }

        let missing = missingBoundaries(for: capability, declared: declaration.boundaries)
        for boundary in missing {
            decisions.append(
                decision(
                    identifier: identifier,
                    capability: capability,
                    reasonCode: .extensionBoundaryMissing,
                    severity: .blocker,
                    message: "Extension capability '\(capability.rawValue)' is missing required boundary '\(boundary.rawValue)'.",
                    remediation: "Declare the boundary explicitly or split the capability into a reviewed narrower path.",
                    detail: "\(capability.rawValue):\(boundary.rawValue)"
                )
            )
        }

        if decisions.isEmpty && canAllow {
            decisions.append(
                decision(
                    identifier: identifier,
                    capability: capability,
                    reasonCode: .extensionDeclared,
                    severity: .allow,
                    message: "Extension capability '\(capability.rawValue)' is declared as a non-mutating \(kind.rawValue) path.",
                    remediation: "Keep execution behind existing Hostwright boundaries; this declaration does not load or run extension code.",
                    detail: capability.rawValue
                )
            )
        }

        return decisions
    }

    private func unsupportedDecision(
        for capability: HostwrightExtensionCapability,
        identifier: String
    ) -> PolicyDecision? {
        switch capability {
        case .policyEvaluation, .controlSurfaceRead, .diagnosticsRead, .runtimeObservation, .stateRead, .schedulerAdvice:
            return nil
        case .runtimeMutation:
            return decision(
                identifier: identifier,
                capability: capability,
                reasonCode: .extensionRuntimeMutationUnsupported,
                severity: .blocker,
                message: "Extension runtime mutation is not supported in current core scope.",
                remediation: "Use existing Hostwright apply, restart, and cleanup gates; any extension mutation path needs a separate threat model and approval.",
                detail: capability.rawValue
            )
        case .stateWrite:
            return decision(
                identifier: identifier,
                capability: capability,
                reasonCode: .extensionStateWriteUnsupported,
                severity: .blocker,
                message: "Extension state writes are not supported in current core scope.",
                remediation: "Keep SQLite writes inside HostwrightState through existing command paths.",
                detail: capability.rawValue
            )
        case .networkingConfiguration:
            return decision(
                identifier: identifier,
                capability: capability,
                reasonCode: .extensionNetworkingUnsupported,
                severity: .blocker,
                message: "Extension networking configuration is not supported in current core scope.",
                remediation: "Keep networking localhost-scoped and defer provider configuration to a separate approved issue.",
                detail: capability.rawValue
            )
        case .tunnelExposure:
            return decision(
                identifier: identifier,
                capability: capability,
                reasonCode: .extensionTunnelUnsupported,
                severity: .blocker,
                message: "Extension tunnel or public exposure is not supported in current core scope.",
                remediation: "Do not configure tunnels, DNS, reverse proxies, or cloud exposure from core.",
                detail: capability.rawValue
            )
        case .secretResolution:
            return decision(
                identifier: identifier,
                capability: capability,
                reasonCode: .extensionSecretResolutionUnsupported,
                severity: .blocker,
                message: "Extension secret resolution is not supported in current core scope.",
                remediation: "Use the existing approved secret backend injection path only.",
                detail: capability.rawValue
            )
        case .acceleratorAccess:
            return decision(
                identifier: identifier,
                capability: capability,
                reasonCode: .extensionAcceleratorUnsupported,
                severity: .blocker,
                message: "Extension accelerator access is not supported in current core scope.",
                remediation: "Defer accelerator access until a separate proof path, threat model, policy gate, and approval exist.",
                detail: capability.rawValue
            )
        }
    }

    private func missingBoundaries(
        for capability: HostwrightExtensionCapability,
        declared: [HostwrightExtensionBoundary]
    ) -> [HostwrightExtensionBoundary] {
        requiredBoundaries(for: capability).filter { boundary in
            !declared.contains(boundary)
        }
    }

    private func requiredBoundaries(for capability: HostwrightExtensionCapability) -> [HostwrightExtensionBoundary] {
        switch capability {
        case .policyEvaluation:
            return [.localPolicy, .redaction, .auditTrail, .noRuntimeMutation]
        case .controlSurfaceRead:
            return [.localPolicy, .redaction, .auditTrail, .explicitStatePath, .noRuntimeMutation]
        case .diagnosticsRead:
            return [.stateStore, .explicitStatePath, .redaction, .auditTrail, .localOnlyNoUpload, .noRuntimeMutation]
        case .runtimeObservation:
            return [.runtimeAdapter, .localPolicy, .redaction, .auditTrail, .noRuntimeMutation]
        case .stateRead:
            return [.stateStore, .explicitStatePath, .redaction, .auditTrail, .noRuntimeMutation]
        case .schedulerAdvice:
            return [.localPolicy, .redaction, .auditTrail, .noRuntimeMutation]
        case .runtimeMutation:
            return [.runtimeAdapter, .localPolicy, .redaction, .auditTrail, .confirmationGate, .ownershipGate, .explicitStatePath]
        case .stateWrite:
            return [.stateStore, .localPolicy, .redaction, .auditTrail, .explicitStatePath]
        case .networkingConfiguration:
            return [.localPolicy, .redaction, .auditTrail, .confirmationGate]
        case .tunnelExposure:
            return [.localPolicy, .redaction, .auditTrail, .confirmationGate, .localOnlyNoUpload]
        case .secretResolution:
            return [.localPolicy, .redaction, .auditTrail, .confirmationGate]
        case .acceleratorAccess:
            return [.localPolicy, .redaction, .auditTrail, .confirmationGate]
        }
    }

    private func decision(
        identifier: String,
        capability: HostwrightExtensionCapability?,
        reasonCode: PolicyReasonCode,
        severity: PolicyDecisionSeverity,
        message: String,
        remediation: String,
        detail: String
    ) -> PolicyDecision {
        PolicyDecision(
            category: .extension,
            reasonCode: reasonCode,
            severity: severity,
            subject: capability?.rawValue ?? identifier,
            message: message,
            remediation: remediation,
            stableDetailKey: "\(identifier)|\(detail)"
        )
    }
}
