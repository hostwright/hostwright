import XCTest
@testable import HostwrightManifest
import HostwrightNetworking

final class Phase07NetworkManifestTests: XCTestCase {
    func testNetworkDeclarationsAndAttachmentsRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: network-demo
            networks:
              frontend: {}
              backend:
                driver: hostOnly
                ipv4: 10.42.0.0/24
                ipv6: fd42::/64
            services:
              api:
                image: local/api:latest
                networks:
                  - network: backend
                    aliases: [z-api, api]
                  - frontend
            """
        )

        XCTAssertEqual(manifest.networks.keys.sorted(), ["backend", "frontend"])
        XCTAssertEqual(manifest.networks["frontend"]?.driver.rawValue, "nat")
        XCTAssertEqual(manifest.networks["frontend"]?.ipv4.manifestValue, "auto")
        XCTAssertEqual(manifest.networks["frontend"]?.ipv6.manifestValue, "auto")
        XCTAssertEqual(manifest.networks["backend"]?.driver.rawValue, "hostOnly")
        XCTAssertEqual(manifest.networks["backend"]?.ipv4.manifestValue, "10.42.0.0/24")
        XCTAssertEqual(manifest.networks["backend"]?.ipv6.manifestValue, "fd42::/64")

        let service = try XCTUnwrap(manifest.services.first)
        XCTAssertEqual(service.networks.map(\.network), ["backend", "frontend"])
        XCTAssertEqual(service.networks[0].aliases, ["api", "z-api"])
        XCTAssertTrue(service.networks[1].aliases.isEmpty)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(canonical, try ManifestCanonicalEncoder.encode(manifest))
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #""backend":"#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #""frontend":"#)?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #""api""#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #""z-api""#)?.lowerBound)
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testLegacyManifestWithoutNetworksKeepsExistingMeaning() throws {
        let source =
            """
            version: 2
            project: legacy-network-default
            services:
              api:
                image: local/api:latest
            """
        let manifest = try ManifestValidator.validated(source)

        XCTAssertTrue(manifest.networks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(manifest.services.first).networks.isEmpty)
        XCTAssertEqual(
            try ManifestValidator.validated(ManifestCanonicalEncoder.encode(manifest)),
            manifest
        )
    }

    func testRejectsInvalidNetworkDriverAndUnknownFieldsStrictly() {
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend:
                driver: bridge
            services:
              api:
                image: local/api:latest
            """,
            contains: "driver must be one of: nat, hostOnly",
            path: "$.networks.backend.driver"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend:
                mtu: 1500
            services:
              api:
                image: local/api:latest
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported top-level network field 'mtu'",
            path: "$.networks.backend.mtu"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks: []
            services:
              api:
                image: local/api:latest
            """,
            code: "HW-MANIFEST-001",
            contains: "Expected a mapping",
            path: "$.networks"
        )
    }

    func testRejectsWrongAddressFamiliesAndFullyDisabledNetworks() {
        assertFailure(
            manifest(networks: "ipv4: fd42::/64"),
            contains: "valid IPv4 CIDR",
            path: "$.networks.backend.ipv4"
        )
        assertFailure(
            manifest(networks: "ipv6: 10.42.0.0/24"),
            contains: "valid IPv6 CIDR",
            path: "$.networks.backend.ipv6"
        )
        assertFailure(
            manifest(networks: "ipv4: disabled\n    ipv6: disabled"),
            contains: "must enable at least one address family",
            path: "$.networks.backend"
        )
    }

    func testIPv4OnlyIPv6OnlyAndDualStackRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: address-families
            networks:
              dual-stack:
                ipv4: 10.42.0.0/24
                ipv6: FD42:0000:0000:0000::/64
              ipv4-only:
                ipv4: 10.43.0.0/24
                ipv6: disabled
              ipv6-only:
                ipv4: disabled
                ipv6: fd43:0:0:0::/64
            services:
              api:
                image: local/api:latest
                networks: [dual-stack, ipv4-only, ipv6-only]
            """
        )

        XCTAssertEqual(manifest.networks["dual-stack"]?.ipv4.manifestValue, "10.42.0.0/24")
        XCTAssertEqual(manifest.networks["dual-stack"]?.ipv6.manifestValue, "fd42::/64")
        XCTAssertEqual(manifest.networks["ipv4-only"]?.ipv6, .disabled)
        XCTAssertEqual(manifest.networks["ipv6-only"]?.ipv4, .disabled)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains(#"ipv6: "fd42::/64""#))
        XCTAssertTrue(canonical.contains(#"ipv6: "disabled""#))
        XCTAssertTrue(canonical.contains(#"ipv4: "disabled""#))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testRejectsNonNetworkCIDRsAndOverlappingExplicitSubnets() {
        assertFailure(
            manifest(networks: "ipv4: 10.42.0.7/24\n    ipv6: disabled"),
            contains: "must use the canonical network address 10.42.0.0/24",
            path: "$.networks.backend.ipv4"
        )
        assertFailure(
            manifest(networks: "ipv4: disabled\n    ipv6: fd42::7/64"),
            contains: "must use the canonical network address fd42::/64",
            path: "$.networks.backend.ipv6"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend:
                ipv4: 10.42.0.0/24
                ipv6: fd42::/64
              frontend:
                ipv4: 10.42.0.128/25
                ipv6: fd43::/64
            services:
              api:
                image: local/api:latest
                networks: [backend]
            """,
            contains: "overlaps network 'backend' IPv4 CIDR 10.42.0.0/24",
            path: "$.networks.frontend.ipv4"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend:
                ipv4: disabled
                ipv6: fd42::/64
              frontend:
                ipv4: disabled
                ipv6: fd42::/80
            services:
              api:
                image: local/api:latest
                networks: [backend]
            """,
            contains: "overlaps network 'backend' IPv6 CIDR fd42::/64",
            path: "$.networks.frontend.ipv6"
        )
    }

    func testRejectsInvalidMissingAndDuplicateServiceAttachments() {
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - missing
            """,
            contains: "must reference a declared top-level network",
            path: "$.services.api.networks"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - backend
                  - network: backend
                    aliases: [api, api]
            """,
            contains: "must not attach network 'backend' more than once",
            path: "$.services.api.networks"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - network: backend
                    aliases: ["Bad_Alias"]
            """,
            contains: "network alias 'Bad_Alias'",
            path: "$.services.api.networks"
        )
        let excessiveAliases = (0...64)
            .map { "alias-\($0)" }
            .joined(separator: ", ")
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - network: backend
                    aliases: [\(excessiveAliases)]
            """,
            contains: "must declare at most 64 aliases",
            path: "$.services.api.networks"
        )
    }

    func testUnixSocketPublicationsRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: socket-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - target: /run/api.sock
                    protocol: unix
                  - host: shared-api.sock
                    target: /run/shared.sock
                    protocol: unix
                    mode: "0660"
            """
        )

        let sockets = try XCTUnwrap(
            manifest.services.first
        ).publishedSockets
        XCTAssertEqual(
            sockets,
            [
                HostwrightPublishedSocket(
                    containerPath: "/run/api.sock"
                ),
                HostwrightPublishedSocket(
                    hostName: "shared-api.sock",
                    containerPath: "/run/shared.sock",
                    mode: .ownerAndGroup
                )
            ]
        )
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains(#"protocol: "unix""#))
        XCTAssertTrue(canonical.contains(#"mode: "0600""#))
        XCTAssertTrue(canonical.contains(#"mode: "0660""#))
        XCTAssertEqual(
            try ManifestValidator.validated(canonical),
            manifest
        )
    }

    func testUnixSocketPublicationRejectsUnsafeShapeBeforeMutation() {
        assertFailure(
            """
            version: 2
            project: socket-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - bind: 127.0.0.1
                    target: /run/api.sock
                    protocol: unix
            """,
            contains: "does not accept bind",
            path: "$.services.api.ports[0].bind"
        )
        assertFailure(
            """
            version: 2
            project: socket-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - target: /run/api.sock
                    protocol: unix
                    mode: "0777"
            """,
            contains: "mode must be one of",
            path: "$.services.api.ports[0].mode"
        )
    }

    func testUnixSocketPublicationRejectsUnsafePathsAndCollisions() throws {
        let manifest = try ManifestParser.parse(
            """
            version: 2
            project: socket-demo
            services:
              api:
                image: local/api:latest
                replicas: 2
                ports:
                  - host: shared.sock
                    target: /run/api:unsafe.sock
                    protocol: unix
                  - host: shared.sock
                    target: /run/second.sock
                    protocol: unix
              worker:
                image: local/worker:latest
                ports:
                  - host: shared.sock
                    target: /run/worker.sock
                    protocol: unix
                  - target: /run/worker.sock
                    protocol: unix
                    mode: "0660"
            """
        )
        let messages = ManifestValidator.validate(manifest).map(\.message)
        XCTAssertTrue(messages.contains {
            $0.contains("without ':'")
        })
        XCTAssertTrue(messages.contains {
            $0.contains("replicas cannot share fixed Unix socket")
        })
        XCTAssertTrue(messages.contains {
            $0.contains("published by multiple services")
        })
        XCTAssertTrue(messages.contains {
            $0.contains("same host path")
        })
        XCTAssertTrue(messages.contains {
            $0.contains("share a container target")
        })
    }

    func testGuardedHostAccessRoundTripsCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: host-access-demo
            networks:
              guarded: {}
            services:
              api:
                image: local/api:latest
                networks: [guarded]
                hostAccess:
                  - hostname: database.hostwright.internal
                    protocol: tcp
                    addressClass: loopback
                    port: 5432
                  - hostname: cache.hostwright.internal
                    protocol: udp
                    addressClass: interface
                    port: 11211
            """
        )

        let endpoints = try XCTUnwrap(manifest.services.first).hostAccess
        XCTAssertEqual(
            endpoints,
            [
                HostwrightHostAccessEndpoint(
                    hostname: "cache.hostwright.internal",
                    protocolName: .udp,
                    addressClass: .interface,
                    port: 11211
                ),
                HostwrightHostAccessEndpoint(
                    hostname: "database.hostwright.internal",
                    protocolName: .tcp,
                    addressClass: .loopback,
                    port: 5432
                )
            ]
        )

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertLessThan(
            try XCTUnwrap(
                canonical.range(of: #""cache.hostwright.internal""#)?.lowerBound
            ),
            try XCTUnwrap(
                canonical.range(of: #""database.hostwright.internal""#)?
                    .lowerBound
            )
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testGuardedHostAccessRejectsUnsafeAndDuplicateEndpoints() throws {
        for hostname in [
            "*",
            "127.0.0.1",
            "::1",
            "localhost",
            "metadata.google.internal",
            "Uppercase.hostwright.internal"
        ] {
            assertFailure(
                hostAccessManifest(
                    """
                    - hostname: "\(hostname)"
                      protocol: tcp
                      addressClass: loopback
                      port: 8080
                    """
                ),
                contains: "must be a lowercase DNS hostname",
                path: "$.services.api.hostAccess[0].hostname"
            )
        }

        assertFailure(
            hostAccessManifest(
                """
                - hostname: api.hostwright.internal
                  protocol: tcp
                  addressClass: loopback
                  port: 0
                """
            ),
            contains: "port must be between 1 and 65535",
            path: "$.services.api.hostAccess[0].port"
        )

        let duplicate = try ManifestParser.parse(
            hostAccessManifest(
                """
                - hostname: api.hostwright.internal
                  protocol: tcp
                  addressClass: loopback
                  port: 8080
                - hostname: api.hostwright.internal
                  protocol: tcp
                  addressClass: loopback
                  port: 8080
                """
            )
        )
        let issues = ManifestValidator.validate(duplicate)
        XCTAssertTrue(
            issues.contains {
                $0.path == "$.services.api.hostAccess[1]" &&
                    $0.message.contains("must not contain duplicate")
            }
        )
    }

    func testGuardedHostAccessRejectsUnknownFieldsAndExcessiveEndpoints() {
        assertFailure(
            hostAccessManifest(
                """
                - hostname: api.hostwright.internal
                  protocol: tcp
                  addressClass: loopback
                  port: 8080
                  redirect: true
                """
            ),
            code: "HW-MANIFEST-003",
            contains: "Unsupported hostAccess field 'redirect'",
            path: "$.services.api.hostAccess[0].redirect"
        )

        let endpoints = (0...HostwrightHostAccessEndpoint.maximumEndpointsPerService)
            .map {
                """
                - hostname: host-\($0).hostwright.internal
                  protocol: tcp
                  addressClass: loopback
                  port: 8080
                """
            }
            .joined(separator: "\n")
        assertFailure(
            hostAccessManifest(endpoints),
            contains: "must declare at most 64 endpoints",
            path: "$.services.api.hostAccess"
        )
    }

    func testGuardedHostAccessRequiresEveryEndpointField() {
        assertFailure(
            hostAccessManifest(
                """
                - hostname: api.hostwright.internal
                  addressClass: loopback
                  port: 8080
                """
            ),
            contains: "protocol is required",
            path: "$.services.api.hostAccess[0].protocol"
        )
        assertFailure(
            hostAccessManifest(
                """
                - hostname: api.hostwright.internal
                  protocol: tcp
                  port: 8080
                """
            ),
            contains: "addressClass is required",
            path: "$.services.api.hostAccess[0].addressClass"
        )
    }

    func testGuardedHostAccessRejectsIPv6OnlyProjectNetwork()
        throws
    {
        assertFailure(
            """
            version: 2
            project: host-access-demo
            networks:
              guarded:
                ipv4: disabled
                ipv6: fd42::/64
            services:
              api:
                image: local/api:latest
                networks: [guarded]
                hostAccess:
                  - hostname: api.hostwright.internal
                    protocol: tcp
                    addressClass: loopback
                    port: 8080
            """,
            contains:
                "hostAccess requires an IPv4-enabled project network",
            path: "$.services.api.networks[0]"
        )
    }

    func testPublishedPortExposureParsesAndCanonicalizes() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: exposure-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - bind: 192.168.1.10
                    host: 8443
                    target: 8443
                    protocol: tcp
                    exposure:
                      scope: lan
                      interfaces: [en1]
                      networkClasses: [vpn, private]
                      allowedCIDRs: [10.0.0.0/8]
                      authentication: tls
                  - "8080:8080"
            """
        )
        let ports = try XCTUnwrap(manifest.services.first?.publishedPorts)
        XCTAssertEqual(ports[0].exposure?.scope, .lan)
        XCTAssertEqual(ports[0].exposure?.networkClasses, [.privateLAN, .vpn])
        XCTAssertEqual(ports[1].effectiveExposure, .localhost)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains("exposure:"))
        XCTAssertFalse(canonical.contains("scope: \"localhost\""))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testLocalhostBindAliasCanonicalizesWithoutChangingExposure() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: exposure-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - bind: localhost
                    host: 8080
                    target: 8080
                    protocol: tcp
            """
        )
        let port = try XCTUnwrap(
            manifest.services.first?.publishedPorts.first
        )

        XCTAssertEqual(port.effectiveBindAddress, "127.0.0.1")
        XCTAssertEqual(port.effectiveExposure, .localhost)
        XCTAssertTrue(
            try ManifestCanonicalEncoder.encode(manifest)
                .contains("bind: \"127.0.0.1\"")
        )
    }

    func testRejectsInvalidPublishedPortExposure() {
        assertFailure(
            """
            version: 2
            project: exposure-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - bind: 127.0.0.2
                    target: 8443
            """,
            contains: "localhost exposure requires",
            path: "$.services.api"
        )
        assertFailure(
            """
            version: 2
            project: exposure-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - bind: 0.0.0.0
                    target: 8443
                    exposure:
                      scope: lan
                      interfaces: [en0]
                      networkClasses: [private]
                      allowedCIDRs: [10.0.0.1/8]
                      authentication: tls
            """,
            contains: "canonical IPv4 or IPv6 CIDRs",
            path: "$.services.api.ports[0].exposure.allowedCIDRs[0]"
        )
        assertFailure(
            """
            version: 2
            project: exposure-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - target: 8443
                    exposure:
                      scope: localhost
                      authentication: tls
            """,
            contains: "localhost exposure requires",
            path: "$.services.api"
        )
        let interfaces = (0...8).map { "en\($0)" }.joined(separator: ", ")
        assertFailure(
            """
            version: 2
            project: exposure-demo
            services:
              api:
                image: local/api:latest
                ports:
                  - bind: 192.168.1.10
                    target: 8443
                    exposure:
                      scope: lan
                      interfaces: [\(interfaces)]
                      networkClasses: [private]
                      allowedCIDRs: [10.0.0.0/8]
                      authentication: tls
            """,
            contains: "at most 8 interfaces",
            path: "$.services.api.ports[0].exposure"
        )
    }

    func testIngressParsesDefaultsAndRoundTripsCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: ingress-demo
            networks:
              backend: {}
            ingress:
              public:
                port: 8080
                routes:
                  - hostname: api.hostwright.internal
                    targetService: api
                    targetPort: 8080
                  - hostname: api.hostwright.internal
                    pathPrefix: /socket
                    methods: [GET]
                    protocol: websocket
                    targetService: api
                    targetPort: 8080
            services:
              api:
                image: local/api:latest
                ports: ["8080:8080"]
                networks: [backend]
            """
        )

        let listener = try XCTUnwrap(manifest.ingress["public"])
        XCTAssertEqual(listener.bindAddress, "127.0.0.1")
        XCTAssertEqual(listener.exposure, .localhost)
        XCTAssertEqual(listener.routes.map(\.pathPrefix), ["/", "/socket"])
        XCTAssertEqual(listener.routes[0].methods, ["GET"])
        XCTAssertEqual(listener.routes[0].protocolName, .http)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains("ingress:"))
        XCTAssertTrue(
            canonical.contains(
                "  \"public\":\n    port: 8080\n    routes:"
            )
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testIngressRejectsUnknownFieldsAndConflictingRoutes() {
        assertFailure(
            """
            version: 2
            project: ingress-demo
            ingress:
              api:
                port: 8080
                routes:
                  - hostname: api.hostwright.internal
                    targetService: api
                    targetPort: 8080
                redirect: true
            services:
              api:
                image: local/api:latest
                ports: ["8080:8080"]
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported ingress field 'redirect'",
            path: "$.ingress.api.redirect"
        )
        assertFailure(
            ingressManifest(
                """
                - hostname: api.hostwright.internal
                  targetService: api
                  targetPort: 8080
                - hostname: api.hostwright.internal
                  targetService: api
                  targetPort: 8080
                """
            ),
            contains: "contains a conflicting route",
            path: "$.ingress.api.routes[1]"
        )
    }

    func testIngressRejectsUnsafeRoutesAndInvalidExposure() {
        assertFailure(
            ingressManifest(
                """
                - hostname: "*.hostwright.internal"
                  pathPrefix: /safe
                  targetService: api
                  targetPort: 8080
                """
            ),
            contains: "must be exact lowercase DNS-like text without wildcards",
            path: "$.ingress.api.routes[0].hostname"
        )
        assertFailure(
            ingressManifest(
                """
                - hostname: api.hostwright.internal
                  pathPrefix: /%2e%2e/admin
                  targetService: api
                  targetPort: 8080
                """
            ),
            contains: "normalized absolute path",
            path: "$.ingress.api.routes[0].pathPrefix"
        )
        assertFailure(
            ingressManifest(
                """
                - hostname: api.hostwright.internal
                  methods: [get]
                  targetService: api
                  targetPort: 8080
                """
            ),
            contains: "unique canonical HTTP methods",
            path: "$.ingress.api.routes[0].methods"
        )
        assertFailure(
            ingressManifest(
                """
                - hostname: api.hostwright.internal
                  targetService: api
                  targetPort: 8080
                """,
                bind: "0.0.0.0",
                exposure: """
                scope: localhost
                authentication: none
                """
            ),
            contains: "exposure does not match",
            path: "$.ingress.api.exposure"
        )
    }

    func testIngressRejectsMissingServiceUndeclaredTargetPortAndMaxima() {
        assertFailure(
            """
            version: 2
            project: ingress-demo
            ingress:
              api:
                port: 8080
                routes:
                  - hostname: api.hostwright.internal
                    targetService: api
                    targetPort: 8080
            services:
              api:
                image: local/api:latest
                ports: ["8080:8080"]
            """,
            contains: "must attach to a declared Hostwright project network",
            path: "$.ingress.api.routes[0].targetService"
        )
        assertFailure(
            ingressManifest(
                """
                - hostname: api.hostwright.internal
                  targetService: missing
                  targetPort: 8080
                """
            ),
            contains: "references missing service 'missing'",
            path: "$.ingress.api.routes[0].targetService"
        )
        assertFailure(
            ingressManifest(
                """
                - hostname: api.hostwright.internal
                  targetService: api
                  targetPort: 9090
                """
            ),
            contains: "must reference a declared container port",
            path: "$.ingress.api.routes[0].targetPort"
        )
        let excessiveRoutes = (0...HostwrightIngressListener.maximumRoutes)
            .map {
                """
                - hostname: route-\($0).hostwright.internal
                  targetService: api
                  targetPort: 8080
                """
            }
            .joined(separator: "\n")
        assertFailure(
            ingressManifest(excessiveRoutes),
            contains: "accepts at most 256 routes per listener",
            path: "$.ingress.api.routes"
        )
    }

    private func manifest(networks: String) -> String {
        """
        version: 2
        project: network-demo
        networks:
          backend:
            \(networks)
        services:
          api:
            image: local/api:latest
            networks: [backend]
        """
    }

    private func hostAccessManifest(_ endpoints: String) -> String {
        """
        version: 2
        project: host-access-demo
        networks:
          guarded: {}
        services:
          api:
            image: local/api:latest
            networks: [guarded]
            hostAccess:
        \(endpoints.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "      \($0)" }
            .joined(separator: "\n"))
        """
    }

    func testCertificateDeclarationsRoundTripAndApplyDefaults() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: certificate-demo
            networks: { backend: {} }
            certificates:
              imported: { source: imported, identitySHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
              local: { source: localCA }
              provider: { source: provider, issuer: acme-prod, statusPolicy: required }
            ingress:
              api:
                certificate: local
                bind: 192.168.1.10
                port: 8443
                exposure: { scope: lan, interfaces: [en0], networkClasses: [private], allowedCIDRs: [10.0.0.0/8], authentication: tls }
                routes: [{ hostname: api.example.test, targetService: api, targetPort: 8080 }]
              imported-api:
                certificate: imported
                port: 8444
                routes: [{ hostname: imported.example.test, targetService: api, targetPort: 8080 }]
              provider-api:
                certificate: provider
                port: 8445
                routes: [{ hostname: provider.example.test, targetService: api, targetPort: 8080 }]
            services:
              api: { image: local/api:latest, ports: ["8080:8080"], networks: [backend] }
            """
        )
        XCTAssertEqual(manifest.certificates["local"]?.renewBeforeSeconds, 604_800)
        XCTAssertEqual(manifest.certificates["local"]?.validitySeconds, 2_592_000)
        XCTAssertEqual(manifest.certificates["local"]?.statusPolicy, .ifAvailable)
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains("certificates:"))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testCertificatesRejectInvalidCombinationsAndMissingIngressReference() {
        assertFailure("""
        version: 2
        project: certificate-demo
        certificates: { imported: { source: imported } }
        services: { api: { image: local/api:latest } }
        """, contains: "requires a lowercase 64-hex", path: "$.certificates.imported.identitySHA256")
        assertFailure("""
        version: 2
        project: certificate-demo
        networks: { backend: {} }
        ingress: { api: { certificate: absent, port: 8080, routes: [{ hostname: api.example.test, targetService: api, targetPort: 8080 }] } }
        services: { api: { image: local/api:latest, ports: ["8080:8080"], networks: [backend] } }
        """, contains: "references missing certificate", path: "$.ingress.api.certificate")
        assertFailure("""
        version: 2
        project: certificate-demo
        certificates: { local: { source: localCA } }
        services: { api: { image: local/api:latest } }
        """, contains: "must be referenced", path: "$.certificates.local")
    }

    func testIngressTLSAndLANRequireCertificate() {
        assertFailure(ingressManifest("""
        - hostname: api.example.test
          targetService: api
          targetPort: 8080
        """, bind: "192.168.1.10", exposure: """
        scope: lan
        interfaces: [en0]
        networkClasses: [private]
        allowedCIDRs: [10.0.0.0/8]
        authentication: tls
        """), contains: "requires a certificate", path: "$.ingress.api.certificate")
    }

    func testIngressMTLSPeersRequireCertificateAndCanonicalize() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: ingress-mtls
            networks: { backend: {} }
            certificates: { local: { source: localCA } }
            ingress:
              api:
                certificate: local
                port: 8443
                exposure: { scope: localhost, authentication: mtls }
                peers: [{ service: worker, role: workload }]
                routes: [{ hostname: api.example.test, targetService: api, targetPort: 8080 }]
            services:
              api: { image: local/api:latest, ports: ["8080:8080"], networks: [backend] }
              worker: { image: local/worker:latest, networks: [backend] }
            """
        )
        XCTAssertEqual(manifest.ingress["api"]?.peers, [HostwrightIngressPeerSelector(service: "worker", role: .workload)])
        XCTAssertTrue(try ManifestCanonicalEncoder.encode(manifest).contains("peers:"))

        assertFailure(
            """
            version: 2
            project: ingress-mtls
            networks: { backend: {} }
            certificates: { local: { source: localCA } }
            ingress: { api: { certificate: local, port: 8443, exposure: { scope: localhost, authentication: mtls }, routes: [{ hostname: api.example.test, targetService: api, targetPort: 8080 }] } }
            services: { api: { image: local/api:latest, ports: ["8080:8080"], networks: [backend] } }
            """,
            contains: "mTLS requires at least one peer",
            path: "$.ingress.api.peers"
        )
    }

    func testServiceNetworkPolicyRoundTripsCanonicalAndKeepsAbsentPolicyCompatible() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: policy-demo
            services:
              api:
                image: local/api:latest
                networkPolicy:
                  ingress:
                    - service: worker
                      project: policy-demo
                      identity: spiffe://hostwright.internal/workers/worker
                      protocol: tcp
                      address: 10.42.0.0/24
                      port: 8080
                      dns: worker.policy.test
                  egress:
                    - protocol: udp
                      address: fd42::/64
                      port: 53
                      dns: resolver.policy.test
            """
        )

        let policy = try XCTUnwrap(manifest.services.first?.networkPolicy)
        XCTAssertEqual(policy.ingress.count, 1)
        XCTAssertEqual(policy.egress.count, 1)
        XCTAssertEqual(policy.ingress[0].protocolName, .tcp)
        XCTAssertEqual(policy.egress[0].protocolName, .udp)
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains("networkPolicy:"))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)

        let legacy = try ManifestValidator.validated(
            """
            version: 2
            project: no-policy
            services:
              api: { image: local/api:latest }
            """
        )
        XCTAssertNil(legacy.services[0].networkPolicy)

        let defaultDeny = try ManifestValidator.validated(
            """
            version: 2
            project: default-deny
            services:
              api: { image: local/api:latest, networkPolicy: {} }
            """
        )
        XCTAssertEqual(
            defaultDeny.services[0].networkPolicy,
            HostwrightServiceNetworkPolicy()
        )
    }

    func testServiceNetworkPolicyRejectsBroadMalformedAndDuplicateRules() {
        assertFailure(
            """
            version: 2
            project: policy-demo
            services:
              api:
                image: local/api:latest
                networkPolicy: { ingress: [{}] }
            """,
            contains: "must contain at least one exact selector",
            path: "$.services.api.networkPolicy.ingress[0]"
        )
        assertFailure(
            """
            version: 2
            project: policy-demo
            services:
              api:
                image: local/api:latest
                networkPolicy:
                  egress:
                    - address: 10.42.0.7/24
            """,
            contains: "must be canonical IPv4 CIDR 10.42.0.0/24",
            path: "$.services.api.networkPolicy.egress[0].address"
        )
        assertFailure(
            """
            version: 2
            project: policy-demo
            services:
              api:
                image: local/api:latest
                networkPolicy:
                  ingress:
                    - service: worker
                    - service: worker
            """,
            contains: "must not contain duplicate rules",
            path: "$.services.api.networkPolicy.ingress[1]"
        )
        assertFailure(
            """
            version: 2
            project: policy-demo
            services:
              api:
                image: local/api:latest
                networkPolicy:
                  ingress:
                    - service: worker
                      protocol: icmp
            """,
            contains: "protocol must be one of: tcp, udp",
            path: "$.services.api.networkPolicy.ingress[0].protocol"
        )
    }

    func testTunnelDeclarationsRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                authenticatedEndpoints:
                  - scheme: tls
                    host: peer.example.test
                    port: 443
                relayEndpoint:
                  scheme: tls
                  host: relay.example.test
                  port: 8443
                bonjourDiscovery: false
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """
        )

        let tunnel = try XCTUnwrap(manifest.tunnels["peer-api"])
        XCTAssertEqual(tunnel.peerUUID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertEqual(tunnel.authenticatedEndpoints.map(\.host), ["peer.example.test"])
        XCTAssertEqual(tunnel.relayEndpoint?.port, 8443)
        XCTAssertFalse(tunnel.bonjourDiscovery)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains("tunnels:"))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testTunnelDeclarationRequiresResolvablePortAndDiscoveryPath() {
        assertFailure(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 9090
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains: "target port 9090 must reference a declared container port",
            path: "$.tunnels.peer-api.targetPort"
        )
        assertFailure(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                bonjourDiscovery: false
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains: "requires an authenticated endpoint or Bonjour discovery",
            path: "$.tunnels.peer-api"
        )
    }

    func testTunnelDeclarationRejectsNonCanonicalPeerAndUnsafeEndpoint() {
        assertFailure(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
                authenticatedEndpoints:
                  - scheme: tls
                    host: peer/path.example.test
                    port: 443
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains: "peerUUID must be a canonical lowercase",
            path: "$.tunnels.peer-api.peerUUID"
        )
        assertFailure(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                authenticatedEndpoints:
                  - scheme: tls
                    host: peer/path.example.test
                    port: 443
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains:
                "endpoint host must be a canonical hostname, IPv4 address, or IPv6 address",
            path: "$.tunnels.peer-api.authenticatedEndpoints[0].host"
        )
    }

    func testTunnelDeclarationSupportsCanonicalIPv6Endpoint() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                authenticatedEndpoints:
                  - scheme: tls
                    host: 2001:db8::1
                    port: 443
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """
        )
        XCTAssertEqual(manifest.tunnels["peer-api"]?.authenticatedEndpoints[0].host, "2001:db8::1")
        XCTAssertEqual(
            try ManifestValidator.validated(ManifestCanonicalEncoder.encode(manifest)),
            manifest
        )
    }

    func testTunnelDeclarationRejectsNonTunnelPortAndReplicas() {
        assertFailure(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                authenticatedEndpoints:
                  - scheme: tls
                    host: peer.example.test
                    port: 443
            services:
              api:
                image: local/api:latest
                ports: ["8080:8080"]
            """,
            contains:
                "must use tunnel exposure with authenticated-tunnel identity",
            path: "$.tunnels.peer-api.targetPort"
        )
        assertFailure(
            """
            version: 2
            project: tunnel-demo
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                authenticatedEndpoints:
                  - scheme: tls
                    host: peer.example.test
                    port: 443
            services:
              api:
                image: local/api:latest
                replicas: 2
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains: "requires exactly one target service replica",
            path: "$.tunnels.peer-api.targetService"
        )
    }

    func testRemoteListenerTrustRoundTripsCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: tunnel-listener
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                role: listener
                trust:
                  wireRouteUUID: dddddddd-dddd-4ddd-8ddd-dddddddddddd
                  wireGeneration: 1
                  localIdentitySHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                  peerTrustAnchorSHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
                  peerCertificateSHA256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
                  peerIdentityURI: spiffe://hostwright.internal/projects/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/resources/cccccccc-cccc-4ccc-8ccc-cccccccccccc/roles/tunnel/generations/1
                bindEndpoint:
                  host: 10.0.0.8
                  port: 7443
                bonjourDiscovery: false
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    protocol: tcp
                    bind: 127.0.0.1
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """
        )

        let tunnel = try XCTUnwrap(manifest.tunnels["peer-api"])
        XCTAssertEqual(tunnel.role, .listener)
        XCTAssertEqual(tunnel.bindEndpoint?.host, "10.0.0.8")
        XCTAssertNotNil(tunnel.trust?.peerIdentityURI)
        XCTAssertNil(tunnel.trust?.peerDNSName)
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains(#"role: "listener""#))
        XCTAssertTrue(canonical.contains("peerTrustAnchorSHA256:"))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testRemoteDialerTrustDoesNotRequireRemoteServiceLocally() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: tunnel-dialer
            tunnels:
              peer-api:
                targetService: remote-api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                role: dialer
                trust:
                  wireRouteUUID: dddddddd-dddd-4ddd-8ddd-dddddddddddd
                  wireGeneration: 1
                  localIdentitySHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                  peerTrustAnchorSHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
                  peerCertificateSHA256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
                  peerDNSName: peer.example.test
                bindEndpoint:
                  host: 127.0.0.1
                  port: 9443
                authenticatedEndpoints:
                  - host: peer.example.test
                    port: 7443
                bonjourDiscovery: false
            services:
              client:
                image: local/client:latest
            """
        )

        let tunnel = try XCTUnwrap(manifest.tunnels["peer-api"])
        XCTAssertEqual(tunnel.role, .dialer)
        XCTAssertEqual(tunnel.targetService, "remote-api")
        XCTAssertTrue(try XCTUnwrap(tunnel.bindEndpoint).isLoopback)
        XCTAssertEqual(tunnel.trust?.peerDNSName, "peer.example.test")
        XCTAssertEqual(
            try ManifestValidator.validated(ManifestCanonicalEncoder.encode(manifest)),
            manifest
        )
    }

    func testRemoteTunnelRolesRejectMissingOrAmbiguousTrust() {
        assertFailure(
            """
            version: 2
            project: tunnel-listener
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                role: listener
                bindEndpoint: { host: 10.0.0.8, port: 7443 }
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains: "requires explicit non-TOFU trust",
            path: "$.tunnels.peer-api.trust"
        )
        assertFailure(
            """
            version: 2
            project: tunnel-dialer
            tunnels:
              peer-api:
                targetService: remote-api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                role: dialer
                trust:
                  wireRouteUUID: dddddddd-dddd-4ddd-8ddd-dddddddddddd
                  wireGeneration: 1
                  localIdentitySHA256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
                  peerTrustAnchorSHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
                  peerCertificateSHA256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
                  peerIdentityURI: spiffe://hostwright.internal/projects/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/resources/cccccccc-cccc-4ccc-8ccc-cccccccccccc/roles/tunnel/generations/1
                bindEndpoint: { host: 0.0.0.0, port: 9443 }
                authenticatedEndpoints:
                  - { host: peer.example.test, port: 7443 }
            services:
              client:
                image: local/client:latest
            """,
            contains: "canonical lowercase SHA-256",
            path: "$.tunnels.peer-api.trust"
        )
    }

    func testLocalLoopbackTunnelRejectsRemoteTrustFields() {
        assertFailure(
            """
            version: 2
            project: tunnel-local
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
                trust:
                  wireRouteUUID: dddddddd-dddd-4ddd-8ddd-dddddddddddd
                  wireGeneration: 1
                  localIdentitySHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                  peerTrustAnchorSHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
                  peerCertificateSHA256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains: "local-loopback role must not declare remote trust",
            path: "$.tunnels.peer-api"
        )
    }

    func testTunnelTargetRequiresSingleTCPLoopbackMapping() {
        assertFailure(
            """
            version: 2
            project: tunnel-udp
            tunnels:
              peer-api:
                targetService: api
                targetPort: 8080
                peerUUID: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
            services:
              api:
                image: local/api:latest
                ports:
                  - host: 8080
                    target: 8080
                    protocol: udp
                    exposure:
                      scope: tunnel
                      authentication: authenticated-tunnel
            """,
            contains: "must resolve to one TCP loopback mapping",
            path: "$.tunnels.peer-api.targetPort"
        )
    }

    private func ingressManifest(
        _ routes: String,
        bind: String? = nil,
        exposure: String? = nil
    ) -> String {
        let bindField = bind.map { "    bind: \($0)\n" } ?? ""
        let exposureField = exposure.map {
            "    exposure:\n" + $0.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n") + "\n"
        } ?? ""
        let indentedRoutes = routes.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "      \($0)" }
            .joined(separator: "\n")
        return
            """
            version: 2
            project: ingress-demo
            networks:
              backend: {}
            ingress:
              api:
            \(bindField)\(exposureField)    port: 8080
                routes:
            \(indentedRoutes)
            services:
              api:
                image: local/api:latest
                ports: ["8080:8080"]
                networks: [backend]
            """
    }

    private func assertFailure(
        _ source: String,
        code: String = "HW-MANIFEST-002",
        contains text: String,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ManifestValidator.validated(source),
            file: file,
            line: line
        ) { error in
            guard let parseError = error as? ManifestParseError,
                  let issue = parseError.issues.first else {
                return XCTFail(
                    "Expected structured manifest issue, received \(error)",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(issue.code.rawValue, code, file: file, line: line)
            XCTAssertTrue(issue.message.contains(text), issue.message, file: file, line: line)
            XCTAssertEqual(issue.path, path, file: file, line: line)
        }
    }
}
