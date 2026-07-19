import XCTest
@testable import HostwrightRuntime

final class Gate03MigrationEvidenceTests: XCTestCase {
    func testConfirmedMigrationRefusesCapabilityDriftBeforeRuntimeMutation() async throws {
        let fixture = try Gate03MigrationEvidenceFixture()
        let plan = try await fixture.engine.dryRun(
            request: fixture.request,
            source: fixture.source,
            target: fixture.target
        )
        let changedSnapshot = gate03Snapshot(
            providerID: .appleContainerCLI,
            fingerprint: gate03Digest("9")
        )
        await fixture.source.replaceSnapshot(changedSnapshot)

        do {
            _ = try await fixture.execute(plan: plan)
            XCTFail("A confirmed plan must not execute after capability drift.")
        } catch let error as RuntimeProviderMigrationError {
            XCTAssertEqual(
                error,
                .staleCapability(
                    providerID: .appleContainerCLI,
                    expected: plan.sourceCapabilitySHA256,
                    current: changedSnapshot.canonicalSHA256
                )
            )
        }

        let sourceMutationCount = await fixture.source.mutationCount
        let targetMutationCount = await fixture.target.mutationCount
        let recordedCheckpoints = await fixture.journal.recordedCheckpoints
        XCTAssertEqual(sourceMutationCount, 0)
        XCTAssertEqual(targetMutationCount, 0)
        XCTAssertEqual(recordedCheckpoints, [])
    }

    func testConfirmedMigrationRefusesObservationDriftBeforeRuntimeMutation() async throws {
        let fixture = try Gate03MigrationEvidenceFixture()
        let plan = try await fixture.engine.dryRun(
            request: fixture.request,
            source: fixture.source,
            target: fixture.target
        )
        try await fixture.source.installUnmanagedSentinel()
        let currentObservationSHA256 = try await fixture.source.inventory().semanticSHA256

        do {
            _ = try await fixture.execute(plan: plan)
            XCTFail("A confirmed plan must not execute after observed state drift.")
        } catch let error as RuntimeProviderMigrationError {
            XCTAssertEqual(
                error,
                .observationChanged(
                    providerID: .appleContainerCLI,
                    expected: plan.sourceObservationSHA256,
                    current: currentObservationSHA256
                )
            )
        }

        let sourceMutationCount = await fixture.source.mutationCount
        let targetMutationCount = await fixture.target.mutationCount
        let recordedCheckpoints = await fixture.journal.recordedCheckpoints
        XCTAssertEqual(sourceMutationCount, 0)
        XCTAssertEqual(targetMutationCount, 0)
        XCTAssertEqual(recordedCheckpoints, [])
    }
}

private struct Gate03MigrationEvidenceFixture {
    let projectUUID = "11111111-1111-4111-8111-111111111111"
    let resourceUUID = "22222222-2222-4222-8222-222222222222"
    let sourceFence = "33333333-3333-4333-8333-333333333333"
    let operationID = "gate-03-stale-confirmation"
    let migrationFence = "44444444-4444-4444-8444-444444444444"
    let request: RuntimeProviderMigrationRequest
    let source: Gate03MigrationEvidenceAdapter
    let target: Gate03MigrationEvidenceAdapter
    let journal: Gate03MigrationEvidenceJournal
    let engine: RuntimeProviderMigrationEngine

    init() throws {
        let desired = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(projectName: "sample", serviceName: "api"),
            image: "example.local/api:1"
        )
        let ownership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            resourceGeneration: 1,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            fencingToken: sourceFence
        )
        let sourceSnapshot = gate03Snapshot(
            providerID: .appleContainerCLI,
            fingerprint: gate03Digest("1")
        )
        let targetSnapshot = gate03Snapshot(
            providerID: .appleContainerization,
            fingerprint: gate03Digest("2")
        )
        let imageEvidence = RuntimeLocalImageEvidence(
            reference: desired.image,
            descriptorDigest: gate03OCIDigest("a"),
            variantDigest: gate03OCIDigest("b"),
            architecture: "arm64",
            operatingSystem: "linux"
        )
        source = try Gate03MigrationEvidenceAdapter(
            providerID: .appleContainerCLI,
            snapshot: sourceSnapshot,
            containers: [
                gate03Container(
                    desired: desired,
                    ownership: ownership,
                    lifecycle: .running,
                    runtimeID: "source-api",
                    capabilitySHA256: sourceSnapshot.canonicalSHA256
                )
            ],
            localImages: [:]
        )
        target = try Gate03MigrationEvidenceAdapter(
            providerID: .appleContainerization,
            snapshot: targetSnapshot,
            containers: [],
            localImages: [desired.image: imageEvidence]
        )
        request = RuntimeProviderMigrationRequest(
            projectName: "sample",
            projectUUID: projectUUID,
            projectGeneration: 1,
            sourceProviderID: .appleContainerCLI,
            sourceProviderGeneration: 1,
            targetProviderID: .appleContainerization,
            resources: [
                RuntimeProviderMigrationResource(
                    desiredService: desired,
                    ownership: ownership
                )
            ]
        )
        journal = Gate03MigrationEvidenceJournal()
        engine = RuntimeProviderMigrationEngine(journal: journal)
    }

    func execute(plan: RuntimeProviderMigrationPlan) async throws -> RuntimeProviderMigrationResult {
        try await engine.execute(
            plan: plan,
            request: request,
            confirmationToken: plan.confirmationToken,
            operationID: operationID,
            fencingToken: migrationFence,
            source: source,
            target: target
        )
    }
}

private actor Gate03MigrationEvidenceAdapter: RuntimeAdapter {
    let providerID: RuntimeProviderID
    private var snapshot: RuntimeCapabilitySnapshot
    private var containers: [RuntimeInventoryContainer]
    private let localImages: [String: RuntimeLocalImageEvidence]
    private(set) var mutationCount = 0

    init(
        providerID: RuntimeProviderID,
        snapshot: RuntimeCapabilitySnapshot,
        containers: [RuntimeInventoryContainer],
        localImages: [String: RuntimeLocalImageEvidence]
    ) throws {
        self.providerID = providerID
        self.snapshot = snapshot
        self.containers = containers
        self.localImages = localImages
        _ = try gate03Inventory(containers: containers, images: Array(localImages.values))
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: providerID,
            adapterName: "Gate03MigrationEvidenceAdapter",
            adapterVersion: "1",
            runtimeName: providerID.rawValue,
            runtimeVersion: "1",
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .cleanup]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation, .cleanup]
    }

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot { snapshot }

    func inventory() async throws -> RuntimeInventory {
        try gate03Inventory(containers: containers, images: Array(localImages.values))
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: [],
            adapterMetadata: await metadata(),
            capabilitySHA256: snapshot.canonicalSHA256
        )
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(actions: [], capabilitySHA256: snapshot.canonicalSHA256)
    }

    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String { "1" }

    func runtimeReadiness() async throws -> RuntimeReadinessReport {
        RuntimeReadinessReport(
            runtimeName: providerID.rawValue,
            cliVersion: "1",
            serviceState: .running,
            serviceVersion: "1",
            serviceBuild: "test"
        )
    }

    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        guard let evidence = localImages[imageReference] else {
            throw RuntimeAdapterError.capabilityUnavailable(.readOnlyObservation)
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
        mutationCount += 1
        return RuntimeEvent(
            identity: action.identity,
            message: action.summary,
            resourceIdentifier: action.resourceIdentifier
        )
    }

    func replaceSnapshot(_ value: RuntimeCapabilitySnapshot) {
        snapshot = value
    }

    func installUnmanagedSentinel() throws {
        containers.append(
            RuntimeInventoryContainer(
                runtimeID: "unmanaged-sentinel",
                name: "unmanaged-sentinel",
                imageReference: "example.local/sentinel:1",
                lifecycle: .running,
                health: RuntimeInventoryHealth(availability: .unavailable),
                labels: [],
                ownership: nil,
                initConfiguration: RuntimeInventoryInitConfiguration(
                    executable: "/bin/true",
                    arguments: [],
                    environment: []
                ),
                ports: [],
                mounts: [],
                networks: [],
                services: []
            )
        )
        _ = try gate03Inventory(containers: containers, images: Array(localImages.values))
    }
}

private actor Gate03MigrationEvidenceJournal: RuntimeProviderMigrationJournaling {
    private var intent: RuntimeProviderMigrationIntent?
    private(set) var recordedCheckpoints: [RuntimeProviderMigrationCheckpoint] = []

    func beginOrResume(
        _ proposed: RuntimeProviderMigrationIntent
    ) async throws -> RuntimeProviderMigrationAcquireResult {
        intent = proposed
        return .acquired(
            RuntimeProviderMigrationLease(
                operationID: proposed.operationID,
                fencingToken: proposed.fencingToken,
                confirmationToken: proposed.confirmationToken,
                checkpoint: .intentPersisted
            )
        )
    }

    func verifyFence(operationID: String, fencingToken: String) async throws -> Bool {
        intent?.operationID == operationID && intent?.fencingToken == fencingToken
    }

    func recordCheckpoint(
        operationID: String,
        fencingToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws {
        guard try await verifyFence(operationID: operationID, fencingToken: fencingToken),
              !verificationSHA256.isEmpty else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        recordedCheckpoints.append(checkpoint)
    }

    func commitProviderBinding(
        _ commit: RuntimeProviderMigrationBindingCommit
    ) async throws -> RuntimeProviderMigrationBindingCommitResult {
        .committed
    }

    func finish(
        operationID: String,
        fencingToken: String,
        status: RuntimeProviderMigrationTerminalStatus,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws {}
}

private func gate03Snapshot(
    providerID: RuntimeProviderID,
    fingerprint: String
) -> RuntimeCapabilitySnapshot {
    let components: [RuntimeProviderComponent]
    switch providerID {
    case .appleContainerCLI:
        components = [
            RuntimeProviderComponent(
                identifier: .appleContainerCLI,
                version: "1.1.0",
                build: "release",
                fingerprint: fingerprint
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerAPIService,
                version: "1.1.0",
                build: "release",
                fingerprint: fingerprint
            )
        ]
    case .appleContainerization:
        components = [
            RuntimeProviderComponent(
                identifier: .appleContainerizationHelper,
                version: "0.0.2",
                build: "test",
                fingerprint: fingerprint
            ),
            RuntimeProviderComponent(
                identifier: .containerizationHelperProtocolV1,
                version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                build: "test",
                fingerprint: gate03Digest("3")
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerizationFramework,
                version: RuntimeProviderCapabilityContract.containerizationFrameworkVersion,
                build: "release",
                fingerprint: gate03Digest("4")
            )
        ]
    default:
        components = []
    }
    return RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: providerID,
            components: components,
            minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
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

private func gate03Inventory(
    containers: [RuntimeInventoryContainer],
    images: [RuntimeLocalImageEvidence]
) throws -> RuntimeInventory {
    try RuntimeInventoryBuilder.build(
        machine: RuntimeInventoryMachine(
            state: .running,
            operatingSystem: "macOS 26.0",
            architecture: "arm64",
            runtimeVersion: "1",
            services: [
                RuntimeInventoryService(
                    identifier: "api-server",
                    state: .running,
                    required: true
                )
            ]
        ),
        containers: containers,
        images: images.map {
            RuntimeInventoryImage(
                runtimeID: $0.descriptorDigest,
                descriptorDigest: $0.descriptorDigest,
                references: [$0.reference],
                variants: [
                    RuntimeInventoryImageVariant(
                        digest: $0.variantDigest,
                        architecture: $0.architecture,
                        operatingSystem: $0.operatingSystem
                    )
                ],
                labels: []
            )
        },
        networks: [],
        volumes: []
    )
}

private func gate03Container(
    desired: DesiredRuntimeService,
    ownership: RuntimeInventoryOwnershipEvidence,
    lifecycle: RuntimeInventoryLifecycleState,
    runtimeID: String,
    capabilitySHA256: String
) throws -> RuntimeInventoryContainer {
    let context = RuntimeMutationContext(
        providerID: ownership.providerID,
        capabilitySHA256: capabilitySHA256,
        operationID: "gate-03-observation",
        resourceUUID: ownership.resourceUUID,
        resourceGeneration: ownership.resourceGeneration,
        projectResourceUUID: ownership.projectUUID,
        projectGeneration: ownership.projectGeneration,
        providerGeneration: ownership.providerGeneration,
        fencingToken: ownership.fencingToken
    )
    return RuntimeInventoryContainer(
        runtimeID: runtimeID,
        name: desired.identity.managedResourceIdentifier,
        imageReference: desired.image,
        lifecycle: lifecycle,
        health: RuntimeInventoryHealth(availability: .unavailable),
        labels: try RuntimeManagedResourceIdentity.labels(for: desired.identity, context: context)
            .map { RuntimeInventoryLabel(key: $0.key, value: $0.value) },
        ownership: ownership,
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

private func gate03Digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func gate03OCIDigest(_ character: Character) -> String {
    "sha256:" + gate03Digest(character)
}
