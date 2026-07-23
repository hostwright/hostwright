import Foundation
import HostwrightCore
import HostwrightHealth
import HostwrightManifest
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class RuntimeProviderMigrationCLITests: XCTestCase {
    func testConfirmRefusesStaleTokenAfterDurableOwnershipFenceChanges() throws {
        try withFixture { fixture in
            let dryRun = HostwrightCLI.run(
                arguments: fixture.arguments(mode: ["--dry-run", "--json"]),
                environment: fixture.environment
            )
            XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
            let plan = try JSONDecoder().decode(
                RuntimeProviderMigrationPlan.self,
                from: Data(dryRun.standardOutput.utf8)
            )
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.operationGroupSteps.loadAll().isEmpty)

            let replacementFence = "44444444-4444-4444-8444-444444444444"
            let advanced = try fixture.store.ownership.advanceFencingToken(
                resourceIdentifier: try XCTUnwrap(plan.resources.first).resourceIdentifier,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                expectedResourceUUID: fixture.resourceUUID,
                expectedFencingToken: fixture.sourceFence,
                newFencingToken: replacementFence,
                observedAt: "2026-07-19T12:01:00Z"
            )
            XCTAssertEqual(advanced?.fencingToken, replacementFence)
            try hostwrightWaitForAsync {
                try await fixture.source.replaceFencingToken(
                    expected: fixture.sourceFence,
                    replacement: replacementFence
                )
            }

            let result = HostwrightCLI.run(
                arguments: fixture.arguments(
                    mode: ["--confirm-migration", plan.confirmationToken, "--json"]
                ),
                environment: fixture.environment
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.confirmationMismatch.rawValue)
            XCTAssertEqual(result.standardOutput, "")
            let error = try jsonObject(result.standardError)
            XCTAssertEqual(error["kind"] as? String, "error")
            XCTAssertEqual(error["code"] as? String, HostwrightErrorCode.confirmationMismatch.rawValue)
            XCTAssertEqual(error["exitCode"] as? Int, Int(CLIExitCode.confirmationMismatch.rawValue))
            XCTAssertEqual(
                error["message"] as? String,
                "Migration confirmation token does not match the current dry-run."
            )

            XCTAssertEqual(try adapterSnapshot(fixture.source).mutations, [])
            XCTAssertEqual(try adapterSnapshot(fixture.target).mutations, [])
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.operationGroupSteps.loadAll().isEmpty)

            let project = try fixture.store.desiredStates.loadProject(id: fixture.projectID)
            XCTAssertEqual(project.mutationProvider, RuntimeProviderID.appleContainerCLI.rawValue)
            XCTAssertEqual(project.providerGeneration, 1)
            let ownership = try XCTUnwrap(
                fixture.store.ownership.loadAll().first { $0.resourceUUID == fixture.resourceUUID }
            )
            XCTAssertEqual(ownership.fencingToken, replacementFence)
            XCTAssertEqual(ownership.runtimeAdapter, RuntimeProviderID.appleContainerCLI.rawValue)
            XCTAssertEqual(ownership.providerGeneration, 1)
            XCTAssertEqual(ownership.resourceGeneration, 1)
        }
    }

    func testDryRunThenConfirmTransfersBindingAndRetiresOnlyTheExactSource() throws {
        try withFixture { fixture in
            let dryRun = HostwrightCLI.run(
                arguments: fixture.arguments(mode: ["--dry-run", "--json"]),
                environment: fixture.environment
            )

            XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
            XCTAssertEqual(dryRun.standardError, "")
            let plan = try JSONDecoder().decode(
                RuntimeProviderMigrationPlan.self,
                from: Data(dryRun.standardOutput.utf8)
            )
            XCTAssertTrue(plan.confirmationToken.hasPrefix(RuntimeProviderMigrationPlan.confirmationPrefix))
            XCTAssertEqual(plan.sourceProviderID, .appleContainerCLI)
            XCTAssertEqual(plan.targetProviderID, .appleContainerization)
            XCTAssertEqual(plan.resources.map(\.resourceUUID), [fixture.resourceUUID])
            XCTAssertEqual(
                try adapterSnapshot(fixture.source).mutations,
                [],
                "A migration dry-run must not mutate the source provider."
            )
            XCTAssertEqual(
                try adapterSnapshot(fixture.target).mutations,
                [],
                "A migration dry-run must not mutate the target provider."
            )
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
            let before = try fixture.store.desiredStates.loadProject(id: fixture.projectID)
            XCTAssertEqual(before.mutationProvider, RuntimeProviderID.appleContainerCLI.rawValue)
            XCTAssertEqual(before.providerGeneration, 1)

            let confirmed = HostwrightCLI.run(
                arguments: fixture.arguments(
                    mode: ["--confirm-migration", plan.confirmationToken, "--json"]
                ),
                environment: fixture.environment
            )

            XCTAssertEqual(confirmed.exitCode, 0, confirmed.standardError)
            XCTAssertEqual(confirmed.standardError, "")
            let report = try jsonObject(confirmed.standardOutput)
            XCTAssertEqual(report["providerID"] as? String, RuntimeProviderID.appleContainerization.rawValue)
            XCTAssertEqual(report["providerGeneration"] as? Int, 2)
            XCTAssertEqual(
                report["checkpoint"] as? Int,
                RuntimeProviderMigrationCheckpoint.sourceRetired.rawValue
            )
            XCTAssertEqual(report["resumed"] as? Bool, false)

            let after = try fixture.store.desiredStates.loadProject(id: fixture.projectID)
            XCTAssertEqual(after.resourceUUID, before.resourceUUID)
            XCTAssertEqual(after.mutationProvider, RuntimeProviderID.appleContainerization.rawValue)
            XCTAssertEqual(after.providerGeneration, 2)
            XCTAssertEqual(
                try fixture.store.desiredStates.loadDesiredServices(projectID: fixture.projectID)
                    .map(\.mutationProvider),
                [RuntimeProviderID.appleContainerization.rawValue]
            )

            let ownership = try fixture.store.ownership.loadAll()
            XCTAssertEqual(ownership.count, 1)
            let targetOwnership = try XCTUnwrap(ownership.first)
            XCTAssertEqual(targetOwnership.resourceUUID, fixture.resourceUUID)
            XCTAssertEqual(targetOwnership.projectResourceUUID, before.resourceUUID)
            XCTAssertEqual(targetOwnership.runtimeAdapter, RuntimeProviderID.appleContainerization.rawValue)
            XCTAssertEqual(targetOwnership.providerGeneration, 2)
            XCTAssertEqual(targetOwnership.resourceGeneration, 1)
            XCTAssertEqual(targetOwnership.projectGeneration, 1)

            let sourceState = try adapterSnapshot(fixture.source)
            let targetState = try adapterSnapshot(fixture.target)
            XCTAssertEqual(sourceState.mutations, [.stop, .remove])
            XCTAssertTrue(sourceState.resources.isEmpty)
            XCTAssertEqual(targetState.mutations, [.create, .start])
            XCTAssertEqual(targetState.resources.count, 1)
            XCTAssertEqual(targetState.resources.first?.resourceUUID, fixture.resourceUUID)
            XCTAssertEqual(targetState.resources.first?.lifecycle, .running)
            XCTAssertEqual(targetState.resources.first?.providerID, .appleContainerization)
            XCTAssertEqual(targetState.resources.first?.providerGeneration, 2)

            let operations = try fixture.store.operationGroups.loadProject(projectID: fixture.projectID)
            XCTAssertEqual(operations.count, 1)
            XCTAssertEqual(operations.first?.status, .succeeded)
            XCTAssertEqual(operations.first?.checkpoint, "migration-source-retired")
        }
    }

    private func adapterSnapshot(
        _ adapter: RuntimeProviderMigrationCLIAdapter
    ) throws -> RuntimeProviderMigrationCLIAdapter.Snapshot {
        try hostwrightWaitForAsync { await adapter.snapshot() }
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    private func withFixture(_ body: (RuntimeProviderMigrationCLIFixture) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-runtime-migration-cli-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(try RuntimeProviderMigrationCLIFixture(directory: directory))
    }
}

private struct RuntimeProviderMigrationCLIFixture {
    let projectID = "project-sample"
    let resourceUUID = "22222222-2222-4222-8222-222222222222"
    let sourceFence = "33333333-3333-4333-8333-333333333333"
    let manifestPath: String
    let databasePath: String
    let store: SQLiteStateStore
    let source: RuntimeProviderMigrationCLIAdapter
    let target: RuntimeProviderMigrationCLIAdapter
    let environment: CLIEnvironment

    init(directory: URL) throws {
        let manifestText = """
        version: 2
        project: sample
        services:
          api:
            image: registry.example/api:1.0.0

        """
        let manifestFilePath = directory.appendingPathComponent("hostwright.yaml").path
        let stateDatabasePath = directory.appendingPathComponent("state.sqlite").path
        manifestPath = manifestFilePath
        databasePath = stateDatabasePath
        store = SQLiteStateStore(path: stateDatabasePath)
        try store.migrate()
        let manifest = try ManifestValidator.validated(manifestText)
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: manifestFilePath,
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: "2026-07-19T12:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
        )
        let project = try store.desiredStates.loadProject(id: projectID)
        let desired = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(projectName: "sample", serviceName: "api"),
            image: "registry.example/api:1.0.0"
        )
        let ownership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID,
            projectUUID: project.resourceUUID,
            resourceGeneration: 1,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            fencingToken: sourceFence
        )
        try store.ownership.upsert(
            OwnershipRecord(
                id: "ownership-api",
                resourceIdentifier: desired.identity.managedResourceIdentifier,
                resourceType: "container",
                projectID: projectID,
                serviceName: "api",
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                createdAt: "2026-07-19T12:00:00Z",
                observedAt: "2026-07-19T12:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                resourceUUID: resourceUUID,
                resourceGeneration: 1,
                projectResourceUUID: project.resourceUUID,
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: sourceFence
            )
        )

        let sourceSnapshot = runtimeProviderMigrationCLISnapshot(providerID: .appleContainerCLI)
        let targetSnapshot = runtimeProviderMigrationCLISnapshot(providerID: .appleContainerization)
        source = RuntimeProviderMigrationCLIAdapter(
            providerID: .appleContainerCLI,
            capabilitySnapshot: sourceSnapshot,
            resources: [
                RuntimeProviderMigrationCLIResource(
                    desired: desired,
                    ownership: ownership,
                    lifecycle: .running,
                    runtimeID: "source-container"
                )
            ],
            localImages: [:]
        )
        let image = RuntimeLocalImageEvidence(
            reference: desired.image,
            descriptorDigest: runtimeProviderMigrationCLIDigest("a"),
            variantDigest: runtimeProviderMigrationCLIDigest("b"),
            architecture: "arm64",
            operatingSystem: "linux"
        )
        target = RuntimeProviderMigrationCLIAdapter(
            providerID: .appleContainerization,
            capabilitySnapshot: targetSnapshot,
            resources: [],
            localImages: [image.reference: image]
        )

        let resolution = try HostwrightLocalPathResolver.resolve(
            explicitStateDatabasePath: stateDatabasePath,
            homeDirectory: directory.path,
            environment: [:]
        )
        let sourceAdapter = source
        let targetAdapter = target
        environment = CLIEnvironment(
            fileExists: { $0 == manifestFilePath },
            readTextFile: { path in
                guard path == manifestFilePath else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return manifestText
            },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            localPathResolution: { _ in resolution },
            runtimeAdapter: { sourceAdapter },
            runtimeAdapterForProvider: { providerID in
                switch providerID {
                case .appleContainerCLI:
                    return sourceAdapter
                case .appleContainerization:
                    return targetAdapter
                default:
                    throw RuntimeProviderSelectionError.providerUnavailable(providerID)
                }
            },
            swiftVersion: { "Swift test" },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS 26.0" },
            doctorSystemSnapshot: { .unavailable() }
        )
    }

    func arguments(mode: [String]) -> [String] {
        [
            "runtime", "migrate", manifestPath,
            "--state-db", databasePath,
            "--to", "containerization"
        ] + mode
    }
}

private struct RuntimeProviderMigrationCLIResource: Sendable {
    let desired: DesiredRuntimeService
    var ownership: RuntimeInventoryOwnershipEvidence?
    var lifecycle: RuntimeInventoryLifecycleState
    let runtimeID: String
}

private actor RuntimeProviderMigrationCLIAdapter: RuntimeAdapter {
    struct ResourceSnapshot: Equatable, Sendable {
        let resourceUUID: String?
        let lifecycle: RuntimeInventoryLifecycleState
        let providerID: RuntimeProviderID?
        let providerGeneration: Int?
    }

    struct Snapshot: Equatable, Sendable {
        let mutations: [PlannedRuntimeActionKind]
        let resources: [ResourceSnapshot]
    }

    let providerID: RuntimeProviderID
    let providerSnapshot: RuntimeCapabilitySnapshot
    var resources: [RuntimeProviderMigrationCLIResource]
    let localImages: [String: RuntimeLocalImageEvidence]
    private var mutations: [PlannedRuntimeActionKind] = []

    init(
        providerID: RuntimeProviderID,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        resources: [RuntimeProviderMigrationCLIResource],
        localImages: [String: RuntimeLocalImageEvidence]
    ) {
        self.providerID = providerID
        self.providerSnapshot = capabilitySnapshot
        self.resources = resources
        self.localImages = localImages
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: providerID,
            adapterName: "RuntimeProviderMigrationCLIAdapter",
            adapterVersion: "1.0.0",
            runtimeName: providerID.rawValue,
            runtimeVersion: "1.0.0",
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .cleanup]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation, .cleanup]
    }

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot { providerSnapshot }

    func inventory() async throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.0.0",
                services: [
                    RuntimeInventoryService(
                        identifier: "api-server",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: try resources.map(container),
            images: localImages.values.map { evidence in
                RuntimeInventoryImage(
                    runtimeID: evidence.descriptorDigest,
                    descriptorDigest: evidence.descriptorDigest,
                    references: [evidence.reference],
                    variants: [
                        RuntimeInventoryImageVariant(
                            digest: evidence.variantDigest,
                            architecture: evidence.architecture,
                            operatingSystem: evidence.operatingSystem
                        )
                    ],
                    labels: []
                )
            },
            networks: [],
            volumes: []
        )
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: [],
            adapterMetadata: await metadata(),
            capabilitySHA256: providerSnapshot.canonicalSHA256
        )
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(actions: [], capabilitySHA256: providerSnapshot.canonicalSHA256)
    }

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String { "1.0.0" }

    func runtimeReadiness() async throws -> RuntimeReadinessReport {
        RuntimeReadinessReport(
            runtimeName: providerID.rawValue,
            cliVersion: "1.0.0",
            serviceState: .running,
            serviceVersion: "1.0.0",
            serviceBuild: "test"
        )
    }

    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        guard let evidence = localImages[imageReference] else {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: 1,
                message: "Local image is absent.",
                standardError: ""
            )
        }
        return evidence
    }

    func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        guard confirmation?.confirmed == true,
              let context = confirmation?.context,
              context.providerID == providerID else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Missing migration context.")
        }
        mutations.append(action.kind)
        switch action.kind {
        case .create:
            guard let desired = action.desiredService else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy("Create requires desired state.")
            }
            resources.append(
                RuntimeProviderMigrationCLIResource(
                    desired: desired,
                    ownership: RuntimeInventoryOwnershipEvidence(
                        resourceUUID: context.resourceUUID,
                        projectUUID: context.projectResourceUUID,
                        resourceGeneration: context.resourceGeneration,
                        projectGeneration: context.projectGeneration,
                        providerID: context.providerID,
                        providerGeneration: context.providerGeneration,
                        fencingToken: context.fencingToken
                    ),
                    lifecycle: .stopped,
                    runtimeID: "target-\(context.resourceUUID)"
                )
            )
        case .start:
            try update(.running, context: context)
        case .stop:
            try update(.stopped, context: context)
        case .remove:
            guard let index = resources.firstIndex(where: {
                $0.ownership?.resourceUUID == context.resourceUUID &&
                    $0.ownership?.fencingToken == context.fencingToken
            }) else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "Removal is not covered by the exact migration fence."
                )
            }
            resources.remove(at: index)
        case .restart, .update, .noOp:
            break
        }
        return RuntimeEvent(
            identity: action.identity,
            message: action.summary,
            resourceIdentifier: action.resourceIdentifier
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            mutations: mutations,
            resources: resources.map {
                ResourceSnapshot(
                    resourceUUID: $0.ownership?.resourceUUID,
                    lifecycle: $0.lifecycle,
                    providerID: $0.ownership?.providerID,
                    providerGeneration: $0.ownership?.providerGeneration
                )
            }
        )
    }

    func replaceFencingToken(expected: String, replacement: String) throws {
        guard let index = resources.firstIndex(where: {
            $0.ownership?.resourceUUID != nil && $0.ownership?.fencingToken == expected
        }), let ownership = resources[index].ownership else {
            throw RuntimeAdapterError.outputParseFailed(
                "Expected source ownership fence was unavailable."
            )
        }
        resources[index].ownership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: ownership.resourceUUID,
            projectUUID: ownership.projectUUID,
            resourceGeneration: ownership.resourceGeneration,
            projectGeneration: ownership.projectGeneration,
            providerID: ownership.providerID,
            providerGeneration: ownership.providerGeneration,
            fencingToken: replacement
        )
    }

    private func update(
        _ lifecycle: RuntimeInventoryLifecycleState,
        context: RuntimeMutationContext
    ) throws {
        guard let index = resources.firstIndex(where: {
            $0.ownership?.resourceUUID == context.resourceUUID
        }) else {
            throw RuntimeAdapterError.outputParseFailed("Resource is absent.")
        }
        resources[index].lifecycle = lifecycle
    }

    private func container(
        _ resource: RuntimeProviderMigrationCLIResource
    ) throws -> RuntimeInventoryContainer {
        let labels: [RuntimeInventoryLabel]
        if let ownership = resource.ownership {
            let context = RuntimeMutationContext(
                providerID: ownership.providerID,
                capabilitySHA256: providerSnapshot.canonicalSHA256,
                operationID: "inventory",
                resourceUUID: ownership.resourceUUID,
                resourceGeneration: ownership.resourceGeneration,
                projectResourceUUID: ownership.projectUUID,
                projectGeneration: ownership.projectGeneration,
                providerGeneration: ownership.providerGeneration,
                fencingToken: ownership.fencingToken
            )
            labels = try RuntimeManagedResourceIdentity.labels(
                for: resource.desired.identity,
                context: context
            ).map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
        } else {
            labels = []
        }
        return RuntimeInventoryContainer(
            runtimeID: resource.runtimeID,
            name: resource.desired.identity.managedResourceIdentifier,
            imageReference: resource.desired.image,
            lifecycle: resource.lifecycle,
            health: RuntimeInventoryHealth(availability: .unavailable),
            labels: labels,
            ownership: resource.ownership,
            initConfiguration: RuntimeInventoryInitConfiguration(
                executable: "/bin/service",
                arguments: [],
                environment: []
            ),
            ports: [],
            mounts: [],
            networks: [],
            services: []
        )
    }
}

private func runtimeProviderMigrationCLISnapshot(
    providerID: RuntimeProviderID
) -> RuntimeCapabilitySnapshot {
    let components: [RuntimeProviderComponent]
    if providerID == .appleContainerCLI {
        components = [
            RuntimeProviderComponent(
                identifier: .appleContainerCLI,
                version: "1.1.0",
                build: "release",
                fingerprint: "abcdef0"
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerAPIService,
                version: "1.1.0",
                build: "release",
                fingerprint: "abcdef0"
            )
        ]
    } else {
        components = [
            RuntimeProviderComponent(
                identifier: .appleContainerizationHelper,
                version: "0.0.2",
                build: "test",
                fingerprint: "abcdef1"
            ),
            RuntimeProviderComponent(
                identifier: .containerizationHelperProtocolV1,
                version: "1",
                build: "test",
                fingerprint: "abcdef2"
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerizationFramework,
                version: "0.35.0",
                build: "release",
                fingerprint: "abcdef3"
            )
        ]
    }
    return RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: providerID,
            components: components,
            minimumMacOSVersion: RuntimeProviderMacOSVersion(major: 26),
            supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: RuntimeProviderMacOSVersion(major: 26),
            macOSBuild: "25A123",
            architecture: .arm64
        ),
        features: RuntimeProviderFeature.knownValues.map {
            RuntimeProviderFeatureStatus(
                feature: $0,
                state: .available,
                reason: .implemented
            )
        }
    )
}

private func runtimeProviderMigrationCLIDigest(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
}
