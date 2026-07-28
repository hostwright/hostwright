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
