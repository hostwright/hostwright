import XCTest
@testable import HostwrightManifest
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
}
