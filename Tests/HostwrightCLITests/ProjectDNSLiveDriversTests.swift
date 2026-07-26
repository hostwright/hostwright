import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import HostwrightTestSupport
import XCTest
@testable import HostwrightCLI

final class ProjectDNSLiveDriversTests: XCTestCase {
    func testRuntimeDriverMapsCapabilityAndExactLocalCoreDNSEvidence()
        async throws
    {
        let adapter = try ScriptedProjectDNSRuntimeAdapter(
            inventory: makeInventory()
        )
        let driver = LiveProjectDNSRuntimeDriver(adapter: adapter)

        let capabilitySHA256 =
            try await driver.currentCapabilitySHA256()
        XCTAssertEqual(
            capabilitySHA256,
            ScriptedRuntimeAdapter.testCapabilitySnapshot
                .canonicalSHA256
        )
        let evidence = try await driver.coreDNSImageEvidence()

        XCTAssertEqual(
            evidence,
            CoreDNSInfrastructureImageEvidence(
                resolvedReference:
                    CoreDNSInfrastructureImage
                        .immutableLinuxARM64Reference,
                descriptorDigest:
                    "sha256:\(String(repeating: "a", count: 64))",
                variantDigest:
                    CoreDNSInfrastructureImage.linuxARM64Digest,
                operatingSystem: "linux",
                architecture: "arm64",
                localImageAvailable: true,
                phase05PolicyAccepted: true,
                evidenceSHA256:
                    "cbff10f0f5032afca854dcd5ae5444bf91c74fe3952afd58ef0145910b025031"
            )
        )
        XCTAssertNoThrow(
            try CoreDNSInfrastructureImage.validate(evidence)
        )
        let audit = await adapter.audit()
        XCTAssertEqual(audit.capabilityRequests, 1)
        XCTAssertEqual(
            audit.imageEvidenceRequests,
            [
                CoreDNSInfrastructureImage
                    .immutableLinuxARM64Reference,
            ]
        )
    }

    func testRuntimeDriverMapsCreateStartStopAndExactOwnedRemoveActions()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext()
        let expectedOwnership = makeOwnership(context)
        let resourceIdentifier = identity.managedResourceIdentifier
        let service = DesiredRuntimeService(
            identity: identity,
            image:
                CoreDNSInfrastructureImage
                    .immutableLinuxARM64Reference,
            command: ["-conf", "/etc/coredns/Corefile"]
        )
        let adapter = try ScriptedProjectDNSRuntimeAdapter(
            inventory: makeInventory(
                identity: identity,
                context: context
            )
        )
        let driver = LiveProjectDNSRuntimeDriver(adapter: adapter)

        try await driver.mutate(
            .create(
                service: service,
                resourceIdentifier: resourceIdentifier,
                context: context,
                planSHA256: "create-plan"
            )
        )
        try await driver.mutate(
            .start(
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                context: context,
                planSHA256: "start-plan"
            )
        )
        try await driver.mutate(
            .stop(
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                expectedOwnership: expectedOwnership,
                context: context,
                planSHA256: "stop-plan"
            )
        )
        try await driver.mutate(
            .remove(
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                expectedOwnership: expectedOwnership,
                context: context,
                planSHA256: "remove-plan"
            )
        )

        let audit = await adapter.audit()
        XCTAssertEqual(
            audit.actions,
            [
                PlannedRuntimeAction(
                    kind: .create,
                    identity: identity,
                    resourceIdentifier: resourceIdentifier,
                    isDestructive: false,
                    summary:
                        "Create the UUID-owned project DNS service.",
                    desiredService: service
                ),
                PlannedRuntimeAction(
                    kind: .start,
                    identity: identity,
                    resourceIdentifier: resourceIdentifier,
                    isDestructive: false,
                    summary:
                        "Start the UUID-owned project DNS service."
                ),
                PlannedRuntimeAction(
                    kind: .stop,
                    identity: identity,
                    resourceIdentifier: resourceIdentifier,
                    isDestructive: true,
                    summary:
                        "Stop the exact UUID-owned project DNS service before removal."
                ),
                PlannedRuntimeAction(
                    kind: .remove,
                    identity: identity,
                    resourceIdentifier: resourceIdentifier,
                    isDestructive: true,
                    summary:
                        "Remove the exact UUID-owned project DNS service."
                ),
            ]
        )
        XCTAssertEqual(
            audit.confirmations,
            [
                "create-plan",
                "start-plan",
                "stop-plan",
                "remove-plan",
            ].map {
                RuntimeMutationConfirmation(
                    confirmed: true,
                    reason:
                        "Confirmed project DNS lifecycle plan",
                    planHash: $0,
                    context: context
                )
            }
        )
        XCTAssertEqual(audit.inventoryRequests, 2)
    }

    func testRuntimeDriverRefusesRemoveAfterOwnershipDrift()
        async throws
    {
        let identity = makeIdentity()
        let expectedContext = makeContext()
        let driftedContext = makeContext(
            fencingToken:
                "44444444-4444-4444-8444-444444444444"
        )
        let adapter = try ScriptedProjectDNSRuntimeAdapter(
            inventory: makeInventory(
                identity: identity,
                context: driftedContext
            )
        )
        let driver = LiveProjectDNSRuntimeDriver(adapter: adapter)

        do {
            try await driver.mutate(
                .remove(
                    identity: identity,
                    resourceIdentifier:
                        identity.managedResourceIdentifier,
                    expectedOwnership:
                        makeOwnership(expectedContext),
                    context: expectedContext,
                    planSHA256: "remove-plan"
                )
            )
            XCTFail("Expected ownership drift to refuse removal.")
        } catch {
            let diagnostic = try XCTUnwrap(
                error as? HostwrightDiagnostic
            )
            XCTAssertEqual(diagnostic.code, .runtimeUnavailable)
            XCTAssertEqual(
                diagnostic.message,
                "Project DNS removal refused because exact runtime ownership changed."
            )
        }

        let audit = await adapter.audit()
        XCTAssertEqual(audit.inventoryRequests, 1)
        XCTAssertEqual(audit.actions, [])
        XCTAssertEqual(audit.confirmations, [])
    }

    private func makeIdentity() -> RuntimeServiceIdentity {
        RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "hostwright-dns"
        )
    }

    private func makeContext(
        fencingToken: String =
            "33333333-3333-4333-8333-333333333333"
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256:
                ScriptedRuntimeAdapter.testCapabilitySnapshot
                    .canonicalSHA256,
            operationID: "project-dns-live-driver-test",
            resourceUUID:
                "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 2,
            projectResourceUUID:
                "22222222-2222-4222-8222-222222222222",
            projectGeneration: 3,
            providerGeneration: 4,
            fencingToken: fencingToken
        )
    }

    private func makeOwnership(
        _ context: RuntimeMutationContext
    ) -> RuntimeInventoryOwnershipEvidence {
        RuntimeInventoryOwnershipEvidence(
            resourceUUID: context.resourceUUID,
            projectUUID: context.projectResourceUUID,
            resourceGeneration: context.resourceGeneration,
            projectGeneration: context.projectGeneration,
            providerID: context.providerID,
            providerGeneration: context.providerGeneration,
            fencingToken: context.fencingToken
        )
    }

    private func makeInventory(
        identity: RuntimeServiceIdentity? = nil,
        context: RuntimeMutationContext? = nil
    ) throws -> RuntimeInventory {
        let containers: [RuntimeInventoryContainer]
        if let identity, let context {
            let resourceIdentifier =
                identity.managedResourceIdentifier
            let labels = try RuntimeManagedResourceIdentity.labels(
                for: identity,
                resourceIdentifier: resourceIdentifier,
                context: context
            )
            containers = [
                RuntimeInventoryContainer(
                    runtimeID: resourceIdentifier,
                    name: resourceIdentifier,
                    imageReference:
                        CoreDNSInfrastructureImage
                            .immutableLinuxARM64Reference,
                    lifecycle: .running,
                    health: RuntimeInventoryHealth(
                        availability: .notConfigured
                    ),
                    labels: labels.map {
                        RuntimeInventoryLabel(
                            key: $0.key,
                            value: $0.value
                        )
                    },
                    ownership: makeOwnership(context),
                    initConfiguration:
                        RuntimeInventoryInitConfiguration(
                            executable: "coredns",
                            arguments: [
                                "-conf",
                                "/etc/coredns/Corefile",
                            ],
                            environment: []
                        ),
                    ports: [],
                    mounts: [],
                    networks: [],
                    services: []
                ),
            ]
        } else {
            containers = []
        }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: []
            ),
            containers: containers,
            images: [],
            networks: [],
            volumes: []
        )
    }
}

private struct ProjectDNSRuntimeAdapterAudit: Sendable {
    let capabilityRequests: Int
    let inventoryRequests: Int
    let imageEvidenceRequests: [String]
    let actions: [PlannedRuntimeAction]
    let confirmations: [RuntimeMutationConfirmation]
}

private actor ScriptedProjectDNSRuntimeAdapter: RuntimeAdapter {
    private let scriptedInventory: RuntimeInventory
    private var capabilityRequests = 0
    private var inventoryRequests = 0
    private var imageEvidenceRequests: [String] = []
    private var actions: [PlannedRuntimeAction] = []
    private var confirmations: [RuntimeMutationConfirmation] = []

    init(inventory: RuntimeInventory) {
        scriptedInventory = inventory
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "ScriptedProjectDNSRuntimeAdapter",
            adapterVersion: "test",
            runtimeName: "scripted-test-runtime",
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
        [
            .readOnlyObservation,
            .lifecycleMutation,
            .cleanup,
        ]
    }

    func capabilitySnapshot()
        async throws -> RuntimeCapabilitySnapshot
    {
        capabilityRequests += 1
        return ScriptedRuntimeAdapter.testCapabilitySnapshot
    }

    func inventory() async throws -> RuntimeInventory {
        inventoryRequests += 1
        return scriptedInventory
    }

    func localImageEvidence(
        for imageReference: String
    ) async throws -> RuntimeLocalImageEvidence {
        imageEvidenceRequests.append(imageReference)
        return RuntimeLocalImageEvidence(
            reference:
                CoreDNSInfrastructureImage
                    .immutableLinuxARM64Reference,
            descriptorDigest:
                "sha256:\(String(repeating: "a", count: 64))",
            variantDigest:
                CoreDNSInfrastructureImage.linuxARM64Digest,
            architecture: "arm64",
            operatingSystem: "linux"
        )
    }

    func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: [],
            adapterMetadata: await metadata(),
            capabilitySHA256:
                ScriptedRuntimeAdapter.testCapabilitySnapshot
                    .canonicalSHA256
        )
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(
            actions: [],
            capabilitySHA256:
                ScriptedRuntimeAdapter.testCapabilitySnapshot
                    .canonicalSHA256
        )
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        actions.append(action)
        if let confirmation {
            confirmations.append(confirmation)
        }
        return RuntimeEvent(
            identity: action.identity,
            message: "Scripted project DNS mutation completed.",
            resourceIdentifier: action.resourceIdentifier
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

    func audit() -> ProjectDNSRuntimeAdapterAudit {
        ProjectDNSRuntimeAdapterAudit(
            capabilityRequests: capabilityRequests,
            inventoryRequests: inventoryRequests,
            imageEvidenceRequests: imageEvidenceRequests,
            actions: actions,
            confirmations: confirmations
        )
    }
}
