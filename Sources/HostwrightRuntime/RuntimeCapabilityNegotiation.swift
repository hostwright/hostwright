import CryptoKit
import Foundation
import HostwrightCore

public struct RuntimeProviderID: Codable, Equatable, Hashable, Sendable {
    public static let appleContainerCLI = RuntimeProviderID(rawValue: "apple-container-cli")
    public static let appleContainerization = RuntimeProviderID(rawValue: "apple-containerization")
    public static let knownValues: [RuntimeProviderID] = [
        .appleContainerCLI,
        .appleContainerization
    ]

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeProviderComponentID: Codable, Equatable, Hashable, Sendable {
    public static let appleContainerCLI = RuntimeProviderComponentID(rawValue: "container")
    public static let appleContainerAPIService = RuntimeProviderComponentID(
        rawValue: "container-apiserver"
    )
    public static let appleContainerizationHelper = RuntimeProviderComponentID(
        rawValue: "hostwright-containerization-helper"
    )
    public static let containerizationHelperProtocolV1 = RuntimeProviderComponentID(
        rawValue: "hostwright-containerization-helper-protocol"
    )
    public static let appleContainerizationFramework = RuntimeProviderComponentID(
        rawValue: "apple-containerization-framework"
    )
    public static let knownValues: [RuntimeProviderComponentID] = [
        .appleContainerCLI,
        .appleContainerAPIService,
        .appleContainerizationHelper,
        .containerizationHelperProtocolV1,
        .appleContainerizationFramework
    ]

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeProviderArchitecture: Codable, Equatable, Hashable, Sendable {
    public static let arm64 = RuntimeProviderArchitecture(rawValue: "arm64")
    public static let knownValues: [RuntimeProviderArchitecture] = [.arm64]

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeProviderFeature: Codable, Equatable, Hashable, Sendable {
    public static let observation = RuntimeProviderFeature(rawValue: "observation")
    public static let lifecycle = RuntimeProviderFeature(rawValue: "lifecycle")
    public static let processControl = RuntimeProviderFeature(rawValue: "process-control")
    public static let streaming = RuntimeProviderFeature(rawValue: "streaming")
    public static let images = RuntimeProviderFeature(rawValue: "images")
    public static let networks = RuntimeProviderFeature(rawValue: "networks")
    public static let storage = RuntimeProviderFeature(rawValue: "storage")
    public static let cancellation = RuntimeProviderFeature(rawValue: "cancellation")
    public static let timeouts = RuntimeProviderFeature(rawValue: "timeouts")
    public static let errors = RuntimeProviderFeature(rawValue: "errors")
    public static let cleanup = RuntimeProviderFeature(rawValue: "cleanup")
    public static let knownValues: [RuntimeProviderFeature] = [
        .observation,
        .lifecycle,
        .processControl,
        .streaming,
        .images,
        .networks,
        .storage,
        .cancellation,
        .timeouts,
        .errors,
        .cleanup
    ]

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RuntimeProviderCapabilityState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case available
    case experimental
    case unavailable
    case degraded
    case blocked
}

public enum RuntimeProviderFeatureReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case implemented
    case qualificationIncomplete = "qualification-incomplete"
    case notImplemented = "not-implemented"
    case componentUnavailable = "component-unavailable"
    case componentVersionUnsupported = "component-version-unsupported"
    case platformUnsupported = "platform-unsupported"
    case policyBlocked = "policy-blocked"
}

public struct RuntimeProviderFeatureStatus: Codable, Equatable, Hashable, Sendable {
    public let feature: RuntimeProviderFeature
    public let state: RuntimeProviderCapabilityState
    public let reason: RuntimeProviderFeatureReason

    public init(
        feature: RuntimeProviderFeature,
        state: RuntimeProviderCapabilityState,
        reason: RuntimeProviderFeatureReason
    ) {
        self.feature = feature
        self.state = state
        self.reason = reason
    }
}

public struct RuntimeProviderMacOSVersion: Codable, Comparable, Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: RuntimeProviderMacOSVersion, rhs: RuntimeProviderMacOSVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

public enum RuntimeProviderCapabilityContract {
    public static let minimumMacOSVersion = RuntimeProviderMacOSVersion(major: 26)
    public static let helperProtocolVersion = "1"
    public static let containerizationFrameworkVersion =
        ContainerizationRuntimeAssetContract.frameworkVersion
}

public struct RuntimeProviderComponent: Codable, Equatable, Hashable, Sendable {
    public let identifier: RuntimeProviderComponentID
    public let version: String
    public let build: String
    public let fingerprint: String

    public init(
        identifier: RuntimeProviderComponentID,
        version: String,
        build: String,
        fingerprint: String
    ) {
        self.identifier = identifier
        self.version = version
        self.build = build
        self.fingerprint = fingerprint
    }
}

public struct RuntimeProviderDescriptor: Codable, Equatable, Hashable, Sendable {
    public let providerAPIVersion: Int
    public let providerID: RuntimeProviderID
    public let components: [RuntimeProviderComponent]
    public let minimumMacOSVersion: RuntimeProviderMacOSVersion
    public let supportedArchitectures: [RuntimeProviderArchitecture]

    public init(
        providerAPIVersion: Int = HostwrightContractVersions.runtimeProviderAPI,
        providerID: RuntimeProviderID,
        components: [RuntimeProviderComponent],
        minimumMacOSVersion: RuntimeProviderMacOSVersion,
        supportedArchitectures: [RuntimeProviderArchitecture]
    ) {
        self.providerAPIVersion = providerAPIVersion
        self.providerID = providerID
        self.components = components.sorted(by: Self.componentOrder)
        self.minimumMacOSVersion = minimumMacOSVersion
        self.supportedArchitectures = supportedArchitectures.sorted {
            $0.rawValue < $1.rawValue
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providerAPIVersion
        case providerID
        case components
        case minimumMacOSVersion
        case supportedArchitectures
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerAPIVersion: try values.decode(Int.self, forKey: .providerAPIVersion),
            providerID: try values.decode(RuntimeProviderID.self, forKey: .providerID),
            components: try values.decode([RuntimeProviderComponent].self, forKey: .components),
            minimumMacOSVersion: try values.decode(
                RuntimeProviderMacOSVersion.self,
                forKey: .minimumMacOSVersion
            ),
            supportedArchitectures: try values.decode(
                [RuntimeProviderArchitecture].self,
                forKey: .supportedArchitectures
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerAPIVersion, forKey: .providerAPIVersion)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(components, forKey: .components)
        try values.encode(minimumMacOSVersion, forKey: .minimumMacOSVersion)
        try values.encode(supportedArchitectures, forKey: .supportedArchitectures)
    }

    private static func componentOrder(
        _ lhs: RuntimeProviderComponent,
        _ rhs: RuntimeProviderComponent
    ) -> Bool {
        (
            lhs.identifier.rawValue,
            lhs.version,
            lhs.build,
            lhs.fingerprint
        ) < (
            rhs.identifier.rawValue,
            rhs.version,
            rhs.build,
            rhs.fingerprint
        )
    }
}

public struct RuntimeProviderHostPlatform: Codable, Equatable, Hashable, Sendable {
    public let macOSVersion: RuntimeProviderMacOSVersion
    public let macOSBuild: String
    public let architecture: RuntimeProviderArchitecture

    public init(
        macOSVersion: RuntimeProviderMacOSVersion,
        macOSBuild: String,
        architecture: RuntimeProviderArchitecture
    ) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.architecture = architecture
    }
}

public struct RuntimeCapabilitySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let descriptor: RuntimeProviderDescriptor
    public let host: RuntimeProviderHostPlatform
    public let features: [RuntimeProviderFeatureStatus]

    public init(
        schemaVersion: Int = RuntimeCapabilitySnapshot.currentSchemaVersion,
        descriptor: RuntimeProviderDescriptor,
        host: RuntimeProviderHostPlatform,
        features: [RuntimeProviderFeatureStatus]
    ) {
        self.schemaVersion = schemaVersion
        self.descriptor = descriptor
        self.host = host
        self.features = features.sorted(by: Self.featureOrder)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case descriptor
        case host
        case features
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            descriptor: try values.decode(RuntimeProviderDescriptor.self, forKey: .descriptor),
            host: try values.decode(RuntimeProviderHostPlatform.self, forKey: .host),
            features: try values.decode([RuntimeProviderFeatureStatus].self, forKey: .features)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(descriptor, forKey: .descriptor)
        try values.encode(host, forKey: .host)
        try values.encode(features, forKey: .features)
    }

    public var canonicalSHA256: String {
        var canonical = RuntimeCapabilityCanonicalEncoder()
        canonical.append("hostwright.runtime-provider-capabilities.v2")
        canonical.append("schemaVersion")
        canonical.append(schemaVersion)
        canonical.append("providerAPIVersion")
        canonical.append(descriptor.providerAPIVersion)
        canonical.append("providerID")
        canonical.append(descriptor.providerID.rawValue)

        canonical.append("components.count")
        canonical.append(descriptor.components.count)
        for component in descriptor.components {
            canonical.append("component.identifier")
            canonical.append(component.identifier.rawValue)
            canonical.append("component.version")
            canonical.append(component.version)
            canonical.append("component.build")
            canonical.append(component.build)
            canonical.append("component.fingerprint")
            canonical.append(component.fingerprint)
        }

        canonical.append("minimumMacOSVersion.major")
        canonical.append(descriptor.minimumMacOSVersion.major)
        canonical.append("minimumMacOSVersion.minor")
        canonical.append(descriptor.minimumMacOSVersion.minor)
        canonical.append("minimumMacOSVersion.patch")
        canonical.append(descriptor.minimumMacOSVersion.patch)

        canonical.append("supportedArchitectures.count")
        canonical.append(descriptor.supportedArchitectures.count)
        for architecture in descriptor.supportedArchitectures {
            canonical.append("supportedArchitecture")
            canonical.append(architecture.rawValue)
        }

        canonical.append("host.macOSVersion.major")
        canonical.append(host.macOSVersion.major)
        canonical.append("host.macOSVersion.minor")
        canonical.append(host.macOSVersion.minor)
        canonical.append("host.macOSVersion.patch")
        canonical.append(host.macOSVersion.patch)
        canonical.append("host.macOSBuild")
        canonical.append(host.macOSBuild)
        canonical.append("host.architecture")
        canonical.append(host.architecture.rawValue)

        canonical.append("features.count")
        canonical.append(features.count)
        for feature in features {
            canonical.append("feature.identifier")
            canonical.append(feature.feature.rawValue)
            canonical.append("feature.state")
            canonical.append(feature.state.rawValue)
            canonical.append("feature.reason")
            canonical.append(feature.reason.rawValue)
        }

        return SHA256.hash(data: canonical.data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func featureOrder(
        _ lhs: RuntimeProviderFeatureStatus,
        _ rhs: RuntimeProviderFeatureStatus
    ) -> Bool {
        if lhs.feature.rawValue != rhs.feature.rawValue {
            return lhs.feature.rawValue < rhs.feature.rawValue
        }
        if lhs.state.rawValue != rhs.state.rawValue {
            return lhs.state.rawValue < rhs.state.rawValue
        }
        return lhs.reason.rawValue < rhs.reason.rawValue
    }
}

public enum RuntimeProviderCompatibilityReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case snapshotSchemaUnsupported = "snapshot-schema-unsupported"
    case providerAPIUnsupported = "provider-api-unsupported"
    case providerUnknown = "provider-unknown"
    case providerMismatch = "provider-mismatch"
    case componentUnknown = "component-unknown"
    case componentDuplicate = "component-duplicate"
    case componentMissing = "component-missing"
    case componentMixed = "component-mixed"
    case componentVersionInvalid = "component-version-invalid"
    case componentVersionUnsupported = "component-version-unsupported"
    case componentBuildInvalid = "component-build-invalid"
    case componentFingerprintInvalid = "component-fingerprint-invalid"
    case macOSVersionInvalid = "macos-version-invalid"
    case macOSBuildInvalid = "macos-build-invalid"
    case macOSUnsupported = "macos-unsupported"
    case architectureUnknown = "architecture-unknown"
    case architectureDuplicate = "architecture-duplicate"
    case architectureUnsupported = "architecture-unsupported"
    case featureUnknown = "feature-unknown"
    case featureDuplicate = "feature-duplicate"
    case featureMissing = "feature-missing"
    case featureReasonInvalid = "feature-reason-invalid"
    case featureExperimental = "feature-experimental"
    case featureUnavailable = "feature-unavailable"
    case featureDegraded = "feature-degraded"
    case featureBlocked = "feature-blocked"
}

public struct RuntimeProviderCompatibilityFinding: Codable, Equatable, Hashable, Sendable {
    public let reason: RuntimeProviderCompatibilityReason
    public let feature: RuntimeProviderFeature?
    public let component: RuntimeProviderComponentID?

    public init(
        reason: RuntimeProviderCompatibilityReason,
        feature: RuntimeProviderFeature? = nil,
        component: RuntimeProviderComponentID? = nil
    ) {
        self.reason = reason
        self.feature = feature
        self.component = component
    }
}

public struct RuntimeProviderCompatibilityReport: Codable, Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let state: RuntimeProviderCapabilityState
    public let snapshotSHA256: String
    public let findings: [RuntimeProviderCompatibilityFinding]

    public init(
        providerID: RuntimeProviderID,
        state: RuntimeProviderCapabilityState,
        snapshotSHA256: String,
        findings: [RuntimeProviderCompatibilityFinding]
    ) {
        self.providerID = providerID
        self.state = state
        self.snapshotSHA256 = snapshotSHA256
        self.findings = findings
    }
}

public enum RuntimeProviderCapabilityNegotiator {
    public static func validationFindings(
        for snapshot: RuntimeCapabilitySnapshot
    ) -> [RuntimeProviderCompatibilityFinding] {
        var findings: [RuntimeProviderCompatibilityFinding] = []

        if snapshot.schemaVersion != RuntimeCapabilitySnapshot.currentSchemaVersion {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .snapshotSchemaUnsupported))
        }
        if snapshot.descriptor.providerAPIVersion != HostwrightContractVersions.runtimeProviderAPI {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .providerAPIUnsupported))
        }

        let providerIsKnown = RuntimeProviderID.knownValues.contains(snapshot.descriptor.providerID)
        if !providerIsKnown {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .providerUnknown))
        }

        findings += componentFindings(
            snapshot.descriptor.components,
            providerID: providerIsKnown ? snapshot.descriptor.providerID : nil
        )

        let minimumMacOSIsValid = valid(snapshot.descriptor.minimumMacOSVersion)
        let hostMacOSIsValid = valid(snapshot.host.macOSVersion)
        if !minimumMacOSIsValid || !hostMacOSIsValid {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .macOSVersionInvalid))
        } else if snapshot.host.macOSVersion < snapshot.descriptor.minimumMacOSVersion {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .macOSUnsupported))
        }
        if !validBuild(snapshot.host.macOSBuild) {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .macOSBuildInvalid))
        }

        let advertisedArchitectures = snapshot.descriptor.supportedArchitectures
        if Set(advertisedArchitectures).count != advertisedArchitectures.count {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .architectureDuplicate))
        }
        let knownArchitectures = Set(RuntimeProviderArchitecture.knownValues)
        if advertisedArchitectures.isEmpty ||
            advertisedArchitectures.contains(where: { !knownArchitectures.contains($0) }) ||
            !knownArchitectures.contains(snapshot.host.architecture) {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .architectureUnknown))
        }
        if knownArchitectures.contains(snapshot.host.architecture),
           !advertisedArchitectures.contains(snapshot.host.architecture) {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .architectureUnsupported))
        }

        let knownFeatures = Set(RuntimeProviderFeature.knownValues)
        var featureCounts: [RuntimeProviderFeature: Int] = [:]
        for status in snapshot.features {
            featureCounts[status.feature, default: 0] += 1
            if !knownFeatures.contains(status.feature) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(reason: .featureUnknown, feature: status.feature)
                )
            }
            if !valid(reason: status.reason, for: status.state) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(reason: .featureReasonInvalid, feature: status.feature)
                )
            }
        }
        for (feature, count) in featureCounts where count > 1 {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .featureDuplicate, feature: feature))
        }
        for feature in RuntimeProviderFeature.knownValues where featureCounts[feature] == nil {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .featureMissing, feature: feature))
        }

        return sortedUnique(findings)
    }

    public static func negotiate(
        _ snapshot: RuntimeCapabilitySnapshot,
        expectedProviderID: RuntimeProviderID,
        requiredFeatures: [RuntimeProviderFeature]
    ) -> RuntimeProviderCompatibilityReport {
        var findings = validationFindings(for: snapshot)
        if snapshot.descriptor.providerID != expectedProviderID {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .providerMismatch))
        }

        let knownFeatures = Set(RuntimeProviderFeature.knownValues)
        let requiredCounts = Dictionary(grouping: requiredFeatures, by: { $0 }).mapValues(\.count)
        for (feature, count) in requiredCounts where count > 1 {
            findings.append(RuntimeProviderCompatibilityFinding(reason: .featureDuplicate, feature: feature))
        }

        var statusByFeature: [RuntimeProviderFeature: RuntimeProviderFeatureStatus] = [:]
        for status in snapshot.features where knownFeatures.contains(status.feature) {
            if statusByFeature[status.feature] == nil {
                statusByFeature[status.feature] = status
            }
        }

        for feature in Set(requiredFeatures) {
            guard knownFeatures.contains(feature) else {
                findings.append(RuntimeProviderCompatibilityFinding(reason: .featureUnknown, feature: feature))
                continue
            }
            guard let status = statusByFeature[feature] else {
                findings.append(RuntimeProviderCompatibilityFinding(reason: .featureMissing, feature: feature))
                continue
            }
            switch status.state {
            case .available:
                break
            case .experimental:
                findings.append(RuntimeProviderCompatibilityFinding(reason: .featureExperimental, feature: feature))
            case .unavailable:
                findings.append(RuntimeProviderCompatibilityFinding(reason: .featureUnavailable, feature: feature))
            case .degraded:
                findings.append(RuntimeProviderCompatibilityFinding(reason: .featureDegraded, feature: feature))
            case .blocked:
                findings.append(RuntimeProviderCompatibilityFinding(reason: .featureBlocked, feature: feature))
            }
        }

        let orderedFindings = sortedUnique(findings)
        return RuntimeProviderCompatibilityReport(
            providerID: snapshot.descriptor.providerID,
            state: aggregateState(for: orderedFindings),
            snapshotSHA256: snapshot.canonicalSHA256,
            findings: orderedFindings
        )
    }

    private static func componentFindings(
        _ components: [RuntimeProviderComponent],
        providerID: RuntimeProviderID?
    ) -> [RuntimeProviderCompatibilityFinding] {
        var findings: [RuntimeProviderCompatibilityFinding] = []
        let knownIDs = Set(RuntimeProviderComponentID.knownValues)
        let counts = Dictionary(grouping: components, by: \.identifier).mapValues(\.count)

        for component in components {
            if !knownIDs.contains(component.identifier) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentUnknown,
                        component: component.identifier
                    )
                )
            }
            if !validComponentVersion(component.version, identifier: component.identifier) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentVersionInvalid,
                        component: component.identifier
                    )
                )
            } else if !supportedComponentVersion(component.version, identifier: component.identifier) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentVersionUnsupported,
                        component: component.identifier
                    )
                )
            }
            if !validBuild(component.build) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentBuildInvalid,
                        component: component.identifier
                    )
                )
            }
            if !validFingerprint(component.fingerprint) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentFingerprintInvalid,
                        component: component.identifier
                    )
                )
            }
        }

        for (identifier, count) in counts where count > 1 {
            findings.append(
                RuntimeProviderCompatibilityFinding(
                    reason: .componentDuplicate,
                    component: identifier
                )
            )
        }

        if let providerID {
            let required = requiredComponents(for: providerID)
            for identifier in required where counts[identifier] == nil {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentMissing,
                        component: identifier
                    )
                )
            }
            for identifier in counts.keys where knownIDs.contains(identifier) && !required.contains(identifier) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentMixed,
                        component: identifier
                    )
                )
            }

            if providerID == .appleContainerCLI,
               let cli = components.first(where: { $0.identifier == .appleContainerCLI }),
               let service = components.first(where: { $0.identifier == .appleContainerAPIService }),
               (cli.version != service.version ||
                   cli.build != service.build ||
                   !fingerprintsMatch(cli.fingerprint, service.fingerprint)) {
                findings.append(
                    RuntimeProviderCompatibilityFinding(
                        reason: .componentMixed,
                        component: .appleContainerAPIService
                    )
                )
            }
        }

        return findings
    }

    private static func requiredComponents(
        for providerID: RuntimeProviderID
    ) -> Set<RuntimeProviderComponentID> {
        switch providerID {
        case .appleContainerCLI:
            [.appleContainerCLI, .appleContainerAPIService]
        case .appleContainerization:
            [
                .appleContainerizationHelper,
                .containerizationHelperProtocolV1,
                .appleContainerizationFramework
            ]
        default:
            []
        }
    }

    private static func valid(_ version: RuntimeProviderMacOSVersion) -> Bool {
        version.major > 0 && version.minor >= 0 && version.patch >= 0
    }

    private static func validComponentVersion(
        _ value: String,
        identifier: RuntimeProviderComponentID
    ) -> Bool {
        if identifier == .containerizationHelperProtocolV1 {
            return value.utf8.count <= 64 &&
                value.range(of: "^(?:0|[1-9][0-9]*)$", options: .regularExpression) != nil
        }
        return value.utf8.count <= 64 &&
            value.range(
                of: "^(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$",
                options: .regularExpression
            ) != nil
    }

    private static func supportedComponentVersion(
        _ value: String,
        identifier: RuntimeProviderComponentID
    ) -> Bool {
        switch identifier {
        case .appleContainerCLI, .appleContainerAPIService:
            return ["1.0.0", "1.1.0"].contains(value)
        case .containerizationHelperProtocolV1:
            return value == RuntimeProviderCapabilityContract.helperProtocolVersion
        case .appleContainerizationFramework:
            return value == RuntimeProviderCapabilityContract.containerizationFrameworkVersion
        default:
            return true
        }
    }

    private static func validBuild(_ value: String) -> Bool {
        value.utf8.count <= 128 &&
            value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$",
                options: .regularExpression
            ) != nil
    }

    private static func validFingerprint(_ value: String) -> Bool {
        value == "unspecified" ||
            value.range(of: "^[a-f0-9]{7,64}$", options: .regularExpression) != nil
    }

    private static func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || (lhs != "unspecified" && rhs != "unspecified" && (
            lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
        ))
    }

    private static func valid(
        reason: RuntimeProviderFeatureReason,
        for state: RuntimeProviderCapabilityState
    ) -> Bool {
        switch state {
        case .available:
            reason == .implemented
        case .experimental:
            reason == .qualificationIncomplete
        case .unavailable:
            reason == .notImplemented || reason == .componentUnavailable
        case .degraded:
            reason == .componentUnavailable || reason == .componentVersionUnsupported
        case .blocked:
            reason == .platformUnsupported || reason == .policyBlocked
        }
    }

    private static func sortedUnique(
        _ findings: [RuntimeProviderCompatibilityFinding]
    ) -> [RuntimeProviderCompatibilityFinding] {
        Array(Set(findings)).sorted {
            if $0.reason.rawValue != $1.reason.rawValue {
                return $0.reason.rawValue < $1.reason.rawValue
            }
            if ($0.component?.rawValue ?? "") != ($1.component?.rawValue ?? "") {
                return ($0.component?.rawValue ?? "") < ($1.component?.rawValue ?? "")
            }
            return ($0.feature?.rawValue ?? "") < ($1.feature?.rawValue ?? "")
        }
    }

    private static func aggregateState(
        for findings: [RuntimeProviderCompatibilityFinding]
    ) -> RuntimeProviderCapabilityState {
        var result = RuntimeProviderCapabilityState.available
        for finding in findings {
            let candidate: RuntimeProviderCapabilityState
            switch finding.reason {
            case .featureExperimental:
                candidate = .experimental
            case .featureDegraded:
                candidate = .degraded
            case .featureUnavailable, .featureMissing:
                candidate = .unavailable
            case .featureBlocked,
                 .snapshotSchemaUnsupported,
                 .providerAPIUnsupported,
                 .providerUnknown,
                 .providerMismatch,
                 .componentUnknown,
                 .componentDuplicate,
                 .componentMissing,
                 .componentMixed,
                 .componentVersionInvalid,
                 .componentVersionUnsupported,
                 .componentBuildInvalid,
                 .componentFingerprintInvalid,
                 .macOSVersionInvalid,
                 .macOSBuildInvalid,
                 .macOSUnsupported,
                 .architectureUnknown,
                 .architectureDuplicate,
                 .architectureUnsupported,
                 .featureUnknown,
                 .featureDuplicate,
                 .featureReasonInvalid:
                candidate = .blocked
            }
            if rank(candidate) > rank(result) {
                result = candidate
            }
        }
        return result
    }

    private static func rank(_ state: RuntimeProviderCapabilityState) -> Int {
        switch state {
        case .available:
            0
        case .experimental:
            1
        case .degraded:
            2
        case .unavailable:
            3
        case .blocked:
            4
        }
    }
}

private struct RuntimeCapabilityCanonicalEncoder {
    private(set) var data = Data()

    mutating func append(_ value: Int) {
        append(String(value))
    }

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
