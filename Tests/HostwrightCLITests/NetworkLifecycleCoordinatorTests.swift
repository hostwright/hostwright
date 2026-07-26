import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class NetworkLifecycleCoordinatorTests: XCTestCase {
    func testCreatePersistsIntentBeforeMutationAndCommitsExactObservation()
        async throws
    {
        let fixture = try makeFixture(networkNames: ["backend"])
        defer { fixture.cleanup() }

        let result = try await NetworkLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: digest("d"),
            store: fixture.store,
            environment: fixture.environment
        )

        let desired = try XCTUnwrap(
            fixture.preparation.desiredState.networks.first
        )
        XCTAssertEqual(
            result.newlyCreatedNetworkUUIDs,
            [desired.identity.resourceUUID]
        )
        let audit = await fixture.runtime.audit()
        XCTAssertEqual(audit.operations, [.create("backend")])
        XCTAssertEqual(audit.createIntentChecks, [true])
        let persisted = try XCTUnwrap(
            try fixture.store.networks.loadNetwork(
                id: desired.identity.resourceUUID
            )
        )
        XCTAssertEqual(persisted.lifecycleState, .available)
        XCTAssertEqual(persisted.finalizerState, .active)
        XCTAssertNotNil(persisted.observedSHA256)
        XCTAssertEqual(
            try fixture.store.operationGroups.loadAll().map(\.status),
            [.succeeded]
        )

        let repeated = try await NetworkLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: digest("d"),
            store: fixture.store,
            environment: fixture.environment
        )
        XCTAssertEqual(repeated.newlyCreatedNetworkUUIDs, [])
        let repeatedAudit = await fixture.runtime.audit()
        XCTAssertEqual(
            repeatedAudit.operations,
            [.create("backend")]
        )
    }

    func testStaleCapabilityRefusesBeforeIntentOrProviderMutation()
        async throws
    {
        let fixture = try makeFixture(networkNames: ["backend"])
        defer { fixture.cleanup() }
        await fixture.runtime.setCapability(
            capabilitySnapshot(build: "stale")
        )

        do {
            _ = try await NetworkLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: digest("d"),
                store: fixture.store,
                environment: fixture.environment
            )
            XCTFail("Expected stale capability refusal.")
        } catch {
            XCTAssertEqual(
                (error as? HostwrightDiagnostic)?.code,
                .runtimeUnavailable
            )
        }

        let audit = await fixture.runtime.audit()
        XCTAssertEqual(audit.operations, [])
        XCTAssertEqual(try fixture.store.networks.listNetworks(), [])
        XCTAssertEqual(
            try fixture.store.operationGroups.loadAll(),
            []
        )
    }

    func testUnmanagedCollisionNeverMutatesProviderAndQuarantinesIntent()
        async throws
    {
        let fixture = try makeFixture(networkNames: ["backend"])
        defer { fixture.cleanup() }
        let desired = try XCTUnwrap(
            fixture.preparation.desiredState.networks.first
        )
        await fixture.runtime.seedUnmanagedCollision(
            identity: desired.identity
        )

        do {
            _ = try await NetworkLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: digest("d"),
                store: fixture.store,
                environment: fixture.environment
            )
            XCTFail("Expected unmanaged collision refusal.")
        } catch {
            XCTAssertEqual(
                (error as? HostwrightDiagnostic)?.code,
                .runtimeUnavailable
            )
        }

        let audit = await fixture.runtime.audit()
        XCTAssertEqual(audit.operations, [])
        let record = try XCTUnwrap(
            try fixture.store.networks.loadNetwork(
                id: desired.identity.resourceUUID
            )
        )
        XCTAssertEqual(record.lifecycleState, .faulted)
        XCTAssertEqual(record.finalizerState, .quarantined)
        let group = try XCTUnwrap(
            try fixture.store.operationGroups.loadAll().first
        )
        XCTAssertEqual(group.status, .failed)
        XCTAssertEqual(group.checkpoint, "ownership-quarantined")
    }

    func testProviderErrorWithObservedAbsenceLeavesResumableIntent()
        async throws
    {
        let fixture = try makeFixture(
            networkNames: ["backend"],
            createBehavior: .failAbsent
        )
        defer { fixture.cleanup() }
        let desired = try XCTUnwrap(
            fixture.preparation.desiredState.networks.first
        )

        do {
            _ = try await NetworkLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: digest("d"),
                store: fixture.store,
                environment: fixture.environment
            )
            XCTFail("Expected provider failure.")
        } catch {
            XCTAssertTrue(error is NetworkCoordinatorTestError)
        }

        let audit = await fixture.runtime.audit()
        XCTAssertEqual(audit.operations, [.create("backend")])
        XCTAssertEqual(audit.createIntentChecks, [true])
        let record = try XCTUnwrap(
            try fixture.store.networks.loadNetwork(
                id: desired.identity.resourceUUID
            )
        )
        XCTAssertEqual(record.lifecycleState, .creating)
        XCTAssertEqual(record.finalizerState, .pending)
        let group = try XCTUnwrap(
            try fixture.store.operationGroups.loadAll().first
        )
        XCTAssertEqual(group.status, .interrupted)
        XCTAssertEqual(group.checkpoint, "effect-not-observed")
    }

    func testAmbiguousConflictingObservationQuarantinesExactRecord()
        async throws
    {
        let fixture = try makeFixture(
            networkNames: ["backend"],
            createBehavior: .failConflicting
        )
        defer { fixture.cleanup() }
        let desired = try XCTUnwrap(
            fixture.preparation.desiredState.networks.first
        )

        do {
            _ = try await NetworkLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: digest("d"),
                store: fixture.store,
                environment: fixture.environment
            )
            XCTFail("Expected ambiguous ownership refusal.")
        } catch {
            XCTAssertEqual(
                (error as? HostwrightDiagnostic)?.code,
                .runtimeUnavailable
            )
        }

        let record = try XCTUnwrap(
            try fixture.store.networks.loadNetwork(
                id: desired.identity.resourceUUID
            )
        )
        XCTAssertEqual(record.lifecycleState, .faulted)
        XCTAssertEqual(record.finalizerState, .quarantined)
        XCTAssertNotNil(record.observedSHA256)
        let group = try XCTUnwrap(
            try fixture.store.operationGroups.loadAll().first
        )
        XCTAssertEqual(group.status, .failed)
        XCTAssertEqual(group.checkpoint, "ownership-quarantined")
    }

    func testDeleteUsesReverseExactOrderAndRemovesOwnedState()
        async throws
    {
        let fixture = try makeFixture(
            networkNames: ["backend", "frontend"]
        )
        defer { fixture.cleanup() }
        _ = try await NetworkLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: digest("d"),
            store: fixture.store,
            environment: fixture.environment
        )
        await fixture.runtime.clearAudit()

        try await NetworkLifecycleCoordinator.removeNetworks(
            networkUUIDs: nil,
            preparation: fixture.preparation,
            planSHA256: digest("e"),
            store: fixture.store,
            environment: fixture.environment
        )

        let audit = await fixture.runtime.audit()
        XCTAssertEqual(
            audit.operations,
            [.delete("frontend"), .delete("backend")]
        )
        XCTAssertEqual(audit.deleteIntentChecks, [true, true])
        XCTAssertEqual(try fixture.store.networks.listNetworks(), [])
        XCTAssertEqual(
            try fixture.store.networks.listAttachments(),
            []
        )
        let networkNames = await fixture.runtime.networkNames()
        XCTAssertEqual(networkNames, [])
    }
}

private enum NetworkCoordinatorTestError: Error {
    case injectedCreateFailure
}

private enum NetworkCoordinatorCreateBehavior: Sendable {
    case succeed
    case failAbsent
    case failConflicting
}

private enum NetworkCoordinatorOperation: Equatable, Sendable {
    case create(String)
    case delete(String)
}

private struct NetworkCoordinatorAudit: Equatable, Sendable {
    let operations: [NetworkCoordinatorOperation]
    let createIntentChecks: [Bool]
    let deleteIntentChecks: [Bool]
}

private actor NetworkCoordinatorRuntime:
    RuntimeAdapter,
    RuntimeNetworkProvider
{
    private let store: SQLiteStateStore
    private var capability: RuntimeCapabilitySnapshot
    private let createBehavior: NetworkCoordinatorCreateBehavior
    private var networks: [String: RuntimeInventoryNetwork] = [:]
    private var operations: [NetworkCoordinatorOperation] = []
    private var createIntentChecks: [Bool] = []
    private var deleteIntentChecks: [Bool] = []

    init(
        store: SQLiteStateStore,
        capability: RuntimeCapabilitySnapshot,
        createBehavior: NetworkCoordinatorCreateBehavior
    ) {
        self.store = store
        self.capability = capability
        self.createBehavior = createBehavior
    }

    func setCapability(_ value: RuntimeCapabilitySnapshot) {
        capability = value
    }

    func seedUnmanagedCollision(
        identity: RuntimeNetworkIdentity
    ) {
        networks[identity.runtimeIdentifier] =
            RuntimeInventoryNetwork(
                runtimeID: identity.runtimeIdentifier,
                name: identity.runtimeIdentifier,
                kind: "nat",
                addresses: ["192.168.90.2"],
                labels: [],
                ownership: nil
            )
    }

    func clearAudit() {
        operations = []
        createIntentChecks = []
        deleteIntentChecks = []
    }

    func audit() -> NetworkCoordinatorAudit {
        NetworkCoordinatorAudit(
            operations: operations,
            createIntentChecks: createIntentChecks,
            deleteIntentChecks: deleteIntentChecks
        )
    }

    func networkNames() -> [String] {
        networks.values.map(\.name).sorted()
    }

    func networkCapabilities()
        async throws -> RuntimeNetworkProviderCapabilities
    {
        .appleContainerCLI
    }

    func networkInspect(
        _ request: RuntimeNetworkInspectRequest
    ) async throws -> RuntimeNetworkOperationResult {
        let observed = networks[
            request.identity.runtimeIdentifier
        ]
        return RuntimeNetworkOperationResult(
            providerID: .appleContainerCLI,
            operation: .inspect,
            networkRuntimeIdentifier:
                request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: observed == nil ? .missing : .present,
            verified: true,
            observedNetwork: observed
        )
    }

    func networkCreate(
        _ request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        operations.append(.create(request.identity.logicalName))
        createIntentChecks.append(
            intentPersisted(
                resourceUUID: request.identity.resourceUUID,
                context: context,
                lifecycle: .creating
            )
        )
        switch createBehavior {
        case .succeed:
            let network = try ownedNetwork(
                request: request,
                context: context
            )
            networks[request.identity.runtimeIdentifier] = network
            return operationResult(
                operation: .create,
                request: request,
                state: .present,
                observed: network
            )
        case .failAbsent:
            throw NetworkCoordinatorTestError
                .injectedCreateFailure
        case .failConflicting:
            networks[request.identity.runtimeIdentifier] =
                RuntimeInventoryNetwork(
                    runtimeID: request.identity.runtimeIdentifier,
                    name: request.identity.runtimeIdentifier,
                    kind: request.mode.rawValue,
                    addresses: ["192.168.91.2"],
                    labels: [],
                    ownership: nil
                )
            throw NetworkCoordinatorTestError
                .injectedCreateFailure
        }
    }

    func networkAttach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        throw RuntimeAdapterError.capabilityUnavailable(
            .lifecycleMutation
        )
    }

    func networkDetach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        throw RuntimeAdapterError.capabilityUnavailable(
            .lifecycleMutation
        )
    }

    func networkDelete(
        _ request: RuntimeNetworkDeleteRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        operations.append(.delete(request.identity.logicalName))
        let observedOwnership = networks[
            request.identity.runtimeIdentifier
        ]?.ownership
        deleteIntentChecks.append(
            intentPersisted(
                resourceUUID: request.identity.resourceUUID,
                context: context,
                lifecycle: .deleting
            ) &&
                request.expectedOwnership != nil &&
                request.expectedOwnership == observedOwnership
        )
        networks.removeValue(
            forKey: request.identity.runtimeIdentifier
        )
        return RuntimeNetworkOperationResult(
            providerID: .appleContainerCLI,
            operation: .delete,
            networkRuntimeIdentifier:
                request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: .missing,
            verified: true
        )
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "NetworkCoordinatorRuntime",
            adapterVersion: "1",
            runtimeName: "container",
            runtimeVersion: "1.1.0",
            supportsMutation: true,
            capabilities: [
                .readOnlyObservation,
                .lifecycleMutation,
                .cleanup,
            ]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation, .cleanup]
    }

    func capabilitySnapshot()
        async throws -> RuntimeCapabilitySnapshot
    {
        capability
    }

    func inventory() async throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: []
            ),
            containers: [],
            images: [],
            networks: Array(networks.values),
            volumes: []
        )
    }

    func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: [],
            adapterMetadata: await metadata(),
            capabilitySHA256: capability.canonicalSHA256
        )
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(
            actions: [],
            capabilitySHA256: capability.canonicalSHA256
        )
    }

    func logs(
        for service: ObservedRuntimeService,
        tail: Int
    ) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(
            .logStreaming
        )
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Network coordinator tests do not execute workload actions."
        )
    }

    private func intentPersisted(
        resourceUUID: String,
        context: RuntimeMutationContext,
        lifecycle: NetworkStateResourceLifecycle
    ) -> Bool {
        guard let record = try? store.networks.loadNetwork(
            id: resourceUUID
        ),
        record.lifecycleState == lifecycle,
        record.fencingToken == context.fencingToken,
        let group = try? store.operationGroups.load(
            id: record.operationGroupID
        ),
        group.status == .active,
        group.checkpoint == "intent-persisted",
        group.intentJSONRedacted.contains(
            context.capabilitySHA256
        ) else {
            return false
        }
        return true
    }

    private func ownedNetwork(
        request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext
    ) throws -> RuntimeInventoryNetwork {
        let labels = try RuntimeNetworkOwnership.labels(
            for: request.identity,
            context: context,
            userLabels: request.labels
        )
        return RuntimeInventoryNetwork(
            runtimeID: request.identity.runtimeIdentifier,
            name: request.identity.runtimeIdentifier,
            kind: request.mode.rawValue,
            addresses: [
                "192.168.88.2",
                "fd00::2",
            ],
            labels: labels.map {
                RuntimeInventoryLabel(key: $0.key, value: $0.value)
            },
            ownership: RuntimeInventoryOwnershipEvidence(
                resourceUUID: context.resourceUUID,
                projectUUID: context.projectResourceUUID,
                resourceGeneration: context.resourceGeneration,
                projectGeneration: context.projectGeneration,
                providerID: context.providerID,
                providerGeneration: context.providerGeneration,
                fencingToken: context.fencingToken
            )
        )
    }

    private func operationResult(
        operation: RuntimeNetworkProviderOperation,
        request: RuntimeNetworkCreateRequest,
        state: RuntimeNetworkResultState,
        observed: RuntimeInventoryNetwork?
    ) -> RuntimeNetworkOperationResult {
        RuntimeNetworkOperationResult(
            providerID: .appleContainerCLI,
            operation: operation,
            networkRuntimeIdentifier:
                request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: state,
            verified: true,
            observedNetwork: observed
        )
    }
}

private struct NetworkCoordinatorFixture {
    let root: URL
    let store: SQLiteStateStore
    let runtime: NetworkCoordinatorRuntime
    let preparation: LifecycleCommandPreparation
    let environment: CLIEnvironment

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeFixture(
    networkNames: [String],
    createBehavior: NetworkCoordinatorCreateBehavior = .succeed
) throws -> NetworkCoordinatorFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "hostwright-network-coordinator-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let store = SQLiteStateStore(
        path: root.appendingPathComponent("state.sqlite").path
    )
    try store.migrate()
    let projectID = "project-network-coordinator"
    try seedProject(
        store,
        projectID: projectID
    )
    let projectUUID = try store.desiredStates
        .loadProject(id: projectID)
        .resourceUUID
    let capability = capabilitySnapshot(build: "current")
    let networks = try networkNames.map {
        DesiredRuntimeNetwork(
            identity: try RuntimeNetworkIdentity(
                logicalName: $0,
                projectUUID: projectUUID
            ),
            mode: .nat,
            ipv4: .automatic,
            ipv6: .automatic
        )
    }
    let preparation = LifecycleCommandPreparation(
        manifestSHA256: digest("a"),
        manifestBaseDirectory: root.path,
        desiredState: DesiredRuntimeState(
            projectName: "network-coordinator",
            networks: networks,
            services: []
        ),
        observedState: ObservedRuntimeState(
            projectName: "network-coordinator",
            services: []
        ),
        observationSHA256: digest("b"),
        projectID: projectID,
        projectResourceUUID: projectUUID,
        projectGeneration: 1,
        providerID: .appleContainerCLI,
        providerGeneration: 1,
        capabilitySHA256: capability.canonicalSHA256,
        planFencingToken: HostwrightResourceUUID.legacy(
            kind: "network-test-plan-fence",
            identifier: projectID
        )
    )
    let runtime = NetworkCoordinatorRuntime(
        store: store,
        capability: capability,
        createBehavior: createBehavior
    )
    let environment = CLIEnvironment(
        fileExists: {
            FileManager.default.fileExists(atPath: $0)
        },
        readTextFile: {
            try String(contentsOfFile: $0, encoding: .utf8)
        },
        writeTextFile: { path, value in
            try value.write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
        },
        executablePath: { _ in nil },
        runtimeAdapter: { runtime },
        runtimeAdapterForProvider: { providerID in
            guard providerID == .appleContainerCLI else {
                throw RuntimeProviderSelectionError
                    .providerUnavailable(providerID)
            }
            return runtime
        },
        networkProviderForProvider: { providerID in
            guard providerID == .appleContainerCLI else {
                throw RuntimeProviderSelectionError
                    .providerUnavailable(providerID)
            }
            return runtime
        },
        swiftVersion: { "Swift test" },
        platformSnapshot: {
            PlatformSnapshot(
                macOSMajorVersion: 26,
                architecture: "arm64"
            )
        },
        operatingSystemDescription: { "macOS test" }
    )
    return NetworkCoordinatorFixture(
        root: root,
        store: store,
        runtime: runtime,
        preparation: preparation,
        environment: environment
    )
}

private func seedProject(
    _ store: SQLiteStateStore,
    projectID: String
) throws {
    try store.desiredStates.saveManifestSnapshot(
        projectID: projectID,
        manifestPath: "hostwright.yaml",
        manifestHash: digest("a"),
        desiredGeneration: 1,
        manifest: HostwrightManifest(
            version: 2,
            project: "network-coordinator",
            services: []
        ),
        timestamp: "2026-07-26T12:00:00Z",
        mutationProvider:
            RuntimeProviderID.appleContainerCLI.rawValue
    )
}

private func capabilitySnapshot(
    build: String
) -> RuntimeCapabilitySnapshot {
    RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: .appleContainerCLI,
            components: [
                RuntimeProviderComponent(
                    identifier: .appleContainerCLI,
                    version: "1.1.0",
                    build: build,
                    fingerprint: "network-coordinator"
                ),
            ],
            minimumMacOSVersion:
                RuntimeProviderCapabilityContract
                    .minimumMacOSVersion,
            supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: RuntimeProviderMacOSVersion(
                major: 26,
                minor: 0,
                patch: 0
            ),
            macOSBuild: build,
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

private func digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
