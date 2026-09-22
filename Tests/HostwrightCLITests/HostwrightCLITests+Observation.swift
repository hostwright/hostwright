import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightCLITests {
    func testStatusWithStateDatabaseObservesAndRecordsEvent() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .healthy,
                        ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)],
                        publishedSockets: [
                            RuntimeUnixSocketPublication(
                                hostPath:
                                    "/tmp/hostwright/api.sock",
                                containerPath: "/run/api.sock",
                                mode: .ownerAndGroup
                            )
                        ]
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])

            let result = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: ScriptedApplyRuntimeAdapter(observedState: observed))
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Runtime: observed"))
            XCTAssertTrue(result.standardOutput.contains("Runtime parser: status-observation-v1"))
            XCTAssertTrue(result.standardOutput.contains("Telemetry: local-only; no upload"))
            XCTAssertTrue(result.standardOutput.contains("lifecycle=running"))
            XCTAssertTrue(
                result.standardOutput.contains(
                    "sockets=/tmp/hostwright/api.sock->/run/api.sock/0660"
                )
            )
            XCTAssertTrue(result.standardOutput.contains("id=\(RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier)"))
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            let statusEvent = try XCTUnwrap(events.first { $0.type == "status.observed" })
            XCTAssertEqual(
                try jsonObject(statusEvent.payloadJSONRedacted)["capabilitySHA256"] as? String,
                ScriptedApplyRuntimeAdapter.testCapabilitySnapshot.canonicalSHA256
            )
        }
    }

    func testStatusReportsMultipleReplicasWithoutDuplicateKeyFailure() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifest = """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                replicas: 2
                resources:
                  requests:
                    cpus: 1
                    memory: 512MiB
                  limits:
                    cpus: 1
                    memory: 512MiB

            """
            let primaryIdentity = RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api"
            )
            let replicaIdentity = RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "replica-1"
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: replicaIdentity,
                        resourceIdentifier: replicaIdentity.managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .healthy
                    ),
                    ObservedRuntimeService(
                        identity: primaryIdentity,
                        resourceIdentifier: primaryIdentity.managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .healthy
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let files = FileBox(files: [
                HostwrightIdentity.manifestFileName: manifest
            ])
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)

            let textResult = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            XCTAssertEqual(textResult.exitCode, 0)
            XCTAssertTrue(textResult.standardOutput.contains("- api: id="))
            XCTAssertTrue(
                textResult.standardOutput.contains("- api[replica-1]: id=")
            )

            let jsonResult = HostwrightCLI.run(
                arguments: [
                    "status", "--state-db", databasePath, "--output", "json"
                ],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            XCTAssertEqual(jsonResult.exitCode, 0)
            let json = try jsonObject(jsonResult.standardOutput)
            let services = try XCTUnwrap(json["services"] as? [[String: Any]])
            let instances = try XCTUnwrap(
                services.first?["instances"] as? [[String: Any]]
            )
            XCTAssertEqual(
                instances.compactMap { $0["instance"] as? String },
                ["replica-1"]
            )
            XCTAssertEqual(
                instances.compactMap { $0["identity"] as? String },
                ["demo/api", "demo/api/replica-1"]
            )
        }
    }

    func testStatusRejectsChangedObservedCapabilityBeforeRecordingState() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: fakeAdapterMetadata,
                capabilitySHA256: ScriptedApplyRuntimeAdapter.changedCapabilitySnapshot.canonicalSHA256
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed)

            let result = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.runtimeUnavailable.rawValue)
            XCTAssertTrue(result.standardError.contains("staleCapability"))
            let store = SQLiteStateStore(path: databasePath)
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try store.events.loadAll().isEmpty)
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)
            XCTAssertNil(try store.observedStates.loadLatestSnapshot(
                projectID: "project-demo",
                providerID: .appleContainerCLI
            ))
            XCTAssertThrowsError(try store.desiredStates.loadProject(id: "project-demo"))
        }
    }

    func testStatusJSONOutputSupportsDefaultAndExplicitStatePaths() throws {
        let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { home in
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: fakeAdapterMetadata
            )
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            let defaultResult = HostwrightCLI.run(
                arguments: ["status", "--output", "json"],
                environment: environment(
                    files: files,
                    runtimeAdapter: ScriptedApplyRuntimeAdapter(observedState: observed),
                    localPathResolution: { explicitPath in
                        try HostwrightLocalPathResolver.resolve(
                            explicitStateDatabasePath: explicitPath,
                            homeDirectory: home.path,
                            environment: [:]
                        )
                    }
                )
            )

            XCTAssertEqual(defaultResult.exitCode, 0)
            let defaultJSON = try jsonObject(defaultResult.standardOutput)
            XCTAssertEqual(defaultJSON["kind"] as? String, "status")
            XCTAssertEqual(defaultJSON["stateDatabasePath"] as? String, resolution.stateDatabasePath)
            let runtime = try XCTUnwrap(defaultJSON["runtime"] as? [String: Any])
            XCTAssertEqual(runtime["observed"] as? Bool, true)
        }

        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                        resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .healthy,
                        ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)],
                        publishedSockets: [
                            RuntimeUnixSocketPublication(
                                hostPath:
                                    "/tmp/hostwright/api.sock",
                                containerPath: "/run/api.sock",
                                mode: .ownerAndGroup
                            )
                        ],
                        networks: [
                            RuntimeNetworkAttachment(
                                name: "default",
                                hostname: "api.local",
                                ipv4Address: "192.168.64.8/24",
                                mtu: 1280
                            )
                        ]
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let result = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath, "--output", "json"],
                environment: environment(files: files, runtimeAdapter: ScriptedApplyRuntimeAdapter(observedState: observed))
            )

            XCTAssertEqual(result.exitCode, 0)
            let json = try jsonObject(result.standardOutput)
            XCTAssertEqual(json["kind"] as? String, "status")
            XCTAssertNotNil(json["planHash"])
            XCTAssertEqual(
                json["capabilitySHA256"] as? String,
                ScriptedApplyRuntimeAdapter.testCapabilitySnapshot.canonicalSHA256
            )
            let observedRuntime = try XCTUnwrap(json["runtime"] as? [String: Any])
            XCTAssertEqual(observedRuntime["observed"] as? Bool, true)
            XCTAssertEqual(observedRuntime["parser"] as? String, "status-observation-v1")
            XCTAssertEqual(observedRuntime["runtimeName"] as? String, "fake-runtime")
            XCTAssertEqual(json["telemetryPolicy"] as? String, "local-only; no upload")
            let services = try XCTUnwrap(json["services"] as? [[String: Any]])
            XCTAssertEqual(services.first?["name"] as? String, "api")
            let observedService = try XCTUnwrap(services.first?["observed"] as? [String: Any])
            XCTAssertEqual(
                observedService["resourceIdentifier"] as? String,
                RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier
            )
            let sockets = try XCTUnwrap(
                observedService["sockets"] as? [[String: Any]]
            )
            XCTAssertEqual(sockets.count, 1)
            XCTAssertEqual(
                sockets[0]["containerPath"] as? String,
                "/run/api.sock"
            )
            XCTAssertEqual(
                sockets[0]["hostPath"] as? String,
                "/tmp/hostwright/api.sock"
            )
            XCTAssertEqual(sockets[0]["mode"] as? String, "0660")
            let networks = try XCTUnwrap(observedService["networks"] as? [[String: Any]])
            XCTAssertEqual(networks.first?["ipv4Address"] as? String, "192.168.64.8/24")
            XCTAssertEqual(networks.first?["mtu"] as? Int, 1280)
        }
    }

    func testStatusStateDatabaseFailureUsesStateExitCodeAndJSONEnvelope() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { directory in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])

            let result = HostwrightCLI.run(
                arguments: ["status", "--state-db", directory.path, "--output", "json"],
                environment: environment(files: files)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            let json = try jsonObject(result.standardError)
            XCTAssertEqual(json["kind"] as? String, "error")
            XCTAssertEqual(json["code"] as? String, HostwrightErrorCode.stateStoreUnavailable.rawValue)
            XCTAssertEqual(json["exitCode"] as? Int, Int(CLIExitCode.stateUnavailable.rawValue))
        }
    }

    func testLogsUseRuntimeAdapterAndRedactOutput() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                    lifecycleState: .running
                )],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed, logsText: "token=\(fakeSecret)\nready")

            let result = HostwrightCLI.run(
                arguments: ["logs", "api", "--tail", "5", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Tail: 5"))
            XCTAssertTrue(result.standardOutput.contains("[REDACTED]"))
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            XCTAssertEqual(adapter.logRequests, [RuntimeServiceIdentity(projectName: "demo", serviceName: "api")])
            XCTAssertEqual(adapter.logResourceIdentifiers, [RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier])
            let events = try SQLiteStateStore(path: databasePath).events.loadAll()
            XCTAssertTrue(events.contains { $0.type == "logs.read" })
        }
    }

    func testBoundedLogsSelectsSDKProviderAndItsExactOwnershipHints() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
            let resourceIdentifier = identity.managedResourceIdentifier
            try store.ownership.upsert(OwnershipRecord(
                id: "ownership-sdk-logs", resourceIdentifier: resourceIdentifier, resourceType: "container",
                projectID: "project-demo", serviceName: "api", runtimeAdapter: RuntimeProviderID.appleContainerization.rawValue,
                createdAt: "2026-07-01T00:00:00Z", observedAt: "2026-07-01T00:00:00Z", cleanupEligible: true,
                metadataJSONRedacted: "{}", identityVersion: RuntimeManagedResourceIdentity.currentVersion))
            let snapshot = RuntimeCapabilitySnapshot(
                descriptor: RuntimeProviderDescriptor(providerID: .appleContainerization, components: [
                    RuntimeProviderComponent(identifier: .appleContainerizationHelper, version: "0.0.2", build: "test", fingerprint: String(repeating: "a", count: 64)),
                    RuntimeProviderComponent(identifier: .containerizationHelperProtocolV1, version: "1", build: "test", fingerprint: String(repeating: "b", count: 64)),
                    RuntimeProviderComponent(identifier: .appleContainerizationFramework, version: "0.35.0", build: "test", fingerprint: String(repeating: "c", count: 64))
                ], minimumMacOSVersion: .init(major: 26), supportedArchitectures: [.arm64]),
                host: ScriptedApplyRuntimeAdapter.testCapabilitySnapshot.host,
                features: ScriptedApplyRuntimeAdapter.testCapabilitySnapshot.features)
            let metadata = RuntimeAdapterMetadata(providerID: .appleContainerization, adapterName: "sdk-unit-fixture",
                adapterVersion: "test", runtimeName: "sdk-unit-fixture", runtimeVersion: "0.35.0", supportsMutation: true,
                capabilities: [.readOnlyObservation, .logStreaming])
            let adapter = ScriptedApplyRuntimeAdapter(observedState: ObservedRuntimeState(projectName: "demo",
                services: [ObservedRuntimeService(identity: identity, resourceIdentifier: resourceIdentifier, lifecycleState: .running)],
                adapterMetadata: metadata, capabilitySHA256: snapshot.canonicalSHA256), logsText: "hwq:unit-fixture:2",
                capabilitySnapshots: [snapshot])
            var selectedEnvironment = environment(files: files)
            selectedEnvironment.runtimeProviderProbes = { [.available(snapshot)] }
            selectedEnvironment.runtimeAdapterForProvider = { provider in
                XCTAssertEqual(provider, .appleContainerization)
                return adapter
            }
            selectedEnvironment.runtimeAdapter = {
                XCTFail("Bounded SDK logs must select the provider adapter")
                return adapter
            }
            let result = HostwrightCLI.run(arguments: ["logs", "api", "--runtime-provider", "containerization", "--state-db", databasePath],
                environment: selectedEnvironment)
            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardOutput.contains("hwq:unit-fixture:2"))
            XCTAssertEqual(adapter.logResourceIdentifiers, [resourceIdentifier])
            XCTAssertEqual(adapter.observedDesiredStates.first?.ownedResourceHints.map(\.resourceIdentifier), [resourceIdentifier])
            XCTAssertEqual(adapter.observedDesiredStates.first?.ownedResourceHints.first?.ownership?.providerID, .appleContainerization)
        }
    }

    func testBoundedLogsRejectsSelectedProviderObservationMismatchBeforeLogRead() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let metadata = RuntimeAdapterMetadata(providerID: .appleContainerization, adapterName: "wrong-provider-unit-fixture",
                adapterVersion: "test", runtimeName: "unit-fixture", runtimeVersion: nil, supportsMutation: false, capabilities: [.readOnlyObservation])
            let adapter = ScriptedApplyRuntimeAdapter(observedState: ObservedRuntimeState(projectName: "demo", services: [], adapterMetadata: metadata))
            let result = HostwrightCLI.run(arguments: ["logs", "api", "--runtime-provider", "apple-cli", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter))
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(adapter.logResourceIdentifiers.isEmpty)
        }
    }

    func testLogsUsesStateBackedLegacyExactResourceIdentifier() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
            let resourceIdentifier = identity.legacyManagedResourceIdentifier
            try store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-legacy-logs",
                    resourceIdentifier: resourceIdentifier,
                    resourceType: "container",
                    projectID: "project-demo",
                    serviceName: "api",
                    runtimeAdapter: "AppleContainerApplyAdapter",
                    createdAt: "2026-07-01T00:00:00Z",
                    observedAt: "2026-07-01T00:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    identityVersion: 1
                )
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: identity,
                        resourceIdentifier: resourceIdentifier,
                        lifecycleState: .running
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed, logsText: "ready")

            let result = HostwrightCLI.run(
                arguments: ["logs", "api", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardOutput.contains("Resource: \(resourceIdentifier)"))
            XCTAssertEqual(adapter.logResourceIdentifiers, [resourceIdentifier])
            XCTAssertEqual(adapter.observedDesiredStates.first?.ownedResourceHints.map(\.resourceIdentifier), [resourceIdentifier])
            let event = try XCTUnwrap(store.events.loadAll().first { $0.type == "logs.read" })
            XCTAssertTrue(event.payloadJSONRedacted.contains(resourceIdentifier))
        }
    }

    func testLogsStateDatabaseFailureUsesStateExitCode() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { directory in
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: singleServiceManifest])
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                    lifecycleState: .running
                )],
                adapterMetadata: fakeAdapterMetadata
            )
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observed, logsText: "ready")

            let result = HostwrightCLI.run(
                arguments: ["logs", "api", "--state-db", directory.path],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertEqual(adapter.logRequests, [])
        }
    }

    func testEventsCommandReadsStateLedgerDeterministically() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.events.append([
                EventRecord(id: "event-2", timestamp: "2026-07-01T00:00:02Z", severity: .warning, type: "logs.read", source: "test", projectID: "project-demo", serviceName: "api", runtimeAdapter: nil, message: "token=\(fakeSecret)", payloadJSONRedacted: "{}"),
                EventRecord(id: "event-1", timestamp: "2026-07-01T00:00:01Z", severity: .info, type: "status.observed", source: "test", projectID: "project-demo", serviceName: nil, runtimeAdapter: nil, message: "ok", payloadJSONRedacted: "{}")
            ])

            let result = HostwrightCLI.run(arguments: ["events", "--state-db", databasePath, "--project", "demo"], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertLessThan(result.standardOutput.range(of: "status.observed")!.lowerBound, result.standardOutput.range(of: "logs.read")!.lowerBound)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
        }
    }

    func testEventsJSONOutputIsOrderedAndRedacted() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: singleServiceManifest)
            try store.events.append([
                EventRecord(id: "event-2", timestamp: "2026-07-01T00:00:02Z", severity: .warning, type: "logs.read", source: "test", projectID: "project-demo", serviceName: "api", runtimeAdapter: nil, message: "token=\(fakeSecret)", payloadJSONRedacted: #"{"token":"\#(fakeSecret)"}"#),
                EventRecord(id: "event-1", timestamp: "2026-07-01T00:00:01Z", severity: .info, type: "status.observed", source: "test", projectID: "project-demo", serviceName: nil, runtimeAdapter: nil, message: "ok", payloadJSONRedacted: "{}")
            ])

            let result = HostwrightCLI.run(arguments: ["events", "--state-db", databasePath, "--project", "demo", "--output", "json"], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            let json = try jsonObject(result.standardOutput)
            XCTAssertEqual(json["kind"] as? String, "events")
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertEqual(events.map { $0["type"] as? String }, ["status.observed", "logs.read"])
            XCTAssertEqual(events.last?["message"] as? String, "token=[REDACTED]")
        }
    }

    func testEventsFiltersSortsAndLimitsResults() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: twoServiceManifest)
            try store.events.append([
                EventRecord(id: "event-1", timestamp: "2026-07-01T00:00:01Z", severity: .info, type: "status.observed", source: "test", projectID: "project-demo", serviceName: nil, runtimeAdapter: nil, message: "ok", payloadJSONRedacted: "{}"),
                EventRecord(id: "event-2", timestamp: "2026-07-01T00:00:02Z", severity: .error, type: "cleanup.failed", source: "test", projectID: "project-demo", serviceName: "api", runtimeAdapter: nil, message: "token=\(fakeSecret)", payloadJSONRedacted: "{}"),
                EventRecord(id: "event-3", timestamp: "2026-07-01T00:00:03Z", severity: .error, type: "cleanup.failed", source: "test", projectID: "project-demo", serviceName: "worker", runtimeAdapter: nil, message: "worker failed", payloadJSONRedacted: "{}")
            ])

            let result = HostwrightCLI.run(
                arguments: ["events", "--state-db", databasePath, "--project", "demo", "--type", "cleanup.failed", "--severity", "error", "--sort", "desc", "--limit", "1", "--output", "json"],
                environment: environment(files: FileBox())
            )

            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardOutput.contains(fakeSecret))
            let json = try jsonObject(result.standardOutput)
            let filters = try XCTUnwrap(json["filters"] as? [String: Any])
            XCTAssertEqual(filters["type"] as? String, "cleanup.failed")
            XCTAssertEqual(filters["sort"] as? String, "desc")
            XCTAssertEqual(filters["limit"] as? Int, 1)
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0]["id"] as? String, "event-3")
        }
    }

    func testEventsCommandDoesNotCreateOrMigrateMissingStateDatabase() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let result = HostwrightCLI.run(arguments: ["events", "--state-db", databasePath], environment: environment(files: FileBox()))

            XCTAssertEqual(result.exitCode, CLIExitCode.stateUnavailable.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.stateStoreUnavailable.rawValue))
            XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))
        }
    }
}
