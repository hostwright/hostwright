import Darwin
import Foundation
import HostwrightCore

/// Transport contract for Hostwright service tunnels. This is deliberately an
/// application transport, not a VPN or NetworkExtension configuration.
public enum HostwrightTunnelTransport: String, Codable, Equatable, Sendable {
    case direct
    case relay
}

/// A declared endpoint is configuration, not an authorized runtime route. The
/// lifecycle engine supplies fencing and operation authority when it materializes
/// a `HostwrightTunnelRoute`.
public enum HostwrightTunnelEndpointScheme: String, Codable, Equatable, Sendable {
    case tls
}

public enum HostwrightTunnelRole: String, Codable, Equatable, Sendable {
    case localLoopback = "local-loopback"
    case listener
    case dialer
}

public struct HostwrightTunnelManifestEndpoint: Codable, Equatable, Hashable, Sendable {
    public let scheme: HostwrightTunnelEndpointScheme
    public let host: String
    public let port: Int

    public init(
        scheme: HostwrightTunnelEndpointScheme = .tls,
        host: String,
        port: Int
    ) {
        self.scheme = scheme
        self.host = Self.canonicalHost(host) ?? host.lowercased()
        self.port = port
    }

    public static func isValidHost(_ value: String) -> Bool {
        canonicalHost(value) != nil
    }

    public static func canonicalHost(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= 253,
              value.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }),
              !value.contains("/"),
              !value.contains("@"),
              !value.contains("[") && !value.contains("]") else {
            return nil
        }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else {
                return nil
            }
            return String(
                decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
                as: UTF8.self
            )
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else {
                return nil
            }
            return String(
                decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
                as: UTF8.self
            ).lowercased()
        }
        let hostname = value.lowercased()
        guard hostname == value,
              HostwrightHostAccessPolicy.isValidHostname(hostname) else {
            return nil
        }
        return hostname
    }
}

public struct HostwrightTunnelBindEndpoint: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = HostwrightTunnelManifestEndpoint.canonicalHost(host) ?? host.lowercased()
        self.port = port
    }

    public var isLoopback: Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    public var isWildcard: Bool {
        host == "0.0.0.0" || host == "::"
    }

    public var isIPAddress: Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }

    public var isValid: Bool {
        HostwrightTunnelManifestEndpoint.canonicalHost(host) == host &&
            (1...65_535).contains(port)
    }
}

/// Public certificate references for an explicitly paired tunnel peer. These
/// values identify Keychain-backed identities and trust anchors; private key
/// material is never part of the manifest or persisted route.
public struct HostwrightTunnelTrust: Codable, Equatable, Sendable {
    public let wireRouteUUID: String
    public let wireGeneration: Int64
    public let localIdentitySHA256: String
    public let peerTrustAnchorSHA256: String
    public let peerCertificateSHA256: String
    public let peerDNSName: String?
    public let peerIdentityURI: String?

    public init(
        wireRouteUUID: String,
        wireGeneration: Int64,
        localIdentitySHA256: String,
        peerTrustAnchorSHA256: String,
        peerCertificateSHA256: String,
        peerDNSName: String? = nil,
        peerIdentityURI: String? = nil
    ) {
        self.wireRouteUUID = wireRouteUUID
        self.wireGeneration = wireGeneration
        self.localIdentitySHA256 = localIdentitySHA256
        self.peerTrustAnchorSHA256 = peerTrustAnchorSHA256
        self.peerCertificateSHA256 = peerCertificateSHA256
        self.peerDNSName = peerDNSName
        self.peerIdentityURI = peerIdentityURI
    }

    public var isValid: Bool {
        HostwrightResourceUUID.isValid(wireRouteUUID) &&
            wireRouteUUID == wireRouteUUID.lowercased() &&
            wireGeneration > 0 &&
            Self.isCanonicalSHA256(localIdentitySHA256) &&
            Self.isCanonicalSHA256(peerTrustAnchorSHA256) &&
            Self.isCanonicalSHA256(peerCertificateSHA256) &&
            peerDNSName.map(Self.isCanonicalDNSName) ?? true &&
            peerIdentityURI.map(Self.isCanonicalIdentityURI) ?? true
    }

    public static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    public static func isCanonicalDNSName(_ value: String) -> Bool {
        value == value.lowercased() &&
            HostwrightHostAccessPolicy.isValidHostname(value)
    }

    public static func isCanonicalIdentityURI(_ value: String) -> Bool {
        guard value.utf8.count <= 512,
              let components = URLComponents(string: value),
              components.scheme == "spiffe",
              components.host == HostwrightMutualTLSIdentity.trustDomain,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.string == value else {
            return false
        }
        let fields = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard fields.count == 8,
              fields[0] == "projects",
              fields[2] == "resources",
              fields[4] == "roles",
              fields[6] == "generations",
              HostwrightResourceUUID.isValid(String(fields[1])),
              HostwrightResourceUUID.isValid(String(fields[3])),
              fields[5] ==
                Substring(HostwrightIdentityRole.tunnel.rawValue),
              let generation = Int(fields[7]),
              generation > 0 else {
            return false
        }
        return true
    }
}

/// The manifest-level input for one bounded, authenticated service tunnel.
/// It deliberately excludes runtime-only route authority such as fences and
/// operation IDs.
public struct HostwrightTunnelDeclaration: Codable, Equatable, Sendable {
    public static let maximumDeclarations = 64
    public static let maximumAuthenticatedEndpoints = 8

    public let targetService: String
    public let targetPort: Int
    public let peerUUID: String
    public let role: HostwrightTunnelRole
    public let trust: HostwrightTunnelTrust?
    public let bindEndpoint: HostwrightTunnelBindEndpoint?
    public let authenticatedEndpoints: [HostwrightTunnelManifestEndpoint]
    public let relayEndpoint: HostwrightTunnelManifestEndpoint?
    public let bonjourDiscovery: Bool

    public init(
        targetService: String,
        targetPort: Int,
        peerUUID: String,
        role: HostwrightTunnelRole,
        trust: HostwrightTunnelTrust? = nil,
        bindEndpoint: HostwrightTunnelBindEndpoint? = nil,
        authenticatedEndpoints: [HostwrightTunnelManifestEndpoint] = [],
        relayEndpoint: HostwrightTunnelManifestEndpoint? = nil,
        bonjourDiscovery: Bool = true
    ) {
        self.targetService = targetService
        self.targetPort = targetPort
        self.peerUUID = peerUUID.lowercased()
        self.role = role
        self.trust = trust
        self.bindEndpoint = bindEndpoint
        self.authenticatedEndpoints = authenticatedEndpoints.sorted {
            ($0.scheme.rawValue, $0.host, $0.port) <
                ($1.scheme.rawValue, $1.host, $1.port)
        }
        self.relayEndpoint = relayEndpoint
        self.bonjourDiscovery = bonjourDiscovery
    }

    public init(
        targetService: String,
        targetPort: Int,
        peerUUID: String,
        authenticatedEndpoints: [HostwrightTunnelManifestEndpoint] = [],
        relayEndpoint: HostwrightTunnelManifestEndpoint? = nil,
        bonjourDiscovery: Bool = true
    ) {
        self.init(
            targetService: targetService,
            targetPort: targetPort,
            peerUUID: peerUUID,
            role: .localLoopback,
            trust: nil,
            bindEndpoint: nil,
            authenticatedEndpoints: authenticatedEndpoints,
            relayEndpoint: relayEndpoint,
            bonjourDiscovery: bonjourDiscovery
        )
    }

    private enum CodingKeys: String, CodingKey {
        case targetService, targetPort, peerUUID, role, trust
        case bindEndpoint, authenticatedEndpoints, relayEndpoint
        case bonjourDiscovery
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(
            keyedBy: CodingKeys.self
        )
        self.init(
            targetService: try values.decode(
                String.self,
                forKey: .targetService
            ),
            targetPort: try values.decode(
                Int.self,
                forKey: .targetPort
            ),
            peerUUID: try values.decode(
                String.self,
                forKey: .peerUUID
            ),
            role: try values.decodeIfPresent(
                HostwrightTunnelRole.self,
                forKey: .role
            ) ?? .localLoopback,
            trust: try values.decodeIfPresent(
                HostwrightTunnelTrust.self,
                forKey: .trust
            ),
            bindEndpoint: try values.decodeIfPresent(
                HostwrightTunnelBindEndpoint.self,
                forKey: .bindEndpoint
            ),
            authenticatedEndpoints:
                try values.decodeIfPresent(
                    [HostwrightTunnelManifestEndpoint].self,
                    forKey: .authenticatedEndpoints
                ) ?? [],
            relayEndpoint: try values.decodeIfPresent(
                HostwrightTunnelManifestEndpoint.self,
                forKey: .relayEndpoint
            ),
            bonjourDiscovery:
                try values.decodeIfPresent(
                    Bool.self,
                    forKey: .bonjourDiscovery
                ) ?? true
        )
    }
}

public struct HostwrightTunnelEndpoint: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }),
              (1...65_535).contains(port) else {
            throw HostwrightTunnelError.invalidEndpoint
        }
        self.host = host.lowercased()
        self.port = port
    }
}

/// Bonjour is discovery-only. A candidate never grants authorization.
public struct HostwrightBonjourTunnelCandidate: Codable, Equatable, Sendable {
    public let serviceName: String
    public let endpoint: HostwrightTunnelEndpoint
    public let peerUUID: String

    public init(serviceName: String, endpoint: HostwrightTunnelEndpoint, peerUUID: String) throws {
        guard !serviceName.isEmpty, serviceName.utf8.count <= 63,
              HostwrightResourceUUID.isValid(peerUUID) else {
            throw HostwrightTunnelError.invalidCandidate
        }
        self.serviceName = serviceName
        self.endpoint = endpoint
        self.peerUUID = peerUUID.lowercased()
    }
}

public struct HostwrightTunnelRoute: Codable, Equatable, Sendable {
    public let routeUUID: String
    public let projectUUID: String
    public let peerUUID: String
    public let generation: Int64
    public let providerID: String
    public let providerGeneration: Int64
    public let fencingToken: String
    public let operationGroupID: String
    public let desiredSHA256: String
    public let role: HostwrightTunnelRole
    public let trust: HostwrightTunnelTrust?
    public let bindEndpoint: HostwrightTunnelBindEndpoint?
    public let forwardEndpoint: HostwrightTunnelEndpoint?
    public let authenticatedEndpoints: [HostwrightTunnelEndpoint]
    public let relayEndpoint: HostwrightTunnelEndpoint?

    public init(routeUUID: String = HostwrightResourceUUID.generate(), projectUUID: String, peerUUID: String, generation: Int64, providerID: String, providerGeneration: Int64, fencingToken: String, operationGroupID: String, desiredSHA256: String, role: HostwrightTunnelRole, trust: HostwrightTunnelTrust? = nil, bindEndpoint: HostwrightTunnelBindEndpoint? = nil, forwardEndpoint: HostwrightTunnelEndpoint? = nil, authenticatedEndpoints: [HostwrightTunnelEndpoint], relayEndpoint: HostwrightTunnelEndpoint? = nil) throws {
        guard HostwrightResourceUUID.isValid(routeUUID),
              HostwrightResourceUUID.isValid(projectUUID),
              HostwrightResourceUUID.isValid(peerUUID),
              HostwrightResourceUUID.isValid(fencingToken),
              HostwrightResourceUUID.isValid(operationGroupID),
              !providerID.isEmpty, providerID.utf8.count <= 256,
              providerGeneration > 0, generation > 0,
              desiredSHA256.utf8.count == 64,
              desiredSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              (!authenticatedEndpoints.isEmpty || role == .listener),
              Set(authenticatedEndpoints).count == authenticatedEndpoints.count else {
            throw HostwrightTunnelError.invalidRoute
        }
        switch role {
        case .localLoopback:
            guard trust == nil, bindEndpoint == nil else {
                throw HostwrightTunnelError.invalidRoute
            }
        case .listener:
            guard let trust, trust.isValid,
                  trust.peerIdentityURI != nil,
                  trust.peerDNSName == nil,
                  let bindEndpoint, bindEndpoint.isValid,
                  bindEndpoint.isIPAddress,
                  !bindEndpoint.isWildcard,
                  let forwardEndpoint, Self.isLoopback(forwardEndpoint) else {
                throw HostwrightTunnelError.invalidRoute
            }
        case .dialer:
            guard let trust, trust.isValid,
                  trust.peerDNSName != nil,
                  trust.peerIdentityURI == nil,
                  let bindEndpoint, bindEndpoint.isValid,
                  bindEndpoint.isLoopback,
                  !authenticatedEndpoints.isEmpty,
                  forwardEndpoint == nil else {
                throw HostwrightTunnelError.invalidRoute
            }
        }
        self.routeUUID = routeUUID.lowercased()
        self.projectUUID = projectUUID.lowercased()
        self.peerUUID = peerUUID.lowercased()
        self.generation = generation
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken.lowercased()
        self.operationGroupID = operationGroupID.lowercased()
        self.desiredSHA256 = desiredSHA256
        self.role = role
        self.trust = trust
        self.bindEndpoint = bindEndpoint
        self.forwardEndpoint = forwardEndpoint
        self.authenticatedEndpoints = authenticatedEndpoints.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
        self.relayEndpoint = relayEndpoint
    }

    public init(
        routeUUID: String = HostwrightResourceUUID.generate(),
        projectUUID: String,
        peerUUID: String,
        generation: Int64,
        providerID: String,
        providerGeneration: Int64,
        fencingToken: String,
        operationGroupID: String,
        desiredSHA256: String,
        authenticatedEndpoints: [HostwrightTunnelEndpoint],
        relayEndpoint: HostwrightTunnelEndpoint? = nil
    ) throws {
        try self.init(
            routeUUID: routeUUID,
            projectUUID: projectUUID,
            peerUUID: peerUUID,
            generation: generation,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            operationGroupID: operationGroupID,
            desiredSHA256: desiredSHA256,
            role: .localLoopback,
            trust: nil,
            bindEndpoint: nil,
            forwardEndpoint: nil,
            authenticatedEndpoints: authenticatedEndpoints,
            relayEndpoint: relayEndpoint
        )
    }

    private static func isLoopback(_ endpoint: HostwrightTunnelEndpoint) -> Bool {
        endpoint.host == "127.0.0.1" ||
            endpoint.host == "::1" ||
            endpoint.host == "localhost"
    }

    private enum CodingKeys: String, CodingKey {
        case routeUUID, projectUUID, peerUUID, generation, providerID
        case providerGeneration, fencingToken, operationGroupID, desiredSHA256
        case role, trust, bindEndpoint, forwardEndpoint
        case authenticatedEndpoints, relayEndpoint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            routeUUID: values.decode(String.self, forKey: .routeUUID),
            projectUUID: values.decode(String.self, forKey: .projectUUID),
            peerUUID: values.decode(String.self, forKey: .peerUUID),
            generation: values.decode(Int64.self, forKey: .generation),
            providerID: values.decode(String.self, forKey: .providerID),
            providerGeneration: values.decode(Int64.self, forKey: .providerGeneration),
            fencingToken: values.decode(String.self, forKey: .fencingToken),
            operationGroupID: values.decode(String.self, forKey: .operationGroupID),
            desiredSHA256: values.decode(String.self, forKey: .desiredSHA256),
            role: values.decodeIfPresent(HostwrightTunnelRole.self, forKey: .role) ?? .localLoopback,
            trust: values.decodeIfPresent(HostwrightTunnelTrust.self, forKey: .trust),
            bindEndpoint: values.decodeIfPresent(HostwrightTunnelBindEndpoint.self, forKey: .bindEndpoint),
            forwardEndpoint: values.decodeIfPresent(HostwrightTunnelEndpoint.self, forKey: .forwardEndpoint),
            authenticatedEndpoints: values.decode([HostwrightTunnelEndpoint].self, forKey: .authenticatedEndpoints),
            relayEndpoint: values.decodeIfPresent(HostwrightTunnelEndpoint.self, forKey: .relayEndpoint)
        )
    }
}

public struct HostwrightTunnelFrame: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 64 * 1_024
    public static let maximumChannels = 128
    public let routeUUID: String
    public let generation: Int64
    public let fencingToken: String
    public let channel: Int
    public let sequence: UInt64
    public let payload: Data

    public init(routeUUID: String, generation: Int64, fencingToken: String, channel: Int, sequence: UInt64, payload: Data) throws {
        guard HostwrightResourceUUID.isValid(routeUUID), HostwrightResourceUUID.isValid(fencingToken),
              generation > 0, (0..<Self.maximumChannels).contains(channel),
              !payload.isEmpty, payload.count <= Self.maximumPayloadBytes else {
            throw HostwrightTunnelError.invalidFrame
        }
        self.routeUUID = routeUUID.lowercased()
        self.generation = generation
        self.fencingToken = fencingToken.lowercased()
        self.channel = channel
        self.sequence = sequence
        self.payload = payload
    }
}

public enum HostwrightTunnelError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidCandidate, invalidRoute, invalidFrame
    case staleFence, routeReplay, duplicatePeer, conflictingGeneration
    case unauthenticated, downgradeRejected, cancelled, revoked
}
