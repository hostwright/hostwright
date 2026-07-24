import HostwrightCore
import HostwrightSecrets

public struct HostwrightManifest: Equatable, Sendable {
    public static let currentVersion = HostwrightContractVersions.manifest
    public static let legacyVersion = 1

    public var version: Int?
    public var project: String?
    public var imagePolicy: HostwrightImagePolicy?
    public var services: [HostwrightService]

    public var effectiveVersion: Int {
        version ?? Self.legacyVersion
    }

    public var effectiveImagePolicy: HostwrightImagePolicy {
        imagePolicy ?? .allowTags
    }

    public init(project: String?, services: [HostwrightService]) {
        self.init(version: nil, project: project, imagePolicy: nil, services: services)
    }

    public init(version: Int?, project: String?, services: [HostwrightService]) {
        self.init(version: version, project: project, imagePolicy: nil, services: services)
    }

    public init(
        version: Int?,
        project: String?,
        imagePolicy: HostwrightImagePolicy?,
        services: [HostwrightService]
    ) {
        self.version = version
        self.project = project
        self.imagePolicy = imagePolicy
        self.services = services
    }
}

public enum HostwrightImagePolicy: String, Equatable, Sendable {
    case allowTags = "allow-tags"
    case requireDigest = "require-digest"
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
    public var volumes: [String]
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
        volumes: [String] = [],
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
        self.ports = ports
        self.volumes = volumes
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
