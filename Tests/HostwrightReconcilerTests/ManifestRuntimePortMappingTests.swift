import XCTest
@testable import HostwrightManifest
@testable import HostwrightNetworking
@testable import HostwrightReconciler
@testable import HostwrightRuntime

final class ManifestRuntimePortMappingTests: XCTestCase {
    func testMapsFixedAndDynamicPublishedPorts() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            publishedPorts: [
                HostwrightPublishedPort(
                    host: HostwrightPortSpan(start: 18_080),
                    target: HostwrightPortSpan(start: 8_080)
                ),
                HostwrightPublishedPort(
                    target: HostwrightPortSpan(start: 5_353),
                    protocolName: .udp
                )
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(mapping.desiredState.services.first).ports,
            [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1",
                    allocation: .fixed
                ),
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 5_353,
                    protocolName: .udp,
                    bindAddress: "127.0.0.1",
                    allocation: .dynamic
                )
            ]
        )
    }

    func testExpandsEqualLengthPublishedPortRanges() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            publishedPorts: [
                HostwrightPublishedPort(
                    host: HostwrightPortSpan(start: 18_080, end: 18_082),
                    target: HostwrightPortSpan(start: 8_080, end: 8_082),
                    protocolName: .udp,
                    bindAddress: "::1"
                )
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(mapping.desiredState.services.first).ports,
            [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .udp,
                    bindAddress: "::1",
                    allocation: .fixed
                ),
                RuntimePortMapping(
                    hostPort: 18_081,
                    containerPort: 8_081,
                    protocolName: .udp,
                    bindAddress: "::1",
                    allocation: .fixed
                ),
                RuntimePortMapping(
                    hostPort: 18_082,
                    containerPort: 8_082,
                    protocolName: .udp,
                    bindAddress: "::1",
                    allocation: .fixed
                )
            ]
        )
    }

    func testExpandsDynamicTargetRangeWithoutResolvingHostPorts() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            publishedPorts: [
                HostwrightPublishedPort(
                    target: HostwrightPortSpan(start: 8_080, end: 8_082),
                    protocolName: .udp
                )
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(mapping.desiredState.services.first).ports,
            [
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_080,
                    protocolName: .udp,
                    bindAddress: "127.0.0.1",
                    allocation: .dynamic
                ),
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_081,
                    protocolName: .udp,
                    bindAddress: "127.0.0.1",
                    allocation: .dynamic
                ),
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8_082,
                    protocolName: .udp,
                    bindAddress: "127.0.0.1",
                    allocation: .dynamic
                )
            ]
        )
    }

    func testBlocksNonLoopbackPublishedPortBeforeMutation() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            publishedPorts: [
                HostwrightPublishedPort(
                    target: HostwrightPortSpan(start: 8_080),
                    bindAddress: "192.168.1.10"
                )
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.contains {
            $0.kind == .unsafeExposure &&
                $0.severity == .blocker &&
                $0.stableDetailKey == "192.168.1.10" &&
                $0.message == "Published port bind address '192.168.1.10' is outside the localhost-only runtime boundary."
        })
    }

    func testMapsDeclaredLANExposureAndBlocksUntilSecureListenerIsQualified() throws {
        let exposure = HostwrightPortExposurePolicy(
            scope: .lan,
            interfaces: ["en0"],
            networkClasses: [.privateLAN],
            allowedCIDRs: ["192.168.1.0/24"],
            authentication: .tls
        )
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            publishedPorts: [
                HostwrightPublishedPort(
                    host: HostwrightPortSpan(start: 18_080),
                    target: HostwrightPortSpan(start: 8_080),
                    protocolName: .tcp,
                    bindAddress: "192.168.1.10",
                    exposure: exposure
                )
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertEqual(
            try XCTUnwrap(mapping.desiredState.services.first)
                .ports.first?.exposurePolicy,
            exposure
        )
        XCTAssertTrue(mapping.issues.contains {
            $0.kind == .unsupportedFeature &&
                $0.severity == .blocker &&
                $0.message ==
                    "Published port exposure scope 'lan' requires a qualified secure listener provider before mutation."
        })
    }

    func testCarriesLocalhostIngressWithoutAddingBlockers() throws {
        let route = HostwrightIngressRoute(
            hostname: "api.hostwright.internal",
            targetService: "api",
            targetPort: 8_080
        )
        let ingress = HostwrightIngressListener(
            port: 18_080,
            routes: [route]
        )
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            ports: ["8080:8080"]
        )
        let manifest = HostwrightManifest(
            version: 2,
            project: "demo",
            imagePolicy: nil,
            imageTrust: nil,
            imageSBOM: nil,
            networks: [:],
            ingress: ["api": ingress],
            services: [service]
        )

        let mapping = ManifestRuntimeMapper.map(manifest)

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.ingress, manifest.ingress)
    }

    func testCarriesQualifiedLANIngressWithoutLegacyAvailabilityBlocker() {
        let exposure = HostwrightPortExposurePolicy(
            scope: .lan,
            interfaces: ["en0"],
            networkClasses: [.privateLAN],
            allowedCIDRs: ["192.168.1.0/24"],
            authentication: .tls
        )
        let ingress = HostwrightIngressListener(
            bindAddress: "192.168.1.10",
            port: 8_443,
            exposure: exposure,
            certificate: "api-tls",
            routes: [
                HostwrightIngressRoute(
                    hostname: "api.example.test",
                    targetService: "api",
                    targetPort: 8_080
                ),
            ]
        )
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            ports: ["8080:8080"]
        )
        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(
                version: 2,
                project: "demo",
                imagePolicy: nil,
                imageTrust: nil,
                imageSBOM: nil,
                networks: [:],
                certificates: [
                    "api-tls": HostwrightCertificateDeclaration(
                        source: .localCA
                    ),
                ],
                ingress: ["public": ingress],
                services: [service]
            )
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.ingress["public"], ingress)
        XCTAssertEqual(
            mapping.certificates["api-tls"],
            HostwrightCertificateDeclaration(source: .localCA)
        )
    }

    func testLegacyPortLiteralStillMapsAsFixedTCPOnLocalhost() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            ports: ["18080:8080"]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(mapping.desiredState.services.first).ports,
            [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1",
                    allocation: .fixed
                )
            ]
        )
    }

    func testMalformedLegacyPortLiteralStillProducesBlocker() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            ports: ["not-a-port"]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.contains {
            $0.kind == .unsupportedFeature &&
                $0.severity == .blocker &&
                $0.message == "Port 'not-a-port' cannot be mapped to a supported runtime port."
        })
    }

    func testMapsUnixSocketsIntoPrivateDeterministicRuntimePaths() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            publishedSockets: [
                HostwrightPublishedSocket(
                    containerPath: "/run/api.sock"
                ),
                HostwrightPublishedSocket(
                    hostName: "shared.sock",
                    containerPath: "/run/shared.sock",
                    mode: .ownerAndGroup
                )
            ]
        )
        let root = "/tmp/hostwright-gate06-sockets"
        let first = ManifestRuntimeMapper.map(
            HostwrightManifest(
                version: 2,
                project: "demo",
                services: [service]
            ),
            projectResourceUUID:
                "11111111-1111-4111-8111-111111111111",
            unixSocketRootDirectory: root
        )
        let second = ManifestRuntimeMapper.map(
            HostwrightManifest(
                version: 2,
                project: "demo",
                services: [service]
            ),
            projectResourceUUID:
                "11111111-1111-4111-8111-111111111111",
            unixSocketRootDirectory: root
        )

        XCTAssertTrue(first.issues.isEmpty)
        XCTAssertEqual(first, second)
        let sockets = try XCTUnwrap(
            first.desiredState.services.first
        ).publishedSockets
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets[1].hostPath, "\(root)/shared.sock")
        XCTAssertEqual(sockets[1].containerPath, "/run/shared.sock")
        XCTAssertEqual(sockets[1].mode, .ownerAndGroup)
        XCTAssertTrue(sockets[0].hostPath.hasPrefix(root + "/"))
        XCTAssertTrue(sockets[0].hostPath.hasSuffix(".sock"))
    }

    func testBlocksUnixSocketPathThatExceedsDarwinLimit() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            publishedSockets: [
                HostwrightPublishedSocket(
                    hostName: "api.sock",
                    containerPath: "/run/api.sock"
                )
            ]
        )
        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(
                version: 2,
                project: "demo",
                services: [service]
            ),
            unixSocketRootDirectory:
                "/tmp/\(String(repeating: "a", count: 96))"
        )

        XCTAssertTrue(mapping.issues.contains {
            $0.kind == .unsupportedFeature &&
                $0.severity == .blocker &&
                $0.message.contains("exceeds the platform path limit")
        })
        XCTAssertTrue(
            mapping.desiredState.services[0].publishedSockets.isEmpty
        )
    }
}
