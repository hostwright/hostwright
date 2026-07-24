import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleProbeLiveIntegrationTests: XCTestCase {
    func testPostStartHookUsesExactContainerAndPersistsCompletion() async throws {
        let interactive = ProbeLiveInteractiveExecutor(outcomes: [.succeeded])
        let fixture = try ProbeLiveFixture(
            action: .runHook,
            desired: probeLiveDesired(
                hooks: RuntimeLifecycleHooks(
                    postStart: ["/usr/bin/post-start", "--ready"]
                )
            ),
            postcondition: LifecyclePlanCondition(
                kind: "hook-completed",
                subject: "phase04/web",
                expectedValue: "postStart"
            ),
            interactive: interactive
        )
        defer { fixture.cleanup() }

        let outcome = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        )
        XCTAssertEqual(outcome, .accepted)
        let observation = await fixture.effects.observe(
            node: fixture.node,
            context: fixture.context
        )
        guard case .satisfied = observation else {
            return XCTFail(
                "Expected exact post-hook observation to succeed, got \(observation)."
            )
        }

        let calls = interactive.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.resourceIdentifier, fixture.binding.resourceIdentifier)
        XCTAssertEqual(calls.first?.arguments, ["/usr/bin/post-start", "--ready"])
        XCTAssertEqual(calls.first?.workingDirectory, "/work")
        let hookSteps = try fixture.store.operationGroupSteps
            .load(groupID: fixture.context.groupID)
            .filter { $0.plannedActionType == "hook-checkpoint" }
        XCTAssertEqual(hookSteps.map(\.status), [.started, .succeeded])
        XCTAssertEqual(
            try fixture.exactOwnership().fencingToken,
            fixture.binding.currentFencingToken
        )
    }

    func testHookFailureAfterExecutionBeginsPreservesSafeHoldFence() async throws {
        let interactive = ProbeLiveInteractiveExecutor(outcomes: [.timedOut])
        let fixture = try ProbeLiveFixture(
            action: .runHook,
            desired: probeLiveDesired(
                hooks: RuntimeLifecycleHooks(
                    preStop: ["/usr/bin/pre-stop"]
                )
            ),
            postcondition: LifecyclePlanCondition(
                kind: "hook-completed",
                subject: "phase04/web",
                expectedValue: "preStop"
            ),
            interactive: interactive
        )
        defer { fixture.cleanup() }

        guard case .failed(let failure) =
            await fixture.effects.apply(
                node: fixture.node,
                context: fixture.context
            ) else {
            return XCTFail("Expected failed hook execution.")
        }
        XCTAssertEqual(failure.category, .ambiguousEffect)
        guard case .ambiguous =
            await fixture.effects.observe(
                node: fixture.node,
                context: fixture.context
            ) else {
            return XCTFail("Expected hook failure to preserve a safe hold.")
        }

        let hookSteps = try fixture.store.operationGroupSteps
            .load(groupID: fixture.context.groupID)
            .filter { $0.plannedActionType == "hook-checkpoint" }
        XCTAssertEqual(hookSteps.map(\.status), [.started, .failed])
        XCTAssertTrue(hookSteps.last?.metadataJSONRedacted.contains(
            #""effectPossible":true"#
        ) == true)
        XCTAssertEqual(
            try fixture.exactOwnership().fencingToken,
            fixture.context.fencingToken
        )
    }

    func testReadinessResumesInFlightCheckpointAndPersistsEveryAttempt() async throws {
        let interactive = ProbeLiveInteractiveExecutor(
            outcomes: [.succeeded, .succeeded]
        )
        let desired = probeLiveDesired(
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                    ),
                    intervalSeconds: 1,
                    timeoutSeconds: 2,
                    successThreshold: 2,
                    failureThreshold: 2
                )
            )
        )
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: desired,
            postcondition: LifecyclePlanCondition(
                kind: "probe-readiness",
                subject: "phase04/web",
                expectedValue: "healthy"
            ),
            interactive: interactive
        )
        defer { fixture.cleanup() }

        try fixture.probeStore.save(
            RuntimeProbeSnapshot(
                resourceIdentifier: fixture.binding.resourceIdentifier,
                startedAtMilliseconds: fixture.clock.now(),
                states: [
                    RuntimeProbeState(
                        kind: .readiness,
                        phase: .executing,
                        attemptCount: 1,
                        inFlightAttempt: 1,
                        nextAttemptAtMilliseconds: fixture.clock.now(),
                        lastAttemptAtMilliseconds: fixture.clock.now()
                    )
                ]
            ),
            groupID: fixture.context.groupID,
            fencingToken: fixture.context.fencingToken,
            serviceName: "web",
            updatedAt: "2026-07-23T12:00:00Z"
        )

        let outcome = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        )
        XCTAssertEqual(outcome, .accepted)
        let observation = await fixture.effects.observe(
            node: fixture.node,
            context: fixture.context
        )
        guard case .satisfied = observation else {
            return XCTFail(
                "Expected resumed readiness verification to pass, got \(observation)."
            )
        }

        XCTAssertEqual(interactive.snapshot().count, 2)
        let persisted = try XCTUnwrap(
            fixture.probeStore.loadLatest(
                groupID: fixture.context.groupID,
                resourceIdentifier: fixture.binding.resourceIdentifier
            )
        )
        XCTAssertEqual(persisted.state(for: .readiness)?.phase, .succeeded)
        XCTAssertEqual(persisted.state(for: .readiness)?.attemptCount, 3)
        XCTAssertEqual(
            persisted.state(for: .readiness)?.consecutiveSuccesses,
            2
        )
        let checkpointCount = try fixture.store.operationGroupSteps
            .load(groupID: fixture.context.groupID)
            .filter { $0.plannedActionType == "probe-checkpoint" }
            .count
        XCTAssertGreaterThanOrEqual(checkpointCount, 6)
    }

    func testUnavailableProviderFailsBeforeContainerExecution() async throws {
        let interactive = ProbeLiveInteractiveExecutor(outcomes: [.succeeded])
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: probeLiveDesired(
                probes: RuntimeProbeSet(
                    readiness: RuntimeProbeConfiguration(
                        action: .exec(
                            RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                        )
                    )
                )
            ),
            postcondition: LifecyclePlanCondition(
                kind: "probe-readiness",
                subject: "phase04/web",
                expectedValue: "healthy"
            ),
            providerID: .appleContainerization,
            interactive: interactive
        )
        defer { fixture.cleanup() }

        guard case .failed(let failure) =
            await fixture.effects.apply(
                node: fixture.node,
                context: fixture.context
            ) else {
            return XCTFail("Expected unqualified provider probe to fail.")
        }
        XCTAssertEqual(failure.category, .incompatible)
        XCTAssertEqual(interactive.snapshot().count, 0)
        let observation = await fixture.effects.observe(
            node: fixture.node,
            context: fixture.context
        )
        guard case .noEffect = observation else {
            return XCTFail(
                "Unavailable probe must remain mutation-free, got \(observation)."
            )
        }
    }

    func testPersistedNodeDeadlineStopsProbeBeforeContainerExecution() async throws {
        let interactive = ProbeLiveInteractiveExecutor(outcomes: [.succeeded])
        let clock = ProbeLiveClock(milliseconds: 10_000)
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: probeLiveDesired(
                probes: RuntimeProbeSet(
                    startup: RuntimeProbeConfiguration(
                        action: .exec(
                            RuntimeProbeExecAction(command: ["/usr/bin/startup"])
                        )
                    )
                )
            ),
            postcondition: LifecyclePlanCondition(
                kind: "probe-startup",
                subject: "phase04/web",
                expectedValue: "healthy"
            ),
            timeoutSeconds: 5,
            interactive: interactive,
            clock: clock
        )
        defer { fixture.cleanup() }
        try fixture.appendStartedSagaStep(
            startedAt: "1970-01-01T00:00:01Z"
        )

        guard case .failed(let failure) =
            await fixture.effects.apply(
                node: fixture.node,
                context: fixture.context
            ) else {
            return XCTFail("Expected persisted deadline to stop execution.")
        }
        XCTAssertEqual(failure.category, .timedOut)
        XCTAssertEqual(interactive.snapshot().count, 0)
    }

    func testReadinessFailureDoesNotPreventBoundedLivenessRestartAndRecovery() async throws {
        let interactive = ProbeLiveInteractiveExecutor(
            outcomes: [.failed, .succeeded]
        )
        let desired = probeLiveDesired(
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                    ),
                    intervalSeconds: 1,
                    timeoutSeconds: 2,
                    successThreshold: 1,
                    failureThreshold: 1
                ),
                liveness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/alive"])
                    ),
                    intervalSeconds: 1,
                    timeoutSeconds: 2,
                    successThreshold: 1,
                    failureThreshold: 1
                )
            ),
            restartPolicy: .onFailure
        )
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: desired,
            postcondition: LifecyclePlanCondition(
                kind: "probe-liveness",
                subject: "phase04/web",
                expectedValue: "healthy"
            ),
            interactive: interactive
        )
        defer { fixture.cleanup() }

        try fixture.probeStore.save(
            RuntimeProbeSnapshot(
                resourceIdentifier: fixture.binding.resourceIdentifier,
                startedAtMilliseconds: fixture.clock.now(),
                states: [
                    RuntimeProbeState(
                        kind: .readiness,
                        phase: .failed,
                        consecutiveFailures: 1,
                        attemptCount: 1,
                        nextAttemptAtMilliseconds: fixture.clock.now(),
                        lastAttemptAtMilliseconds: fixture.clock.now(),
                        lastOutcome: .failed,
                        lastDiagnosticRedacted: "not ready"
                    ),
                    RuntimeProbeState(
                        kind: .liveness,
                        phase: .waiting,
                        nextAttemptAtMilliseconds: fixture.clock.now()
                    )
                ]
            ),
            groupID: fixture.context.groupID,
            fencingToken: fixture.context.fencingToken,
            serviceName: "web",
            updatedAt: "2026-07-23T12:00:00Z"
        )

        let outcome = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        )
        XCTAssertEqual(outcome, .accepted)
        let actions = await fixture.adapter.executedActions()
        XCTAssertEqual(actions.map(\.kind), [.restart])
        XCTAssertEqual(actions.map(\.isDestructive), [true])
        let calls = interactive.snapshot()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(
            calls.map(\.arguments),
            [
                ["/usr/bin/alive"],
                ["/usr/bin/alive"]
            ]
        )
        let restartState = try XCTUnwrap(
            fixture.store.restartPolicies.load(
                projectID: fixture.context.plan.projectID,
                serviceName: desired.identity.serviceName
            )
        )
        XCTAssertEqual(restartState.status, .active)
        XCTAssertEqual(restartState.attemptCount, 0)
        guard case .satisfied =
            await fixture.effects.observe(
                node: fixture.node,
                context: fixture.context
            ) else {
            return XCTFail("Expected liveness to verify after bounded restart.")
        }
    }

    func testOrdinaryRestartIsExplicitlyDestructive() async throws {
        let fixture = try ProbeLiveFixture(
            action: .restart,
            desired: probeLiveDesired(),
            postcondition: LifecyclePlanCondition(
                kind: "lifecycle",
                subject: "phase04/web",
                expectedValue: "running"
            ),
            interactive: ProbeLiveInteractiveExecutor(outcomes: [])
        )
        defer { fixture.cleanup() }

        let outcome = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        )
        XCTAssertEqual(outcome, .accepted)
        let actions = await fixture.adapter.executedActions()
        XCTAssertEqual(actions.map(\.kind), [.restart])
        XCTAssertEqual(actions.map(\.isDestructive), [true])
    }
}

private struct ProbeLiveInteractiveCall: Equatable, Sendable {
    let resourceIdentifier: String
    let arguments: [String]
    let workingDirectory: String?
    let timeoutMilliseconds: Int
}

private enum ProbeLiveInteractiveOutcome: Sendable {
    case succeeded
    case failed
    case timedOut
}

private final class ProbeLiveInteractiveExecutor:
    LifecycleProbeInteractiveExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var outcomes: [ProbeLiveInteractiveOutcome]
    private var calls: [ProbeLiveInteractiveCall] = []

    init(outcomes: [ProbeLiveInteractiveOutcome]) {
        self.outcomes = outcomes
    }

    func executeProbeCommand(
        resourceIdentifier: String,
        arguments: [String],
        workingDirectory: String?,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult {
        let outcome = lock.withLock { () -> ProbeLiveInteractiveOutcome in
            calls.append(
                ProbeLiveInteractiveCall(
                    resourceIdentifier: resourceIdentifier,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    timeoutMilliseconds: timeoutMilliseconds
                )
            )
            return outcomes.isEmpty ? .succeeded : outcomes.removeFirst()
        }
        switch outcome {
        case .succeeded:
            return RuntimeInteractiveExecutionResult(
                operation: .exec,
                exitStatus: 0,
                emittedFrameCount: 0,
                standardErrorTail: ""
            )
        case .failed:
            throw RuntimeInteractiveError.processFailed(
                exitStatus: 1,
                diagnostic: "probe failed"
            )
        case .timedOut:
            throw RuntimeInteractiveError.processTimedOut
        }
    }

    func snapshot() -> [ProbeLiveInteractiveCall] {
        lock.withLock { calls }
    }
}

private struct ProbeLiveNetworkClient:
    LifecycleProbeNetworkRequesting,
    Sendable
{
    func httpStatusCode(
        at url: URL,
        timeoutMilliseconds: Int,
        maximumRedirects: Int
    ) async throws -> Int {
        200
    }

    func connectTCP(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) async throws {}
}

private final class ProbeLiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64

    init(milliseconds: Int64 = 1_000) {
        self.milliseconds = milliseconds
    }

    func now() -> Int64 {
        lock.withLock { milliseconds }
    }

    func sleep(_ duration: Int64) async throws {
        if duration <= 250 {
            lock.withLock {
                milliseconds += max(1, duration)
            }
            await Task.yield()
            return
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

private actor ProbeLiveRuntimeAdapter: RuntimeAdapter {
    private let capability: RuntimeCapabilitySnapshot
    private let binding: LifecycleResourceBinding
    private let desired: DesiredRuntimeService
    private var actions: [PlannedRuntimeAction] = []

    init(
        capability: RuntimeCapabilitySnapshot,
        binding: LifecycleResourceBinding,
        desired: DesiredRuntimeService
    ) {
        self.capability = capability
        self.binding = binding
        self.desired = desired
    }

    func metadata() async -> RuntimeAdapterMetadata {
        metadataValue
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation, .healthObservation]
    }

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        capability
    }

    func inventory() async throws -> RuntimeInventory {
        let labels = try RuntimeManagedResourceIdentity.labels(
            for: desired.identity,
            context: RuntimeMutationContext(
                providerID: binding.providerID,
                capabilitySHA256: capability.canonicalSHA256,
                operationID: "77777777-7777-4777-8777-777777777777",
                resourceUUID: binding.resourceUUID,
                resourceGeneration: binding.resourceGeneration,
                projectResourceUUID: binding.projectResourceUUID,
                projectGeneration: binding.projectGeneration,
                providerGeneration: binding.providerGeneration,
                fencingToken: binding.currentFencingToken
            )
        ).map {
            RuntimeInventoryLabel(key: $0.key, value: $0.value)
        }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: [
                    RuntimeInventoryService(
                        identifier: "runtime",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: [
                RuntimeInventoryContainer(
                    runtimeID: "runtime-web",
                    name: binding.resourceIdentifier,
                    imageReference: desired.image,
                    lifecycle: .running,
                    health: RuntimeInventoryHealth(
                        availability: .notConfigured
                    ),
                    labels: labels,
                    ownership: binding.ownershipEvidence,
                    initConfiguration: RuntimeInventoryInitConfiguration(
                        executable: "/usr/bin/service",
                        arguments: [],
                        environment: []
                    ),
                    ports: [],
                    mounts: [],
                    networks: [],
                    services: []
                )
            ],
            images: [],
            networks: [],
            volumes: []
        )
    }

    func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: [
                ObservedRuntimeService(
                    identity: desired.identity,
                    resourceIdentifier: binding.resourceIdentifier,
                    image: desired.image,
                    lifecycleState: .running,
                    healthState: .notConfigured
                )
            ],
            adapterMetadata: metadataValue,
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
        RuntimeLogResult(identity: service.identity, text: "", lineLimit: tail)
    }

    func runtimeVersion() async throws -> String {
        "1.1.0"
    }

    func runtimeReadiness() async throws -> RuntimeReadinessReport {
        RuntimeReadinessReport(
            runtimeName: "runtime",
            cliVersion: "1.1.0",
            serviceState: .running,
            serviceVersion: "1.1.0",
            serviceBuild: "test"
        )
    }

    func localImageEvidence(
        for imageReference: String
    ) async throws -> RuntimeLocalImageEvidence {
        RuntimeLocalImageEvidence(
            reference: imageReference,
            descriptorDigest: "sha256:\(String(repeating: "a", count: 64))",
            variantDigest: "sha256:\(String(repeating: "b", count: 64))",
            architecture: "arm64",
            operatingSystem: "linux"
        )
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        guard action.kind == .restart,
              action.isDestructive,
              confirmation?.confirmed == true,
              confirmation?.context?.resourceUUID == binding.resourceUUID else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Test adapter requires an exact destructive restart."
            )
        }
        actions.append(action)
        return RuntimeEvent(
            identity: action.identity,
            message: action.summary,
            resourceIdentifier: action.resourceIdentifier
        )
    }

    func executedActions() -> [PlannedRuntimeAction] {
        actions
    }

    private var metadataValue: RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: capability.descriptor.providerID,
            adapterName: "ProbeLiveRuntimeAdapter",
            adapterVersion: "1.0.0",
            runtimeName: "runtime",
            runtimeVersion: "1.1.0",
            supportsMutation: true,
            capabilities: [
                .readOnlyObservation,
                .lifecycleMutation,
                .healthObservation
            ]
        )
    }
}

private struct ProbeLiveFixture {
    let directory: URL
    let store: SQLiteStateStore
    let probeStore: LifecycleProbeCheckpointStore
    let binding: LifecycleResourceBinding
    let node: LifecyclePlanNode
    let context: LifecycleSagaContext
    let clock: ProbeLiveClock
    let adapter: ProbeLiveRuntimeAdapter
    let effects: LifecycleLiveEffects

    init(
        action: LifecyclePlanAction,
        desired: DesiredRuntimeService,
        postcondition: LifecyclePlanCondition,
        providerID: RuntimeProviderID = .appleContainerCLI,
        timeoutSeconds: Int = 20,
        interactive: ProbeLiveInteractiveExecutor,
        clock: ProbeLiveClock = ProbeLiveClock()
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-probe-live-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        self.clock = clock

        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-phase04",
            manifestPath: nil,
            manifestHash: String(repeating: "a", count: 64),
            desiredGeneration: 1,
            manifest: HostwrightManifest(
                version: 2,
                project: desired.identity.projectName,
                services: [
                    HostwrightService(
                        name: desired.identity.serviceName,
                        image: desired.image
                    )
                ]
            ),
            timestamp: "2026-07-23T12:00:00Z",
            mutationProvider: providerID.rawValue
        )
        let projectResourceUUID = try store.desiredStates
            .loadProject(id: "project-phase04")
            .resourceUUID
        let resourceUUID = "11111111-1111-4111-8111-111111111111"
        let resourceFence = "33333333-3333-4333-8333-333333333333"
        let operationFence = "44444444-4444-4444-8444-444444444444"
        binding = try LifecycleResourceBinding(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectResourceUUID,
            projectGeneration: 1,
            providerID: providerID,
            providerGeneration: 1,
            currentFencingToken: resourceFence
        )
        try store.ownership.upsert(
            OwnershipRecord(
                id: "ownership-web",
                resourceIdentifier: binding.resourceIdentifier,
                resourceType: "container",
                projectID: "project-phase04",
                serviceName: desired.identity.serviceName,
                runtimeAdapter: providerID.rawValue,
                createdAt: "2026-07-23T12:00:00Z",
                observedAt: "2026-07-23T12:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                resourceUUID: binding.resourceUUID,
                resourceGeneration: binding.resourceGeneration,
                projectResourceUUID: binding.projectResourceUUID,
                projectGeneration: binding.projectGeneration,
                providerGeneration: binding.providerGeneration,
                fencingToken: binding.currentFencingToken
            )
        )

        let capability = probeLiveCapability(providerID: providerID)
        node = try LifecyclePlanNode(
            key: "web-\(action.rawValue.replacingOccurrences(of: "-", with: "_"))",
            action: action,
            serviceName: desired.identity.serviceName,
            resourceIdentifier: binding.resourceIdentifier,
            resourceUUID: binding.resourceUUID,
            resourceGeneration: binding.resourceGeneration,
            fencingToken: operationFence,
            postconditions: [postcondition],
            timeoutSeconds: timeoutSeconds
        )
        let plan = try LifecyclePlan(
            command: action == .restart ? .restart : .up,
            projectID: "project-phase04",
            projectName: desired.identity.projectName,
            projectResourceUUID: binding.projectResourceUUID,
            projectGeneration: binding.projectGeneration,
            providerID: providerID,
            providerGeneration: binding.providerGeneration,
            manifestSHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            capabilitySHA256: capability.canonicalSHA256,
            nodes: [node]
        )
        let groupID = "55555555-5555-4555-8555-555555555555"
        let operationID = "66666666-6666-4666-8666-666666666666"
        context = LifecycleSagaContext(
            plan: plan,
            operationID: operationID,
            groupID: groupID,
            fencingToken: operationFence,
            attempt: 1
        )
        let acquired = try store.operationGroups.acquire(
            OperationGroupRecord(
                id: groupID,
                operationID: operationID,
                groupKind: "lifecycle-v1",
                projectID: plan.projectID,
                serviceName: nil,
                plannedActionType: plan.command.rawValue,
                status: .active,
                groupIdempotencyKey: plan.planSHA256,
                planHash: plan.planSHA256,
                checkpoint: "intent-persisted",
                lockOwner: "probe-live-test",
                lockExpiresAt: nil,
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "",
                createdAt: "2026-07-23T12:00:00Z",
                updatedAt: "2026-07-23T12:00:00Z",
                metadataJSONRedacted: "{}",
                fencingToken: operationFence,
                intentJSONRedacted: try plan.canonicalJSON(),
                compensationJSONRedacted: "[]",
                verificationJSONRedacted: "{}"
            )
        )
        guard acquired.acquired != nil else {
            throw StateStoreError.invalidRecord(
                "Probe live test operation group was not acquired."
            )
        }

        let observed = ObservedRuntimeState(
            projectName: desired.identity.projectName,
            services: [
                ObservedRuntimeService(
                    identity: desired.identity,
                    resourceIdentifier: binding.resourceIdentifier,
                    image: desired.image,
                    lifecycleState: .running,
                    healthState: .notConfigured
                )
            ],
            adapterMetadata: RuntimeAdapterMetadata(
                providerID: providerID,
                adapterName: "ProbeLiveRuntimeAdapter",
                adapterVersion: "1.0.0",
                runtimeName: "runtime",
                runtimeVersion: "1.1.0",
                supportsMutation: true,
                capabilities: [
                    .readOnlyObservation,
                    .lifecycleMutation,
                    .healthObservation
                ]
            ),
            capabilitySHA256: capability.canonicalSHA256
        )
        let desiredState = DesiredRuntimeState(
            projectName: desired.identity.projectName,
            services: [desired],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: binding.resourceIdentifier,
                    identity: binding.identity,
                    identityVersion: binding.identityVersion,
                    ownership: binding.ownershipEvidence
                )
            ]
        )
        let state = LifecycleRuntimeExecutionState(
            projectID: plan.projectID,
            providerID: providerID,
            capabilitySHA256: capability.canonicalSHA256,
            desiredState: desiredState,
            observedState: observed,
            bindings: [binding.identity: binding],
            desiredByNode: [node.key: desired]
        )
        adapter = ProbeLiveRuntimeAdapter(
            capability: capability,
            binding: binding,
            desired: desired
        )
        probeStore = LifecycleProbeCheckpointStore(store: store)
        effects = LifecycleLiveEffects(
            adapter: adapter,
            state: state,
            store: store,
            probeStore: probeStore,
            environment: .live,
            interactiveExecutor: interactive,
            probeNetworkClient: ProbeLiveNetworkClient(),
            nowMilliseconds: { clock.now() },
            sleepMilliseconds: { duration in
                try await clock.sleep(duration)
            }
        )
    }

    func appendStartedSagaStep(startedAt: String) throws {
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: context.groupID,
                stepKey: node.key,
                direction: .forward,
                plannedActionType: node.action.rawValue,
                serviceName: node.serviceName,
                resourceIdentifier: node.resourceIdentifier,
                stepIdempotencyKey: node.idempotencyKey,
                status: .started,
                startedAt: startedAt,
                updatedAt: startedAt,
                finishedAt: nil,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: "",
                metadataJSONRedacted: "{}"
            ),
            expectedFencingToken: context.fencingToken
        )
    }

    func exactOwnership() throws -> OwnershipRecord {
        try XCTUnwrap(
            store.ownership.loadAll().first {
                $0.resourceUUID == binding.resourceUUID
            }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func probeLiveDesired(
    probes: RuntimeProbeSet = RuntimeProbeSet(),
    restartPolicy: RuntimeRestartPolicy = .no,
    hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks()
) -> DesiredRuntimeService {
    DesiredRuntimeService(
        identity: RuntimeServiceIdentity(
            projectName: "phase04",
            serviceName: "web"
        ),
        image: "local/phase04:latest",
        workingDirectory: "/work",
        probes: probes,
        restartPolicy: restartPolicy,
        hooks: hooks
    )
}

private func probeLiveCapability(
    providerID: RuntimeProviderID
) -> RuntimeCapabilitySnapshot {
    let component: RuntimeProviderComponentID =
        providerID == .appleContainerCLI
        ? .appleContainerCLI
        : .appleContainerizationHelper
    return RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: providerID,
            components: [
                RuntimeProviderComponent(
                    identifier: component,
                    version: "1.1.0",
                    build: "release",
                    fingerprint: String(repeating: "c", count: 64)
                )
            ],
            minimumMacOSVersion:
                RuntimeProviderCapabilityContract.minimumMacOSVersion,
            supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: RuntimeProviderMacOSVersion(major: 26),
            macOSBuild: "25A1",
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
