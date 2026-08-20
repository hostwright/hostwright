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

    func testComposeCapacityContractRoundTripsCanonicalSubset() throws {
        let source = """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:1
                command: ["serve", "--port", "8080"]
                deploy:
                  resources:
                    limits:
                      cpus: 2
                      memory: "1GB"
                    reservations:
                      cpus: "1"
                      memory: 512M

            """

        let imported = HostwrightCompose.importDocument(source)

        XCTAssertTrue(imported.succeeded)
        XCTAssertEqual(imported.lossReport.losses, [])
        let manifest = try ManifestValidator.validated(try XCTUnwrap(imported.manifestText))
        XCTAssertEqual(
            manifest.services.first?.resources,
            HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 2, memory: "1GiB")
            )
        )
        XCTAssertEqual(
            imported.canonicalComposeText,
            """
            name: "demo"
            services:
              api:
                image: "ghcr.io/example/api:1"
                command: ["serve", "--port", "8080"]
                deploy:
                  resources:
                    reservations:
                      cpus: "1"
                      memory: "512m"
                    limits:
                      cpus: "2"
                      memory: "1g"

            """
        )

        let roundTripped = HostwrightCompose.importDocument(try XCTUnwrap(imported.canonicalComposeText))
        XCTAssertTrue(roundTripped.succeeded)
        XCTAssertEqual(roundTripped.manifestText, imported.manifestText)
        XCTAssertEqual(roundTripped.canonicalComposeText, imported.canonicalComposeText)
    }

    func testComposeCapacityMemoryUnitsMapExactly() throws {
        for (composeValue, manifestValue) in [
            ("1b", "1B"),
            ("2k", "2KiB"),
            ("3KB", "3KiB"),
            ("4m", "4MiB"),
            ("5MB", "5MiB"),
            ("6g", "6GiB"),
            ("7GB", "7GiB"),
        ] {
            let imported = HostwrightCompose.importDocument(
                """
                name: demo
                services:
                  api:
                    image: ghcr.io/example/api:1
                    deploy:
                      resources:
                        reservations:
                          cpus: "1"
                          memory: \(composeValue)
                        limits:
                          cpus: "1"
                          memory: \(composeValue)

                """
            )

            XCTAssertTrue(imported.succeeded, composeValue)
            let manifest = try ManifestValidator.validated(try XCTUnwrap(imported.manifestText))
            XCTAssertEqual(manifest.services.first?.resources?.requests.memory, manifestValue)
            XCTAssertEqual(manifest.services.first?.resources?.limits?.memory, manifestValue)
        }
    }

    func testComposeCapacityMalformedQuotedScalarsKeepCanonicalLeafPaths() {
        for (caseName, malformedCPU, malformedMemory) in [
            ("unterminated", "\"1", "\"512m"),
            ("trailing garbage", "\"1\"x", "\"512m\"x"),
        ] {
            for (section, field) in [
                ("reservations", "cpus"),
                ("reservations", "memory"),
                ("limits", "cpus"),
                ("limits", "memory"),
            ] {
                let malformed = field == "cpus" ? malformedCPU : malformedMemory
                let result = HostwrightCompose.importDocument(
                    """
                    name: demo
                    services:
                      api:
                        image: ghcr.io/example/api:1
                        deploy:
                          resources:
                            reservations:
                              cpus: \(section == "reservations" && field == "cpus" ? malformed : "\"1\"")
                              memory: \(section == "reservations" && field == "memory" ? malformed : "512m")
                            limits:
                              cpus: \(section == "limits" && field == "cpus" ? malformed : "\"2\"")
                              memory: \(section == "limits" && field == "memory" ? malformed : "1g")

                    """
                )
                let description = "\(caseName) \(section).\(field)"

                XCTAssertFalse(result.succeeded, description)
                XCTAssertEqual(result.lossReport.losses.first?.code, .invalidInput, description)
                XCTAssertEqual(
                    result.lossReport.losses.first?.path,
                    "$.services.api.deploy.resources.\(section).\(field)",
                    description
                )
            }
        }
    }

    func testComposeCapacityMultiServiceRoundTripCanonicalizesManifestOrder() throws {
        let imported = HostwrightCompose.importDocument(
            """
            name: demo
            services:
              worker:
                image: ghcr.io/example/worker:1
                deploy:
                  resources:
                    reservations:
                      cpus: "1"
                      memory: 512m
                    limits:
                      cpus: "1"
                      memory: 512m
              api:
                image: ghcr.io/example/api:1
                deploy:
                  resources:
                    reservations:
                      cpus: "1"
                      memory: 512m
                    limits:
                      cpus: "2"
                      memory: 1g

            """
        )

        XCTAssertTrue(imported.succeeded)
        let manifestText = try XCTUnwrap(imported.manifestText)
        let apiRange = try XCTUnwrap(manifestText.range(of: "  api:"))
        let workerRange = try XCTUnwrap(manifestText.range(of: "  worker:"))
        XCTAssertTrue(apiRange.lowerBound < workerRange.lowerBound)

        let roundTripped = HostwrightCompose.importDocument(try XCTUnwrap(imported.canonicalComposeText))
        XCTAssertTrue(roundTripped.succeeded)
        XCTAssertEqual(roundTripped.manifestText, imported.manifestText)
        XCTAssertEqual(roundTripped.canonicalComposeText, imported.canonicalComposeText)
    }

    func testComposeCapacityContractRejectsPartialUnsupportedAndAmbiguousValues() {
        let partial = HostwrightCompose.importDocument(
            """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:1
                deploy:
                  resources:
                    reservations:
                      cpus: "1"
                      memory: 512m
                    limits:
                      cpus: "2"

            """
        )
        XCTAssertFalse(partial.succeeded)
        XCTAssertTrue(partial.lossReport.losses.contains {
            $0.code == .invalidManifest &&
                $0.path == "$.services.api" &&
                $0.message.contains("resources.limits.memory must be declared")
        })

        for (line, path) in [
            ("      replicas: 2", "$.services.api.deploy.replicas"),
            ("        mystery: true", "$.services.api.deploy.resources.mystery"),
            ("          pids: 4", "$.services.api.deploy.resources.limits.pids"),
            ("          devices:", "$.services.api.deploy.resources.limits.devices"),
        ] {
            let result = HostwrightCompose.importDocument(
                """
                name: demo
                services:
                  api:
                    image: ghcr.io/example/api:1
                    deploy:
                      resources:
                        reservations:
                          cpus: "1"
                          memory: 512m
                        limits:
                          cpus: "2"
                          memory: 1g
                \(line)

                """
            )
            XCTAssertFalse(result.succeeded, path)
            XCTAssertTrue(result.lossReport.losses.contains {
                $0.code == .unsupportedInput && $0.path == path
            }, path)
        }

        for (field, value) in [
            ("cpus", "0.5"),
            ("cpus", "0"),
            ("cpus", "+1"),
            ("cpus", "01"),
            ("cpus", "1e0"),
            ("cpus", "999999999999999999999999"),
            ("memory", "512MiB"),
            ("memory", "0m"),
            ("memory", "-1m"),
            ("memory", "512.0m"),
            ("memory", "512"),
            ("memory", "9223372036854775808b"),
        ] {
            let result = HostwrightCompose.importDocument(
                """
                name: demo
                services:
                  api:
                    image: ghcr.io/example/api:1
                    deploy:
                      resources:
                        reservations:
                          cpus: \(field == "cpus" ? value : "1")
                          memory: \(field == "memory" ? value : "512m")
                        limits:
                          cpus: 2
                          memory: 1g

                """
            )
            XCTAssertFalse(result.succeeded, "\(field)=\(value)")
            XCTAssertEqual(result.lossReport.losses.first?.code, .invalidInput, "\(field)=\(value)")
            XCTAssertEqual(
                result.lossReport.losses.first?.path,
                "$.services.api.deploy.resources.reservations.\(field)",
                "\(field)=\(value)"
            )
        }

        for (syntax, path) in [
            ("reservations: &capacity", "$.services.api.deploy.resources.reservations"),
            ("reservations: *capacity", "$.services.api.deploy.resources.reservations"),
            ("reservations: {cpus: 1, memory: 512m}", "$.services.api.deploy.resources.reservations"),
            ("<<: *capacity", "$.services.api.deploy.resources.<<"),
        ] {
            let result = HostwrightCompose.importDocument(
                """
                name: demo
                services:
                  api:
                    image: ghcr.io/example/api:1
                    deploy:
                      resources:
                        \(syntax)

                """
            )
            XCTAssertFalse(result.succeeded, syntax)
            XCTAssertEqual(result.lossReport.losses.first?.code, .invalidInput, syntax)
            XCTAssertEqual(result.lossReport.losses.first?.path, path, syntax)
        }

        let duplicate = HostwrightCompose.importDocument(
            """
            name: demo
            services:
              api:
                image: ghcr.io/example/api:1
                deploy:
                  resources:
                    reservations:
                      cpus: "1"
                      cpus: "2"
                      memory: 512m
                    limits:
                      cpus: "2"
                      memory: 1g

            """
        )
        XCTAssertFalse(duplicate.succeeded)
        XCTAssertEqual(duplicate.lossReport.losses.first?.code, .invalidInput)
        XCTAssertEqual(
            duplicate.lossReport.losses.first?.path,
            "$.services.api.deploy.resources.reservations.cpus"
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
        XCTAssertEqual(result.lossReport.losses.map(\.code), [.exportLoss, .exportLoss])
        XCTAssertEqual(
            result.lossReport.losses.map(\.path),
            ["$.imagePolicy", "$.services.api.labels"]
        )
        XCTAssertTrue(result.lossReport.losses.allSatisfy { $0.severity == .error })
    }

    func testComposeExportRejectsResourcesOutsideExactCapacitySubset() {
        let manifest = HostwrightManifest(
            version: HostwrightManifest.currentVersion,
            project: "demo",
            services: [
                HostwrightService(
                    name: "api",
                    image: "ghcr.io/example/api:1",
                    resources: HostwrightResources(
                        requests: HostwrightResourceSet(
                            cpus: 1,
                            memory: "1TiB",
                            disk: "1GiB",
                            process: 2
                        ),
                        limits: HostwrightResourceSet(
                            cpus: 2,
                            memory: "2TiB",
                            disk: "2GiB",
                            process: 4
                        )
                    ),
                    scheduling: HostwrightSchedulingPolicy(
                        acceleratorClaims: [HostwrightAcceleratorClaim(name: "gpu")]
                    )
                )
            ]
        )

        let result = HostwrightCompose.exportDocument(manifest)

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.composeText)
        XCTAssertEqual(
            result.lossReport.losses.map(\.path),
            [
                "$.services.api.resources.disk",
                "$.services.api.resources.limits.memory",
                "$.services.api.resources.process",
                "$.services.api.resources.requests.memory",
                "$.services.api.scheduling",
            ]
        )
        XCTAssertTrue(result.lossReport.losses.allSatisfy { $0.code == .exportLoss })
    }

    func testComposeExportAndUpdateRejectEveryPartialCapacityShape() {
        let cases: [(name: String, resources: HostwrightResources, paths: [String])] = [
            (
                "missing request cpus",
                HostwrightResources(
                    requests: HostwrightResourceSet(memory: "512MiB"),
                    limits: HostwrightResourceSet(cpus: 2, memory: "1GiB")
                ),
                ["$.services.api.resources.requests.cpus"]
            ),
            (
                "missing request memory",
                HostwrightResources(
                    requests: HostwrightResourceSet(cpus: 1),
                    limits: HostwrightResourceSet(cpus: 2, memory: "1GiB")
                ),
                ["$.services.api.resources.requests.memory"]
            ),
            (
                "missing limits",
                HostwrightResources(
                    requests: HostwrightResourceSet(cpus: 1, memory: "512MiB")
                ),
                [
                    "$.services.api.resources.limits.cpus",
                    "$.services.api.resources.limits.memory",
                ]
            ),
            (
                "missing limit cpus",
                HostwrightResources(
                    requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                    limits: HostwrightResourceSet(memory: "1GiB")
                ),
                ["$.services.api.resources.limits.cpus"]
            ),
            (
                "missing limit memory",
                HostwrightResources(
                    requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                    limits: HostwrightResourceSet(cpus: 2)
                ),
                ["$.services.api.resources.limits.memory"]
            ),
        ]
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

        for testCase in cases {
            let partial = HostwrightManifest(
                version: HostwrightManifest.currentVersion,
                project: "demo",
                services: [
                    HostwrightService(
                        name: "api",
                        image: "ghcr.io/example/api:1",
                        resources: testCase.resources
                    )
                ]
            )

            let exported = HostwrightCompose.exportDocument(partial)
            XCTAssertFalse(exported.succeeded, testCase.name)
            XCTAssertNil(exported.composeText, testCase.name)
            XCTAssertEqual(
                exported.lossReport.losses.filter { $0.code == .exportLoss }.map(\.path),
                testCase.paths,
                testCase.name
            )

            let plan = HostwrightCompose.planUpdate(current: current, desired: partial)
            XCTAssertFalse(plan.accepted, testCase.name)
            XCTAssertTrue(plan.changes.isEmpty, testCase.name)
            XCTAssertFalse(plan.mutatesRuntime, testCase.name)
            XCTAssertEqual(
                plan.lossReport.losses.filter { $0.code == .exportLoss }.map(\.path),
                testCase.paths.map { "$.desired\($0.dropFirst())" },
                testCase.name
            )
        }
    }

    func testComposeUpdatePlanIncludesResourceChangesWithoutMutation() {
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
                    resources: HostwrightResources(
                        requests: HostwrightResourceSet(cpus: 2, memory: "1GiB"),
                        limits: HostwrightResourceSet(cpus: 2, memory: "1GiB")
                    ),
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
        XCTAssertTrue(first.accepted)
        XCTAssertTrue(first.lossReport.canProceed)
        XCTAssertFalse(first.mutatesRuntime)
        XCTAssertEqual(first.changes.map(\.kind), [.updateService, .addService])
        XCTAssertEqual(first.changes.map(\.serviceName), ["api", "worker"])
        XCTAssertEqual(first.changes.first?.fields, ["deploy.resources", "env", "image"])
        XCTAssertEqual(first.changes.last?.fields, ["service"])
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
        XCTAssertEqual(plan.lossReport.losses.map(\.code), [.updateRejected])
        XCTAssertEqual(plan.lossReport.losses.map(\.path), ["$.project"])
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
