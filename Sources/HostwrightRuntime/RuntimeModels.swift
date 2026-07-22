import Foundation
import HostwrightCore
import HostwrightSecrets

public struct RuntimeServiceIdentity: Equatable, Hashable, Sendable {
    public let projectName: String
    public let serviceName: String
    public let instanceName: String?

    public init(projectName: String, serviceName: String, instanceName: String? = nil) {
        self.projectName = projectName
        self.serviceName = serviceName
        self.instanceName = instanceName
    }

    public var displayName: String {
        if let instanceName {
            return "\(projectName)/\(serviceName)/\(instanceName)"
        }
        return "\(projectName)/\(serviceName)"
    }

    public var managedResourceIdentifier: String {
        RuntimeManagedResourceIdentity.resourceIdentifier(for: self)
    }

    public var legacyManagedResourceIdentifier: String {
        RuntimeManagedResourceIdentity.legacyResourceIdentifier(for: self)
    }
}

public struct RuntimeOwnedResourceHint: Equatable, Sendable {
    public let resourceIdentifier: String
    public let identity: RuntimeServiceIdentity
    public let identityVersion: Int
    public let ownership: RuntimeInventoryOwnershipEvidence?

    public init(
        resourceIdentifier: String,
        identity: RuntimeServiceIdentity,
        identityVersion: Int,
        ownership: RuntimeInventoryOwnershipEvidence? = nil
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.identity = identity
        self.identityVersion = identityVersion
        self.ownership = ownership
    }
}

public enum RuntimeLifecycleState: String, Equatable, Sendable {
    case unknown
    case missing
    case created
    case running
    case stopped
    case exited
    case failed
}

public enum RuntimeHealthState: String, Equatable, Sendable {
    case unknown
    case notConfigured
    case starting
    case healthy
    case unhealthy
}

public enum RuntimeRestartPolicy: String, Equatable, Sendable {
    case no
    case onFailure
    case unlessStopped

    public var allowsManagedStart: Bool {
        self == .onFailure || self == .unlessStopped
    }
}

public struct RuntimeHealthCheckSpec: Equatable, Sendable {
    public static let defaultIntervalSeconds = 30
    public static let maximumIntervalSeconds = 86_400
    public static let defaultTimeoutSeconds = 5
    public static let maximumTimeoutSeconds = 30

    public let command: [String]
    public let intervalSeconds: Int
    public let timeout: RuntimeCommandTimeout

    public init(
        command: [String],
        intervalSeconds: Int = RuntimeHealthCheckSpec.defaultIntervalSeconds,
        timeoutSeconds: Int = RuntimeHealthCheckSpec.defaultTimeoutSeconds
    ) {
        self.command = command
        self.intervalSeconds = min(max(1, intervalSeconds), Self.maximumIntervalSeconds)
        self.timeout = RuntimeCommandTimeout(seconds: min(max(1, timeoutSeconds), Self.maximumTimeoutSeconds))
    }
}

public enum RuntimeHealthCheckStatus: String, Equatable, Sendable {
    case notConfigured
    case skipped
    case healthy
    case unhealthy
    case unknown
}

public struct RuntimeHealthCheckResult: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let status: RuntimeHealthCheckStatus
    public let exitStatus: Int32?
    public let timedOut: Bool
    public let command: [String]
    public let standardOutput: String
    public let standardError: String

    public init(
        identity: RuntimeServiceIdentity,
        status: RuntimeHealthCheckStatus,
        exitStatus: Int32?,
        timedOut: Bool,
        command: [String],
        standardOutput: String,
        standardError: String
    ) {
        self.identity = identity
        self.status = status
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.command = command
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum RuntimePortProtocol: String, Equatable, Sendable {
    case tcp
    case udp
}

public struct RuntimePortMapping: Equatable, Sendable {
    public let hostPort: Int?
    public let containerPort: Int
    public let protocolName: RuntimePortProtocol
    public let bindAddress: String?

    public init(hostPort: Int?, containerPort: Int, protocolName: RuntimePortProtocol = .tcp, bindAddress: String? = nil) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
        self.bindAddress = bindAddress
    }
}

public struct RuntimeNetworkAttachment: Equatable, Sendable {
    public let name: String
    public let kind: String?
    public let address: String?
    public let gateway: String?
    public let interfaceName: String?
    public let hostname: String?
    public let ipv4Address: String?
    public let ipv4Gateway: String?
    public let ipv6Address: String?
    public let macAddress: String?
    public let mtu: Int?

    public init(
        name: String,
        kind: String? = nil,
        address: String? = nil,
        gateway: String? = nil,
        interfaceName: String? = nil,
        hostname: String? = nil,
        ipv4Address: String? = nil,
        ipv4Gateway: String? = nil,
        ipv6Address: String? = nil,
        macAddress: String? = nil,
        mtu: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.address = address
        self.gateway = gateway
        self.interfaceName = interfaceName
        self.hostname = hostname
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Address = ipv6Address
        self.macAddress = macAddress
        self.mtu = mtu
    }
}

public enum RuntimeMountAccess: String, Equatable, Sendable {
    case readOnly
    case readWrite
    case unknown
}

public struct RuntimeMountReference: Equatable, Sendable {
    public let source: String
    public let target: String
    public let access: RuntimeMountAccess

    public init(source: String, target: String, access: RuntimeMountAccess = .unknown) {
        self.source = source
        self.target = target
        self.access = access
    }
}

public struct RuntimeEnvironmentValue: Equatable, Sendable {
    public let name: String
    public let value: String
    public let isSensitive: Bool
    public let secretReference: HostwrightSecretReference?

    public init(
        name: String,
        value: String,
        isSensitive: Bool = false,
        secretReference: HostwrightSecretReference? = nil
    ) {
        self.name = name
        self.value = value
        self.isSensitive = isSensitive
        self.secretReference = secretReference
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RuntimeEnvironmentValue {
        RuntimeEnvironmentValue(
            name: name,
            value: isSensitive || secretReference != nil || policy.isSensitiveKey(name) ? policy.replacement : policy.redact(value),
            isSensitive: isSensitive,
            secretReference: secretReference
        )
    }
}

public struct DesiredRuntimeService: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let image: String
    public let command: [String]
    public let environment: [RuntimeEnvironmentValue]
    public let ports: [RuntimePortMapping]
    public let mounts: [RuntimeMountReference]
    public let healthCheck: RuntimeHealthCheckSpec?
    public let restartPolicy: RuntimeRestartPolicy

    public init(
        identity: RuntimeServiceIdentity,
        image: String,
        command: [String] = [],
        environment: [RuntimeEnvironmentValue] = [],
        ports: [RuntimePortMapping] = [],
        mounts: [RuntimeMountReference] = [],
        healthCheck: RuntimeHealthCheckSpec? = nil,
        restartPolicy: RuntimeRestartPolicy = .no
    ) {
        self.identity = identity
        self.image = image
        self.command = command
        self.environment = environment
        self.ports = ports
        self.mounts = mounts
        self.healthCheck = healthCheck
        self.restartPolicy = restartPolicy
    }
}

public struct RuntimeLogResult: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let text: String
    public let lineLimit: Int

    public init(identity: RuntimeServiceIdentity, text: String, lineLimit: Int) {
        self.identity = identity
        self.text = text
        self.lineLimit = lineLimit
    }
}

public struct RuntimeResourceUsageSnapshot: Equatable, Sendable {
    public let resourceIdentifier: String
    public let cpuUsageMicroseconds: UInt64
    public let memoryUsageBytes: UInt64
    public let memoryLimitBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkTransmitBytes: UInt64
    public let blockReadBytes: UInt64
    public let blockWriteBytes: UInt64
    public let processCount: Int

    public init(
        resourceIdentifier: String,
        cpuUsageMicroseconds: UInt64,
        memoryUsageBytes: UInt64,
        memoryLimitBytes: UInt64,
        networkReceiveBytes: UInt64,
        networkTransmitBytes: UInt64,
        blockReadBytes: UInt64,
        blockWriteBytes: UInt64,
        processCount: Int
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkTransmitBytes = networkTransmitBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.processCount = processCount
    }
}

public struct RuntimeLocalImageEvidence: Equatable, Sendable {
    public let reference: String
    public let descriptorDigest: String
    public let variantDigest: String
    public let architecture: String
    public let operatingSystem: String

    public init(
        reference: String,
        descriptorDigest: String,
        variantDigest: String,
        architecture: String,
        operatingSystem: String
    ) {
        self.reference = reference
        self.descriptorDigest = descriptorDigest
        self.variantDigest = variantDigest
        self.architecture = architecture
        self.operatingSystem = operatingSystem
    }
}

public struct ObservedRuntimeService: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let resourceIdentifier: String
    public let image: String?
    public let lifecycleState: RuntimeLifecycleState
    public let healthState: RuntimeHealthState
    public let ports: [RuntimePortMapping]
    public let networks: [RuntimeNetworkAttachment]
    public let mounts: [RuntimeMountReference]
    public let observedAt: String?

    public init(
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        image: String? = nil,
        lifecycleState: RuntimeLifecycleState = .unknown,
        healthState: RuntimeHealthState = .unknown,
        ports: [RuntimePortMapping] = [],
        networks: [RuntimeNetworkAttachment] = [],
        mounts: [RuntimeMountReference] = [],
        observedAt: String? = nil
    ) {
        self.identity = identity
        self.resourceIdentifier = resourceIdentifier
        self.image = image
        self.lifecycleState = lifecycleState
        self.healthState = healthState
        self.ports = ports
        self.networks = networks
        self.mounts = mounts
        self.observedAt = observedAt
    }
}

public struct DesiredRuntimeState: Equatable, Sendable {
    public let projectName: String
    public let services: [DesiredRuntimeService]
    public let ownedResourceHints: [RuntimeOwnedResourceHint]

    public init(
        projectName: String,
        services: [DesiredRuntimeService],
        ownedResourceHints: [RuntimeOwnedResourceHint] = []
    ) {
        self.projectName = projectName
        self.services = services
        self.ownedResourceHints = ownedResourceHints
    }
}

public struct ObservedRuntimeState: Equatable, Sendable {
    public let projectName: String
    public let services: [ObservedRuntimeService]
    public let adapterMetadata: RuntimeAdapterMetadata?
    public let capabilitySHA256: String?

    public init(
        projectName: String,
        services: [ObservedRuntimeService],
        adapterMetadata: RuntimeAdapterMetadata? = nil,
        capabilitySHA256: String? = nil
    ) {
        self.projectName = projectName
        self.services = services
        self.adapterMetadata = adapterMetadata
        self.capabilitySHA256 = capabilitySHA256
    }
}

public enum PlannedRuntimeActionKind: String, Equatable, Sendable {
    case create
    case update
    case start
    case stop
    case restart
    case remove
    case noOp
}

public struct PlannedRuntimeAction: Equatable, Sendable {
    public let kind: PlannedRuntimeActionKind
    public let identity: RuntimeServiceIdentity
    public let resourceIdentifier: String
    public let isDestructive: Bool
    public let summary: String
    public let desiredService: DesiredRuntimeService?

    public init(
        kind: PlannedRuntimeActionKind,
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        isDestructive: Bool,
        summary: String,
        desiredService: DesiredRuntimeService? = nil
    ) {
        self.kind = kind
        self.identity = identity
        self.resourceIdentifier = resourceIdentifier
        self.isDestructive = isDestructive
        self.summary = summary
        self.desiredService = desiredService
    }
}

public struct RuntimePlan: Equatable, Sendable {
    public let actions: [PlannedRuntimeAction]
    public let warnings: [String]
    public let capabilitySHA256: String?

    public init(
        actions: [PlannedRuntimeAction],
        warnings: [String] = [],
        capabilitySHA256: String? = nil
    ) {
        self.actions = actions
        self.warnings = warnings
        self.capabilitySHA256 = capabilitySHA256
    }

    public var mutatesRuntime: Bool {
        actions.contains { $0.kind != .noOp }
    }

    public var includesDestructiveAction: Bool {
        actions.contains { $0.isDestructive }
    }
}

public enum RuntimeEventSeverity: String, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct RuntimeEvent: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity?
    public let severity: RuntimeEventSeverity
    public let message: String
    public let resourceIdentifier: String?

    public init(
        identity: RuntimeServiceIdentity?,
        severity: RuntimeEventSeverity = .info,
        message: String,
        resourceIdentifier: String? = nil
    ) {
        self.identity = identity
        self.severity = severity
        self.message = message
        self.resourceIdentifier = resourceIdentifier
    }
}

public enum RuntimeCapability: String, Codable, Equatable, Hashable, Sendable {
    case readOnlyObservation
    case lifecycleMutation
    case logStreaming
    case healthObservation
    case cleanup
    case volumeInspection
    case networkInspection
}

public struct RuntimeAdapterMetadata: Codable, Equatable, Sendable {
    public let providerAPIVersion: Int
    public let providerID: RuntimeProviderID
    public let adapterName: String
    public let adapterVersion: String
    public let runtimeName: String
    public let runtimeVersion: String?
    public let supportsMutation: Bool
    public let capabilities: [RuntimeCapability]

    public init(
        providerAPIVersion: Int = HostwrightContractVersions.runtimeProviderAPI,
        providerID: RuntimeProviderID,
        adapterName: String,
        adapterVersion: String,
        runtimeName: String,
        runtimeVersion: String? = nil,
        supportsMutation: Bool,
        capabilities: [RuntimeCapability]
    ) {
        self.providerAPIVersion = providerAPIVersion
        self.providerID = providerID
        self.adapterName = adapterName
        self.adapterVersion = adapterVersion
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.supportsMutation = supportsMutation
        self.capabilities = capabilities
    }
}

public enum RuntimeProviderCompatibility {
    public static func mutationIncompatibility(_ metadata: RuntimeAdapterMetadata) -> String? {
        guard metadata.providerAPIVersion == HostwrightContractVersions.runtimeProviderAPI else {
            return "Runtime provider \(metadata.adapterName) advertises API v\(metadata.providerAPIVersion); Hostwright requires Runtime Provider API v\(HostwrightContractVersions.runtimeProviderAPI)."
        }
        guard RuntimeProviderID.knownValues.contains(metadata.providerID) else {
            return "Runtime provider \(metadata.adapterName) advertises unsupported provider identity \(metadata.providerID.rawValue)."
        }
        guard metadata.supportsMutation else {
            return "Runtime provider \(metadata.adapterName) does not authorize lifecycle mutation."
        }
        guard metadata.capabilities.contains(.lifecycleMutation) else {
            return "Runtime provider \(metadata.adapterName) does not advertise the lifecycleMutation capability required for Hostwright mutation."
        }
        return nil
    }
}

public struct RuntimeMutationContext: Equatable, Sendable {
    public let providerAPIVersion: Int
    public let providerID: RuntimeProviderID
    public let capabilitySHA256: String
    public let operationID: String
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let projectResourceUUID: String
    public let projectGeneration: Int
    public let providerGeneration: Int
    public let fencingToken: String

    public init(
        providerAPIVersion: Int = HostwrightContractVersions.runtimeProviderAPI,
        providerID: RuntimeProviderID,
        capabilitySHA256: String,
        operationID: String,
        resourceUUID: String,
        resourceGeneration: Int,
        projectResourceUUID: String,
        projectGeneration: Int,
        providerGeneration: Int,
        fencingToken: String
    ) {
        self.providerAPIVersion = providerAPIVersion
        self.providerID = providerID
        self.capabilitySHA256 = capabilitySHA256
        self.operationID = operationID
        self.resourceUUID = resourceUUID
        self.resourceGeneration = resourceGeneration
        self.projectResourceUUID = projectResourceUUID
        self.projectGeneration = projectGeneration
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
    }

    public var validationIssue: String? {
        guard providerAPIVersion == HostwrightContractVersions.runtimeProviderAPI else {
            return "Mutation context provider API version is unsupported."
        }
        guard RuntimeProviderID.knownValues.contains(providerID) else {
            return "Mutation context provider identity is unsupported."
        }
        guard capabilitySHA256.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil else {
            return "Mutation context capability digest must be a lowercase SHA-256 value."
        }
        guard !operationID.isEmpty,
              operationID.count <= 256,
              operationID.rangeOfCharacter(from: .controlCharacters) == nil else {
            return "Mutation context operation identity is invalid."
        }
        guard HostwrightResourceUUID.isValid(resourceUUID),
              HostwrightResourceUUID.isValid(projectResourceUUID),
              HostwrightResourceUUID.isValid(fencingToken) else {
            return "Mutation context resource, project, and fencing identities must be UUIDs."
        }
        guard resourceGeneration > 0,
              projectGeneration > 0,
              providerGeneration > 0 else {
            return "Mutation context generations must be positive."
        }
        return nil
    }
}
