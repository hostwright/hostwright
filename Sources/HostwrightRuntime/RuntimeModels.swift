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
        "hostwright-\(projectName)-\(serviceName)"
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

    public init(name: String, kind: String? = nil, address: String? = nil, gateway: String? = nil, interfaceName: String? = nil) {
        self.name = name
        self.kind = kind
        self.address = address
        self.gateway = gateway
        self.interfaceName = interfaceName
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

    public init(name: String, value: String, isSensitive: Bool = false) {
        self.name = name
        self.value = value
        self.isSensitive = isSensitive
    }

    public func redacted(using policy: RuntimeRedactionPolicy = .default) -> RuntimeEnvironmentValue {
        RuntimeEnvironmentValue(
            name: name,
            value: isSensitive || policy.isSensitiveKey(name) ? policy.replacement : policy.redact(value),
            isSensitive: isSensitive
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

public struct ObservedRuntimeService: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let image: String?
    public let lifecycleState: RuntimeLifecycleState
    public let healthState: RuntimeHealthState
    public let ports: [RuntimePortMapping]
    public let networks: [RuntimeNetworkAttachment]
    public let mounts: [RuntimeMountReference]
    public let observedAt: String?

    public init(
        identity: RuntimeServiceIdentity,
        image: String? = nil,
        lifecycleState: RuntimeLifecycleState = .unknown,
        healthState: RuntimeHealthState = .unknown,
        ports: [RuntimePortMapping] = [],
        networks: [RuntimeNetworkAttachment] = [],
        mounts: [RuntimeMountReference] = [],
        observedAt: String? = nil
    ) {
        self.identity = identity
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

    public init(projectName: String, services: [DesiredRuntimeService]) {
        self.projectName = projectName
        self.services = services
    }
}

public struct ObservedRuntimeState: Equatable, Sendable {
    public let projectName: String
    public let services: [ObservedRuntimeService]
    public let adapterMetadata: RuntimeAdapterMetadata?

    public init(projectName: String, services: [ObservedRuntimeService], adapterMetadata: RuntimeAdapterMetadata? = nil) {
        self.projectName = projectName
        self.services = services
        self.adapterMetadata = adapterMetadata
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
    public let isDestructive: Bool
    public let summary: String
    public let desiredService: DesiredRuntimeService?

    public init(
        kind: PlannedRuntimeActionKind,
        identity: RuntimeServiceIdentity,
        isDestructive: Bool,
        summary: String,
        desiredService: DesiredRuntimeService? = nil
    ) {
        self.kind = kind
        self.identity = identity
        self.isDestructive = isDestructive
        self.summary = summary
        self.desiredService = desiredService
    }
}

public struct RuntimePlan: Equatable, Sendable {
    public let actions: [PlannedRuntimeAction]
    public let warnings: [String]

    public init(actions: [PlannedRuntimeAction], warnings: [String] = []) {
        self.actions = actions
        self.warnings = warnings
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

public enum RuntimeCapability: String, Equatable, Hashable, Sendable {
    case readOnlyObservation
    case lifecycleMutation
    case logStreaming
    case healthObservation
    case cleanup
    case volumeInspection
    case networkInspection
}

public struct RuntimeAdapterMetadata: Equatable, Sendable {
    public let adapterName: String
    public let adapterVersion: String
    public let runtimeName: String
    public let runtimeVersion: String?
    public let supportsMutation: Bool
    public let capabilities: [RuntimeCapability]

    public init(
        adapterName: String,
        adapterVersion: String,
        runtimeName: String,
        runtimeVersion: String? = nil,
        supportsMutation: Bool,
        capabilities: [RuntimeCapability]
    ) {
        self.adapterName = adapterName
        self.adapterVersion = adapterVersion
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.supportsMutation = supportsMutation
        self.capabilities = capabilities
    }
}
