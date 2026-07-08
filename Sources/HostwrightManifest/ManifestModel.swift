import HostwrightCore
import HostwrightSecrets

public struct HostwrightManifest: Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int?
    public var project: String?
    public var imagePolicy: HostwrightImagePolicy?
    public var services: [HostwrightService]
    public var effectiveVersion: Int {
        version ?? Self.currentVersion
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

    public init(version: Int?, project: String?, imagePolicy: HostwrightImagePolicy?, services: [HostwrightService]) {
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
    public var command: [String]
    public var env: [String: String]
    public var secretEnv: [String: HostwrightSecretReference]
    public var ports: [String]
    public var volumes: [String]
    public var health: HostwrightHealthCheck?
    public var restart: HostwrightRestart?

    public init(
        name: String,
        image: String?,
        command: [String] = [],
        env: [String: String] = [:],
        secretEnv: [String: HostwrightSecretReference] = [:],
        ports: [String] = [],
        volumes: [String] = [],
        health: HostwrightHealthCheck? = nil,
        restart: HostwrightRestart? = nil
    ) {
        self.name = name
        self.image = image
        self.command = command
        self.env = env
        self.secretEnv = secretEnv
        self.ports = ports
        self.volumes = volumes
        self.health = health
        self.restart = restart
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

public struct HostwrightRestart: Equatable, Sendable {
    public var policy: String

    public init(policy: String) {
        self.policy = policy
    }
}

public struct ManifestIssue: Equatable, Sendable {
    public let code: HostwrightErrorCode
    public let message: String
    public let line: Int?

    public init(code: HostwrightErrorCode, message: String, line: Int? = nil) {
        self.code = code
        self.message = message
        self.line = line
    }

    public var rendered: String {
        if let line {
            return "\(code.rawValue): line \(line): \(message)"
        }
        return "\(code.rawValue): \(message)"
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
