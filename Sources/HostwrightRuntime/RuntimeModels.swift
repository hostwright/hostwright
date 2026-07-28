import Foundation
import HostwrightCore
import HostwrightNetworking
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

public enum RuntimeHostPortAllocation: String, Equatable, Sendable {
    case fixed
    case dynamic
}

public struct RuntimePortMapping: Equatable, Sendable {
    public let hostPort: Int?
    public let containerPort: Int
    public let protocolName: RuntimePortProtocol
    public let bindAddress: String?
    public let allocation: RuntimeHostPortAllocation

    public init(
        hostPort: Int?,
        containerPort: Int,
        protocolName: RuntimePortProtocol = .tcp,
        bindAddress: String? = nil,
        allocation: RuntimeHostPortAllocation = .fixed
    ) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
        self.bindAddress = bindAddress
        self.allocation = allocation
    }
}

public enum RuntimeUnixSocketMode:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case ownerOnly = "0600"
    case ownerAndGroup = "0660"

    public var fileMode: UInt16 {
        switch self {
        case .ownerOnly:
            return 0o600
        case .ownerAndGroup:
            return 0o660
        }
    }
}

public struct RuntimeUnixSocketPublication:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let hostPath: String
    public let containerPath: String
    public let mode: RuntimeUnixSocketMode

    public init(
        hostPath: String,
        containerPath: String,
        mode: RuntimeUnixSocketMode = .ownerOnly
    ) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.mode = mode
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

public enum RuntimeMountKind: String, Equatable, Sendable {
    case bind
    case volume
    case tmpfs
}

public struct RuntimeMountReference: Equatable, Sendable {
    public let source: String
    public let target: String
    public let kind: RuntimeMountKind
    public let access: RuntimeMountAccess
    public let mode: String?
    public let sizeBytes: UInt64?

    public init(
        source: String,
        target: String,
        kind: RuntimeMountKind = .bind,
        access: RuntimeMountAccess = .unknown,
        mode: String? = nil,
        sizeBytes: UInt64? = nil
    ) {
        self.source = source
        self.target = target
        self.kind = kind
        self.access = access
        self.mode = mode
        self.sizeBytes = sizeBytes
    }

    public init(source: String, target: String, access: RuntimeMountAccess = .unknown) {
        self.init(
            source: source,
            target: target,
            kind: .bind,
            access: access,
            mode: nil,
            sizeBytes: nil
        )
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

public enum RuntimeDependencyCondition: String, Codable, Equatable, Sendable {
    case started
    case ready
    case completed
}

public struct RuntimeServiceDependency: Codable, Equatable, Sendable {
    public let serviceName: String
    public let condition: RuntimeDependencyCondition

    public init(serviceName: String, condition: RuntimeDependencyCondition) {
        self.serviceName = serviceName
        self.condition = condition
    }
}

public enum RuntimeProbeKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case startup
    case readiness
    case liveness

    public var order: Int {
        switch self {
        case .startup: 0
        case .readiness: 1
        case .liveness: 2
        }
    }
}

public enum RuntimeProbeActionKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case exec
    case http
    case tcp
}

public struct RuntimeProbeExecAction: Codable, Equatable, Sendable {
    public let command: [String]

    public init(command: [String]) {
        self.command = command
    }
}

public struct RuntimeProbeHTTPAction: Codable, Equatable, Sendable {
    public let port: Int
    public let path: String

    public init(port: Int, path: String = "/") {
        self.port = port
        self.path = path
    }

    public var implicitLoopbackURL: URL? {
        URL(string: "http://127.0.0.1:\(port)\(path)")
    }
}

public struct RuntimeProbeTCPAction: Codable, Equatable, Sendable {
    public let port: Int

    public init(port: Int) {
        self.port = port
    }
}

public enum RuntimeProbeAction: Codable, Equatable, Sendable {
    case exec(RuntimeProbeExecAction)
    case http(RuntimeProbeHTTPAction)
    case tcp(RuntimeProbeTCPAction)

    public var kind: RuntimeProbeActionKind {
        switch self {
        case .exec: .exec
        case .http: .http
        case .tcp: .tcp
        }
    }
}

public struct RuntimeProbeConfiguration: Codable, Equatable, Sendable {
    public let action: RuntimeProbeAction
    public let startPeriodSeconds: Int
    public let intervalSeconds: Int
    public let timeoutSeconds: Int
    public let successThreshold: Int
    public let failureThreshold: Int

    public init(
        action: RuntimeProbeAction,
        startPeriodSeconds: Int = 0,
        intervalSeconds: Int = 30,
        timeoutSeconds: Int = 5,
        successThreshold: Int = 1,
        failureThreshold: Int = 3
    ) {
        self.action = action
        self.startPeriodSeconds = startPeriodSeconds
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.successThreshold = successThreshold
        self.failureThreshold = failureThreshold
    }
}

public struct RuntimeProbeSet: Codable, Equatable, Sendable {
    public let startup: RuntimeProbeConfiguration?
    public let readiness: RuntimeProbeConfiguration?
    public let liveness: RuntimeProbeConfiguration?

    public init(
        startup: RuntimeProbeConfiguration? = nil,
        readiness: RuntimeProbeConfiguration? = nil,
        liveness: RuntimeProbeConfiguration? = nil
    ) {
        self.startup = startup
        self.readiness = readiness
        self.liveness = liveness
    }

    public subscript(kind: RuntimeProbeKind) -> RuntimeProbeConfiguration? {
        switch kind {
        case .startup: startup
        case .readiness: readiness
        case .liveness: liveness
        }
    }

    public var configuredKinds: [RuntimeProbeKind] {
        RuntimeProbeKind.allCases.filter { self[$0] != nil }
    }
}

public enum RuntimeUpdateStrategy: String, Codable, Equatable, Sendable {
    case rolling
    case recreate
}

public struct RuntimeUpdatePolicy: Codable, Equatable, Sendable {
    public let strategy: RuntimeUpdateStrategy
    public let maxSurge: Int
    public let maxUnavailable: Int
    public let progressDeadlineSeconds: Int

    public init(
        strategy: RuntimeUpdateStrategy = .rolling,
        maxSurge: Int = 1,
        maxUnavailable: Int = 0,
        progressDeadlineSeconds: Int = 300
    ) {
        self.strategy = strategy
        self.maxSurge = maxSurge
        self.maxUnavailable = maxUnavailable
        self.progressDeadlineSeconds = progressDeadlineSeconds
    }
}

public struct RuntimeLifecycleHooks: Codable, Equatable, Sendable {
    public let postStart: [String]?
    public let preStop: [String]?

    public init(postStart: [String]? = nil, preStop: [String]? = nil) {
        self.postStart = postStart
        self.preStop = preStop
    }
}

public struct DesiredRuntimeService: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let logicalServiceName: String
    public let replicaIndex: Int
    public let image: String
    public let imageLock: RuntimeImageDigestLock?
    public let platformOperatingSystem: String
    public let platformArchitecture: String
    public let cpuCount: Int?
    public let memoryBytes: UInt64?
    public let userID: UInt32?
    public let groupID: UInt32?
    public let workingDirectory: String?
    public let entrypoint: [String]
    public let command: [String]
    public let initProcess: Bool
    public let dependencies: [RuntimeServiceDependency]
    public let environment: [RuntimeEnvironmentValue]
    public let labels: [String: String]
    public let ports: [RuntimePortMapping]
    public let publishedSockets: [RuntimeUnixSocketPublication]
    public let hostAccess: [HostwrightHostAccessEndpoint]
    public let networks: [RuntimeDesiredNetworkAttachment]
    public let mounts: [RuntimeMountReference]
    public let healthCheck: RuntimeHealthCheckSpec?
    public let probes: RuntimeProbeSet
    public let restartPolicy: RuntimeRestartPolicy
    public let updatePolicy: RuntimeUpdatePolicy
    public let hooks: RuntimeLifecycleHooks
    public let rosetta: Bool
    public let virtualization: Bool
    public let readOnlyRootFilesystem: Bool
    public let sharedMemoryBytes: UInt64?

    public init(
        identity: RuntimeServiceIdentity,
        logicalServiceName: String? = nil,
        replicaIndex: Int = 0,
        image: String,
        imageLock: RuntimeImageDigestLock? = nil,
        platformOperatingSystem: String = "linux",
        platformArchitecture: String = "arm64",
        cpuCount: Int? = nil,
        memoryBytes: UInt64? = nil,
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        workingDirectory: String? = nil,
        entrypoint: [String] = [],
        command: [String] = [],
        initProcess: Bool = false,
        dependencies: [RuntimeServiceDependency] = [],
        environment: [RuntimeEnvironmentValue] = [],
        labels: [String: String] = [:],
        ports: [RuntimePortMapping] = [],
        publishedSockets: [RuntimeUnixSocketPublication] = [],
        hostAccess: [HostwrightHostAccessEndpoint] = [],
        mounts: [RuntimeMountReference] = [],
        healthCheck: RuntimeHealthCheckSpec? = nil,
        probes: RuntimeProbeSet = RuntimeProbeSet(),
        restartPolicy: RuntimeRestartPolicy = .no,
        updatePolicy: RuntimeUpdatePolicy = RuntimeUpdatePolicy(),
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks(),
        rosetta: Bool = false,
        virtualization: Bool = false,
        readOnlyRootFilesystem: Bool = false,
        sharedMemoryBytes: UInt64? = nil
    ) {
        self.init(
            identity: identity,
            logicalServiceName: logicalServiceName,
            replicaIndex: replicaIndex,
            image: image,
            imageLock: imageLock,
            platformOperatingSystem: platformOperatingSystem,
            platformArchitecture: platformArchitecture,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            userID: userID,
            groupID: groupID,
            workingDirectory: workingDirectory,
            entrypoint: entrypoint,
            command: command,
            initProcess: initProcess,
            dependencies: dependencies,
            environment: environment,
            labels: labels,
            ports: ports,
            publishedSockets: publishedSockets,
            hostAccess: hostAccess,
            networks: [],
            mounts: mounts,
            healthCheck: healthCheck,
            probes: probes,
            restartPolicy: restartPolicy,
            updatePolicy: updatePolicy,
            hooks: hooks,
            rosetta: rosetta,
            virtualization: virtualization,
            readOnlyRootFilesystem: readOnlyRootFilesystem,
            sharedMemoryBytes: sharedMemoryBytes
        )
    }

    public init(
        identity: RuntimeServiceIdentity,
        logicalServiceName: String? = nil,
        replicaIndex: Int = 0,
        image: String,
        imageLock: RuntimeImageDigestLock? = nil,
        platformOperatingSystem: String = "linux",
        platformArchitecture: String = "arm64",
        cpuCount: Int? = nil,
        memoryBytes: UInt64? = nil,
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        workingDirectory: String? = nil,
        entrypoint: [String] = [],
        command: [String] = [],
        initProcess: Bool = false,
        dependencies: [RuntimeServiceDependency] = [],
        environment: [RuntimeEnvironmentValue] = [],
        labels: [String: String] = [:],
        ports: [RuntimePortMapping] = [],
        publishedSockets: [RuntimeUnixSocketPublication] = [],
        hostAccess: [HostwrightHostAccessEndpoint] = [],
        networks: [RuntimeDesiredNetworkAttachment],
        mounts: [RuntimeMountReference] = [],
        healthCheck: RuntimeHealthCheckSpec? = nil,
        probes: RuntimeProbeSet = RuntimeProbeSet(),
        restartPolicy: RuntimeRestartPolicy = .no,
        updatePolicy: RuntimeUpdatePolicy = RuntimeUpdatePolicy(),
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks(),
        rosetta: Bool = false,
        virtualization: Bool = false,
        readOnlyRootFilesystem: Bool = false,
        sharedMemoryBytes: UInt64? = nil
    ) {
        self.identity = identity
        self.logicalServiceName = logicalServiceName ?? identity.serviceName
        self.replicaIndex = replicaIndex
        self.image = image
        self.imageLock = imageLock
        self.platformOperatingSystem = platformOperatingSystem
        self.platformArchitecture = platformArchitecture
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.userID = userID
        self.groupID = groupID
        self.workingDirectory = workingDirectory
        self.entrypoint = entrypoint
        self.command = command
        self.initProcess = initProcess
        self.dependencies = dependencies
        self.environment = environment
        self.labels = labels
        self.ports = ports
        self.publishedSockets = publishedSockets
        self.hostAccess = hostAccess.sorted(
            by: HostwrightHostAccessPolicy.canonicalPrecedes
        )
        self.networks = networks
        self.mounts = mounts
        self.healthCheck = healthCheck
        self.probes = probes
        self.restartPolicy = restartPolicy
        self.updatePolicy = updatePolicy
        self.hooks = hooks
        self.rosetta = rosetta
        self.virtualization = virtualization
        self.readOnlyRootFilesystem = readOnlyRootFilesystem
        self.sharedMemoryBytes = sharedMemoryBytes
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

public enum RuntimeImageDigestLockError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidReference
    case invalidDigest
    case invalidPlatform
    case invalidProvider
    case invalidCapability
    case evidenceMismatch
}

public struct RuntimeImageDigestLock: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let requestedReference: String
    public let resolvedReference: String
    public let descriptorDigest: String
    public let variantDigest: String
    public let operatingSystem: String
    public let architecture: String
    public let providerID: RuntimeProviderID
    public let capabilitySHA256: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        requestedReference: String,
        resolvedReference: String,
        descriptorDigest: String,
        variantDigest: String,
        operatingSystem: String,
        architecture: String,
        providerID: RuntimeProviderID,
        capabilitySHA256: String
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RuntimeImageDigestLockError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        let requested: String
        let resolved: String
        do {
            requested = try RuntimeImageLifecycleContract.validatedReference(
                requestedReference
            )
            resolved = try RuntimeImageLifecycleContract.validatedReference(
                resolvedReference
            )
        } catch {
            throw RuntimeImageDigestLockError.invalidReference
        }
        let descriptor: String
        let variant: String
        do {
            descriptor = try RuntimeImageLifecycleContract.validatedDigest(
                descriptorDigest
            )
            variant = try RuntimeImageLifecycleContract.validatedDigest(
                variantDigest
            )
        } catch {
            throw RuntimeImageDigestLockError.invalidDigest
        }
        guard Self.resolvedReference(
            for: requested,
            descriptorDigest: descriptor
        ) == resolved else {
            throw RuntimeImageDigestLockError.invalidReference
        }
        if let requestedDigest = Self.digest(in: requested),
           requestedDigest != descriptor {
            throw RuntimeImageDigestLockError.evidenceMismatch
        }
        guard operatingSystem == "linux",
              architecture == "arm64" || architecture == "amd64" else {
            throw RuntimeImageDigestLockError.invalidPlatform
        }
        guard RuntimeProviderID.knownValues.contains(providerID) else {
            throw RuntimeImageDigestLockError.invalidProvider
        }
        guard capabilitySHA256.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil else {
            throw RuntimeImageDigestLockError.invalidCapability
        }
        self.schemaVersion = schemaVersion
        self.requestedReference = requested
        self.resolvedReference = resolved
        self.descriptorDigest = descriptor
        self.variantDigest = variant
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.providerID = providerID
        self.capabilitySHA256 = capabilitySHA256
    }

    public static func resolve(
        requestedReference: String,
        evidence: RuntimeLocalImageEvidence,
        providerID: RuntimeProviderID,
        capabilitySHA256: String
    ) throws -> RuntimeImageDigestLock {
        guard evidence.reference == requestedReference else {
            throw RuntimeImageDigestLockError.evidenceMismatch
        }
        return try RuntimeImageDigestLock(
            requestedReference: requestedReference,
            resolvedReference: resolvedReference(
                for: requestedReference,
                descriptorDigest: evidence.descriptorDigest
            ),
            descriptorDigest: evidence.descriptorDigest,
            variantDigest: evidence.variantDigest,
            operatingSystem: evidence.operatingSystem,
            architecture: evidence.architecture,
            providerID: providerID,
            capabilitySHA256: capabilitySHA256
        )
    }

    public func verify(
        _ evidence: RuntimeLocalImageEvidence,
        providerID: RuntimeProviderID,
        capabilitySHA256: String
    ) throws {
        guard self.providerID == providerID,
              self.capabilitySHA256 == capabilitySHA256,
              evidence.reference == requestedReference ||
                evidence.reference == resolvedReference,
              evidence.descriptorDigest == descriptorDigest,
              evidence.variantDigest == variantDigest,
              evidence.operatingSystem == operatingSystem,
              evidence.architecture == architecture else {
            throw RuntimeImageDigestLockError.evidenceMismatch
        }
    }

    private static func resolvedReference(
        for requestedReference: String,
        descriptorDigest: String
    ) -> String {
        let withoutDigest = requestedReference.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? requestedReference
        let slash = withoutDigest.lastIndex(of: "/")
        let colon = withoutDigest.lastIndex(of: ":")
        let repository: String
        if let colon, slash == nil || colon > slash! {
            repository = String(withoutDigest[..<colon])
        } else {
            repository = withoutDigest
        }
        return "\(repository)@\(descriptorDigest)"
    }

    private static func digest(in reference: String) -> String? {
        let parts = reference.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        return parts.count == 2 ? String(parts[1]) : nil
    }
}

public struct ObservedRuntimeService: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let resourceIdentifier: String
    public let image: String?
    public let lifecycleState: RuntimeLifecycleState
    public let healthState: RuntimeHealthState
    public let ports: [RuntimePortMapping]
    public let publishedSockets: [RuntimeUnixSocketPublication]
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
        publishedSockets: [RuntimeUnixSocketPublication] = [],
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
        self.publishedSockets = publishedSockets
        self.networks = networks
        self.mounts = mounts
        self.observedAt = observedAt
    }
}

public struct DesiredRuntimeState: Equatable, Sendable {
    public let projectName: String
    public let networks: [DesiredRuntimeNetwork]
    public let services: [DesiredRuntimeService]
    public let ownedResourceHints: [RuntimeOwnedResourceHint]

    public init(
        projectName: String,
        services: [DesiredRuntimeService],
        ownedResourceHints: [RuntimeOwnedResourceHint] = []
    ) {
        self.init(
            projectName: projectName,
            networks: [],
            services: services,
            ownedResourceHints: ownedResourceHints
        )
    }

    public init(
        projectName: String,
        networks: [DesiredRuntimeNetwork],
        services: [DesiredRuntimeService],
        ownedResourceHints: [RuntimeOwnedResourceHint] = []
    ) {
        self.projectName = projectName
        self.networks = networks
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
    public let requiresProcessCompletion: Bool
    public let summary: String
    public let desiredService: DesiredRuntimeService?

    public init(
        kind: PlannedRuntimeActionKind,
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        isDestructive: Bool,
        requiresProcessCompletion: Bool = false,
        summary: String,
        desiredService: DesiredRuntimeService? = nil
    ) {
        self.kind = kind
        self.identity = identity
        self.resourceIdentifier = resourceIdentifier
        self.isDestructive = isDestructive
        self.requiresProcessCompletion = requiresProcessCompletion
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
    case networkLifecycle
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
