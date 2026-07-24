import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

final class LifecyclePlanTests: XCTestCase {
    func testPlanUsesStableTopologicalOrderAndCanonicalDigest() throws {
        let fence = HostwrightResourceUUID.generate()
        let create = try node(key: "create-web", fence: fence)
        let verify = try node(
            key: "verify-web",
            fence: fence,
            dependencies: ["create-web"],
            action: .verify
        )

        let first = try plan(nodes: [verify, create], fence: fence)
        let second = try plan(nodes: [create, verify], fence: fence)

        XCTAssertEqual(first.nodes.map(\.key), ["create-web", "verify-web"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.planSHA256.count, 64)
        XCTAssertEqual(try first.canonicalJSON(), try second.canonicalJSON())
        XCTAssertNotEqual(first.nodes[0].idempotencyKey, first.nodes[1].idempotencyKey)
    }

    func testPlanRejectsMissingDependenciesAndCycles() throws {
        let fence = HostwrightResourceUUID.generate()
        let missing = try node(
            key: "verify-web",
            fence: fence,
            dependencies: ["missing"],
            action: .verify
        )
        XCTAssertThrowsError(try plan(nodes: [missing], fence: fence)) { error in
            XCTAssertEqual(
                error as? LifecyclePlanError,
                .missingDependency(node: "verify-web", dependency: "missing")
            )
        }

        let first = try node(key: "first", fence: fence, dependencies: ["second"])
        let second = try node(key: "second", fence: fence, dependencies: ["first"])
        XCTAssertThrowsError(try plan(nodes: [first, second], fence: fence)) { error in
            XCTAssertEqual(
                error as? LifecyclePlanError,
                .dependencyCycle(["first", "second"])
            )
        }
    }

    func testDesiredSpecificationIsCanonicalAndRedactsSensitiveKeys() throws {
        let node = try self.node(
            key: "create-web",
            fence: HostwrightResourceUUID.generate(),
            desiredSpecificationJSONRedacted:
                #"{"z":2,"token":"plain-secret","image":"local/web@sha256:abc","nested":{"password":"plain-secret"}}"#
        )

        XCTAssertEqual(
            node.desiredSpecificationJSONRedacted,
            #"{"image":"local/web@sha256:abc","nested":{"password":"[REDACTED]"},"token":"[REDACTED]","z":2}"#
        )
        XCTAssertFalse(node.desiredSpecificationJSONRedacted.contains("plain-secret"))
    }

    func testDecodingRejectsTamperedCanonicalPlanDigest() throws {
        let fence = HostwrightResourceUUID.generate()
        let value = try plan(
            nodes: [try node(key: "create-web", fence: fence)],
            fence: fence
        )
        let tampered = try value.canonicalJSON().replacingOccurrences(
            of: value.planSHA256,
            with: String(repeating: "0", count: 64)
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(LifecyclePlan.self, from: Data(tampered.utf8))
        )
    }

    func testPlanPersistsValidatedParallelismInCanonicalDigest() throws {
        let fence = HostwrightResourceUUID.generate()
        let nodes = [try node(key: "create-web", fence: fence)]
        let serial = try plan(nodes: nodes, fence: fence, parallelism: 1)
        let parallel = try plan(nodes: nodes, fence: fence, parallelism: 2)

        XCTAssertEqual(serial.parallelism, 1)
        XCTAssertEqual(parallel.parallelism, 2)
        XCTAssertNotEqual(serial.planSHA256, parallel.planSHA256)
        XCTAssertEqual(
            try JSONDecoder().decode(
                LifecyclePlan.self,
                from: Data(parallel.canonicalJSON().utf8)
            ),
            parallel
        )
        XCTAssertThrowsError(try plan(nodes: nodes, fence: fence, parallelism: 0))
        XCTAssertThrowsError(try plan(nodes: nodes, fence: fence, parallelism: 33))
    }

    private func plan(
        nodes: [LifecyclePlanNode],
        fence: String,
        parallelism: Int = 1
    ) throws -> LifecyclePlan {
        try LifecyclePlan(
            command: .up,
            projectID: "project-demo",
            projectName: "demo",
            projectResourceUUID: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-demo"
            ),
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            capabilitySHA256: String(repeating: "c", count: 64),
            parallelism: parallelism,
            nodes: nodes
        )
    }

    private func node(
        key: String,
        fence: String,
        dependencies: [String] = [],
        action: LifecyclePlanAction = .create,
        desiredSpecificationJSONRedacted: String = "{}"
    ) throws -> LifecyclePlanNode {
        try LifecyclePlanNode(
            key: key,
            action: action,
            serviceName: "web",
            resourceIdentifier: "hostwright-demo-web",
            resourceUUID: HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: "project-demo:web"
            ),
            resourceGeneration: 1,
            fencingToken: fence,
            dependencies: dependencies,
            compensation: action.mutatesRuntime
                ? LifecycleCompensation(action: .delete)
                : nil,
            desiredSpecificationJSONRedacted: desiredSpecificationJSONRedacted
        )
    }
}

final class LifecycleSagaExecutorTests: XCTestCase {
    func testIntentIsDurableBeforeEffectAndSuccessfulNodesCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let effects = InspectingLifecycleEffects(store: fixture.store)
        let executor = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let result = try await executor.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-test"
        )

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.completedNodeKeys, ["create-web"])
        let durableIntentObserved = await effects.observedDurableIntentBeforeApply()
        XCTAssertTrue(durableIntentObserved)
        let group = try XCTUnwrap(fixture.store.operationGroups.load(id: fixture.groupID))
        XCTAssertEqual(group.status, .succeeded)
        XCTAssertEqual(group.checkpoint, "verified")
        XCTAssertTrue(group.intentJSONRedacted.contains(fixture.plan.planSHA256))
        let persistedPlan = try LifecyclePersistedIntentCodec.decode(
            group.intentJSONRedacted
        )
        XCTAssertEqual(persistedPlan, fixture.plan)
        XCTAssertEqual(
            persistedPlan.nodes.map(\.key),
            fixture.plan.nodes.map(\.key)
        )
        XCTAssertEqual(
            persistedPlan.nodes.map(\.idempotencyKey),
            fixture.plan.nodes.map(\.idempotencyKey)
        )
        XCTAssertFalse(group.intentJSONRedacted.contains("keychain://"))
        XCTAssertFalse(group.intentJSONRedacted.contains("demo/api"))
        let steps = try fixture.store.operationGroupSteps.load(groupID: fixture.groupID)
        XCTAssertEqual(steps.map(\.status), [.started, .succeeded])
    }

    func testConcurrentExactPlanExecutionRejectsLoserBeforeDuplicateEffect() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let effects = BlockingLifecycleEffects()
        let first = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )
        let second = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let winner = Task {
            try await first.execute(
                plan: fixture.plan,
                operationID: fixture.operationID,
                groupID: fixture.groupID,
                fencingToken: fixture.fence,
                lockOwner: "lifecycle-concurrency-test"
            )
        }
        await effects.waitUntilApplyStarted()

        do {
            _ = try await second.execute(
                plan: fixture.plan,
                operationID: fixture.operationID,
                groupID: fixture.groupID,
                fencingToken: fixture.fence,
                lockOwner: "lifecycle-concurrency-test"
            )
            XCTFail("The second executor must not adopt an active operation group.")
        } catch {
            XCTAssertEqual(
                error as? LifecycleSagaError,
                .operationConflict(existingGroupID: fixture.groupID)
            )
        }

        let applyCountBeforeRelease = await effects.applyCount()
        XCTAssertEqual(applyCountBeforeRelease, 1)
        await effects.releaseApply()
        let winnerResult = try await winner.value

        XCTAssertEqual(winnerResult.status, .succeeded)
        let finalApplyCount = await effects.applyCount()
        XCTAssertEqual(finalApplyCount, 1)
        let steps = try fixture.store.operationGroupSteps.load(groupID: fixture.groupID)
        XCTAssertEqual(steps.filter { $0.status == .started }.count, 1)
        XCTAssertEqual(steps.filter { $0.status == .succeeded }.count, 1)
    }

    func testExpiredExactActiveLeaseHasOneReclaimerAndReobservesBeforeRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let node = try XCTUnwrap(fixture.plan.nodes.first)
        let expiredAt = "2026-07-22T23:59:00Z"
        XCTAssertNotNil(
            try fixture.store.operationGroups.acquire(
                OperationGroupRecord(
                    id: fixture.groupID,
                    operationID: fixture.operationID,
                    groupKind: "lifecycle-v1",
                    projectID: fixture.plan.projectID,
                    serviceName: nil,
                    plannedActionType: fixture.plan.command.rawValue,
                    status: .active,
                    groupIdempotencyKey: fixture.plan.planSHA256,
                    planHash: fixture.plan.planSHA256,
                    checkpoint: "\(node.key):effect-pending",
                    lockOwner: "terminated-lifecycle-owner",
                    lockExpiresAt: expiredAt,
                    rollbackAvailable: true,
                    manualRecoveryHintRedacted: "",
                    createdAt: "2026-07-22T23:50:00Z",
                    updatedAt: "2026-07-22T23:50:00Z",
                    metadataJSONRedacted: "{}",
                    fencingToken: fixture.fence,
                    intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(
                        fixture.plan
                    ),
                    compensationJSONRedacted: "[]",
                    verificationJSONRedacted:
                        #"{"checkpoint":"create-web:effect-pending"}"#
                ),
                currentTimestamp: "2026-07-22T23:50:00Z"
            ).acquired
        )
        try fixture.store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: fixture.groupID,
                stepKey: node.key,
                direction: .forward,
                plannedActionType: node.action.rawValue,
                serviceName: node.serviceName,
                resourceIdentifier: node.resourceIdentifier,
                stepIdempotencyKey: "\(node.idempotencyKey):forward:1",
                status: .started,
                startedAt: "2026-07-22T23:50:00Z",
                updatedAt: "2026-07-22T23:50:00Z",
                finishedAt: nil,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: "",
                metadataJSONRedacted: #"{"attempt":1}"#
            ),
            expectedFencingToken: fixture.fence
        )
        let effects = BlockingLifecycleEffects()
        let first = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )
        let second = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let winner = Task {
            try await first.execute(
                plan: fixture.plan,
                operationID: fixture.operationID,
                groupID: fixture.groupID,
                fencingToken: fixture.fence,
                lockOwner: "lifecycle-reclaimer-one"
            )
        }
        await effects.waitUntilApplyStarted()

        let reclaimed = try XCTUnwrap(
            fixture.store.operationGroups.load(id: fixture.groupID)
        )
        XCTAssertEqual(reclaimed.lockOwner, "lifecycle-reclaimer-one")
        XCTAssertEqual(reclaimed.lockExpiresAt, "2026-07-23T00:15:00Z")
        do {
            _ = try await second.execute(
                plan: fixture.plan,
                operationID: fixture.operationID,
                groupID: fixture.groupID,
                fencingToken: fixture.fence,
                lockOwner: "lifecycle-reclaimer-two"
            )
            XCTFail("A renewed exact active lease must have only one reclaimer.")
        } catch {
            XCTAssertEqual(
                error as? LifecycleSagaError,
                .operationConflict(existingGroupID: fixture.groupID)
            )
        }

        let observationCountBeforeRelease = await effects.observationCount()
        let applyCountBeforeRelease = await effects.applyCount()
        XCTAssertEqual(observationCountBeforeRelease, 1)
        XCTAssertEqual(applyCountBeforeRelease, 1)
        await effects.releaseApply()
        let winnerResult = try await winner.value
        let finalObservationCount = await effects.observationCount()
        let finalApplyCount = await effects.applyCount()
        XCTAssertEqual(winnerResult.status, .succeeded)
        XCTAssertEqual(finalObservationCount, 2)
        XCTAssertEqual(finalApplyCount, 1)
    }

    func testRetriesOnlyAfterObservationProvesNoEffectAndStopsAtSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let failure = normalizedFailure(
            category: .timedOut,
            retry: .safeAfterObservation,
            recovery: .reobserve,
            operationID: fixture.operationID
        )
        let effects = ScriptedLifecycleEffects(
            apply: [.failed(failure), .accepted],
            observe: [
                .noEffect(LifecycleNodeVerification(summaryRedacted: "no effect")),
                .satisfied(LifecycleNodeVerification(summaryRedacted: "created"))
            ]
        )
        let executor = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let result = try await executor.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-test"
        )

        XCTAssertEqual(result.status, .succeeded)
        let applyCount = await effects.applyCount()
        XCTAssertEqual(applyCount, 2)
        let steps = try fixture.store.operationGroupSteps.load(groupID: fixture.groupID)
        XCTAssertEqual(steps.filter { $0.status == .started }.count, 2)
        XCTAssertEqual(steps.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(steps.filter { $0.status == .succeeded }.count, 1)
    }

    func testDefinitiveFailureCompensatesPreviouslyVerifiedEffectsInReverse() async throws {
        let fixture = try makeFixture(nodeCount: 2)
        defer { fixture.cleanup() }
        let failure = normalizedFailure(
            category: .rejected,
            retry: .never,
            recovery: .none,
            operationID: fixture.operationID
        )
        let effects = ScriptedLifecycleEffects(
            apply: [.accepted, .failed(failure)],
            observe: [
                .satisfied(LifecycleNodeVerification(summaryRedacted: "first created")),
                .noEffect(LifecycleNodeVerification(summaryRedacted: "second rejected"))
            ],
            compensate: [
                .compensated(LifecycleNodeVerification(summaryRedacted: "first removed"))
            ]
        )
        let executor = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let result = try await executor.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-test"
        )

        XCTAssertEqual(result.status, .compensated)
        let compensatedNodeKeys = await effects.compensatedNodeKeys()
        XCTAssertEqual(compensatedNodeKeys, ["create-web"])
        let group = try XCTUnwrap(fixture.store.operationGroups.load(id: fixture.groupID))
        XCTAssertEqual(group.status, .failed)
        XCTAssertEqual(group.checkpoint, "compensated")
    }

    func testForwardDeadlineFailureUsesRollbackContextForCompensation() async throws {
        let fixture = try makeFixture(nodeCount: 2)
        defer { fixture.cleanup() }
        let failure = normalizedFailure(
            category: .timedOut,
            retry: .never,
            recovery: .compensate,
            operationID: fixture.operationID
        )
        let effects = ScriptedLifecycleEffects(
            apply: [.accepted, .failed(failure)],
            observe: [
                .satisfied(LifecycleNodeVerification(summaryRedacted: "first created")),
                .noEffect(
                    LifecycleNodeVerification(
                        summaryRedacted: "deadline had no second effect"
                    )
                )
            ],
            compensate: [
                .compensated(LifecycleNodeVerification(summaryRedacted: "first removed"))
            ]
        )

        let result = try await LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        ).execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-deadline-compensation-test"
        )

        XCTAssertEqual(result.status, .compensated)
        let applyDirections = await effects.applyDirections()
        let compensationDirections = await effects.compensationDirections()
        XCTAssertEqual(applyDirections, [.forward, .forward])
        XCTAssertEqual(compensationDirections, [.rollback])
    }

    func testInterruptedCompensationIsReobservedWithoutRepeatingTheInverse() async throws {
        for rollbackStatus in [
            OperationGroupStepStatus.started,
            .succeeded
        ] {
            let fixture = try makeFixture(nodeCount: 2)
            defer { fixture.cleanup() }
            let first = try XCTUnwrap(
                fixture.plan.nodes.first { $0.key == "create-web" }
            )
            let second = try XCTUnwrap(
                fixture.plan.nodes.first { $0.key == "create-worker" }
            )
            let acquired = try fixture.store.operationGroups.acquire(
                OperationGroupRecord(
                    id: fixture.groupID,
                    operationID: fixture.operationID,
                    groupKind: "lifecycle-v1",
                    projectID: fixture.plan.projectID,
                    serviceName: nil,
                    plannedActionType: fixture.plan.command.rawValue,
                    status: .active,
                    groupIdempotencyKey: fixture.plan.planSHA256,
                    planHash: fixture.plan.planSHA256,
                    checkpoint: "\(first.key):compensation-pending",
                    lockOwner: "terminated-lifecycle-owner",
                    lockExpiresAt: "2026-07-22T23:59:00Z",
                    rollbackAvailable: true,
                    manualRecoveryHintRedacted: "",
                    createdAt: "2026-07-22T23:50:00Z",
                    updatedAt: "2026-07-22T23:50:00Z",
                    metadataJSONRedacted: "{}",
                    fencingToken: fixture.fence,
                    intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(
                        fixture.plan
                    ),
                    compensationJSONRedacted: "[]",
                    verificationJSONRedacted:
                        #"{"checkpoint":"create-web:compensation-pending"}"#
                ),
                currentTimestamp: "2026-07-22T23:50:00Z"
            )
            XCTAssertNotNil(acquired.acquired)

            func append(
                node: LifecyclePlanNode,
                direction: OperationGroupStepDirection,
                status: OperationGroupStepStatus,
                attempt: Int
            ) throws {
                let timestamp = "2026-07-22T23:50:00Z"
                try fixture.store.operationGroupSteps.append(
                    OperationGroupStepRecord(
                        id: HostwrightResourceUUID.generate(),
                        groupID: fixture.groupID,
                        stepKey: node.key,
                        direction: direction,
                        plannedActionType: direction == .forward
                            ? node.action.rawValue
                            : (node.compensation?.action.rawValue ?? "none"),
                        serviceName: node.serviceName,
                        resourceIdentifier: node.resourceIdentifier,
                        stepIdempotencyKey:
                            "\(node.idempotencyKey):\(direction.rawValue):\(attempt)",
                        status: status,
                        startedAt: status == .started ? timestamp : nil,
                        updatedAt: timestamp,
                        finishedAt: status == .started ? nil : timestamp,
                        lastErrorRedacted: status == .failed
                            ? "scripted failure"
                            : nil,
                        manualRecoveryHintRedacted: "",
                        metadataJSONRedacted:
                            #"{"failureCategory":"rejected"}"#
                    ),
                    expectedFencingToken: fixture.fence
                )
            }

            try append(
                node: first,
                direction: .forward,
                status: .started,
                attempt: 1
            )
            try append(
                node: first,
                direction: .forward,
                status: .succeeded,
                attempt: 1
            )
            for attempt in 1...3 {
                try append(
                    node: second,
                    direction: .forward,
                    status: .started,
                    attempt: attempt
                )
                try append(
                    node: second,
                    direction: .forward,
                    status: .failed,
                    attempt: attempt
                )
            }
            try append(
                node: first,
                direction: .rollback,
                status: rollbackStatus,
                attempt: 1
            )

            let observations: [LifecycleSagaObservation] =
                rollbackStatus == .started
                ? [
                    .noEffect(
                        LifecycleNodeVerification(
                            summaryRedacted: "second create had no effect"
                        )
                    ),
                    .satisfied(
                        LifecycleNodeVerification(
                            summaryRedacted:
                                "interrupted compensation already removed the first resource"
                        )
                    )
                ]
                : [
                    .noEffect(
                        LifecycleNodeVerification(
                            summaryRedacted: "second create had no effect"
                        )
                    )
                ]
            let effects = ScriptedLifecycleEffects(
                apply: [],
                observe: observations
            )
            let result = try await LifecycleSagaExecutor(
                store: fixture.store,
                effects: effects,
                validator: ExactLifecycleValidator(),
                clock: FixedLifecycleClock()
            ).execute(
                plan: fixture.plan,
                operationID: fixture.operationID,
                groupID: fixture.groupID,
                fencingToken: fixture.fence,
                lockOwner: "lifecycle-compensation-resume"
            )

            XCTAssertEqual(result.status, .compensated)
            let compensatedNodeKeys = await effects.compensatedNodeKeys()
            XCTAssertEqual(compensatedNodeKeys, [])
            let rollbackSteps = try fixture.store.operationGroupSteps
                .load(groupID: fixture.groupID)
                .filter {
                    $0.stepKey == first.key &&
                        $0.direction == .rollback
                }
            XCTAssertEqual(
                rollbackSteps.filter { $0.status == .started }.count,
                rollbackStatus == .started ? 1 : 0
            )
            XCTAssertEqual(
                rollbackSteps.filter { $0.status == .succeeded }.count,
                1
            )
        }
    }

    func testAmbiguousEffectEntersSafeHoldWithoutCompensation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let effects = ScriptedLifecycleEffects(
            apply: [.accepted],
            observe: [
                .ambiguous(LifecycleNodeVerification(summaryRedacted: "identity unavailable"))
            ]
        )
        let executor = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let result = try await executor.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-test"
        )

        XCTAssertEqual(result.status, .safeHold)
        let compensatedNodeKeys = await effects.compensatedNodeKeys()
        XCTAssertEqual(compensatedNodeKeys, [])
        XCTAssertEqual(
            try fixture.store.operationGroups.load(id: fixture.groupID)?.status,
            .failed
        )
    }

    func testCancelledNoEffectCanResumeSameFencedOperation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let cancellation = normalizedFailure(
            category: .cancelled,
            retry: .safeAfterObservation,
            recovery: .reobserve,
            operationID: fixture.operationID
        )
        let firstEffects = ScriptedLifecycleEffects(
            apply: [.failed(cancellation)],
            observe: [.noEffect(LifecycleNodeVerification(summaryRedacted: "cancelled cleanly"))]
        )
        let first = LifecycleSagaExecutor(
            store: fixture.store,
            effects: firstEffects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )
        let interrupted = try await first.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-test"
        )
        XCTAssertEqual(interrupted.status, .interrupted)

        let resumeEffects = ScriptedLifecycleEffects(
            apply: [.accepted],
            observe: [
                .noEffect(LifecycleNodeVerification(summaryRedacted: "still absent")),
                .satisfied(LifecycleNodeVerification(summaryRedacted: "created on resume"))
            ]
        )
        let resumed = LifecycleSagaExecutor(
            store: fixture.store,
            effects: resumeEffects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )
        let result = try await resumed.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-test-resume"
        )

        XCTAssertEqual(result.status, .succeeded)
        let resumedApplyCount = await resumeEffects.applyCount()
        XCTAssertEqual(resumedApplyCount, 1)
        let steps = try fixture.store.operationGroupSteps.load(groupID: fixture.groupID)
        XCTAssertEqual(steps.filter { $0.status == .started }.count, 2)
    }

    func testStaleProviderContextFailsBeforeAnyEffect() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let effects = ScriptedLifecycleEffects(apply: [.accepted], observe: [])
        let executor = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: StaleLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let result = try await executor.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-test"
        )

        XCTAssertEqual(result.status, .safeHold)
        let applyCount = await effects.applyCount()
        XCTAssertEqual(applyCount, 0)
    }

    func testDependencyReadyWavesHonorParallelismAndSerializeLedgerOrder() async throws {
        let fixture = try makeWaveFixture(parallelism: 2)
        defer { fixture.cleanup() }
        let effects = WaveTrackingLifecycleEffects()
        let executor = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let result = try await executor.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-wave-test"
        )

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(
            result.completedNodeKeys,
            ["create-api", "create-web", "create-worker", "verify-project"]
        )
        let maximumConcurrentApplyCount = await effects.maximumConcurrentApplyCount()
        let dependencyViolations = await effects.dependencyViolations()
        XCTAssertEqual(maximumConcurrentApplyCount, 2)
        XCTAssertEqual(dependencyViolations, [])
        let steps = try fixture.store.operationGroupSteps.load(groupID: fixture.groupID)
        XCTAssertEqual(
            steps.map { "\($0.stepKey):\($0.status.rawValue)" },
            [
                "create-api:started",
                "create-web:started",
                "create-api:succeeded",
                "create-web:succeeded",
                "create-worker:started",
                "create-worker:succeeded",
                "verify-project:started",
                "verify-project:succeeded"
            ]
        )
    }

    func testFailurePreventsDownstreamWaveAndCompensatesSuccessfulSibling() async throws {
        let fixture = try makeFailureWaveFixture()
        defer { fixture.cleanup() }
        let effects = FailingWaveLifecycleEffects(
            failure: normalizedFailure(
                category: .rejected,
                retry: .never,
                recovery: .none,
                operationID: fixture.operationID
            )
        )
        let executor = LifecycleSagaExecutor(
            store: fixture.store,
            effects: effects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )

        let result = try await executor.execute(
            plan: fixture.plan,
            operationID: fixture.operationID,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            lockOwner: "lifecycle-failure-wave-test"
        )

        XCTAssertEqual(result.status, .compensated)
        let appliedNodeKeys = await effects.appliedNodeKeys()
        let compensatedNodeKeys = await effects.compensatedNodeKeys()
        XCTAssertEqual(Set(appliedNodeKeys), Set(["create-failing", "create-sibling"]))
        XCTAssertFalse(appliedNodeKeys.contains("verify-downstream"))
        XCTAssertEqual(compensatedNodeKeys, ["create-sibling"])
        let steps = try fixture.store.operationGroupSteps.load(groupID: fixture.groupID)
        XCTAssertFalse(steps.contains { $0.stepKey == "verify-downstream" })
    }

    func testConcurrentCompletionOrderDoesNotChangePersistedOutcomeOrder() async throws {
        let firstFixture = try makeWaveFixture(parallelism: 2)
        defer { firstFixture.cleanup() }
        let firstEffects = WaveTrackingLifecycleEffects(
            delayMillisecondsByNode: ["create-api": 40, "create-web": 1]
        )
        let firstExecutor = LifecycleSagaExecutor(
            store: firstFixture.store,
            effects: firstEffects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )
        let firstResult = try await firstExecutor.execute(
            plan: firstFixture.plan,
            operationID: firstFixture.operationID,
            groupID: firstFixture.groupID,
            fencingToken: firstFixture.fence,
            lockOwner: "lifecycle-stable-wave-a"
        )

        let secondFixture = try makeWaveFixture(parallelism: 2)
        defer { secondFixture.cleanup() }
        let secondEffects = WaveTrackingLifecycleEffects(
            delayMillisecondsByNode: ["create-api": 1, "create-web": 40]
        )
        let secondExecutor = LifecycleSagaExecutor(
            store: secondFixture.store,
            effects: secondEffects,
            validator: ExactLifecycleValidator(),
            clock: FixedLifecycleClock()
        )
        let secondResult = try await secondExecutor.execute(
            plan: secondFixture.plan,
            operationID: secondFixture.operationID,
            groupID: secondFixture.groupID,
            fencingToken: secondFixture.fence,
            lockOwner: "lifecycle-stable-wave-b"
        )

        let firstSteps = try firstFixture.store.operationGroupSteps
            .load(groupID: firstFixture.groupID)
            .map { "\($0.stepKey):\($0.status.rawValue)" }
        let secondSteps = try secondFixture.store.operationGroupSteps
            .load(groupID: secondFixture.groupID)
            .map { "\($0.stepKey):\($0.status.rawValue)" }
        XCTAssertEqual(firstResult.completedNodeKeys, secondResult.completedNodeKeys)
        XCTAssertEqual(firstSteps, secondSteps)
    }

    private func makeFixture(nodeCount: Int = 1) throws -> LifecycleSagaFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-lifecycle-saga-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        let projectID = "project-demo"
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: nil,
            manifestHash: String(repeating: "a", count: 64),
            desiredGeneration: 1,
            manifest: HostwrightManifest(
                version: HostwrightManifest.currentVersion,
                project: "demo",
                services: [
                    HostwrightService(name: "web", image: "local/web@sha256:abc")
                ]
            ),
            timestamp: "2026-07-23T00:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
        )
        let fence = HostwrightResourceUUID.generate()
        let first = try LifecyclePlanNode(
            key: "create-web",
            action: .create,
            serviceName: "web",
            resourceIdentifier: "hostwright-demo-web",
            resourceUUID: HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: "\(projectID):web"
            ),
            resourceGeneration: 1,
            fencingToken: fence,
            compensation: LifecycleCompensation(action: .delete),
            desiredSpecificationJSONRedacted:
                #"{"image":"local/web@sha256:abc","secretEnv":{"API_TOKEN":"keychain://demo/api"}}"#
        )
        var nodes = [first]
        if nodeCount > 1 {
            nodes.append(
                try LifecyclePlanNode(
                    key: "create-worker",
                    action: .create,
                    serviceName: "worker",
                    resourceIdentifier: "hostwright-demo-worker",
                    resourceUUID: HostwrightResourceUUID.legacy(
                        kind: "service",
                        identifier: "\(projectID):worker"
                    ),
                    resourceGeneration: 1,
                    fencingToken: fence,
                    dependencies: ["create-web"],
                    compensation: LifecycleCompensation(action: .delete),
                    desiredSpecificationJSONRedacted:
                        #"{"image":"local/worker@sha256:def"}"#
                )
            )
        }
        let plan = try LifecyclePlan(
            command: .up,
            projectID: projectID,
            projectName: "demo",
            projectResourceUUID: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: projectID
            ),
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            capabilitySHA256: String(repeating: "c", count: 64),
            nodes: nodes
        )
        return LifecycleSagaFixture(
            directory: directory,
            store: store,
            plan: plan,
            operationID: HostwrightResourceUUID.generate(),
            groupID: HostwrightResourceUUID.generate(),
            fence: fence
        )
    }

    private func makeWaveFixture(parallelism: Int) throws -> LifecycleSagaFixture {
        try makeCustomFixture(parallelism: parallelism) { fence in
            let api = try parallelNode(key: "create-api", fence: fence)
            let web = try parallelNode(key: "create-web", fence: fence)
            let worker = try parallelNode(key: "create-worker", fence: fence)
            let verify = try parallelNode(
                key: "verify-project",
                fence: fence,
                dependencies: ["create-api", "create-web", "create-worker"],
                action: .verify
            )
            return [verify, worker, web, api]
        }
    }

    private func makeFailureWaveFixture() throws -> LifecycleSagaFixture {
        try makeCustomFixture(parallelism: 2) { fence in
            let failing = try parallelNode(key: "create-failing", fence: fence)
            let sibling = try parallelNode(key: "create-sibling", fence: fence)
            let downstream = try parallelNode(
                key: "verify-downstream",
                fence: fence,
                dependencies: ["create-failing", "create-sibling"],
                action: .verify
            )
            return [downstream, sibling, failing]
        }
    }

    private func makeCustomFixture(
        parallelism: Int,
        nodes: (String) throws -> [LifecyclePlanNode]
    ) throws -> LifecycleSagaFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-lifecycle-wave-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let store = SQLiteStateStore(
                path: directory.appendingPathComponent("state.sqlite").path
            )
            try store.migrate()
            let projectID = "project-demo"
            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: nil,
                manifestHash: String(repeating: "a", count: 64),
                desiredGeneration: 1,
                manifest: HostwrightManifest(
                    version: HostwrightManifest.currentVersion,
                    project: "demo",
                    services: [
                        HostwrightService(name: "web", image: "local/web@sha256:abc")
                    ]
                ),
                timestamp: "2026-07-23T00:00:00Z",
                mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
            )
            let fence = HostwrightResourceUUID.generate()
            let plan = try LifecyclePlan(
                command: .up,
                projectID: projectID,
                projectName: "demo",
                projectResourceUUID: HostwrightResourceUUID.legacy(
                    kind: "project",
                    identifier: projectID
                ),
                projectGeneration: 1,
                providerID: .appleContainerCLI,
                providerGeneration: 1,
                manifestSHA256: String(repeating: "a", count: 64),
                observationSHA256: String(repeating: "b", count: 64),
                capabilitySHA256: String(repeating: "c", count: 64),
                parallelism: parallelism,
                nodes: try nodes(fence)
            )
            return LifecycleSagaFixture(
                directory: directory,
                store: store,
                plan: plan,
                operationID: HostwrightResourceUUID.generate(),
                groupID: HostwrightResourceUUID.generate(),
                fence: fence
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func parallelNode(
        key: String,
        fence: String,
        dependencies: [String] = [],
        action: LifecyclePlanAction = .create
    ) throws -> LifecyclePlanNode {
        try LifecyclePlanNode(
            key: key,
            action: action,
            serviceName: key,
            resourceIdentifier: "hostwright-demo-\(key)",
            resourceUUID: HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: "project-demo:\(key)"
            ),
            resourceGeneration: 1,
            fencingToken: fence,
            dependencies: dependencies,
            compensation: action.mutatesRuntime
                ? LifecycleCompensation(action: .delete)
                : nil,
            desiredSpecificationJSONRedacted: #"{"image":"local/test@sha256:abc"}"#
        )
    }

    private func normalizedFailure(
        category: RuntimeFailureCategory,
        retry: RuntimeRetryDisposition,
        recovery: RuntimeRecoveryDisposition,
        operationID: String
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: category,
            retryDisposition: retry,
            recoveryDisposition: recovery,
            providerID: RuntimeProviderID.appleContainerCLI.rawValue,
            providerVersion: "1.1.0",
            operationID: operationID,
            diagnostic: "scripted failure",
            guidance: "follow recorded recovery"
        )
    }
}

private struct LifecycleSagaFixture {
    let directory: URL
    let store: SQLiteStateStore
    let plan: LifecyclePlan
    let operationID: String
    let groupID: String
    let fence: String

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct ExactLifecycleValidator: LifecycleSagaContextValidating {
    func validate(
        plan: LifecyclePlan,
        node: LifecyclePlanNode,
        expectedFencingToken: String
    ) async -> LifecycleSagaValidation {
        LifecycleSagaValidation(
            providerID: plan.providerID,
            providerGeneration: plan.providerGeneration,
            capabilitySHA256: plan.capabilitySHA256,
            projectResourceUUID: plan.projectResourceUUID,
            projectGeneration: plan.projectGeneration,
            fencingToken: expectedFencingToken,
            ownershipVerified: true
        )
    }
}

private struct StaleLifecycleValidator: LifecycleSagaContextValidating {
    func validate(
        plan: LifecyclePlan,
        node: LifecyclePlanNode,
        expectedFencingToken: String
    ) async -> LifecycleSagaValidation {
        LifecycleSagaValidation(
            providerID: plan.providerID,
            providerGeneration: plan.providerGeneration,
            capabilitySHA256: String(repeating: "d", count: 64),
            projectResourceUUID: plan.projectResourceUUID,
            projectGeneration: plan.projectGeneration,
            fencingToken: expectedFencingToken,
            ownershipVerified: true
        )
    }
}

private struct FixedLifecycleClock: LifecycleSagaClock {
    func now() -> String {
        "2026-07-23T00:00:00Z"
    }
}

private actor InspectingLifecycleEffects: LifecycleSagaEffects {
    private let store: SQLiteStateStore
    private var durableIntentObserved = false

    init(store: SQLiteStateStore) {
        self.store = store
    }

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        if let group = try? store.operationGroups.load(id: context.groupID),
           group.status == .active,
           group.checkpoint == "\(node.key):effect-pending",
           group.intentJSONRedacted.contains(context.plan.planSHA256) {
            durableIntentObserved = true
        }
        return .accepted
    }

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        .satisfied(LifecycleNodeVerification(summaryRedacted: "verified"))
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        .compensated(LifecycleNodeVerification(summaryRedacted: "compensated"))
    }

    func observedDurableIntentBeforeApply() -> Bool {
        durableIntentObserved
    }
}

private actor BlockingLifecycleEffects: LifecycleSagaEffects {
    private var applyStarted = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []
    private var applyRelease: CheckedContinuation<Void, Never>?
    private var appliedCount = 0
    private var observedCount = 0
    private var effectCommitted = false

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        appliedCount += 1
        if appliedCount == 1 {
            applyStarted = true
            let waiters = applyWaiters
            applyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                applyRelease = continuation
            }
        }
        effectCommitted = true
        return .accepted
    }

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        observedCount += 1
        if effectCommitted {
            return .satisfied(LifecycleNodeVerification(summaryRedacted: "verified"))
        }
        return .noEffect(LifecycleNodeVerification(summaryRedacted: "not yet applied"))
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        .compensated(LifecycleNodeVerification(summaryRedacted: "compensated"))
    }

    func waitUntilApplyStarted() async {
        guard !applyStarted else { return }
        await withCheckedContinuation { continuation in
            applyWaiters.append(continuation)
        }
    }

    func releaseApply() {
        applyRelease?.resume()
        applyRelease = nil
    }

    func applyCount() -> Int {
        appliedCount
    }

    func observationCount() -> Int {
        observedCount
    }
}

private actor ScriptedLifecycleEffects: LifecycleSagaEffects {
    private var applyOutcomes: [LifecycleSagaApplyOutcome]
    private var observations: [LifecycleSagaObservation]
    private var compensationOutcomes: [LifecycleSagaCompensationOutcome]
    private var appliedNodes: [String] = []
    private var compensatedNodes: [String] = []
    private var appliedDirections: [OperationGroupStepDirection] = []
    private var compensatedDirections: [OperationGroupStepDirection] = []

    init(
        apply: [LifecycleSagaApplyOutcome],
        observe: [LifecycleSagaObservation],
        compensate: [LifecycleSagaCompensationOutcome] = []
    ) {
        applyOutcomes = apply
        observations = observe
        compensationOutcomes = compensate
    }

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        appliedNodes.append(node.key)
        appliedDirections.append(context.direction)
        guard !applyOutcomes.isEmpty else {
            return .accepted
        }
        return applyOutcomes.removeFirst()
    }

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        guard !observations.isEmpty else {
            return .ambiguous(
                LifecycleNodeVerification(summaryRedacted: "missing scripted observation")
            )
        }
        return observations.removeFirst()
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        compensatedNodes.append(node.key)
        compensatedDirections.append(context.direction)
        guard !compensationOutcomes.isEmpty else {
            return .compensated(
                LifecycleNodeVerification(summaryRedacted: "scripted compensation")
            )
        }
        return compensationOutcomes.removeFirst()
    }

    func applyCount() -> Int {
        appliedNodes.count
    }

    func compensatedNodeKeys() -> [String] {
        compensatedNodes
    }

    func applyDirections() -> [OperationGroupStepDirection] {
        appliedDirections
    }

    func compensationDirections() -> [OperationGroupStepDirection] {
        compensatedDirections
    }
}

private actor WaveTrackingLifecycleEffects: LifecycleSagaEffects {
    private let delayMillisecondsByNode: [String: Int]
    private var activeApplyCount = 0
    private var maximumApplyCount = 0
    private var observedNodes: Set<String> = []
    private var violations: [String] = []

    init(delayMillisecondsByNode: [String: Int] = [:]) {
        self.delayMillisecondsByNode = delayMillisecondsByNode
    }

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        let missingDependencies = node.dependencies.filter { !observedNodes.contains($0) }
        if !missingDependencies.isEmpty {
            violations.append("\(node.key):\(missingDependencies.sorted().joined(separator: ","))")
        }
        activeApplyCount += 1
        maximumApplyCount = max(maximumApplyCount, activeApplyCount)
        let delay = delayMillisecondsByNode[node.key] ?? 25
        try? await Task.sleep(for: .milliseconds(delay))
        activeApplyCount -= 1
        return .accepted
    }

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        observedNodes.insert(node.key)
        return .satisfied(
            LifecycleNodeVerification(summaryRedacted: "\(node.key) verified")
        )
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        .compensated(LifecycleNodeVerification(summaryRedacted: "\(node.key) compensated"))
    }

    func maximumConcurrentApplyCount() -> Int {
        maximumApplyCount
    }

    func dependencyViolations() -> [String] {
        violations
    }
}

private actor FailingWaveLifecycleEffects: LifecycleSagaEffects {
    private let failure: RuntimeNormalizedFailure
    private var appliedNodes: [String] = []
    private var compensatedNodes: [String] = []

    init(failure: RuntimeNormalizedFailure) {
        self.failure = failure
    }

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        appliedNodes.append(node.key)
        return node.key == "create-failing" ? .failed(failure) : .accepted
    }

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        if node.key == "create-failing" {
            return .noEffect(
                LifecycleNodeVerification(summaryRedacted: "failure had no effect")
            )
        }
        return .satisfied(
            LifecycleNodeVerification(summaryRedacted: "\(node.key) verified")
        )
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        compensatedNodes.append(node.key)
        return .compensated(
            LifecycleNodeVerification(summaryRedacted: "\(node.key) compensated")
        )
    }

    func appliedNodeKeys() -> [String] {
        appliedNodes
    }

    func compensatedNodeKeys() -> [String] {
        compensatedNodes
    }
}
