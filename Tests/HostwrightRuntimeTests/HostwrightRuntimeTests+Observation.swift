import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightRuntime

extension HostwrightRuntimeTests {
    func testAppleContainerReadOnlyAdapterReadsTailLogsWithoutFollowAttachOrExec() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let runner = RoutingRuntimeProcessRunner { spec in
            XCTAssertEqual(spec.arguments, ["logs", "-n", "25", resourceIdentifier])
            XCTAssertFalse(spec.arguments.contains("--follow"))
            XCTAssertFalse(spec.arguments.contains("--attach"))
            XCTAssertFalse(spec.arguments.contains("exec"))
            return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "token=fake-token\nready", standardError: "")
        }
        let adapter = AppleContainerReadOnlyAdapter(executableResolver: resolvedContainer, processRunner: runner)
        let observedService = ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: resourceIdentifier,
            lifecycleState: .running
        )

        let logs = try await adapter.logs(for: observedService, tail: 25)

        XCTAssertEqual(logs.lineLimit, 25)
        XCTAssertTrue(logs.text.contains("[REDACTED]"))
        XCTAssertFalse(logs.text.contains("fake-token"))
    }

    func testAppleContainerReadOnlyAdapterMissingExecutableDegradesHonestly() async {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(executables: [:]),
            processRunner: ScriptedRuntimeProcessRunner(behavior: .failure(.runtimeUnavailable("should not run")))
        )

        do {
            _ = try await adapter.observe(desiredState: desiredState)
            XCTFail("Expected missing executable to fail.")
        } catch let error as RuntimeAdapterError {
            guard case .runtimeUnavailable(let message) = error else {
                return XCTFail("Expected runtimeUnavailable, got \(error).")
            }
            XCTAssertTrue(message.contains("not found"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerParserParsesEmptyFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: fixture("apple-container-list-empty-real-json.txt")
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.adapterMetadata?.supportsMutation, false)
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserParsesRealEmptyJSONFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: fixture("apple-container-list-empty-real-json.txt")
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.projectName, desiredState.projectName)
        XCTAssertEqual(AppleContainerCommand.arguments(for: .listContainers), ["list", "--all", "--format", "json"])
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserIgnoresRealBuilderContainerFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: structuredBuilderContainerOutput()
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: proofDesiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.projectName, "proof")
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserParsesRealCreatedProofContainerFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: structuredProofContainerOutput()
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: proofDesiredStateWithExactOwnership)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].identity, proofIdentity)
        XCTAssertEqual(observed.services[0].image, "hostwright-proof-web:create-only")
        XCTAssertEqual(observed.services[0].lifecycleState, .stopped)
        XCTAssertEqual(observed.services[0].ports.first?.hostPort, 18080)
        XCTAssertEqual(observed.services[0].ports.first?.containerPort, 80)
        XCTAssertEqual(observed.services[0].ports.first?.protocolName, .tcp)
        XCTAssertEqual(observed.services[0].ports.first?.bindAddress, "0.0.0.0")
        XCTAssertEqual(observed.services[0].resourceIdentifier, proofIdentity.managedResourceIdentifier)
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserObservesExactPublishedUnixSocket()
        throws {
        let publications = [
            RuntimeUnixSocketPublication(
                hostPath: "/tmp/hostwright-a.sock",
                containerPath: "/run/a.sock",
                mode: .ownerOnly
            ),
            RuntimeUnixSocketPublication(
                hostPath: "/tmp/hostwright-z.sock",
                containerPath: "/run/z.sock",
                mode: .ownerAndGroup
            )
        ]
        let service = DesiredRuntimeService(
            identity: proofIdentity,
            image: "hostwright-proof-web:create-only",
            ports: [
                RuntimePortMapping(
                    hostPort: 18080,
                    containerPort: 80
                )
            ],
            publishedSockets: Array(publications.reversed())
        )
        let state = DesiredRuntimeState(
            projectName: "proof",
            services: [service],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier:
                        proofIdentity.managedResourceIdentifier,
                    identity: proofIdentity,
                    identityVersion:
                        RuntimeManagedResourceIdentity.currentVersion,
                    ownership: ownershipEvidence(
                        for: proofObservationMutationContext
                    )
                )
            ]
        )

        let observed = try AppleContainerObservationParser.parse(
            structuredProofContainerOutput(
                publishedSockets: publications.reversed().map {
                    [
                        "containerPath": $0.containerPath,
                        "hostPath": $0.hostPath,
                        "permissions":
                            $0.mode == .ownerOnly ? 0o600 : 0o660
                    ]
                }
            ),
            desiredState: state,
            metadata: ScriptedRuntimeAdapter.defaultMetadata
        )

        XCTAssertEqual(
            observed.services.first?.publishedSockets,
            publications
        )

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                structuredProofContainerOutput(
                    publishedSockets: [
                        [
                            "containerPath": "/run/a.sock",
                            "hostPath": "/tmp/hostwright-duplicate.sock",
                            "permissions": 0o600
                        ],
                        [
                            "containerPath": "/run/b.sock",
                            "hostPath": "/tmp/hostwright-duplicate.sock",
                            "permissions": 0o600
                        ]
                    ]
                ),
                desiredState: state,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        )
    }

    func testAppleContainerParserIncludesOwnedOrphanAndIgnoresUnrelatedProject() throws {
        let orphan = RuntimeServiceIdentity(projectName: "demo", serviceName: "orphan")
        let unrelated = RuntimeServiceIdentity(projectName: "other", serviceName: "api")
        let outputObject: [[String: Any]] = [
            realContainerListItem(
                identity: orphan,
                state: "running",
                networks: [[
                    "hostname": "orphan.local",
                    "ipv4Address": "192.168.64.2/24",
                    "ipv4Gateway": "192.168.64.1",
                    "ipv6Address": "fd00::2/64",
                    "macAddress": "02:00:00:00:00:02",
                    "mtu": 1280,
                    "network": "default"
                ]]
            ),
            realContainerListItem(identity: unrelated, state: "stopped", networks: [])
        ]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        let observed = try AppleContainerObservationParser.parse(
            output,
            desiredState: desiredState,
            metadata: ScriptedRuntimeAdapter.defaultMetadata
        )

        XCTAssertEqual(observed.services.map(\.identity), [orphan])
        XCTAssertEqual(observed.services[0].resourceIdentifier, orphan.managedResourceIdentifier)
        XCTAssertEqual(observed.services[0].networks[0].name, "default")
        XCTAssertEqual(observed.services[0].networks[0].hostname, "orphan.local")
        XCTAssertEqual(observed.services[0].networks[0].ipv4Address, "192.168.64.2/24")
        XCTAssertEqual(observed.services[0].networks[0].ipv4Gateway, "192.168.64.1")
        XCTAssertEqual(observed.services[0].networks[0].ipv6Address, "fd00::2/64")
        XCTAssertEqual(observed.services[0].networks[0].macAddress, "02:00:00:00:00:02")
        XCTAssertEqual(observed.services[0].networks[0].mtu, 1280)
    }

    func testAppleContainerParserRejectsDesiredVersionedContainerWithoutOwnershipLabels() throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": desiredService.image],
                "labels": [:],
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("missing exact ownership labels"))
        }
    }

    func testAppleContainerParserRejectsDesiredIdentifierClaimedByAnotherProject() throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let otherProjectIdentity = RuntimeServiceIdentity(projectName: "other", serviceName: identity.serviceName)
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": desiredService.image],
                "labels": RuntimeManagedResourceIdentity.labels(for: otherProjectIdentity),
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("claim another project"))
        }
    }

    func testAppleContainerParserUsesOwnershipVersionForLegacyIDMatchingV2Shape() throws {
        let serviceName = "0123456789abcdef0123456789abcdef"
        let legacyIdentity = RuntimeServiceIdentity(projectName: "v2-a-b", serviceName: serviceName)
        let legacyIdentifier = legacyIdentity.legacyManagedResourceIdentifier
        XCTAssertTrue(RuntimeManagedResourceIdentity.isCurrentIdentifier(legacyIdentifier))
        let state = DesiredRuntimeState(
            projectName: legacyIdentity.projectName,
            services: [DesiredRuntimeService(identity: legacyIdentity, image: "local/test:latest")],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: legacyIdentifier,
                    identity: legacyIdentity,
                    identityVersion: 1
                )
            ]
        )
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": legacyIdentifier,
                "image": ["reference": "local/test:latest"],
                "labels": [:],
                "publishedPorts": []
            ],
            "id": legacyIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        let observed = try AppleContainerObservationParser.parse(
            output,
            desiredState: state,
            metadata: ScriptedRuntimeAdapter.defaultMetadata
        )

        XCTAssertEqual(observed.services.first?.identity, legacyIdentity)
        XCTAssertEqual(observed.services.first?.resourceIdentifier, legacyIdentifier)
    }

    func testAppleContainerParserRejectsUnlabeledVersionedOwnedOrphan() throws {
        let orphan = RuntimeServiceIdentity(projectName: "demo", serviceName: "orphan")
        let resourceIdentifier = orphan.managedResourceIdentifier
        let state = DesiredRuntimeState(
            projectName: "demo",
            services: [desiredService],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: resourceIdentifier,
                    identity: orphan,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion
                )
            ]
        )
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": "local/test:latest"],
                "labels": [:],
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: state,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("missing compatible exact ownership labels"))
        }
    }

    func testAppleContainerParserParsesRunningFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: fixture("apple-container-1.1.0-inventory-containers.json")
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: desiredStateWithExactOwnership)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].identity.serviceName, "api")
        XCTAssertEqual(observed.services[0].lifecycleState, .running)
        XCTAssertEqual(observed.services[0].healthState, .unknown)
        XCTAssertEqual(observed.services[0].ports.first?.hostPort, 8080)
        XCTAssertEqual(observed.services[0].ports.map(\.hostPort), [8080, 8081])
        XCTAssertEqual(observed.services[0].networks.first?.name, "default")
        XCTAssertEqual(observed.services[0].networks.first?.kind, "container-network-vmnet:nat")
        XCTAssertNil(observed.services[0].networks.first?.interfaceName)
        XCTAssertEqual(observed.services[0].mounts.map(\.target), ["/cache", "/srv/data"])
        XCTAssertEqual(observed.services[0].mounts.last?.access, .readOnly)
        assertCompleteObservationMatrix(
            runner,
            expectedStatsContainerID: identity.managedResourceIdentifier
        )
    }

    func testAppleContainerParserFailsClosedForMalformedRealNetworkOutput() {
        let resourceIdentifier = proofIdentity.managedResourceIdentifier
        let output = """
        [
          {
            "configuration": {
              "id": "\(resourceIdentifier)",
              "image": { "reference": "hostwright-proof-web:create-only" },
              "labels": {
                "dev.hostwright.managed": "true",
                "dev.hostwright.identity-version": "2",
                "dev.hostwright.project": "proof",
                "dev.hostwright.service": "web",
                "dev.hostwright.resource-id": "\(resourceIdentifier)"
              },
              "publishedPorts": []
            },
            "id": "\(resourceIdentifier)",
            "status": {
              "state": "running",
              "networks": [
                { "name": "vmnet" }
              ]
            }
          }
        ]
        """

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: proofDesiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertTrue(message.contains("Unsupported Apple container network keys"))
        }
    }

    func testAppleContainerParserFailsClosedForMalformedOutputWithRedaction() throws {
        let cases: [(name: String, output: String, diagnostic: String, secrets: [String])] = [
            (
                "malformed text", "not-json token=fake-token password=fake-password",
                "[REDACTED]", ["fake-token", "fake-password"]
            ),
            (
                "unsupported root with secret fields",
                #"{"items":[],"token":"fake-token","password":"fake-password"}"#,
                "Unsupported keys", ["fake-token", "fake-password"]
            ),
            (
                "unsupported list item", #"[{"id":"abc","image":"example","token":"fake-token"}]"#,
                "Unsupported real Apple container list item shape", ["fake-token"]
            ),
            (
                "fixture with embedded secret text", try fixture("apple-container-list-redaction.txt"),
                "Unsupported keys", ["fake-token", "fake-password"]
            ),
        ]
        for scenario in cases {
            XCTAssertThrowsError(
                try AppleContainerObservationParser.parse(
                    scenario.output,
                    desiredState: desiredState,
                    metadata: ScriptedRuntimeAdapter.defaultMetadata
                ),
                scenario.name
            ) { error in
                guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                    return XCTFail("\(scenario.name): expected outputParseFailed, got \(error).")
                }
                for secret in scenario.secrets {
                    XCTAssertFalse(message.contains(secret), scenario.name)
                }
                XCTAssertTrue(message.contains(scenario.diagnostic), scenario.name)
            }
        }
    }
}
