import Foundation
import HostwrightNetworking
import HostwrightNetworkProviders
import HostwrightRuntime

public enum NetworkHelperProtocolV1 {
    public static let version = 1
    public static let maximumFrameBytes =
        ContainerizationHelperProtocolV1.maximumPayloadBytes
    public static let maximumCorefileBytes = 1 * 1_024 * 1_024
    public static let maximumIngressRequestLineBytes = 8 * 1_024
    public static let maximumIngressHeaderBytes = 64 * 1_024
    public static let maximumIngressBodyBytes = 8 * 1_024 * 1_024
    public static let maximumIngressAccessLogEntries = 256
    public static let maximumTunnelEndpoints = 8
    public static let maximumTunnelOperationMilliseconds: Int64 = 30_000
}

public enum NetworkHelperIngressAccessOutcome:
    String,
    Codable,
    Equatable,
    Sendable
{
    case rejected
    case noRoute
    case unavailable
    case upstreamFailed
    case forwarded
}

public struct NetworkHelperIngressAccessLogEntry:
    Codable,
    Equatable,
    Sendable
{
    public let eventID: String
    public let timestampUnixMilliseconds: Int64
    public let listenerName: String
    public let method: String?
    public let routeHostname: String?
    public let routePathPrefix: String?
    public let protocolName: HostwrightIngressRouteProtocol?
    public let targetServiceUUID: String?
    public let outcome: NetworkHelperIngressAccessOutcome
    public let durationMilliseconds: Int64

    init(
        eventID: UUID = UUID(),
        timestampUnixMilliseconds: Int64,
        listenerName: String,
        method: String?,
        routeHostname: String?,
        routePathPrefix: String?,
        protocolName: HostwrightIngressRouteProtocol?,
        targetServiceUUID: String?,
        outcome: NetworkHelperIngressAccessOutcome,
        durationMilliseconds: Int64
    ) {
        self.eventID = eventID.uuidString.lowercased()
        self.timestampUnixMilliseconds = timestampUnixMilliseconds
        self.listenerName = listenerName
        self.method = method.map { String($0.prefix(32)) }
        self.routeHostname = routeHostname
        self.routePathPrefix = routePathPrefix
        self.protocolName = protocolName
        self.targetServiceUUID = targetServiceUUID
        self.outcome = outcome
        self.durationMilliseconds = max(0, durationMilliseconds)
    }
}

enum NetworkHelperOperation: String, Codable, CaseIterable, Sendable {
    case apply
    case status
    case remove
    case providerInvoke
    case providerRevoke
    case tunnelSetup
    case tunnelStatus
    case tunnelReconnect
    case tunnelRotateKey
    case tunnelDrain
    case tunnelTeardown
}

enum NetworkHelperDisposition: String, Codable, Sendable {
    case absent
    case active
    case conflict
    case quarantined
}

public struct NetworkHelperDNSIdentity: Codable, Equatable, Hashable, Sendable {
    public let projectUUID: String
    public let dnsUUID: String
    public let generation: Int
    public let fencingToken: String

    public init(
        projectUUID: String,
        dnsUUID: String,
        generation: Int,
        fencingToken: String
    ) {
        self.projectUUID = projectUUID
        self.dnsUUID = dnsUUID
        self.generation = generation
        self.fencingToken = fencingToken
    }

    func validated() throws -> Self {
        guard Self.isCanonicalUUID(projectUUID),
              Self.isCanonicalUUID(dnsUUID),
              generation > 0,
              Self.isCanonicalUUID(fencingToken) else {
            throw NetworkHelperError.invalidIdentity
        }
        return self
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

struct NetworkHelperRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let operation: NetworkHelperOperation
    let identity: NetworkHelperDNSIdentity
    let corefile: String?
    let hostAccessBindings: [ProjectDNSHostAccessBinding]?
    let ingressBindings: [ProjectIngressListenerBinding]?
    let certificateBindings: [ProjectCertificateRequestBinding]?
    let policyPlan: NetworkPolicyPlan?
    let predecessorFencingToken: String?
    let providerInvocation: NetworkHelperProviderInvocation?
    let providerRevocation: NetworkHelperProviderRevocation?
    let tunnel: NetworkHelperTunnelRequest?

    init(
        protocolVersion: Int = NetworkHelperProtocolV1.version,
        requestID: UUID = UUID(),
        operation: NetworkHelperOperation,
        identity: NetworkHelperDNSIdentity,
        corefile: String? = nil,
        hostAccessBindings: [ProjectDNSHostAccessBinding] = [],
        ingressBindings: [ProjectIngressListenerBinding] = [],
        certificateBindings: [ProjectCertificateRequestBinding] = [],
        policyPlan: NetworkPolicyPlan? = nil,
        predecessorFencingToken: String? = nil,
        providerInvocation: NetworkHelperProviderInvocation? = nil,
        providerRevocation: NetworkHelperProviderRevocation? = nil,
        tunnel: NetworkHelperTunnelRequest? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID.uuidString.lowercased()
        self.operation = operation
        self.identity = identity
        self.corefile = corefile
        self.hostAccessBindings = hostAccessBindings.sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
        self.ingressBindings = ingressBindings.sorted(
            by: ProjectIngressListenerBinding.canonicalPrecedes
        )
        self.certificateBindings = certificateBindings.sorted(
            by: ProjectCertificateRequestBinding.canonicalPrecedes
        )
        self.policyPlan = policyPlan
        self.predecessorFencingToken = predecessorFencingToken
        self.providerInvocation = providerInvocation
        self.providerRevocation = providerRevocation
        self.tunnel = tunnel
    }

    func validated() throws -> Self {
        guard protocolVersion == NetworkHelperProtocolV1.version else {
            throw NetworkHelperError.unsupportedProtocolVersion
        }
        guard let requestUUID = UUID(uuidString: requestID),
              requestUUID.uuidString.lowercased() == requestID else {
            throw NetworkHelperError.invalidRequest
        }
        _ = try identity.validated()
        if let predecessorFencingToken {
            guard let uuid = UUID(uuidString: predecessorFencingToken),
                  uuid.uuidString.lowercased() ==
                    predecessorFencingToken else {
                throw NetworkHelperError.invalidIdentity
            }
        }

        switch operation {
        case .apply:
            guard let corefile,
                  !corefile.isEmpty,
                  !corefile.utf8.contains(0),
                  corefile.lengthOfBytes(using: .utf8)
                    <= NetworkHelperProtocolV1.maximumCorefileBytes else {
                throw NetworkHelperError.invalidCorefile
            }
            _ = try NetworkHelperHostAccessValidation.validated(
                hostAccessBindings ?? []
            )
            _ = try NetworkHelperIngressValidation.validated(
                ingressBindings ?? []
            )
            _ = try NetworkHelperCertificateValidation.validated(
                certificateBindings ?? []
            )
            if let policyPlan {
                try NetworkHelperPolicyBroker.validated(
                    plan: policyPlan,
                    identity: identity
                )
            }
            guard providerInvocation == nil,
                  providerRevocation == nil,
                  tunnel == nil else {
                throw NetworkHelperError.invalidRequest
            }
        case .status, .remove:
            guard corefile == nil,
                  hostAccessBindings == nil ||
                    hostAccessBindings?.isEmpty == true,
                  ingressBindings == nil ||
                    ingressBindings?.isEmpty == true,
                  certificateBindings == nil ||
                    certificateBindings?.isEmpty == true,
                  policyPlan == nil,
                  predecessorFencingToken == nil,
                  providerInvocation == nil,
                  providerRevocation == nil,
                  tunnel == nil else {
                throw NetworkHelperError.invalidRequest
            }
        case .providerInvoke:
            guard corefile == nil,
                  hostAccessBindings == nil ||
                    hostAccessBindings?.isEmpty == true,
                  ingressBindings == nil ||
                    ingressBindings?.isEmpty == true,
                  certificateBindings == nil ||
                    certificateBindings?.isEmpty == true,
                  policyPlan == nil,
                  predecessorFencingToken == nil,
                  let providerInvocation,
                  providerRevocation == nil,
                  tunnel == nil else {
                throw NetworkHelperError.invalidRequest
            }
            _ = try providerInvocation.validated()
        case .providerRevoke:
            guard corefile == nil,
                  hostAccessBindings == nil ||
                    hostAccessBindings?.isEmpty == true,
                  ingressBindings == nil ||
                    ingressBindings?.isEmpty == true,
                  certificateBindings == nil ||
                    certificateBindings?.isEmpty == true,
                  policyPlan == nil,
                  predecessorFencingToken == nil,
                  providerInvocation == nil,
                  let providerRevocation,
                  tunnel == nil else {
                throw NetworkHelperError.invalidRequest
            }
            _ = try providerRevocation.validated()
        case .tunnelSetup, .tunnelStatus, .tunnelReconnect,
                .tunnelRotateKey, .tunnelDrain,
                .tunnelTeardown:
            guard corefile == nil,
                  hostAccessBindings == nil ||
                    hostAccessBindings?.isEmpty == true,
                  ingressBindings == nil ||
                    ingressBindings?.isEmpty == true,
                  certificateBindings == nil ||
                    certificateBindings?.isEmpty == true,
                  policyPlan == nil,
                  predecessorFencingToken == nil,
                  providerInvocation == nil,
                  providerRevocation == nil,
                  let tunnel else {
                throw NetworkHelperError.invalidRequest
            }
            _ = try tunnel.validated(identity: identity)
        }
        return self
    }
}

public struct NetworkHelperTunnelRequest:
    Codable,
    Equatable,
    Sendable
{
    public let route: HostwrightTunnelRoute
    public let timeoutMilliseconds: Int64
    public let execution: NetworkHelperTunnelExecution?

    public init(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64 = 5_000,
        execution: NetworkHelperTunnelExecution? = nil
    ) {
        self.route = route
        self.timeoutMilliseconds = timeoutMilliseconds
        self.execution = execution
    }

    func validated(
        identity: NetworkHelperDNSIdentity
    ) throws -> Self {
        guard route.projectUUID == identity.projectUUID,
              route.routeUUID == identity.dnsUUID,
              route.generation == Int64(identity.generation),
              route.fencingToken == identity.fencingToken,
              route.authenticatedEndpoints.count <=
                NetworkHelperProtocolV1.maximumTunnelEndpoints,
              (1...NetworkHelperProtocolV1
                .maximumTunnelOperationMilliseconds)
                .contains(timeoutMilliseconds),
              (try? execution?.validated(route: route)) != nil ||
                execution == nil,
              let rebuilt = try? HostwrightTunnelRoute(
                routeUUID: route.routeUUID,
                projectUUID: route.projectUUID,
                peerUUID: route.peerUUID,
                generation: route.generation,
                providerID: route.providerID,
                providerGeneration: route.providerGeneration,
                fencingToken: route.fencingToken,
                operationGroupID: route.operationGroupID,
                desiredSHA256: route.desiredSHA256,
                role: route.role,
                trust: route.trust,
                bindEndpoint: route.bindEndpoint,
                forwardEndpoint: route.forwardEndpoint,
                authenticatedEndpoints:
                    route.authenticatedEndpoints,
                relayEndpoint: route.relayEndpoint
              ),
              rebuilt == route else {
            throw NetworkHelperError.invalidTunnel
        }
        return self
    }
}

public enum NetworkHelperTunnelRole:
    String,
    Codable,
    Equatable,
    Sendable
{
    case listener
    case dialer
}

public struct NetworkHelperTunnelExecution:
    Codable,
    Equatable,
    Sendable
{
    public let role: NetworkHelperTunnelRole
    public let wireRouteUUID: String
    public let wireGeneration: Int64
    public let wireFencingToken: String
    public let localIdentitySHA256: String
    public let peerTrustAnchorSHA256: String
    public let peerCertificateSHA256: String
    public let peerDNSName: String?
    public let peerIdentityURI: String?
    public let serviceTarget: HostwrightTunnelEndpoint?
    public let localForwardEndpoint: HostwrightTunnelEndpoint?

    public init(
        role: NetworkHelperTunnelRole,
        wireRouteUUID: String,
        wireGeneration: Int64,
        wireFencingToken: String,
        localIdentitySHA256: String,
        peerTrustAnchorSHA256: String,
        peerCertificateSHA256: String,
        peerDNSName: String? = nil,
        peerIdentityURI: String? = nil,
        serviceTarget: HostwrightTunnelEndpoint? = nil,
        localForwardEndpoint: HostwrightTunnelEndpoint? = nil
    ) {
        self.role = role
        self.wireRouteUUID = wireRouteUUID
        self.wireGeneration = wireGeneration
        self.wireFencingToken = wireFencingToken
        self.localIdentitySHA256 = localIdentitySHA256
        self.peerTrustAnchorSHA256 = peerTrustAnchorSHA256
        self.peerCertificateSHA256 = peerCertificateSHA256
        self.peerDNSName = peerDNSName
        self.peerIdentityURI = peerIdentityURI
        self.serviceTarget = serviceTarget
        self.localForwardEndpoint = localForwardEndpoint
    }

    func validated(
        route: HostwrightTunnelRoute? = nil
    ) throws -> Self {
        let fingerprints = [
            localIdentitySHA256,
            peerTrustAnchorSHA256,
            peerCertificateSHA256,
        ]
        guard fingerprints.allSatisfy(Self.isCanonicalSHA256)
                && Self.isCanonicalUUID(wireRouteUUID)
                && wireGeneration > 0
                && Self.isCanonicalUUID(wireFencingToken)
        else {
            throw NetworkHelperError.invalidTunnel
        }
        switch role {
        case .listener:
            guard peerDNSName == nil,
                  let peerIdentityURI,
                  Self.isCanonicalPeerIdentity(peerIdentityURI),
                  let serviceTarget,
                  Self.isLoopback(serviceTarget.host),
                  localForwardEndpoint == nil else {
                throw NetworkHelperError.invalidTunnel
            }
        case .dialer:
            guard peerIdentityURI == nil,
                  let peerDNSName,
                  Self.isCanonicalDNSName(peerDNSName),
                  serviceTarget == nil,
                  let localForwardEndpoint,
                  Self.isLoopback(localForwardEndpoint.host)
            else {
                throw NetworkHelperError.invalidTunnel
            }
        }
        if let route {
            let expectedRole: HostwrightTunnelRole =
                role == .listener ? .listener : .dialer
            guard route.role == expectedRole,
                  route.trust?.wireRouteUUID
                    == wireRouteUUID,
                  route.trust?.wireGeneration
                    == wireGeneration,
                  route.trust?.localIdentitySHA256
                    == localIdentitySHA256,
                  route.trust?.peerTrustAnchorSHA256
                    == peerTrustAnchorSHA256,
                  route.trust?.peerCertificateSHA256
                    == peerCertificateSHA256,
                  route.trust?.peerDNSName == peerDNSName,
                  route.trust?.peerIdentityURI
                    == peerIdentityURI else {
                throw NetworkHelperError.invalidTunnel
            }
            switch role {
            case .listener:
                guard route.forwardEndpoint == serviceTarget else {
                    throw NetworkHelperError.invalidTunnel
                }
            case .dialer:
                guard route.forwardEndpoint == nil,
                      route.bindEndpoint?.host ==
                        localForwardEndpoint?.host,
                      route.bindEndpoint?.port ==
                        localForwardEndpoint?.port else {
                    throw NetworkHelperError.invalidTunnel
                }
            }
        }
        return self
    }

    private static func isCanonicalSHA256(
        _ value: String
    ) -> Bool {
        value.utf8.count == 64 &&
            value.utf8.allSatisfy {
                (48...57).contains($0) ||
                    (97...102).contains($0)
            }
    }

    private static func isCanonicalUUID(
        _ value: String
    ) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased()
            == value
    }

    private static func isCanonicalDNSName(
        _ value: String
    ) -> Bool {
        guard value == value.lowercased(),
              value.utf8.count <= 253,
              !value.isEmpty else {
            return false
        }
        return value.split(separator: ".").allSatisfy {
            !$0.isEmpty &&
                $0.utf8.count <= 63 &&
                $0.first != "-" &&
                $0.last != "-" &&
                $0.utf8.allSatisfy {
                    (97...122).contains($0) ||
                        (48...57).contains($0) ||
                        $0 == 45
                }
        }
    }

    private static func isCanonicalPeerIdentity(
        _ value: String
    ) -> Bool {
        guard value.utf8.count <= 512,
              let components = URLComponents(string: value),
              components.scheme == "spiffe",
              components.host == "hostwright.internal",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.string == value else {
            return false
        }
        return components.path.hasPrefix("/projects/")
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" ||
            host == "localhost" ||
            host == "::1"
    }
}

public struct NetworkHelperTunnelResult:
    Codable,
    Equatable,
    Sendable
{
    public let routeUUID: String
    public let generation: Int64
    public let fencingToken: String
    public let phase: HostwrightTunnelSessionPhase
    public let selectedTransport: HostwrightTunnelTransport?
    public let live: Bool
    public let reconnectAttempt: Int
    public let observedSHA256: String?
    public let reconnectDelayMilliseconds: Int?
    public let reconnects: Int
    public let keyRotations: Int
    public let rejectedFrames: Int
    public let teardownCount: Int

    init(
        intent: HostwrightTunnelSessionIntent,
        live: Bool,
        metrics: HostwrightTunnelMetrics? = nil,
        reconnectDelayMilliseconds: Int? = nil
    ) {
        routeUUID = intent.route.routeUUID
        generation = intent.route.generation
        fencingToken = intent.route.fencingToken
        phase = intent.phase
        selectedTransport = intent.selectedTransport
        self.live = live
        reconnectAttempt = intent.reconnectAttempt
        observedSHA256 = intent.observedSHA256
        self.reconnectDelayMilliseconds =
            reconnectDelayMilliseconds
        reconnects = metrics?.reconnects ?? 0
        keyRotations = metrics?.keyRotations ?? 0
        rejectedFrames = metrics?.rejectedFrames ?? 0
        teardownCount = metrics?.teardownCount ?? 0
    }

    init(
        route: HostwrightTunnelRoute,
        phase: HostwrightTunnelSessionPhase,
        selectedTransport: HostwrightTunnelTransport?,
        live: Bool,
        reconnectAttempt: Int,
        observedSHA256: String?
    ) {
        routeUUID = route.routeUUID
        generation = route.generation
        fencingToken = route.fencingToken
        self.phase = phase
        self.selectedTransport = selectedTransport
        self.live = live
        self.reconnectAttempt = reconnectAttempt
        self.observedSHA256 = observedSHA256
        reconnectDelayMilliseconds = nil
        reconnects = 0
        keyRotations = 0
        rejectedFrames = 0
        teardownCount = 0
    }
}

public struct NetworkHelperCertificateSummary:
    Codable,
    Equatable,
    Sendable
{
    public let name: String
    public let certificateUUID: String
    public let source: HostwrightCertificateSourceKind
    public let certificateSHA256: String
    public let issuerCertificateSHA256: String?
    public let dnsNames: [String]
    public let notValidBefore: Date
    public let notValidAfter: Date
    public let revocationStatus: String
    public let renewalNeeded: Bool

    public init(
        name: String,
        certificateUUID: String,
        source: HostwrightCertificateSourceKind,
        certificateSHA256: String,
        issuerCertificateSHA256: String?,
        dnsNames: [String],
        notValidBefore: Date,
        notValidAfter: Date,
        revocationStatus: String,
        renewalNeeded: Bool
    ) {
        self.name = name
        self.certificateUUID = certificateUUID
        self.source = source
        self.certificateSHA256 = certificateSHA256
        self.issuerCertificateSHA256 = issuerCertificateSHA256
        self.dnsNames = dnsNames.sorted()
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
        self.revocationStatus = revocationStatus
        self.renewalNeeded = renewalNeeded
    }
}

struct NetworkHelperStatus: Codable, Equatable, Sendable {
    let disposition: NetworkHelperDisposition
    let identity: NetworkHelperDNSIdentity?
    let corefileSHA256: String?
    let hostAccessSHA256: String?
    let hostAccessActive: Bool?
    let ingressSHA256: String?
    let ingressActive: Bool?
    let ingressAccessLog: [NetworkHelperIngressAccessLogEntry]?
    let mutualTLSAudit: [NetworkHelperMutualTLSAuditEntry]?
    let certificateSHA256: String?
    let certificateActive: Bool?
    let certificateEvidenceSHA256: String?
    let certificateSummaries: [NetworkHelperCertificateSummary]?
    let policySHA256: String?
    let policyActive: Bool?
    let reason: String?

    init(
        disposition: NetworkHelperDisposition,
        identity: NetworkHelperDNSIdentity?,
        corefileSHA256: String?,
        hostAccessSHA256: String? = nil,
        hostAccessActive: Bool? = nil,
        ingressSHA256: String? = nil,
        ingressActive: Bool? = nil,
        ingressAccessLog: [NetworkHelperIngressAccessLogEntry]? = nil,
        mutualTLSAudit:
            [NetworkHelperMutualTLSAuditEntry]? = nil,
        certificateSHA256: String? = nil,
        certificateActive: Bool? = nil,
        certificateEvidenceSHA256: String? = nil,
        certificateSummaries: [NetworkHelperCertificateSummary]? = nil,
        policySHA256: String? = nil,
        policyActive: Bool? = nil,
        reason: String?
    ) {
        self.disposition = disposition
        self.identity = identity
        self.corefileSHA256 = corefileSHA256
        self.hostAccessSHA256 = hostAccessSHA256
        self.hostAccessActive = hostAccessActive
        self.ingressSHA256 = ingressSHA256
        self.ingressActive = ingressActive
        self.ingressAccessLog = ingressAccessLog
        self.mutualTLSAudit = mutualTLSAudit
        self.certificateSHA256 = certificateSHA256
        self.certificateActive = certificateActive
        self.certificateEvidenceSHA256 = certificateEvidenceSHA256
        self.certificateSummaries = certificateSummaries
        self.policySHA256 = policySHA256
        self.policyActive = policyActive
        self.reason = reason
    }
}

enum NetworkHelperErrorCode: String, Codable, Sendable {
    case invalidRequest
    case unsupportedProtocolVersion
    case invalidIdentity
    case invalidCorefile
    case invalidFrame
    case conflict
    case quarantined
    case unsafePath
    case ioFailure
    case permissionDenied
    case bindingUnavailable
    case certificateUnavailable
    case invalidCertificate
    case invalidProvider
    case providerRejected
    case invalidTunnel
    case tunnelRejected
}

struct NetworkHelperFailure: Codable, Equatable, Sendable {
    let code: NetworkHelperErrorCode
    let message: String
}

struct NetworkHelperResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let operation: NetworkHelperOperation
    let status: NetworkHelperStatus?
    let providerResult: NetworkHelperProviderResult?
    let tunnelResult: NetworkHelperTunnelResult?
    let error: NetworkHelperFailure?

    init(
        requestID: String,
        operation: NetworkHelperOperation,
        status: NetworkHelperStatus
    ) {
        protocolVersion = NetworkHelperProtocolV1.version
        self.requestID = requestID
        self.operation = operation
        self.status = status
        providerResult = nil
        tunnelResult = nil
        error = nil
    }

    init(
        requestID: String,
        operation: NetworkHelperOperation,
        providerResult: NetworkHelperProviderResult
    ) {
        protocolVersion = NetworkHelperProtocolV1.version
        self.requestID = requestID
        self.operation = operation
        status = nil
        self.providerResult = providerResult
        tunnelResult = nil
        error = nil
    }

    init(
        requestID: String,
        operation: NetworkHelperOperation,
        tunnelResult: NetworkHelperTunnelResult
    ) {
        protocolVersion = NetworkHelperProtocolV1.version
        self.requestID = requestID
        self.operation = operation
        status = nil
        providerResult = nil
        self.tunnelResult = tunnelResult
        error = nil
    }

    init(
        requestID: String,
        operation: NetworkHelperOperation,
        error: NetworkHelperFailure
    ) {
        protocolVersion = NetworkHelperProtocolV1.version
        self.requestID = requestID
        self.operation = operation
        status = nil
        providerResult = nil
        tunnelResult = nil
        self.error = error
    }
}

enum NetworkHelperError: Error, Equatable, Sendable {
    case invalidRequest
    case unsupportedProtocolVersion
    case invalidIdentity
    case invalidCorefile
    case invalidFrame
    case conflict
    case quarantined
    case unsafePath
    case ioFailure
    case permissionDenied
    case bindingUnavailable
    case certificateUnavailable
    case invalidCertificate
    case invalidProvider
    case providerRejected
    case invalidTunnel
    case tunnelRejected

    var failure: NetworkHelperFailure {
        let code: NetworkHelperErrorCode
        let message: String
        switch self {
        case .invalidRequest:
            code = .invalidRequest
            message = "request is invalid"
        case .unsupportedProtocolVersion:
            code = .unsupportedProtocolVersion
            message = "protocol version is unsupported"
        case .invalidIdentity:
            code = .invalidIdentity
            message = "DNS ownership identity is invalid"
        case .invalidCorefile:
            code = .invalidCorefile
            message = "CoreDNS configuration is invalid"
        case .invalidFrame:
            code = .invalidFrame
            message = "request frame is invalid"
        case .conflict:
            code = .conflict
            message = "DNS ownership conflicts with the active generation"
        case .quarantined:
            code = .quarantined
            message = "DNS state is quarantined"
        case .unsafePath:
            code = .unsafePath
            message = "DNS state path is unsafe"
        case .ioFailure:
            code = .ioFailure
            message = "DNS state operation failed"
        case .permissionDenied:
            code = .permissionDenied
            message =
                "host-access listener permission is unavailable"
        case .bindingUnavailable:
            code = .bindingUnavailable
            message =
                "host-access listener or target is unavailable"
        case .certificateUnavailable:
            code = .certificateUnavailable
            message = "certificate is unavailable"
        case .invalidCertificate:
            code = .invalidCertificate
            message = "certificate request is invalid"
        case .invalidProvider:
            code = .invalidProvider
            message = "network provider request is invalid"
        case .providerRejected:
            code = .providerRejected
            message = "network provider operation was rejected"
        case .invalidTunnel:
            code = .invalidTunnel
            message = "service tunnel request is invalid"
        case .tunnelRejected:
            code = .tunnelRejected
            message = "service tunnel operation was rejected"
        }
        return NetworkHelperFailure(code: code, message: message)
    }
}

enum NetworkHelperCanonicalJSON {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try ContainerizationHelperCanonicalJSON.encode(value)
        } catch {
            throw NetworkHelperError.invalidFrame
        }
    }

    static func decode<Value: Codable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try ContainerizationHelperCanonicalJSON.decode(
                type,
                from: data
            )
        } catch {
            throw NetworkHelperError.invalidFrame
        }
    }

    static func frame<Value: Encodable>(_ value: Value) throws -> Data {
        let payload = try encode(value)
        do {
            return try ContainerizationHelperFraming.frame(payload)
        } catch {
            throw NetworkHelperError.invalidFrame
        }
    }

    static func decodeFrame<Value: Codable>(
        _ type: Value.Type,
        from frame: Data
    ) throws -> Value {
        let payload: Data
        do {
            payload = try ContainerizationHelperFraming.decodeSingleFrame(
                frame
            )
        } catch {
            throw NetworkHelperError.invalidFrame
        }
        return try decode(type, from: payload)
    }
}
