import Foundation
import HostwrightCore

/// Transport contract for Hostwright service tunnels. This is deliberately an
/// application transport, not a VPN or NetworkExtension configuration.
public enum HostwrightTunnelTransport: String, Codable, Equatable, Sendable {
    case direct
    case relay
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
    public let authenticatedEndpoints: [HostwrightTunnelEndpoint]
    public let relayEndpoint: HostwrightTunnelEndpoint?

    public init(routeUUID: String = HostwrightResourceUUID.generate(), projectUUID: String, peerUUID: String, generation: Int64, providerID: String, providerGeneration: Int64, fencingToken: String, operationGroupID: String, desiredSHA256: String, authenticatedEndpoints: [HostwrightTunnelEndpoint], relayEndpoint: HostwrightTunnelEndpoint? = nil) throws {
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
              !authenticatedEndpoints.isEmpty,
              Set(authenticatedEndpoints).count == authenticatedEndpoints.count else {
            throw HostwrightTunnelError.invalidRoute
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
        self.authenticatedEndpoints = authenticatedEndpoints.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
        self.relayEndpoint = relayEndpoint
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
