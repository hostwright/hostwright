import CryptoKit
import Foundation
import HostwrightCore
import HostwrightNetworkHelperCore
import HostwrightNetworking
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

protocol ServiceTunnelHelperDriving: Sendable {
    func setup(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult
    func status(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult
    func reconnect(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult
    func rotateKey(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult
    func drain(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult
    func teardown(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult
}

struct LiveServiceTunnelHelperDriver:
    ServiceTunnelHelperDriving,
    Sendable
{
    private let client: NetworkHelperClient

    init(
        environment: CLIEnvironment,
        stateDatabasePath: String?
    ) throws {
        guard let hostExecutable = Bundle.main.executableURL else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Service tunnels could not resolve the Hostwright executable location."
            )
        }
        let resolution = try environment.localPathResolution(
            stateDatabasePath
        )
        client = NetworkHelperClient(
            configuration: NetworkHelperClientConfiguration(
                executableURL: hostExecutable
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "hostwright-network-helper",
                        isDirectory: false
                    ),
                runtimeDirectoryURL: URL(
                    fileURLWithPath:
                        resolution.layout.runtimeDirectory,
                    isDirectory: true
                ).appendingPathComponent(
                    "network-helper",
                    isDirectory: true
                ),
                requestTimeoutMilliseconds: 30_000,
                stateDatabaseURL: URL(
                    fileURLWithPath:
                        resolution.stateDatabasePath,
                    isDirectory: false
                )
            )
        )
    }

    func setup(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult {
        try await client.setupTunnel(
            identity: try identity(route),
            request: try request(
                route,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    }

    func status(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult {
        try await client.tunnelStatus(
            identity: try identity(route),
            request: try request(
                route,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    }

    func reconnect(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult {
        try await client.reconnectTunnel(
            identity: try identity(route),
            request: try request(
                route,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    }

    func rotateKey(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult {
        try await client.rotateTunnelKey(
            identity: try identity(route),
            request: try request(
                route,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    }

    func drain(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult {
        try await client.drainTunnel(
            identity: try identity(route),
            request: try request(
                route,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    }

    func teardown(
        route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) async throws -> NetworkHelperTunnelResult {
        try await client.teardownTunnel(
            identity: try identity(route),
            request: try request(
                route,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    }

    private func request(
        _ route: HostwrightTunnelRoute,
        timeoutMilliseconds: Int64
    ) throws -> NetworkHelperTunnelRequest {
        NetworkHelperTunnelRequest(
            route: route,
            timeoutMilliseconds: timeoutMilliseconds,
            execution:
                try ServiceTunnelLifecycleCoordinator
                    .helperExecution(route)
        )
    }

    private func identity(
        _ route: HostwrightTunnelRoute
    ) throws -> NetworkHelperDNSIdentity {
        guard let generation = Int(exactly: route.generation) else {
            throw HostwrightDiagnostic(
                code: .unsafeExposure,
                message:
                    "Service tunnel generation exceeds the helper protocol bound."
            )
        }
        return NetworkHelperDNSIdentity(
            projectUUID: route.projectUUID,
            dnsUUID: route.routeUUID,
            generation: generation,
            fencingToken: route.fencingToken
        )
    }
}

enum ServiceTunnelLifecycleCoordinator {
    typealias Discovery = @Sendable (
        String,
        HostwrightTunnelDeclaration
    ) throws -> [HostwrightBonjourTunnelCandidate]

    static func helperExecution(
        _ route: HostwrightTunnelRoute
    ) throws -> NetworkHelperTunnelExecution? {
        guard route.role != .localLoopback else {
            return nil
        }
        guard let trust = route.trust else {
            throw HostwrightDiagnostic(
                code: .unsafeExposure,
                message:
                    "Remote service tunnel route is missing its exact trust binding."
            )
        }
        let wireFencingToken =
            HostwrightResourceUUID.legacy(
                kind: "service-tunnel-wire-fence",
                identifier:
                    "\(trust.wireRouteUUID):\(trust.wireGeneration):" +
                    [
                        trust.localIdentitySHA256,
                        trust.peerCertificateSHA256,
                    ].sorted().joined(separator: ":")
            )
        switch route.role {
        case .localLoopback:
            return nil
        case .listener:
            guard let peerIdentityURI =
                    trust.peerIdentityURI,
                  let serviceTarget =
                    route.forwardEndpoint else {
                throw HostwrightDiagnostic(
                    code: .unsafeExposure,
                    message:
                        "Listener tunnel route is missing its exact peer identity or service target."
                )
            }
            return NetworkHelperTunnelExecution(
                role: .listener,
                wireRouteUUID: trust.wireRouteUUID,
                wireGeneration: trust.wireGeneration,
                wireFencingToken: wireFencingToken,
                localIdentitySHA256:
                    trust.localIdentitySHA256,
                peerTrustAnchorSHA256:
                    trust.peerTrustAnchorSHA256,
                peerCertificateSHA256:
                    trust.peerCertificateSHA256,
                peerIdentityURI: peerIdentityURI,
                serviceTarget: serviceTarget
            )
        case .dialer:
            guard let peerDNSName = trust.peerDNSName,
                  let bindEndpoint = route.bindEndpoint else {
                throw HostwrightDiagnostic(
                    code: .unsafeExposure,
                    message:
                        "Dialer tunnel route is missing its exact peer DNS identity or local forward endpoint."
                )
            }
            return NetworkHelperTunnelExecution(
                role: .dialer,
                wireRouteUUID: trust.wireRouteUUID,
                wireGeneration: trust.wireGeneration,
                wireFencingToken: wireFencingToken,
                localIdentitySHA256:
                    trust.localIdentitySHA256,
                peerTrustAnchorSHA256:
                    trust.peerTrustAnchorSHA256,
                peerCertificateSHA256:
                    trust.peerCertificateSHA256,
                peerDNSName: peerDNSName,
                localForwardEndpoint:
                    try HostwrightTunnelEndpoint(
                        host: bindEndpoint.host,
                        port: bindEndpoint.port
                    )
            )
        }
    }

    static func validateLiveCredentialPrerequisites(
        _ declarations:
            [String: HostwrightTunnelDeclaration]
    ) throws {
        for (name, declaration) in declarations.sorted(
            by: { $0.key < $1.key }
        ) {
            if declaration.role == .localLoopback,
               !declaration.authenticatedEndpoints.contains(
                   where: {
                       $0.host == "127.0.0.1" ||
                           $0.host == "localhost" ||
                           $0.host == "::1"
                   }
               ) {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Tunnel '\(name)' requires an explicit loopback endpoint. No mutation was attempted."
                )
            }
            guard declaration.role == .localLoopback ||
                    declaration.trust != nil else {
                throw HostwrightDiagnostic(
                    code: .unsafeExposure,
                    message:
                        "Tunnel '\(name)' requires an exact non-TOFU trust binding. No mutation was attempted."
                )
            }
            if declaration.role != .localLoopback,
               let trust = declaration.trust {
                let role:
                    NetworkHelperTunnelRole =
                        declaration.role == .listener
                            ? .listener : .dialer
                do {
                    _ = try NetworkHelperTunnelCredentialPreflight
                        .validate(
                            descriptor:
                                NetworkHelperTunnelCredentialDescriptor(
                                    role: role,
                                    localIdentitySHA256:
                                        trust.localIdentitySHA256,
                                    peerTrustAnchorSHA256:
                                        trust.peerTrustAnchorSHA256,
                                    peerCertificateSHA256:
                                        trust.peerCertificateSHA256,
                                    peerDNSName:
                                        trust.peerDNSName,
                                    peerIdentityURI:
                                        trust.peerIdentityURI
                                )
                        )
                } catch {
                    throw HostwrightDiagnostic(
                        code: .runtimeUnavailable,
                        message:
                            "Tunnel '\(name)' could not validate its exact Keychain identity and peer trust before mutation."
                    )
                }
            }
        }
    }

    static func routes(
        declarations: [String: HostwrightTunnelDeclaration],
        preparation: LifecycleCommandPreparation,
        operationGroupID: String,
        discovery: Discovery = { _, _ in [] }
    ) throws -> [HostwrightTunnelRoute] {
        try declarations.sorted(by: { $0.key < $1.key }).map {
            name,
            declaration in
            let services = preparation.desiredState.services.filter {
                $0.logicalServiceName ==
                    declaration.targetService
            }
            let matches = services.flatMap { service in
                service.ports.compactMap { port in
                    port.containerPort == declaration.targetPort &&
                        port.exposurePolicy.scope == .tunnel &&
                        port.exposurePolicy.authentication ==
                            .authenticatedTunnel
                        ? (service, port)
                        : nil
                }
            }
            let match: (
                DesiredRuntimeService,
                RuntimePortMapping
            )?
            let binding: LifecycleResourceBinding?
            switch declaration.role {
            case .localLoopback, .listener:
                guard matches.count == 1,
                      let resolved = matches.first,
                      let resolvedBinding =
                        preparation.resourceBindings.first(where: {
                            $0.identity == resolved.0.identity
                        }) else {
                    throw HostwrightDiagnostic(
                        code: .unsafeExposure,
                        message:
                            "Tunnel '\(name)' must resolve to exactly one authenticated-tunnel runtime port and exact resource binding."
                    )
                }
                match = resolved
                binding = resolvedBinding
            case .dialer:
                match = nil
                binding = nil
            }
            let declared = try declaration
                .authenticatedEndpoints.map {
                    try HostwrightTunnelEndpoint(
                        host: $0.host,
                        port: $0.port
                    )
                }
            let discovered = declaration.bonjourDiscovery
                ? try discovery(name, declaration).filter {
                    $0.peerUUID == declaration.peerUUID
                }.map(\.endpoint)
                : []
            let endpoints = Array(
                Set(declared + discovered)
            ).sorted { ($0.host, $0.port) < ($1.host, $1.port) }
            guard !endpoints.isEmpty ||
                    declaration.role == .listener else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Tunnel '\(name)' has no authenticated endpoint after bounded Bonjour discovery."
                )
            }
            let relay = try declaration.relayEndpoint.map {
                try HostwrightTunnelEndpoint(
                    host: $0.host,
                    port: $0.port
                )
            }
            let routeUUID = HostwrightResourceUUID.legacy(
                kind: "service-tunnel-route",
                identifier:
                    "\(preparation.projectResourceUUID):\(name)"
            )
            let desiredSHA256 = try desiredSHA256(
                name: name,
                declaration: declaration,
                resourceUUID: binding?.resourceUUID,
                resourceGeneration:
                    binding?.resourceGeneration
            )
            let forwardEndpoint:
                HostwrightTunnelEndpoint?
            if let match {
                guard let hostPort = match.1.hostPort,
                      let bindAddress = match.1.bindAddress else {
                    throw HostwrightDiagnostic(
                        code: .unsafeExposure,
                        message:
                            "Tunnel '\(name)' target port has no resolved loopback forwarding endpoint."
                    )
                }
                forwardEndpoint = try HostwrightTunnelEndpoint(
                    host: bindAddress,
                    port: hostPort
                )
            } else {
                forwardEndpoint = nil
            }
            return try HostwrightTunnelRoute(
                routeUUID: routeUUID,
                projectUUID:
                    preparation.projectResourceUUID,
                peerUUID: declaration.peerUUID,
                generation: Int64(
                    binding?.resourceGeneration ??
                        preparation.projectGeneration
                ),
                providerID: preparation.providerID.rawValue,
                providerGeneration:
                    Int64(preparation.providerGeneration),
                fencingToken:
                    preparation.planFencingToken,
                operationGroupID: operationGroupID,
                desiredSHA256: desiredSHA256,
                role: declaration.role,
                trust: declaration.trust,
                bindEndpoint: declaration.bindEndpoint,
                forwardEndpoint: forwardEndpoint,
                authenticatedEndpoints: endpoints,
                relayEndpoint: relay
            )
        }
    }

    static func reconcile(
        command: LifecycleCommand,
        desiredRoutes: [HostwrightTunnelRoute],
        projectUUID: String,
        timeoutSeconds: Int,
        store: SQLiteStateStore,
        helper: any ServiceTunnelHelperDriving
    ) async throws {
        let timeout = min(
            Int64(timeoutSeconds) * 1_000,
            NetworkHelperProtocolV1
                .maximumTunnelOperationMilliseconds
        )
        let persisted = try store.serviceTunnels
            .listRecoverable(projectUUID: projectUUID)
            .compactMap {
                try store.serviceTunnels.load(
                    routeUUID: $0.id
                )?.route
            }
        let persistedByID = Dictionary(
            uniqueKeysWithValues: persisted.map {
                ($0.routeUUID, $0)
            }
        )
        switch command {
        case .down, .stop:
            for route in persisted.sorted(by: routePrecedes) {
                _ = try await helper.drain(
                    route: route,
                    timeoutMilliseconds: timeout
                )
            }
        case .remove:
            for route in persisted.sorted(by: routePrecedes) {
                _ = try await helper.teardown(
                    route: route,
                    timeoutMilliseconds: timeout
                )
            }
        case .up, .run, .start, .restart, .update, .apply,
                .resume, .rollback:
            let desiredByID = Dictionary(
                uniqueKeysWithValues: desiredRoutes.map {
                    ($0.routeUUID, $0)
                }
            )
            for route in persisted.sorted(by: routePrecedes)
            where desiredByID[route.routeUUID] != route {
                _ = try await helper.teardown(
                    route: route,
                    timeoutMilliseconds: timeout
                )
            }
            for route in desiredRoutes.sorted(by: routePrecedes) {
                if command == .restart,
                   let current = persistedByID[route.routeUUID],
                   current == route {
                    let status = try await helper.status(
                        route: current,
                        timeoutMilliseconds: timeout
                    )
                    if status.live {
                        _ = try await helper.rotateKey(
                            route: current,
                            timeoutMilliseconds: timeout
                        )
                        _ = try await helper.reconnect(
                            route: current,
                            timeoutMilliseconds: timeout
                        )
                        continue
                    }
                }
                _ = try await helper.setup(
                    route: route,
                    timeoutMilliseconds: timeout
                )
            }
        }
    }

    private static func desiredSHA256(
        name: String,
        declaration: HostwrightTunnelDeclaration,
        resourceUUID: String?,
        resourceGeneration: Int?
    ) throws -> String {
        struct Evidence: Encodable {
            let name: String
            let declaration: HostwrightTunnelDeclaration
            let resourceUUID: String?
            let resourceGeneration: Int?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return SHA256.hash(
            data: try encoder.encode(
                Evidence(
                    name: name,
                    declaration: declaration,
                    resourceUUID: resourceUUID,
                    resourceGeneration: resourceGeneration
                )
            )
        ).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func routePrecedes(
        _ lhs: HostwrightTunnelRoute,
        _ rhs: HostwrightTunnelRoute
    ) -> Bool {
        (
            lhs.peerUUID,
            lhs.generation,
            lhs.routeUUID
        ) < (
            rhs.peerUUID,
            rhs.generation,
            rhs.routeUUID
        )
    }
}

struct LifecycleServiceTunnelFinalizer:
    LifecycleSagaFinalizing,
    Sendable
{
    let preparation: LifecycleCommandPreparation
    let timeoutSeconds: Int
    let store: SQLiteStateStore
    let helper: any ServiceTunnelHelperDriving
    let discovery:
        ServiceTunnelLifecycleCoordinator.Discovery

    init(
        preparation: LifecycleCommandPreparation,
        timeoutSeconds: Int,
        store: SQLiteStateStore,
        helper: any ServiceTunnelHelperDriving,
        discovery:
            @escaping ServiceTunnelLifecycleCoordinator.Discovery = {
                _,
                _ in []
            }
    ) {
        self.preparation = preparation
        self.timeoutSeconds = timeoutSeconds
        self.store = store
        self.helper = helper
        self.discovery = discovery
    }

    func finalize(
        context: LifecycleSagaContext
    ) async throws {
        let routes: [HostwrightTunnelRoute]
        switch context.plan.command {
        case .up, .run, .start, .restart, .update, .apply,
                .resume, .rollback:
            routes = try ServiceTunnelLifecycleCoordinator.routes(
                declarations:
                    preparation.tunnelDeclarations,
                preparation: preparation,
                operationGroupID: context.groupID,
                discovery: discovery
            )
        case .down, .stop, .remove:
            routes = []
        }
        try await ServiceTunnelLifecycleCoordinator.reconcile(
            command: context.plan.command,
            desiredRoutes: routes,
            projectUUID: preparation.projectResourceUUID,
            timeoutSeconds: timeoutSeconds,
            store: store,
            helper: helper
        )
    }
}
