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

    func testComposeImportReportsV3ResourceAdmissionAtTheServicePath() {
        let source = """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:1
                command: ["serve", "--port", "8080"]
                ports:
                  - "8080:8080"
                volumes:
                  - "./data:/data:rw"
                environment:
                  APP_ENV: "development"
                  PUBLIC_URL: "http://localhost:8080"
                healthcheck:
                  test: ["CMD", "curl", "http://localhost:8080/health"]
                  interval: "10s"
                restart: "unless-stopped"

            """

        let imported = HostwrightCompose.importDocument(source)
        XCTAssertFalse(imported.succeeded)
        XCTAssertNil(imported.manifestText)
        XCTAssertNil(imported.canonicalComposeText)
        XCTAssertEqual(imported.lossReport.losses.map(\.code), [.invalidManifest])
        XCTAssertEqual(imported.lossReport.losses.map(\.path), ["$.services.api"])
        XCTAssertEqual(
            imported.lossReport.losses.first?.message,
            "Service 'api' resources must declare explicit requests and limits, including CPU and memory, for an executable v3 service."
        )
    }

    func testComposeImportReportsStablePathsAndRejectsUnknownSemantics() {
        let result = HostwrightCompose.importDocument(
            """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:1
                build:
                  context: .
                mystery: true

            """
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.manifestText)
        XCTAssertNil(result.canonicalComposeText)
        XCTAssertFalse(result.lossReport.canProceed)
        XCTAssertEqual(result.lossReport.losses.map(\.code), [.unsupportedInput, .unsupportedInput])
        XCTAssertEqual(
            result.lossReport.losses.map(\.path),
            ["$.services.api.build", "$.services.api.mystery"]
        )
        XCTAssertTrue(result.lossReport.losses.allSatisfy { $0.severity == .error })
    }

    func testComposeMalformedInputUsesInvalidInputContractCode() {
        let result = HostwrightCompose.importDocument(
            """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:1
                command: ["serve",]

            """
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.lossReport.losses.map(\.code), [.invalidInput])
        XCTAssertEqual(result.lossReport.losses.map(\.path), ["$.services.api.command"])
    }

    func testComposeExportFailsClosedWithDeterministicLosses() {
        let manifest = HostwrightManifest(
            version: HostwrightManifest.currentVersion,
            project: "demo",
            imagePolicy: .requireDigest,
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    resources: executableResources,
                    labels: ["team": "platform"]
                )
            ]
        )

        let result = HostwrightCompose.exportDocument(manifest)
        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.composeText)
        XCTAssertEqual(result.lossReport.losses.map(\.code), [.exportLoss, .exportLoss, .exportLoss])
        XCTAssertEqual(
            result.lossReport.losses.map(\.path),
            ["$.imagePolicy", "$.services.api.labels", "$.services.api.resources"]
        )
        XCTAssertTrue(result.lossReport.losses.allSatisfy { $0.severity == .error })
    }

    func testComposeUpdatePlanRejectsV3ResourceSemanticsWithoutMutation() {
        let current = HostwrightManifest(
            version: HostwrightManifest.currentVersion,
            project: "demo",
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api:1",
                    resources: executableResources
                )
            ]
        )
        let desired = HostwrightManifest(
            version: HostwrightManifest.currentVersion,
            project: "demo",
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api:2",
                    resources: executableResources,
                    env: ["APP_ENV": "production"]
                ),
                HostwrightService(
                    name: "worker",
                    image: "ghcr.io/example/worker:1",
                    resources: executableResources
                )
            ]
        )

        let first = HostwrightCompose.planUpdate(current: current, desired: desired)
        let second = HostwrightCompose.planUpdate(current: current, desired: desired)

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.accepted)
        XCTAssertFalse(first.lossReport.canProceed)
        XCTAssertFalse(first.mutatesRuntime)
        XCTAssertEqual(first.changes, [])
        XCTAssertEqual(
            first.lossReport.losses.map(\.path),
            [
                "$.current.services.api.resources",
                "$.desired.services.api.resources",
                "$.desired.services.worker.resources",
            ]
        )
    }

    func testComposeUpdatePlanRejectsProjectMismatchBeforePlanningChanges() {
        let current = HostwrightManifest(
            version: HostwrightManifest.currentVersion,
            project: "old",
            services: [HostwrightService(name: "api", image: "ghcr.io/example/api:1", resources: executableResources)]
        )
        let desired = HostwrightManifest(
            version: HostwrightManifest.currentVersion,
            project: "new",
            services: [HostwrightService(name: "api", image: "ghcr.io/example/api:2", resources: executableResources)]
        )

        let plan = HostwrightCompose.planUpdate(current: current, desired: desired)
        XCTAssertFalse(plan.accepted)
        XCTAssertTrue(plan.changes.isEmpty)
        XCTAssertEqual(plan.lossReport.losses.map(\.code), [.exportLoss, .exportLoss, .updateRejected])
        XCTAssertEqual(
            plan.lossReport.losses.map(\.path),
            ["$.current.services.api.resources", "$.desired.services.api.resources", "$.project"]
        )
        XCTAssertFalse(plan.mutatesRuntime)
    }

    func testComposeContractJSONIsStableAndVersioned() throws {
        let result = HostwrightCompose.importDocument(
            """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:1

            """
        )

        let first = try ComposeContractJSON.render(result)
        let second = try ComposeContractJSON.render(result)
        XCTAssertEqual(first, second)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["contractVersion"] as? String, "v1")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["succeeded"] as? Bool, false)
        XCTAssertEqual(object["canonicalComposeText"] as? String, result.canonicalComposeText)
        let lossReport = try XCTUnwrap(object["lossReport"] as? [String: Any])
        let losses = try XCTUnwrap(lossReport["losses"] as? [[String: Any]])
        XCTAssertEqual(losses.first?["code"] as? String, "HW-COMPOSE-004")
        XCTAssertEqual(losses.first?["path"] as? String, "$.services.api")
    }

    private var executableResources: HostwrightResources {
        HostwrightResources(
            requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
            limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
        )
    }
}
