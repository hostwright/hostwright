public enum RuntimeProviderSelection: String, Codable, Equatable, Sendable {
    case automatic = "auto"
    case appleCLI = "apple-cli"
    case containerization

    public var explicitProviderID: RuntimeProviderID? {
        switch self {
        case .automatic:
            return nil
        case .appleCLI:
            return .appleContainerCLI
        case .containerization:
            return .appleContainerization
        }
    }
}

public enum RuntimeProviderSelectionError: Error, Equatable, Sendable {
    case unknownExistingBinding(String)
    case explicitProviderConflictsWithBinding(bound: RuntimeProviderID, requested: RuntimeProviderID)
    case providerUnavailable(RuntimeProviderID)
    case noCompatibleProvider
    case staleCapability(expectedSHA256: String, currentSHA256: String)
    case invalidPersistedProviderMetadataEvidence
    case unsupportedProviderMetadataDowngrade(persistedRevision: Int, currentRevision: Int)

    public var guidance: String {
        switch self {
        case .unknownExistingBinding:
            return "Inspect and migrate the legacy provider binding before mutation."
        case .explicitProviderConflictsWithBinding:
            return "Use hostwright runtime migrate to change a project provider."
        case .providerUnavailable:
            return "Restore the requested provider and negotiate capabilities again."
        case .noCompatibleProvider:
            return "Install a supported Apple container CLI or a fully capable Containerization helper."
        case .staleCapability:
            return "Generate a new plan from a fresh capability snapshot."
        case .invalidPersistedProviderMetadataEvidence:
            return "Repair or restore the runtime observation projection, then perform a fresh structured observation."
        case .unsupportedProviderMetadataDowngrade:
            return "Upgrade Hostwright to a version that supports the persisted provider metadata revision."
        }
    }
}

public struct RuntimeProviderSelectionResult: Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let capabilitySHA256: String
    public let preservedBinding: Bool
    public let requiresReobservation: Bool
    public let reason: String

    public init(
        providerID: RuntimeProviderID,
        capabilitySHA256: String,
        preservedBinding: Bool,
        requiresReobservation: Bool = false,
        reason: String
    ) {
        self.providerID = providerID
        self.capabilitySHA256 = capabilitySHA256
        self.preservedBinding = preservedBinding
        self.requiresReobservation = requiresReobservation
        self.reason = reason
    }
}

public enum RuntimeProviderBinding {
    public static func persistedValues(for providerID: RuntimeProviderID) -> [String] {
        switch providerID {
        case .appleContainerCLI:
            return [
                RuntimeProviderID.appleContainerCLI.rawValue,
                "AppleContainerApplyAdapter",
                "AppleContainerReadOnlyAdapter",
                "AppleContainerCLIAdapter"
            ]
        case .appleContainerization:
            return [
                RuntimeProviderID.appleContainerization.rawValue,
                "AppleContainerizationRuntimeAdapter",
                "ContainerizationRuntimeAdapter",
                "AppleContainerizationAdapter"
            ]
        default:
            return [providerID.rawValue]
        }
    }

    public static func stableID(for persistedValue: String) -> RuntimeProviderID? {
        for providerID in RuntimeProviderID.knownValues {
            if persistedValues(for: providerID).contains(persistedValue) {
                return providerID
            }
        }
        return nil
    }
}

public enum RuntimeProviderSelector {
    public static func select(
        requested: RuntimeProviderSelection,
        existingBinding: String?,
        snapshots: [RuntimeCapabilitySnapshot],
        persistedEvidence: RuntimeProviderMetadataEvidence? = nil,
        requiredFeatures: Set<RuntimeProviderFeature> = [.observation, .lifecycle]
    ) throws -> RuntimeProviderSelectionResult {
        let byID = Dictionary(grouping: snapshots, by: { $0.descriptor.providerID })
        guard byID.values.allSatisfy({ $0.count == 1 }) else {
            throw RuntimeProviderSelectionError.noCompatibleProvider
        }

        if let existingBinding {
            guard let boundID = RuntimeProviderBinding.stableID(for: existingBinding) else {
                throw RuntimeProviderSelectionError.unknownExistingBinding(existingBinding)
            }
            if let requestedID = requested.explicitProviderID, requestedID != boundID {
                throw RuntimeProviderSelectionError.explicitProviderConflictsWithBinding(
                    bound: boundID,
                    requested: requestedID
                )
            }
            try requireSupportedRevision(persistedEvidence)
            guard let snapshot = byID[boundID]?.first,
                  isCompatible(snapshot, requiredFeatures: requiredFeatures) else {
                throw RuntimeProviderSelectionError.providerUnavailable(boundID)
            }
            let recovery = try recoveryRequirement(
                persistedEvidence: persistedEvidence,
                currentCapabilitySHA256: snapshot.canonicalSHA256
            )
            return RuntimeProviderSelectionResult(
                providerID: boundID,
                capabilitySHA256: snapshot.canonicalSHA256,
                preservedBinding: true,
                requiresReobservation: recovery.required,
                reason: recovery.reason ?? "Preserved the existing project provider binding."
            )
        }

        if let requestedID = requested.explicitProviderID {
            guard let snapshot = byID[requestedID]?.first,
                  isCompatible(snapshot, requiredFeatures: requiredFeatures) else {
                throw RuntimeProviderSelectionError.providerUnavailable(requestedID)
            }
            return RuntimeProviderSelectionResult(
                providerID: requestedID,
                capabilitySHA256: snapshot.canonicalSHA256,
                preservedBinding: false,
                reason: "Selected the explicitly requested compatible provider."
            )
        }

        for providerID in [RuntimeProviderID.appleContainerCLI, .appleContainerization] {
            if let snapshot = byID[providerID]?.first,
               isCompatible(snapshot, requiredFeatures: requiredFeatures) {
                return RuntimeProviderSelectionResult(
                    providerID: providerID,
                    capabilitySHA256: snapshot.canonicalSHA256,
                    preservedBinding: false,
                    reason: providerID == .appleContainerCLI
                        ? "Selected the compatible Apple container CLI provider."
                        : "Selected the fully capable Containerization helper because the CLI provider was unavailable."
                )
            }
        }
        throw RuntimeProviderSelectionError.noCompatibleProvider
    }

    public static func requireFreshCapability(
        expectedSHA256: String,
        currentSnapshot: RuntimeCapabilitySnapshot
    ) throws {
        let current = currentSnapshot.canonicalSHA256
        guard expectedSHA256 == current else {
            throw RuntimeProviderSelectionError.staleCapability(
                expectedSHA256: expectedSHA256,
                currentSHA256: current
            )
        }
    }

    private static func isCompatible(
        _ snapshot: RuntimeCapabilitySnapshot,
        requiredFeatures: Set<RuntimeProviderFeature>
    ) -> Bool {
        RuntimeProviderCapabilityNegotiator.negotiate(
            snapshot,
            expectedProviderID: snapshot.descriptor.providerID,
            requiredFeatures: requiredFeatures.sorted { $0.rawValue < $1.rawValue }
        ).state == .available
    }

    private static func recoveryRequirement(
        persistedEvidence: RuntimeProviderMetadataEvidence?,
        currentCapabilitySHA256: String
    ) throws -> (required: Bool, reason: String?) {
        guard let persistedEvidence else {
            return (false, nil)
        }
        guard let persistedSHA256 = persistedEvidence.capabilitySHA256 else {
            return (
                true,
                "Preserved the existing project provider binding; legacy provider metadata requires a fresh structured re-observation before use."
            )
        }
        guard persistedSHA256 == currentCapabilitySHA256 else {
            return (
                true,
                "Preserved the existing project provider binding; the capability digest changed and a fresh structured re-observation is required before use."
            )
        }
        return (false, nil)
    }

    private static func requireSupportedRevision(
        _ persistedEvidence: RuntimeProviderMetadataEvidence?
    ) throws {
        guard let persistedEvidence,
              persistedEvidence.providerMetadataRevision > RuntimeProviderMetadataEvidence.currentRevision else {
            return
        }
        throw RuntimeProviderSelectionError.unsupportedProviderMetadataDowngrade(
            persistedRevision: persistedEvidence.providerMetadataRevision,
            currentRevision: RuntimeProviderMetadataEvidence.currentRevision
        )
    }
}
