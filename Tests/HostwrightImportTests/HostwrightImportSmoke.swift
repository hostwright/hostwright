import HostwrightImport
import HostwrightManifest
import XCTest

final class HostwrightImportTests: XCTestCase {
    func testStackSubsetWithoutExplicitResourcesFailsClosed() throws {
        let result = StackFileImporter.convert(
            """
            version: "3.9"
            name: demo
            services:
              api:
                image: ghcr.io/example/api:latest
                command: ["serve"]
                ports:
                  - "8080:8080"
                volumes:
                  - "./data:/data:rw"
                environment:
                  PUBLIC_URL: http://localhost:8080
                  APP_ENV: development
                healthcheck:
                  test: ["CMD", "curl", "http://localhost:8080/health"]
                  interval: 10s
                restart: on-failure
              worker:
                image: ghcr.io/example/worker:latest
                environment:
                  APP_ENV: development

            """
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.line, 1)
        let resourceErrors = result.errors.filter {
            $0.message.contains("resources must declare explicit requests and limits")
        }
        XCTAssertEqual(resourceErrors.count, 2)
        XCTAssertTrue(resourceErrors.contains { $0.message.contains("api") })
        XCTAssertTrue(resourceErrors.contains { $0.message.contains("worker") })
        XCTAssertTrue(resourceErrors.allSatisfy { $0.code == .manifestValidationFailed })
    }

    func testImportDiagnosticsAreDeterministic() {
        let stack = """
        name: demo
        services:
          api:
            image: ghcr.io/example/api:latest
            network_mode: host

        """

        let first = StackFileImporter.convert(stack)
        let second = StackFileImporter.convert(stack)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.errors.map(\.rendered), second.errors.map(\.rendered))
    }

    func testInlineArraysWithoutExplicitResourcesFailClosed() throws {
        let result = StackFileImporter.convert(
            """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:latest
                command: ["python", "print(a,b)"]
                healthcheck:
                  test: ["CMD", "curl", "http://localhost:8080/a,b"]

            """
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
        XCTAssertTrue(result.errors.contains {
            $0.message.contains("resources must declare explicit requests and limits")
        })
    }

    func testQuotedEnvironmentScalarsCannotBypassResourceAdmission() throws {
        let result = StackFileImporter.convert(
            #"""
            name: demo
            services:
              api:
                image: ghcr.io/example/api:latest
                environment:
                  JSON_DOC: '{"a":1}'
                  NOTE: "a\\b\"c"

            """#
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
        XCTAssertTrue(result.errors.contains {
            $0.message.contains("resources must declare explicit requests and limits")
        })
    }

    func testManifestEmitterPreservesStructuredPublishedPorts() throws {
        let publishedPorts = [
            try XCTUnwrap(HostwrightPublishedPort.legacy("18080:8080")),
            HostwrightPublishedPort(
                target: HostwrightPortSpan(start: 8_181),
                protocolName: .tcp,
                bindAddress: "127.0.0.1"
            ),
            HostwrightPublishedPort(
                host: HostwrightPortSpan(start: 19_090, end: 19_091),
                target: HostwrightPortSpan(start: 9_090, end: 9_091),
                protocolName: .udp,
                bindAddress: "::1"
            ),
        ]
        let manifest = HostwrightManifest(
            version: 3,
            project: "demo",
            services: [
                HostwrightService(
                    name: "api",
                    image: "example.invalid/api:latest",
                    resources: HostwrightResources(
                        requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                        limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
                    ),
                    publishedPorts: publishedPorts
                ),
            ]
        )

        let rendered = HostwrightManifestEmitter.render(manifest)
        XCTAssertTrue(rendered.contains(#"      - "18080:8080""#))
        XCTAssertTrue(rendered.contains(#"      - bind: "127.0.0.1""#))
        XCTAssertTrue(rendered.contains("        target: 8181"))
        XCTAssertTrue(rendered.contains(#"      - bind: "::1""#))
        XCTAssertTrue(rendered.contains(#"        host: "19090-19091""#))
        XCTAssertTrue(rendered.contains(#"        target: "9090-9091""#))
        XCTAssertTrue(rendered.contains(#"        protocol: "udp""#))

        let roundTripped = try ManifestValidator.validated(rendered)
        XCTAssertEqual(
            roundTripped.services.first?.publishedPorts,
            publishedPorts
        )
    }

    func testUnsupportedNetworkingAndSecretFieldsFailClosedWithPolicyReasons() {
        let result = StackFileImporter.convert(
            """
            name: demo
            networks:
              public:
                driver: bridge
            services:
              api:
                image: ghcr.io/example/api:latest
                network_mode: host
                secrets:
                  - api_token

            """
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.manifestText)
        XCTAssertTrue(result.errors.contains {
            $0.line == 2 &&
                $0.policyReasonCode == "secureExposureUnsupported" &&
                $0.message.contains("Unsupported stack-file top-level stack file field 'networks'")
        })
        XCTAssertTrue(result.errors.contains {
            $0.line == 8 &&
                $0.policyReasonCode == "secureExposureUnsupported" &&
                $0.message.contains("network_mode")
        })
        XCTAssertTrue(result.errors.contains {
            $0.line == 9 &&
                $0.policyReasonCode == "untrustedManifestUnsupportedField" &&
                $0.message.contains("secrets")
        })
    }

    func testNamedVolumesAndShellHealthchecksAreRejected() {
        let result = StackFileImporter.convert(
            """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:latest
                volumes:
                  - "db-data:/data"
                healthcheck:
                  test: ["CMD-SHELL", "curl -f http://localhost:8080/health"]

            """
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.errors.contains {
            $0.line == 6 &&
                $0.policyReasonCode == "unsafeMountSource" &&
                $0.message.contains("Named volumes")
        })
        XCTAssertTrue(result.errors.contains {
            $0.line == 8 &&
                $0.policyReasonCode == "lifecycleUnsupported" &&
                $0.message.contains("supports only [\"CMD\", ...]")
        })
    }

    func testConvertedManifestValidationStillFailsClosed() {
        let result = StackFileImporter.convert(
            """
            name: demo
            services:
              api:
                environment:
                  PASSWORD: plain

            """
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.errors.contains {
            $0.code == .manifestValidationFailed &&
                $0.message == "Service 'api' must define a non-empty image."
        })
        XCTAssertTrue(result.errors.contains {
            $0.code == .manifestValidationFailed &&
                $0.message.contains("plaintext sensitive values must use secretEnv")
        })
    }
}
