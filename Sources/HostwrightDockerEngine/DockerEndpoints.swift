import Foundation

public enum DockerEndpointError: Error, Equatable, Sendable {
    case invalidTarget
    case unsupportedAPIVersion
    case unsupportedOperation
    case methodNotAllowed
}

public enum DockerEndpoint: Equatable, Hashable, Sendable {
    case ping
    case version
    case info
    case containersList
    case containerInspect(id: String)
    case imagesList
    case imageInspect(reference: String)
    case events

    public var identifier: String {
        switch self {
        case .ping: return "ping"
        case .version: return "version"
        case .info: return "info"
        case .containersList: return "containers.list"
        case .containerInspect: return "containers.inspect"
        case .imagesList: return "images.list"
        case .imageInspect: return "images.inspect"
        case .events: return "events"
        }
    }

    public var isLocal: Bool {
        switch self {
        case .ping, .version: return true
        case .info, .containersList, .containerInspect, .imagesList, .imageInspect, .events:
            return false
        }
    }

    public static func resolve(
        method: DockerHTTPMethod,
        target: String
    ) throws -> DockerEndpoint {
        let parsed = try splitTarget(target)
        if let version = parsed.version, !version.isSupported {
            throw DockerEndpointError.unsupportedAPIVersion
        }
        let components = parsed.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { throw DockerEndpointError.invalidTarget }

        if components == ["_ping"] {
            guard method == .get || method == .head else {
                throw DockerEndpointError.methodNotAllowed
            }
            return .ping
        }
        if components == ["version"] {
            guard method == .get else { throw DockerEndpointError.methodNotAllowed }
            return .version
        }
        if components == ["info"] {
            guard method == .get else { throw DockerEndpointError.methodNotAllowed }
            return .info
        }
        if components == ["containers", "json"] {
            guard method == .get else { throw DockerEndpointError.methodNotAllowed }
            return .containersList
        }
        if components.count == 3, components[0] == "containers", components[2] == "json" {
            guard method == .get, isSafeIdentifier(components[1]) else {
                throw method == .get ? DockerEndpointError.invalidTarget : DockerEndpointError.methodNotAllowed
            }
            return .containerInspect(id: try decodePathComponent(components[1]))
        }
        if components == ["images", "json"] {
            guard method == .get else { throw DockerEndpointError.methodNotAllowed }
            return .imagesList
        }
        if components.count >= 3, components[0] == "images",
           components.last == "json" {
            guard method == .get else { throw DockerEndpointError.methodNotAllowed }
            let encodedReference = components.dropFirst().dropLast().joined(separator: "/")
            guard !encodedReference.isEmpty else { throw DockerEndpointError.invalidTarget }
            let reference = try encodedReference
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { try decodePathComponent(String($0)) }
                .joined(separator: "/")
            guard isSafeImageReference(reference) else {
                throw DockerEndpointError.invalidTarget
            }
            return .imageInspect(reference: reference)
        }
        if components == ["events"] {
            guard method == .get else { throw DockerEndpointError.methodNotAllowed }
            return .events
        }
        throw DockerEndpointError.unsupportedOperation
    }

    public static func advertised(for version: DockerAPIVersion) -> Set<String> {
        guard version.isSupported else { return [] }
        let prefix = "/v\(version.rawValue)"
        return [
            "GET \(prefix)/_ping",
            "HEAD \(prefix)/_ping",
            "GET \(prefix)/version",
            "GET \(prefix)/info",
            "GET \(prefix)/containers/json",
            "GET \(prefix)/containers/{id}/json",
            "GET \(prefix)/images/json",
            "GET \(prefix)/images/{name}/json",
            "GET \(prefix)/events",
        ]
    }

    public static func targetVersion(_ target: String) throws -> DockerAPIVersion? {
        try splitTarget(target).version
    }

    public static func unversionedPath(_ target: String) throws -> String {
        try splitTarget(target).path
    }

    private struct ParsedTarget {
        let version: DockerAPIVersion?
        let path: String
    }

    private static func splitTarget(_ target: String) throws -> ParsedTarget {
        guard target.hasPrefix("/"),
              target.utf8.count <= DockerHTTPCodec.maximumRequestLineBytes else {
            throw DockerEndpointError.invalidTarget
        }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            ?? target
        guard !path.contains("//"), !path.contains("\\") else {
            throw DockerEndpointError.invalidTarget
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = components.first, first != ".", first != ".." else {
            throw DockerEndpointError.invalidTarget
        }
        if first.hasPrefix("v") && first != "version" {
            let raw = String(first.dropFirst())
            guard raw.first?.isNumber == true,
                  let version = DockerAPIVersion(rawValue: raw) else {
                throw DockerEndpointError.invalidTarget
            }
            let remainder = components.dropFirst().joined(separator: "/")
            guard !remainder.isEmpty else { throw DockerEndpointError.invalidTarget }
            return ParsedTarget(version: version, path: "/" + remainder)
        }
        return ParsedTarget(version: nil, path: path)
    }

    private static func decodePathComponent(_ value: String) throws -> String {
        guard let decoded = value.removingPercentEncoding,
              !decoded.isEmpty,
              !decoded.contains("\0"),
              !decoded.contains("\r"),
              !decoded.contains("\n") else {
            throw DockerEndpointError.invalidTarget
        }
        return decoded
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil
    }

    private static func isSafeImageReference(_ value: String) -> Bool {
        value.utf8.count <= 512
            && !value.contains("\0")
            && !value.contains("..")
            && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/@-]*$", options: .regularExpression) != nil
    }
}
