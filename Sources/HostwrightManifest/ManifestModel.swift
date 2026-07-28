import HostwrightCore
import HostwrightNetworking
import HostwrightSecrets

public struct HostwrightManifest: Equatable, Sendable {
    public static let currentVersion = HostwrightContractVersions.manifest
    public static let legacyVersion = 1

    public var version: Int?
    public var project: String?
    public var imagePolicy: HostwrightImagePolicy?
    public var imageTrust: HostwrightImageTrustPolicy?
    public var imageSBOM: HostwrightImageSBOMPolicy?
    public var imageVulnerability: HostwrightImageVulnerabilityPolicy?
    public var imageProvenance: HostwrightImageProvenancePolicy?
    public var volumes: [String: HostwrightVolumeDeclaration]
    public var networks: [String: HostwrightNetworkDefinition]
    public var services: [HostwrightService]

    public var effectiveVersion: Int {
        version ?? Self.legacyVersion
    }

    public var effectiveImagePolicy: HostwrightImagePolicy {
        imagePolicy ?? .allowTags
    }

    public init(project: String?, services: [HostwrightService]) {
        self.init(
            version: nil,
            project: project,
            imagePolicy: nil,
            imageTrust: nil,
            imageSBOM: nil,
            imageVulnerability: nil,
            imageProvenance: nil,
            volumes: [:],
            networks: [:],
            services: services
        )
    }

    public init(version: Int?, project: String?, services: [HostwrightService]) {
        self.init(
            version: version,
            project: project,
            imagePolicy: nil,
            imageTrust: nil,
            imageSBOM: nil,
            imageVulnerability: nil,
            imageProvenance: nil,
            volumes: [:],
            networks: [:],
            services: services
        )
    }

    public init(
        version: Int?,
        project: String?,
        imagePolicy: HostwrightImagePolicy?,
        imageTrust: HostwrightImageTrustPolicy?,
        imageSBOM: HostwrightImageSBOMPolicy?,
        imageVulnerability: HostwrightImageVulnerabilityPolicy? = nil,
        imageProvenance: HostwrightImageProvenancePolicy? = nil,
        volumes: [String: HostwrightVolumeDeclaration] = [:],
        services: [HostwrightService]
    ) {
        self.init(
            version: version,
            project: project,
            imagePolicy: imagePolicy,
            imageTrust: imageTrust,
            imageSBOM: imageSBOM,
            imageVulnerability: imageVulnerability,
            imageProvenance: imageProvenance,
            volumes: volumes,
            networks: [:],
            services: services
        )
    }

    public init(
        version: Int?,
        project: String?,
        imagePolicy: HostwrightImagePolicy?,
        imageTrust: HostwrightImageTrustPolicy?,
        imageSBOM: HostwrightImageSBOMPolicy?,
        imageVulnerability: HostwrightImageVulnerabilityPolicy? = nil,
        imageProvenance: HostwrightImageProvenancePolicy? = nil,
        volumes: [String: HostwrightVolumeDeclaration] = [:],
        networks: [String: HostwrightNetworkDefinition],
        services: [HostwrightService]
    ) {
        self.version = version
        self.project = project
        self.imagePolicy = imagePolicy
        self.imageTrust = imageTrust
        self.imageSBOM = imageSBOM
        self.imageVulnerability = imageVulnerability
        self.imageProvenance = imageProvenance
        self.volumes = volumes
        self.networks = networks
        self.services = services
    }

    public init(
        version: Int?,
        project: String?,
        imagePolicy: HostwrightImagePolicy?,
        services: [HostwrightService]
    ) {
        self.init(
            version: version,
            project: project,
            imagePolicy: imagePolicy,
            imageTrust: nil,
            imageSBOM: nil,
            imageVulnerability: nil,
            imageProvenance: nil,
            volumes: [:],
            networks: [:],
            services: services
        )
    }

    public init(
        version: Int?,
        project: String?,
        imagePolicy: HostwrightImagePolicy?,
        imageTrust: HostwrightImageTrustPolicy?,
        services: [HostwrightService]
    ) {
        self.init(
            version: version,
            project: project,
            imagePolicy: imagePolicy,
            imageTrust: imageTrust,
            imageSBOM: nil,
            imageVulnerability: nil,
            imageProvenance: nil,
            volumes: [:],
            networks: [:],
            services: services
        )
    }
}

public enum HostwrightVolumeAccessMode: String, Equatable, Sendable {
    case readWriteOnce = "read-write-once"
    case readOnlyMany = "read-only-many"
}

public enum HostwrightVolumeReclaimPolicy: String, Equatable, Sendable {
    case retain
    case delete
    case snapshotBeforeDelete = "snapshot-before-delete"
    case backupBeforeDelete = "backup-before-delete"
    case recycle
}

public struct HostwrightVolumeDeclaration: Equatable, Sendable {
    public static let defaultProvider = "hostwright-local"

    public var provider: String
    public var capacity: String
    public var accessMode: HostwrightVolumeAccessMode
    public var reclaimPolicy: HostwrightVolumeReclaimPolicy
    public var labels: [String: String]

    public init(
        provider: String = Self.defaultProvider,
        capacity: String,
        accessMode: HostwrightVolumeAccessMode = .readWriteOnce,
        reclaimPolicy: HostwrightVolumeReclaimPolicy = .retain,
        labels: [String: String] = [:]
    ) {
        self.provider = provider
        self.capacity = capacity
        self.accessMode = accessMode
        self.reclaimPolicy = reclaimPolicy
        self.labels = labels
    }
}

public enum HostwrightImagePolicy: String, Equatable, Sendable {
    case allowTags = "allow-tags"
    case requireDigest = "require-digest"
}

public struct HostwrightImageTrustPolicy: Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var threshold: Int
    public var trustedRoot: String?
    public var authorities: [HostwrightImageTrustAuthority]

    public init(
        version: Int = Self.currentVersion,
        threshold: Int,
        trustedRoot: String? = nil,
        authorities: [HostwrightImageTrustAuthority]
    ) {
        self.version = version
        self.threshold = threshold
        self.trustedRoot = trustedRoot
        self.authorities = authorities
    }
}

public enum HostwrightImageTrustAuthorityType: String, Equatable, Sendable {
    case keyed
    case keyless
}

public struct HostwrightImageTrustAuthority: Equatable, Sendable {
    public var id: String
    public var type: HostwrightImageTrustAuthorityType
    public var publicKey: String?
    public var issuer: String?
    public var identity: String?
    public var notBefore: String?
    public var notAfter: String?
    public var revokedAt: String?

    public init(
        id: String,
        type: HostwrightImageTrustAuthorityType,
        publicKey: String? = nil,
        issuer: String? = nil,
        identity: String? = nil,
        notBefore: String? = nil,
        notAfter: String? = nil,
        revokedAt: String? = nil
    ) {
        self.id = id
        self.type = type
        self.publicKey = publicKey
        self.issuer = issuer
        self.identity = identity
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.revokedAt = revokedAt
    }
}

public enum HostwrightImageSBOMRequirement: String, Equatable, Sendable {
    case optional
    case required
}

public enum HostwrightImageSBOMFormat: String, Equatable, Sendable {
    case spdxJSON = "spdx-json"
    case cyclonedxJSON = "cyclonedx-json"
}

public struct HostwrightImageSBOMPolicy: Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var requirement: HostwrightImageSBOMRequirement
    public var formats: [HostwrightImageSBOMFormat]

    public init(
        version: Int = Self.currentVersion,
        requirement: HostwrightImageSBOMRequirement,
        formats: [HostwrightImageSBOMFormat]
    ) {
        self.version = version
        self.requirement = requirement
        self.formats = formats
    }
}

public enum HostwrightVulnerabilitySeverity: String, Equatable, Sendable {
    case low
    case medium
    case high
    case critical
}

public enum HostwrightVulnerabilityExploitability: String, Equatable, Sendable {
    case any
    case knownExploited = "known-exploited"
}

public enum HostwrightVulnerabilityFixAvailability: String, Equatable, Sendable {
    case any
    case fixAvailable = "fix-available"
}

public enum HostwrightVulnerabilityDataAction: String, Equatable, Sendable {
    case failOpen = "fail-open"
    case failClosed = "fail-closed"
}

public enum HostwrightVulnerabilityExceptionApprovalMode: String, Equatable, Sendable {
    case required
    case disabled
}

public struct HostwrightImageVulnerabilityAllowlistEntry: Equatable, Sendable {
    public var vulnerabilityID: String
    public var packagePURL: String?
    public var reason: String
    public var expiresAt: String

    public init(
        vulnerabilityID: String,
        packagePURL: String? = nil,
        reason: String,
        expiresAt: String
    ) {
        self.vulnerabilityID = vulnerabilityID
        self.packagePURL = packagePURL
        self.reason = reason
        self.expiresAt = expiresAt
    }
}

public struct HostwrightImageVulnerabilityPolicy: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumMinimumVulnerabilityAgeSeconds = 31_536_000
    public static let minimumMaximumDatabaseAgeSeconds = 60
    public static let maximumMaximumDatabaseAgeSeconds = 2_592_000
    public static let maximumAllowlistEntries = 256

    public var version: Int
    public var severityThreshold: HostwrightVulnerabilitySeverity
    public var minimumVulnerabilityAgeSeconds: Int
    public var exploitability: HostwrightVulnerabilityExploitability
    public var fixAvailability: HostwrightVulnerabilityFixAvailability
    public var maximumDatabaseAgeSeconds: Int
    public var staleAction: HostwrightVulnerabilityDataAction
    public var unavailableAction: HostwrightVulnerabilityDataAction
    public var exceptionApproval: HostwrightVulnerabilityExceptionApprovalMode
    public var allowlist: [HostwrightImageVulnerabilityAllowlistEntry]

    public init(
        version: Int = Self.currentVersion,
        severityThreshold: HostwrightVulnerabilitySeverity,
        minimumVulnerabilityAgeSeconds: Int,
        exploitability: HostwrightVulnerabilityExploitability,
        fixAvailability: HostwrightVulnerabilityFixAvailability,
        maximumDatabaseAgeSeconds: Int,
        staleAction: HostwrightVulnerabilityDataAction,
        unavailableAction: HostwrightVulnerabilityDataAction,
        exceptionApproval: HostwrightVulnerabilityExceptionApprovalMode,
        allowlist: [HostwrightImageVulnerabilityAllowlistEntry] = []
    ) {
        self.version = version
        self.severityThreshold = severityThreshold
        self.minimumVulnerabilityAgeSeconds = minimumVulnerabilityAgeSeconds
        self.exploitability = exploitability
        self.fixAvailability = fixAvailability
        self.maximumDatabaseAgeSeconds = maximumDatabaseAgeSeconds
        self.staleAction = staleAction
        self.unavailableAction = unavailableAction
        self.exceptionApproval = exceptionApproval
        self.allowlist = allowlist
    }
}

public enum HostwrightImageProvenanceRequirement: String, Equatable, Sendable {
    case optional
    case required
}

public struct HostwrightImageProvenanceSigner: Equatable, Sendable {
    public var id: String
    public var publicKey: String
    public var notBefore: String?
    public var notAfter: String?
    public var revokedAt: String?

    public init(
        id: String,
        publicKey: String,
        notBefore: String? = nil,
        notAfter: String? = nil,
        revokedAt: String? = nil
    ) {
        self.id = id
        self.publicKey = publicKey
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.revokedAt = revokedAt
    }
}

public struct HostwrightImageProvenancePolicy: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumBuilderIDs = 16
    public static let maximumBuildTypes = 16
    public static let maximumSigners = 8
    public static let maximumURIUTF8Bytes = 512
    public static let maximumSignerIDUTF8Bytes = 128
    public static let maximumPublicKeyUTF8Bytes = 4_096
    public static let minimumMaximumAgeSeconds = 60
    public static let maximumMaximumAgeSeconds = 31_536_000

    public var version: Int
    public var requirement: HostwrightImageProvenanceRequirement
    public var builderIDs: [String]
    public var buildTypes: [String]
    public var signers: [HostwrightImageProvenanceSigner]
    public var maximumAgeSeconds: Int
    public var requireReproducible: Bool

    public init(
        version: Int = Self.currentVersion,
        requirement: HostwrightImageProvenanceRequirement,
        builderIDs: [String],
        buildTypes: [String],
        signers: [HostwrightImageProvenanceSigner],
        maximumAgeSeconds: Int,
        requireReproducible: Bool
    ) {
        self.version = version
        self.requirement = requirement
        self.builderIDs = builderIDs
        self.buildTypes = buildTypes
        self.signers = signers
        self.maximumAgeSeconds = maximumAgeSeconds
        self.requireReproducible = requireReproducible
    }
}

public enum HostwrightMountKind: String, Equatable, Sendable {
    case bind
    case volume
    case tmpfs
}

public struct HostwrightMountSpec: Equatable, Sendable {
    public var kind: HostwrightMountKind
    public var source: String?
    public var target: String
    public var readOnly: Bool
    public var mode: String?
    public var size: String?
    public var legacyLiteral: String?

    public init(
        kind: HostwrightMountKind,
        source: String? = nil,
        target: String,
        readOnly: Bool = false,
        mode: String? = nil,
        size: String? = nil,
        legacyLiteral: String? = nil
    ) {
        self.kind = kind
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.mode = mode
        self.size = size
        self.legacyLiteral = legacyLiteral
    }

    public var canonicalLegacyLiteral: String? {
        switch kind {
        case .bind, .volume:
            guard let source else { return nil }
            return readOnly ? "\(source):\(target):ro" : "\(source):\(target)"
        case .tmpfs:
            return nil
        }
    }

    public static func legacy(_ value: String) -> HostwrightMountSpec? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            return nil
        }
        let source = String(parts[0])
        let kind: HostwrightMountKind = (source.hasPrefix("/") || source.hasPrefix(".")) ? .bind : .volume
        return HostwrightMountSpec(
            kind: kind,
            source: source,
            target: String(parts[1]),
            readOnly: parts.count == 3 ? parts[2] == "ro" : false,
            legacyLiteral: value
        )
    }
}

public enum HostwrightPortProtocol: String, Equatable, Sendable {
    case tcp
    case udp
}

public struct HostwrightPortSpan: Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int? = nil) {
        self.start = start
        self.end = end ?? start
    }

    public var isSingle: Bool {
        start == end
    }

    public var count: Int {
        (end - start) + 1
    }

    public var singlePort: Int? {
        isSingle ? start : nil
    }

    public var canonicalString: String {
        isSingle ? String(start) : "\(start)-\(end)"
    }

    public var closedRange: ClosedRange<Int> {
        start ... end
    }
}

public struct HostwrightPublishedPort: Sendable {
    public static let localhostBindAddress = "127.0.0.1"
    public static let dynamicHostPortRange = 49_152 ... 65_535

    public let host: HostwrightPortSpan?
    public let target: HostwrightPortSpan
    public let protocolName: HostwrightPortProtocol
    public let bindAddress: String?
    public let legacyLiteral: String?

    public init(
        host: HostwrightPortSpan? = nil,
        target: HostwrightPortSpan,
        protocolName: HostwrightPortProtocol = .tcp,
        bindAddress: String? = nil,
        legacyLiteral: String? = nil
    ) {
        self.host = host
        self.target = target
        self.protocolName = protocolName
        self.bindAddress = bindAddress
        self.legacyLiteral = legacyLiteral
    }

    public var effectiveBindAddress: String {
        bindAddress ?? Self.localhostBindAddress
    }

    public var hostPort: Int? {
        host?.singlePort
    }

    public var containerPort: Int {
        target.start
    }

    public var hostPortRange: ClosedRange<Int>? {
        host?.closedRange
    }

    public var containerPortRange: ClosedRange<Int> {
        target.closedRange
    }

    public var canonicalLegacyLiteral: String? {
        guard protocolName == .tcp,
              effectiveBindAddress == Self.localhostBindAddress,
              let hostPort,
              let containerPort = target.singlePort else {
            return nil
        }
        return "\(hostPort):\(containerPort)"
    }

    public static func legacy(_ value: String) -> HostwrightPublishedPort? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hostPort = Int(parts[0]),
              let containerPort = Int(parts[1]) else {
            return nil
        }

        return HostwrightPublishedPort(
            host: HostwrightPortSpan(start: hostPort),
            target: HostwrightPortSpan(start: containerPort),
            protocolName: .tcp,
            bindAddress: localhostBindAddress,
            legacyLiteral: value
        )
    }
}

extension HostwrightPublishedPort: Equatable {
    public static func == (lhs: HostwrightPublishedPort, rhs: HostwrightPublishedPort) -> Bool {
        lhs.host == rhs.host &&
            lhs.target == rhs.target &&
            lhs.protocolName == rhs.protocolName &&
            lhs.effectiveBindAddress == rhs.effectiveBindAddress
    }
}

public enum HostwrightPublishedSocketMode: String, Equatable, Sendable {
    case ownerOnly = "0600"
    case ownerAndGroup = "0660"
}

public struct HostwrightPublishedSocket: Equatable, Sendable {
    public let hostName: String?
    public let containerPath: String
    public let mode: HostwrightPublishedSocketMode

    public init(
        hostName: String? = nil,
        containerPath: String,
        mode: HostwrightPublishedSocketMode = .ownerOnly
    ) {
        self.hostName = hostName
        self.containerPath = containerPath
        self.mode = mode
    }
}

public struct HostwrightService: Equatable, Sendable {
    public var name: String
    public var image: String?
    public var replicas: Int
    public var platform: HostwrightPlatform
    public var resources: HostwrightResources?
    public var user: UInt32?
    public var group: UInt32?
    public var workdir: String?
    public var entrypoint: [String]
    public var command: [String]
    public var initProcess: Bool
    public var dependsOn: [String: HostwrightDependencyCondition]
    public var env: [String: String]
    public var secretEnv: [String: HostwrightSecretReference]
    public var labels: [String: String]
    public var ports: [String]
    public var publishedPorts: [HostwrightPublishedPort]
    public var publishedSockets: [HostwrightPublishedSocket]
    public var networks: [HostwrightServiceNetworkAttachment]
    public var volumes: [String]
    public var mounts: [HostwrightMountSpec]
    public var probes: HostwrightProbes
    public var health: HostwrightHealthCheck?
    public var restart: HostwrightRestart?
    public var update: HostwrightUpdatePolicy
    public var hooks: HostwrightHooks
    public var rosetta: Bool
    public var virtualization: Bool
    public var readOnlyRootFilesystem: Bool
    public var shmSize: String?

    public init(
        name: String,
        image: String?,
        replicas: Int = 1,
        platform: HostwrightPlatform = HostwrightPlatform(),
        resources: HostwrightResources? = nil,
        user: UInt32? = nil,
        group: UInt32? = nil,
        workdir: String? = nil,
        entrypoint: [String] = [],
        command: [String] = [],
        initProcess: Bool = false,
        dependsOn: [String: HostwrightDependencyCondition] = [:],
        env: [String: String] = [:],
        secretEnv: [String: HostwrightSecretReference] = [:],
        labels: [String: String] = [:],
        ports: [String] = [],
        publishedPorts: [HostwrightPublishedPort] = [],
        publishedSockets: [HostwrightPublishedSocket] = [],
        volumes: [String] = [],
        mounts: [HostwrightMountSpec] = [],
        probes: HostwrightProbes = HostwrightProbes(),
        health: HostwrightHealthCheck? = nil,
        restart: HostwrightRestart? = nil,
        update: HostwrightUpdatePolicy = HostwrightUpdatePolicy(),
        hooks: HostwrightHooks = HostwrightHooks(),
        rosetta: Bool = false,
        virtualization: Bool = false,
        readOnlyRootFilesystem: Bool = false,
        shmSize: String? = nil
    ) {
        self.init(
            name: name,
            image: image,
            replicas: replicas,
            platform: platform,
            resources: resources,
            user: user,
            group: group,
            workdir: workdir,
            entrypoint: entrypoint,
            command: command,
            initProcess: initProcess,
            dependsOn: dependsOn,
            env: env,
            secretEnv: secretEnv,
            labels: labels,
            ports: ports,
            publishedPorts: publishedPorts,
            publishedSockets: publishedSockets,
            networks: [],
            volumes: volumes,
            mounts: mounts,
            probes: probes,
            health: health,
            restart: restart,
            update: update,
            hooks: hooks,
            rosetta: rosetta,
            virtualization: virtualization,
            readOnlyRootFilesystem: readOnlyRootFilesystem,
            shmSize: shmSize
        )
    }

    public init(
        name: String,
        image: String?,
        replicas: Int = 1,
        platform: HostwrightPlatform = HostwrightPlatform(),
        resources: HostwrightResources? = nil,
        user: UInt32? = nil,
        group: UInt32? = nil,
        workdir: String? = nil,
        entrypoint: [String] = [],
        command: [String] = [],
        initProcess: Bool = false,
        dependsOn: [String: HostwrightDependencyCondition] = [:],
        env: [String: String] = [:],
        secretEnv: [String: HostwrightSecretReference] = [:],
        labels: [String: String] = [:],
        ports: [String] = [],
        publishedPorts: [HostwrightPublishedPort] = [],
        publishedSockets: [HostwrightPublishedSocket] = [],
        networks: [HostwrightServiceNetworkAttachment],
        volumes: [String] = [],
        mounts: [HostwrightMountSpec] = [],
        probes: HostwrightProbes = HostwrightProbes(),
        health: HostwrightHealthCheck? = nil,
        restart: HostwrightRestart? = nil,
        update: HostwrightUpdatePolicy = HostwrightUpdatePolicy(),
        hooks: HostwrightHooks = HostwrightHooks(),
        rosetta: Bool = false,
        virtualization: Bool = false,
        readOnlyRootFilesystem: Bool = false,
        shmSize: String? = nil
    ) {
        self.name = name
        self.image = image
        self.replicas = replicas
        self.platform = platform
        self.resources = resources
        self.user = user
        self.group = group
        self.workdir = workdir
        self.entrypoint = entrypoint
        self.command = command
        self.initProcess = initProcess
        self.dependsOn = dependsOn
        self.env = env
        self.secretEnv = secretEnv
        self.labels = labels
        let normalizedPublishedPorts = publishedPorts.isEmpty ? ports.compactMap(HostwrightPublishedPort.legacy) : publishedPorts
        self.publishedPorts = normalizedPublishedPorts
        self.publishedSockets = publishedSockets
        self.ports = ports.isEmpty ? normalizedPublishedPorts.compactMap(\.canonicalLegacyLiteral) : ports
        self.networks = networks
        self.volumes = volumes
        self.mounts = mounts.isEmpty ? volumes.compactMap(HostwrightMountSpec.legacy) : mounts
        self.probes = probes
        self.health = health
        self.restart = restart
        self.update = update
        self.hooks = hooks
        self.rosetta = rosetta
        self.virtualization = virtualization
        self.readOnlyRootFilesystem = readOnlyRootFilesystem
        self.shmSize = shmSize
    }
}

public struct HostwrightPlatform: Equatable, Sendable {
    public var os: HostwrightPlatformOS
    public var architecture: HostwrightArchitecture

    public init(
        os: HostwrightPlatformOS = .linux,
        architecture: HostwrightArchitecture = .arm64
    ) {
        self.os = os
        self.architecture = architecture
    }
}

public enum HostwrightPlatformOS: String, Equatable, Sendable {
    case linux
}

public enum HostwrightArchitecture: String, Equatable, Sendable {
    case arm64
    case amd64
}

public struct HostwrightResources: Equatable, Sendable {
    public var cpus: Int?
    public var memory: String?

    public init(cpus: Int? = nil, memory: String? = nil) {
        self.cpus = cpus
        self.memory = memory
    }
}

public enum HostwrightDependencyCondition: String, Equatable, Sendable {
    case started
    case ready
    case completed
}

public struct HostwrightProbes: Equatable, Sendable {
    public var startup: HostwrightProbe?
    public var readiness: HostwrightProbe?
    public var liveness: HostwrightProbe?

    public init(
        startup: HostwrightProbe? = nil,
        readiness: HostwrightProbe? = nil,
        liveness: HostwrightProbe? = nil
    ) {
        self.startup = startup
        self.readiness = readiness
        self.liveness = liveness
    }
}

public struct HostwrightProbe: Equatable, Sendable {
    public var action: HostwrightProbeAction
    public var startPeriod: Int
    public var interval: Int
    public var timeout: Int
    public var successThreshold: Int
    public var failureThreshold: Int

    public init(
        action: HostwrightProbeAction,
        startPeriod: Int = 0,
        interval: Int = 10,
        timeout: Int = 3,
        successThreshold: Int = 1,
        failureThreshold: Int = 3
    ) {
        self.action = action
        self.startPeriod = startPeriod
        self.interval = interval
        self.timeout = timeout
        self.successThreshold = successThreshold
        self.failureThreshold = failureThreshold
    }
}

public enum HostwrightProbeAction: Equatable, Sendable {
    case exec([String])
    case http(port: Int, path: String)
    case tcp(port: Int)
}

public struct HostwrightRestart: Equatable, Sendable {
    public var policy: String

    public init(policy: String) {
        self.policy = policy
    }
}

public enum HostwrightUpdateStrategy: String, Equatable, Sendable {
    case rolling
    case recreate
}

public struct HostwrightUpdatePolicy: Equatable, Sendable {
    public var strategy: HostwrightUpdateStrategy
    public var maxSurge: Int
    public var maxUnavailable: Int
    public var progressDeadline: Int

    public init(
        strategy: HostwrightUpdateStrategy = .rolling,
        maxSurge: Int = 1,
        maxUnavailable: Int = 0,
        progressDeadline: Int = 300
    ) {
        self.strategy = strategy
        self.maxSurge = maxSurge
        self.maxUnavailable = maxUnavailable
        self.progressDeadline = progressDeadline
    }
}

public struct HostwrightHooks: Equatable, Sendable {
    public var postStart: [String]?
    public var preStop: [String]?

    public init(postStart: [String]? = nil, preStop: [String]? = nil) {
        self.postStart = postStart
        self.preStop = preStop
    }
}

public struct HostwrightHealthCheck: Equatable, Sendable {
    public var command: [String]
    public var interval: String?

    public init(command: [String] = [], interval: String? = nil) {
        self.command = command
        self.interval = interval
    }
}

public struct ManifestIssue: Equatable, Sendable {
    public let code: HostwrightErrorCode
    public let message: String
    public let line: Int?
    public let column: Int?
    public let path: String?

    public init(
        code: HostwrightErrorCode,
        message: String,
        line: Int? = nil,
        column: Int? = nil,
        path: String? = nil
    ) {
        self.code = code
        self.message = message
        self.line = line
        self.column = column
        self.path = path
    }

    public var rendered: String {
        let pathText = path.map { " \($0)" } ?? ""
        switch (line, column) {
        case let (.some(line), .some(column)):
            return "\(code.rawValue): line \(line), column \(column)\(pathText): \(message)"
        case let (.some(line), .none):
            return "\(code.rawValue): line \(line)\(pathText): \(message)"
        case (.none, _):
            return "\(code.rawValue):\(pathText) \(message)"
        }
    }
}

public enum ManifestParseError: Error, Equatable, Sendable {
    case failed([ManifestIssue])

    public var issues: [ManifestIssue] {
        switch self {
        case .failed(let issues):
            return issues
        }
    }
}
