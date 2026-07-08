import HostwrightImport
import HostwrightManifest
import XCTest

final class HostwrightImportTests: XCTestCase {
    func testAcceptedStackSubsetProducesGoldenHostwrightManifest() throws {
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

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.line, 1)
        let expectedManifest = """
            version: 1
            project: demo

            services:
              api:
                image: ghcr.io/example/api:latest
                command: ["serve"]
                ports:
                  - "8080:8080"
                volumes:
                  - "./data:/data:rw"
                env:
                  APP_ENV: development
                  PUBLIC_URL: http://localhost:8080
                health:
                  command: ["curl", "http://localhost:8080/health"]
                  interval: 10s
                restart:
                  policy: on-failure
              worker:
                image: ghcr.io/example/worker:latest
                env:
                  APP_ENV: development

            """ + "\n"
        XCTAssertEqual(result.manifestText, expectedManifest)
        XCTAssertNoThrow(try ManifestValidator.validated(try XCTUnwrap(result.manifestText)))
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
