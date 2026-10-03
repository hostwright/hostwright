import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleProbeLiveIntegrationTests: XCTestCase {
    func testNativeStopStartRestartObservesTheCurrentOperationFence() async throws {
        let fixture = try ProbeLiveFixture(
            action: .stop,
            desired: probeLiveDesired(),
            postcondition: LifecyclePlanCondition(
                kind: "lifecycle", subject: "phase04/web", expectedValue: "stopped"
            ),
            providerID: .appleContainerization,
            planCommand: .restart,
            nativeRestartPair: true,
            interactive: ProbeLiveInteractiveExecutor(outcomes: [])
        )
        defer { fixture.cleanup() }
        let helper = NativeFenceLifecycleHelper(fixture: fixture)
        let effects = try nativeFenceEffects(fixture: fixture, helper: helper)
        let start = try XCTUnwrap(fixture.context.plan.nodes.first { $0.action == .start })
        XCTAssertEqual(fixture.context.plan.nodes.map(\.action), [.stop, .start])
        XCTAssertEqual(start.dependencies, [fixture.node.key])
        XCTAssertNotEqual(fixture.binding.currentFencingToken, fixture.node.fencingToken)
        XCTAssertNotEqual(fixture.node.fencingToken, fixture.context.fencingToken)

        guard case .accepted = await effects.apply(node: fixture.node, context: fixture.context) else {
            return XCTFail("The exact native Stop must complete before its postcondition is observed.")
        }
        let stopped = try await helper.inventory()
        XCTAssertEqual(stopped.containers.first?.lifecycle, .stopped)
        XCTAssertEqual(stopped.containers.first?.ownership?.fencingToken, fixture.context.fencingToken)
        XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.context.fencingToken)
        let stopObservation = await effects.observe(node: fixture.node, context: fixture.context)
        guard case .satisfied = stopObservation else {
            return XCTFail("Completed native Stop must observe the authorized operation fence: \(stopObservation)")
        }
        XCTAssertEqual(try fixture.exactOwnership().fencingToken, stopped.containers.first?.ownership?.fencingToken)
        let priorBinding = await effects.state.binding(for: fixture.binding.identity)
        XCTAssertEqual(priorBinding?.currentFencingToken, fixture.binding.currentFencingToken)
        guard case .accepted = await effects.apply(node: start, context: fixture.context) else {
            return XCTFail("Restart's dependent native Start must retain exact operation authority.")
        }
        let startObservation = await effects.observe(node: start, context: fixture.context)
        guard case .satisfied = startObservation else {
            return XCTFail("Completed native Start must observe the same authorized fence: \(startObservation)")
        }
        let mutations = await helper.mutations()
        XCTAssertEqual(mutations, [.stop, .start])
        XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.context.fencingToken)
        let running = try await helper.inventory()
        XCTAssertEqual(running.containers.first?.ownership?.fencingToken, try fixture.exactOwnership().fencingToken)
        try await LifecycleOwnershipFinalizer(store: fixture.store, adapter: effects.adapter)
            .finalize(context: fixture.context)
        try fixture.store.operationGroups.finish(
            groupID: fixture.context.groupID, status: .succeeded,
            checkpoint: "complete", manualRecoveryHintRedacted: "",
            updatedAt: "2026-10-03T10:00:00Z", metadataJSONRedacted: "{}"
        )
        let hints = try hostwrightRuntimeOwnershipHints(
            store: fixture.store, projectID: fixture.context.plan.projectID,
            projectName: fixture.context.plan.projectName, providerID: .appleContainerization
        )
        XCTAssertEqual(hints.first?.ownership?.fencingToken, fixture.context.fencingToken)
        XCTAssertNil(hints.first?.authorizedAlternateOwnership)
        let observed = try await effects.adapter.observe(desiredState: DesiredRuntimeState(
            projectName: fixture.context.plan.projectName,
            services: [probeLiveDesired()], ownedResourceHints: hints
        ))
        let service = try XCTUnwrap(observed.services.first)
        XCTAssertEqual(service.lifecycleState, .running)
        let logs = try await effects.adapter.logs(for: service, tail: 10)
        XCTAssertEqual(logs.text, "native lifecycle output")

        let next = try await nativeFenceNextOperation(fixture: fixture, adapter: effects.adapter, observed: observed)
        for node in next.context.plan.nodes {
            guard case .accepted = await next.effects.apply(node: node, context: next.context),
                  case .satisfied = await next.effects.observe(node: node, context: next.context) else {
                return XCTFail("A second exact restart must hand off the completed resource projection.")
            }
            let native = try await helper.inventory()
            XCTAssertEqual(try fixture.exactOwnership().fencingToken, next.context.fencingToken)
            XCTAssertEqual(native.containers.first?.ownership?.fencingToken, next.context.fencingToken)
        }
    }

    func testNativeObservationRestoresOnlyTheProvenPriorFenceOnNoEffect() async throws {
        let fixture = try nativeFenceFixture()
        defer { fixture.cleanup() }
        let helper = NativeFenceLifecycleHelper(fixture: fixture)
        await helper.ignoreNextMutation()
        let effects = try nativeFenceEffects(fixture: fixture, helper: helper)
        guard case .accepted = await effects.apply(node: fixture.node, context: fixture.context) else {
            return XCTFail("The fixture must reach post-effect observation.")
        }
        XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.context.fencingToken)
        guard case .noEffect = await effects.observe(node: fixture.node, context: fixture.context) else {
            return XCTFail("The exact old-fence running resource must prove Stop had no effect.")
        }
        let native = try await helper.inventory()
        XCTAssertEqual(native.containers.first?.lifecycle, .running)
        XCTAssertEqual(native.containers.first?.ownership?.fencingToken, fixture.binding.currentFencingToken)
        XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.binding.currentFencingToken)
        let binding = await effects.state.binding(for: fixture.binding.identity)
        XCTAssertEqual(binding, fixture.binding)
    }

    func testNativeDownAndRemovalRequireExactPostconditionsAndKeepNativeFences() async throws {
        for (command, action) in [(LifecycleCommand.down, LifecyclePlanAction.stop), (.remove, .delete)] {
            let fixture = try nativeFenceFixture(command: command, action: action)
            defer { fixture.cleanup() }
            let helper = NativeFenceLifecycleHelper(fixture: fixture)
            let effects = try nativeFenceEffects(fixture: fixture, helper: helper)
            guard case .accepted = await effects.apply(node: fixture.node, context: fixture.context),
                  case .satisfied = await effects.observe(node: fixture.node, context: fixture.context) else {
                return XCTFail("\(command) must verify its real native lifecycle postcondition.")
            }
            let inventory = try await helper.inventory()
            if command == .down {
                XCTAssertEqual(inventory.containers.first?.lifecycle, .stopped)
                XCTAssertEqual(try fixture.exactOwnership().fencingToken, inventory.containers.first?.ownership?.fencingToken)
            } else {
                XCTAssertTrue(inventory.containers.isEmpty)
            }
            try await LifecycleOwnershipFinalizer(store: fixture.store, adapter: effects.adapter)
                .finalize(context: fixture.context)
            if command == .remove {
                XCTAssertTrue(try fixture.store.ownership.loadAll().filter(\.cleanupEligible).isEmpty)
            }
        }
    }

    func testNativeNoEffectWithAnActualFenceHandoffKeepsTheExistingGroupProjection() async throws {
        let fixture = try nativeFenceFixture()
        defer { fixture.cleanup() }
        let helper = NativeFenceLifecycleHelper(fixture: fixture)
        await helper.ignoreNextMutation(rotatingFence: true)
        let effects = try nativeFenceEffects(fixture: fixture, helper: helper)
        guard case .accepted = await effects.apply(node: fixture.node, context: fixture.context),
              case .noEffect = await effects.observe(node: fixture.node, context: fixture.context) else {
            return XCTFail("A fence handoff alone must not claim Stop satisfied its postcondition.")
        }
        let native = try await helper.inventory()
        XCTAssertEqual(native.containers.first?.lifecycle, .running)
        XCTAssertEqual(native.containers.first?.ownership?.fencingToken, fixture.context.fencingToken)
        XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.context.fencingToken)
        let binding = await effects.state.binding(for: fixture.binding.identity)
        XCTAssertEqual(binding, fixture.binding)
    }

    func testNativeObservationRejectsStaleOperationAndExpiredOrMissingAuthority() async throws {
        for mismatch in ["operation", "group", "owner", "fence", "expired", "terminal", "missing-authority"] {
            let fixture = try nativeFenceFixture()
            defer { fixture.cleanup() }
            let helper = NativeFenceLifecycleHelper(fixture: fixture)
            let clock = ProbeLiveClock(milliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
            let effects = try nativeFenceEffects(
                fixture: fixture, helper: helper, nowMilliseconds: { clock.now() }
            )
            if mismatch == "missing-authority" {
                let legacy = try fixture.exactOwnership()
                XCTAssertNil(try OwnershipAuthorityMetadata.decode(from: legacy.metadataJSONRedacted))
                XCTAssertNotNil(try fixture.store.ownership.advanceFencingToken(
                    resourceIdentifier: legacy.resourceIdentifier, runtimeAdapter: legacy.runtimeAdapter,
                    expectedResourceUUID: legacy.resourceUUID, expectedFencingToken: legacy.fencingToken,
                    newFencingToken: fixture.context.fencingToken, observedAt: "2026-10-03T10:00:00Z"
                ))
                let unbound = try LifecycleResourceBinding(
                    record: fixture.exactOwnership(), identity: fixture.binding.identity, providerID: .appleContainerization
                )
                await helper.setOwnership(unbound.ownershipEvidence)
                await helper.setLifecycle(.stopped)
            } else {
                guard case .accepted = await effects.apply(node: fixture.node, context: fixture.context) else {
                    return XCTFail("The fixture must first complete Stop under the genuine current group.")
                }
            }
            if mismatch == "expired" { clock.set(milliseconds: 4_102_444_800_000) }
            if mismatch == "terminal" {
                try fixture.store.operationGroups.finish(
                    groupID: fixture.context.groupID, status: .failed,
                    checkpoint: "safe-hold", manualRecoveryHintRedacted: "",
                    updatedAt: "2026-10-03T10:00:00Z", metadataJSONRedacted: "{}"
                )
            }
            let wrongUUID = "99999999-9999-4999-8999-999999999999"
            let context = LifecycleSagaContext(
                plan: fixture.context.plan,
                operationID: mismatch == "operation" ? wrongUUID : fixture.context.operationID,
                groupID: mismatch == "group" ? wrongUUID : fixture.context.groupID,
                fencingToken: mismatch == "fence" ? wrongUUID : fixture.context.fencingToken,
                leaseOwner: mismatch == "owner" ? "unrelated-owner" : fixture.context.leaseOwner,
                attempt: 1
            )
            guard case .ambiguous = await effects.observe(node: fixture.node, context: context) else {
                return XCTFail("\(mismatch) must never authorize the new native fence.")
            }
            XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.context.fencingToken)
            let binding = await effects.state.binding(for: fixture.binding.identity)
            XCTAssertEqual(binding, fixture.binding)
        }
    }

    func testNativeObservationRejectsUnrelatedOwnershipAndUnplannedNode() async throws {
        for mismatch in ["uuid", "project", "resource-generation", "project-generation", "provider-generation", "fence", "node"] {
            let fixture = try nativeFenceFixture()
            defer { fixture.cleanup() }
            let helper = NativeFenceLifecycleHelper(fixture: fixture)
            let effects = try nativeFenceEffects(fixture: fixture, helper: helper)
            guard case .accepted = await effects.apply(node: fixture.node, context: fixture.context) else {
                return XCTFail("The genuine fenced Stop must precede tampered observation.")
            }
            let inventory = try await helper.inventory()
            let current = try XCTUnwrap(inventory.containers.first?.ownership)
            let wrongUUID = "99999999-9999-4999-8999-999999999999"
            if mismatch != "node" {
                await helper.setOwnership(RuntimeInventoryOwnershipEvidence(
                    resourceUUID: mismatch == "uuid" ? wrongUUID : current.resourceUUID,
                    projectUUID: mismatch == "project" ? wrongUUID : current.projectUUID,
                    resourceGeneration: mismatch == "resource-generation" ? 2 : current.resourceGeneration,
                    projectGeneration: mismatch == "project-generation" ? 2 : current.projectGeneration,
                    providerID: current.providerID,
                    providerGeneration: mismatch == "provider-generation" ? 2 : current.providerGeneration,
                    fencingToken: mismatch == "fence" ? wrongUUID : current.fencingToken
                ))
            }
            let node = mismatch == "node" ? try LifecyclePlanNode(
                key: fixture.node.key, action: .start, serviceName: fixture.node.serviceName,
                resourceIdentifier: fixture.node.resourceIdentifier, resourceUUID: fixture.node.resourceUUID,
                resourceGeneration: fixture.node.resourceGeneration, fencingToken: fixture.node.fencingToken
            ) : fixture.node
            guard case .ambiguous = await effects.observe(node: node, context: fixture.context) else {
                return XCTFail("\(mismatch) must not become a successful postcondition proof.")
            }
            XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.context.fencingToken)
        }
    }

    func testNativeCompensationAndRecoveryRetainExactPriorBinding() async throws {
        let fixture = try nativeFenceFixture()
        defer { fixture.cleanup() }
        let helper = NativeFenceLifecycleHelper(fixture: fixture)
        let effects = try nativeFenceEffects(fixture: fixture, helper: helper)
        guard case .accepted = await effects.apply(node: fixture.node, context: fixture.context) else {
            return XCTFail("The exact Stop must execute before recovery observation.")
        }
        let recoveredBinding = try LifecycleResourceBinding(
            record: fixture.exactOwnership(), identity: fixture.binding.identity, providerID: .appleContainerization
        )
        let recoveryState = LifecycleRuntimeExecutionState(
            projectID: fixture.context.plan.projectID, providerID: .appleContainerization,
            capabilitySHA256: fixture.context.plan.capabilitySHA256,
            desiredState: await effects.state.desiredStateSnapshot(),
            observedState: await effects.state.observedState,
            bindings: [recoveredBinding], desiredByNode: [fixture.node.key: probeLiveDesired()]
        )
        let recoveryEffects = LifecycleLiveEffects(
            adapter: effects.adapter, state: recoveryState, store: fixture.store,
            probeStore: fixture.probeStore, environment: .live,
            schedulerActivationValidator: { _ in }
        )
        guard case .satisfied = await recoveryEffects.observe(node: fixture.node, context: fixture.context) else {
            return XCTFail("Recovery must prove the exact stopped resource under its persisted current fence.")
        }
        let rollback = LifecycleSagaContext(
            plan: fixture.context.plan, operationID: fixture.context.operationID,
            groupID: fixture.context.groupID, fencingToken: fixture.context.fencingToken,
            leaseOwner: fixture.context.leaseOwner, attempt: 1, direction: .rollback
        )
        guard case .compensated = await effects.compensate(
            compensation: try XCTUnwrap(fixture.node.compensation), node: fixture.node, context: rollback
        ) else {
            return XCTFail("Only the configured inverse Start may compensate Stop under the original group.")
        }
        let binding = await effects.state.binding(for: fixture.binding.identity)
        XCTAssertEqual(binding, fixture.binding)
        let native = try await helper.inventory()
        XCTAssertEqual(native.containers.first?.lifecycle, .running)
        XCTAssertEqual(native.containers.first?.ownership?.fencingToken, try fixture.exactOwnership().fencingToken)
        XCTAssertEqual(try fixture.exactOwnership().fencingToken, fixture.context.fencingToken)
        let restored = try await effects.reconcileCompensatedOwnershipProjection(
            context: rollback, allowObservedRuntimeFence: false
        )
        XCTAssertEqual(restored, 0, "Restored lifecycle is not proof that the native prior fence was restored.")
        let unconfigured = try LifecyclePlanNode(
            key: fixture.node.key, action: .stop, serviceName: fixture.node.serviceName,
            resourceIdentifier: fixture.node.resourceIdentifier, resourceUUID: fixture.node.resourceUUID,
            resourceGeneration: fixture.node.resourceGeneration, fencingToken: fixture.node.fencingToken
        )
        guard case .ambiguous = await effects.observe(node: unconfigured, context: rollback) else {
            return XCTFail("An unconfigured inverse must not report compensation proof.")
        }
    }

    func testSDKCompletedHintsPreserveHistoricalRestartAndCurrentStartOnlyScopes() throws {
        for action in [LifecyclePlanAction.restart, .start] {
            let fixture = try nativeFenceFixture()
            defer { fixture.cleanup() }
            let node = try LifecyclePlanNode(
                key: "web-restart", action: action, serviceName: fixture.node.serviceName,
                resourceIdentifier: fixture.node.resourceIdentifier, resourceUUID: fixture.node.resourceUUID,
                resourceGeneration: fixture.node.resourceGeneration, fencingToken: fixture.node.fencingToken
            )
            let projectedFence = action == .restart ? node.fencingToken : fixture.context.fencingToken
            let completed = try nativeFenceCompletedHint(fixture: fixture, nodes: [node], fencingToken: projectedFence)
            let hint = try hostwrightAuthorizedSDKObservationHint(
                completed.hint, ownership: completed.ownership,
                group: completed.group, currentTimestamp: "2026-10-03T10:00:00Z"
            )
            XCTAssertEqual(hint.ownership, completed.hint.ownership)
            if action == .restart {
                XCTAssertEqual(hint.authorizedAlternateOwnership?.fencingToken, fixture.context.fencingToken)
                XCTAssertEqual(hint.authorizedAlternateOwnership?.resourceUUID, fixture.binding.resourceUUID)
            } else {
                XCTAssertNil(hint.authorizedAlternateOwnership)
            }
        }
    }

    func testSDKCompletedRestartHintsRejectMalformedPairsAndUnprovedProjections() throws {
        for mismatch in ["dependency", "extra-node", "node-fence", "generation", "service", "unproved-projection"] {
            let fixture = try nativeFenceFixture()
            defer { fixture.cleanup() }
            let originalStart = try XCTUnwrap(fixture.context.plan.nodes.first { $0.action == .start })
            let start = try LifecyclePlanNode(
                key: originalStart.key, action: originalStart.action,
                serviceName: mismatch == "service" ? "unrelated" : originalStart.serviceName,
                resourceIdentifier: originalStart.resourceIdentifier, resourceUUID: originalStart.resourceUUID,
                resourceGeneration: mismatch == "generation" ? 2 : originalStart.resourceGeneration,
                fencingToken: mismatch == "node-fence" ? "99999999-9999-4999-8999-999999999999" : originalStart.fencingToken,
                dependencies: mismatch == "dependency" ? [] : originalStart.dependencies,
                postconditions: originalStart.postconditions, timeoutSeconds: originalStart.timeoutSeconds
            )
            var nodes = [fixture.node, start]
            if mismatch == "extra-node" {
                nodes.append(try LifecyclePlanNode(
                    key: "web-extra", action: .restart, serviceName: fixture.node.serviceName,
                    resourceIdentifier: fixture.node.resourceIdentifier, resourceUUID: fixture.node.resourceUUID,
                    resourceGeneration: fixture.node.resourceGeneration, fencingToken: fixture.node.fencingToken
                ))
            }
            let completed = try nativeFenceCompletedHint(
                fixture: fixture, nodes: nodes,
                fencingToken: mismatch == "unproved-projection" ? fixture.node.fencingToken : fixture.context.fencingToken
            )
            XCTAssertThrowsError(try hostwrightAuthorizedSDKObservationHint(
                completed.hint, ownership: completed.ownership,
                group: completed.group, currentTimestamp: "2026-10-03T10:00:00Z"
            ), mismatch)
        }
    }

    func testCompensatingRestartRequiresSchedulerAuthority() async throws {
        let fixture = try ProbeLiveFixture(
            action: .stop,
            desired: probeLiveDesired(),
            postcondition: LifecyclePlanCondition(kind: "lifecycle", subject: "phase04/web", expectedValue: "stopped"),
            interactive: ProbeLiveInteractiveExecutor(outcomes: [])
        )
        defer { fixture.cleanup() }
        let effects = schedulerProtectedEffects(fixture)
        guard case .failed(let failure) = await effects.compensate(
            compensation: LifecycleCompensation(action: .restart),
            node: fixture.node,
            context: fixture.context
        ) else {
            return XCTFail("Compensation must require fresh admission before restarting a workload.")
        }
        XCTAssertTrue(failure.diagnostic.contains("scheduler-authority-unavailable"), failure.diagnostic)
        let actions = await fixture.adapter.executedActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testCompletionAwareStartRequiresSchedulerAuthority() async throws {
        let fixture = try ProbeLiveFixture(
            action: .start,
            desired: probeLiveDesired(),
            postcondition: LifecyclePlanCondition(kind: "lifecycle", subject: "phase04/web", expectedValue: "exited"),
            interactive: ProbeLiveInteractiveExecutor(outcomes: [])
        )
        defer { fixture.cleanup() }
        let effects = schedulerProtectedEffects(fixture)
        guard case .failed(let failure) = await effects.apply(node: fixture.node, context: fixture.context) else {
            return XCTFail("Completion-aware start must require fresh admission before starting a workload.")
        }
        XCTAssertTrue(failure.diagnostic.contains("scheduler-authority-unavailable"), failure.diagnostic)
        let actions = await fixture.adapter.executedActions()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(
            try fixture.store.operationGroupSteps.load(groupID: fixture.context.groupID)
                .filter { $0.plannedActionType == "completion-checkpoint" }.map(\.status),
            [.started, .unsupported]
        )
        guard case .noEffect = await effects.observe(node: fixture.node, context: fixture.context) else {
            return XCTFail("Rejected completion start must retain proof that execution did not begin.")
        }
    }

    func testLivenessRecoveryRequiresSchedulerAuthority() async throws {
        let interactive = ProbeLiveInteractiveExecutor(outcomes: [.failed, .succeeded])
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: probeLiveDesired(
                probes: RuntimeProbeSet(liveness: RuntimeProbeConfiguration(
                    action: .exec(RuntimeProbeExecAction(command: ["/usr/bin/alive"])),
                    intervalSeconds: 1, failureThreshold: 1
                )),
                restartPolicy: .onFailure
            ),
            postcondition: LifecyclePlanCondition(kind: "probe-liveness", subject: "phase04/web", expectedValue: "healthy"),
            interactive: interactive
        )
        defer { fixture.cleanup() }
        let effects = schedulerProtectedEffects(fixture)
        guard case .failed(let failure) = await effects.apply(node: fixture.node, context: fixture.context) else {
            return XCTFail("Liveness recovery must require fresh admission before restarting a workload.")
        }
        XCTAssertTrue(failure.diagnostic.contains("scheduler-authority-unavailable"), failure.diagnostic)
        let actions = await fixture.adapter.executedActions()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(interactive.snapshot().count, 1)
    }

    func testStableRolloutObservationReprobesUntilDurableWindowElapses() async throws {
        let clock = ProbeLiveClock(milliseconds: 1_000)
        let interactive = ProbeLiveInteractiveExecutor(
            outcomes: [.succeeded, .succeeded, .succeeded]
        )
        let desired = probeLiveDesired(
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                    ),
                    intervalSeconds: 1,
                    successThreshold: 1,
                    failureThreshold: 1
                )
            ),
            updatePolicy: RuntimeUpdatePolicy(
                progressDeadlineSeconds: 20,
                stableObservationSeconds: 2
            )
        )
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: desired,
            preconditions: [
                LifecyclePlanCondition(
                    kind: "stable-observation-seconds",
                    subject: "phase04/web",
                    expectedValue: "2"
                ),
                LifecyclePlanCondition(
                    kind: "progress-deadline-seconds",
                    subject: "web",
                    expectedValue: "20"
                )
            ],
            postcondition: LifecyclePlanCondition(
                kind: "probe-readiness",
                subject: "phase04/web",
                expectedValue: "stable"
            ),
            planCommand: .update,
            interactive: interactive,
            clock: clock
        )
        defer { fixture.cleanup() }

        let outcome = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        )
        XCTAssertEqual(outcome, .accepted)
        XCTAssertGreaterThanOrEqual(clock.now(), 3_000)
        XCTAssertEqual(interactive.snapshot().count, 3)
        let snapshot = try XCTUnwrap(
            fixture.probeStore.loadLatest(
                groupID: fixture.context.groupID,
                resourceIdentifier: fixture.binding.resourceIdentifier
            )
        )
        XCTAssertEqual(snapshot.stableSinceMilliseconds, 1_000)
    }

    func testPromotionRefusesMissingProbeProofBeforePriorRevisionCanRetire() async throws {
        let desired = probeLiveDesired(
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                    )
                )
            )
        )
        let fixture = try ProbeLiveFixture(
            action: .promote,
            desired: desired,
            preconditions: [
                LifecyclePlanCondition(
                    kind: "revision-healthy",
                    subject: "phase04/web",
                    expectedValue: "true"
                ),
                LifecyclePlanCondition(
                    kind: "progress-deadline-seconds",
                    subject: "web",
                    expectedValue: "20"
                )
            ],
            postcondition: LifecyclePlanCondition(
                kind: "revision-current",
                subject: "phase04/web",
                expectedValue: String(repeating: "a", count: 64)
            ),
            planCommand: .update,
            interactive: ProbeLiveInteractiveExecutor(outcomes: [])
        )
        defer { fixture.cleanup() }

        guard case .failed(let failure) = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        ) else {
            return XCTFail("Expected promotion without durable probe proof to fail.")
        }
        XCTAssertEqual(failure.category, .rejected)
        let actions = await fixture.adapter.executedActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testPromotionRecoveryRevalidatesProbeProofBeforeMarkingHealthy() async throws {
        let desired = probeLiveDesired(
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                    )
                )
            )
        )
        let fixture = try ProbeLiveFixture(
            action: .promote,
            desired: desired,
            preconditions: [
                LifecyclePlanCondition(
                    kind: "revision-healthy",
                    subject: "phase04/web",
                    expectedValue: "true"
                ),
                LifecyclePlanCondition(
                    kind: "progress-deadline-seconds",
                    subject: "web",
                    expectedValue: "20"
                )
            ],
            postcondition: LifecyclePlanCondition(
                kind: "revision-current",
                subject: "phase04/web",
                expectedValue: String(repeating: "a", count: 64)
            ),
            planCommand: .update,
            interactive: ProbeLiveInteractiveExecutor(outcomes: [])
        )
        defer { fixture.cleanup() }
        try fixture.probeStore.save(
            RuntimeProbeSnapshot(
                resourceIdentifier: fixture.binding.resourceIdentifier,
                startedAtMilliseconds: 1_000,
                states: [
                    RuntimeProbeState(
                        kind: .readiness,
                        phase: .failed,
                        isPassing: false,
                        consecutiveFailures: 1,
                        attemptCount: 1,
                        nextAttemptAtMilliseconds: 2_000,
                        lastAttemptAtMilliseconds: 1_000,
                        lastOutcome: .failed
                    )
                ]
            ),
            groupID: fixture.context.groupID,
            fencingToken: fixture.context.fencingToken,
            serviceName: "web",
            updatedAt: "2026-07-23T12:00:00Z"
        )

        guard case .noEffect = await fixture.effects.observe(
            node: fixture.node,
            context: fixture.context
        ) else {
            return XCTFail("Recovery must refuse promotion without current probe proof.")
        }
        XCTAssertFalse(
            try fixture.exactOwnership().metadataJSONRedacted.contains(
                #""healthy":true"#
            )
        )
    }

    func testPromotionRefusesStableWindowWithoutTerminalProbeSample() async throws {
        let desired = probeLiveDesired(
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                    ),
                    intervalSeconds: 5
                )
            ),
            updatePolicy: RuntimeUpdatePolicy(
                progressDeadlineSeconds: 20,
                stableObservationSeconds: 2
            )
        )
        let fixture = try ProbeLiveFixture(
            action: .promote,
            desired: desired,
            preconditions: [
                LifecyclePlanCondition(
                    kind: "revision-healthy",
                    subject: "phase04/web",
                    expectedValue: "true"
                ),
                LifecyclePlanCondition(
                    kind: "progress-deadline-seconds",
                    subject: "web",
                    expectedValue: "20"
                )
            ],
            postcondition: LifecyclePlanCondition(
                kind: "revision-current",
                subject: "phase04/web",
                expectedValue: String(repeating: "a", count: 64)
            ),
            planCommand: .update,
            interactive: ProbeLiveInteractiveExecutor(outcomes: []),
            clock: ProbeLiveClock(milliseconds: 4_000)
        )
        defer { fixture.cleanup() }
        try fixture.probeStore.save(
            RuntimeProbeSnapshot(
                resourceIdentifier: fixture.binding.resourceIdentifier,
                startedAtMilliseconds: 1_000,
                stableSinceMilliseconds: 1_000,
                states: [
                    RuntimeProbeState(
                        kind: .readiness,
                        phase: .succeeded,
                        isPassing: true,
                        consecutiveSuccesses: 1,
                        attemptCount: 1,
                        nextAttemptAtMilliseconds: 7_000,
                        lastAttemptAtMilliseconds: 2_000,
                        lastOutcome: .succeeded
                    )
                ]
            ),
            groupID: fixture.context.groupID,
            fencingToken: fixture.context.fencingToken,
            serviceName: "web",
            updatedAt: "2026-07-23T12:00:00Z"
        )

        guard case .failed(let failure) = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        ) else {
            return XCTFail("Promotion requires a terminal sample at the stable boundary.")
        }
        XCTAssertEqual(failure.category, .rejected)
    }

    func testUpdateReadinessDoesNotMarkCandidateHealthyBeforePromotion() async throws {
        let desired = probeLiveDesired(
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                    )
                )
            )
        )
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: desired,
            preconditions: [
                LifecyclePlanCondition(
                    kind: "progress-deadline-seconds",
                    subject: "web",
                    expectedValue: "20"
                )
            ],
            postcondition: LifecyclePlanCondition(
                kind: "probe-readiness",
                subject: "phase04/web",
                expectedValue: "healthy"
            ),
            planCommand: .update,
            interactive: ProbeLiveInteractiveExecutor(outcomes: [.succeeded])
        )
        defer { fixture.cleanup() }

        let applyOutcome = await fixture.effects.apply(
            node: fixture.node,
            context: fixture.context
        )
        XCTAssertEqual(applyOutcome, .accepted)
        guard case .satisfied = await fixture.effects.observe(
            node: fixture.node,
            context: fixture.context
        ) else {
            return XCTFail("Expected readiness proof to persist without promotion.")
        }
        XCTAssertFalse(
            try fixture.exactOwnership().metadataJSONRedacted.contains(
                #""healthy":true"#
            )
        )
    }

    func testStableRolloutStageResumesPersistedHealthWithoutDuplicateMutation() async throws {
        let clock = ProbeLiveClock(milliseconds: 2_500)
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
                    failureThreshold: 1
                )
            ),
            updatePolicy: RuntimeUpdatePolicy(
                progressDeadlineSeconds: 20,
                stableObservationSeconds: 2
            )
        )
        let fixture = try ProbeLiveFixture(
            action: .verify,
            desired: desired,
            preconditions: [
                LifecyclePlanCondition(
                    kind: "stable-observation-seconds",
                    subject: "phase04/web",
                    expectedValue: "2"
                ),
                LifecyclePlanCondition(
                    kind: "progress-deadline-seconds",
                    subject: "web",
                    expectedValue: "20"
                )
            ],
            postcondition: LifecyclePlanCondition(
                kind: "probe-readiness",
                subject: "phase04/web",
                expectedValue: "stable"
            ),
            planCommand: .update,
            interactive: interactive,
            clock: clock
        )
        defer { fixture.cleanup() }
        try fixture.probeStore.save(
            RuntimeProbeSnapshot(
                resourceIdentifier: fixture.binding.resourceIdentifier,
                startedAtMilliseconds: 1_000,
                stableSinceMilliseconds: 1_000,
                states: [
                    RuntimeProbeState(
                        kind: .readiness,
                        phase: .succeeded,
                        isPassing: true,
                        consecutiveSuccesses: 1,
                        attemptCount: 1,
                        nextAttemptAtMilliseconds: 2_000,
                        lastAttemptAtMilliseconds: 1_000,
                        lastOutcome: .succeeded
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
        XCTAssertEqual(interactive.snapshot().count, 2)
        let actions = await fixture.adapter.executedActions()
        XCTAssertTrue(actions.isEmpty)
        let persisted = try XCTUnwrap(
            fixture.probeStore.loadLatest(
                groupID: fixture.context.groupID,
                resourceIdentifier: fixture.binding.resourceIdentifier
            )
        )
        XCTAssertEqual(persisted.stableSinceMilliseconds, 1_000)
        XCTAssertEqual(persisted.state(for: .readiness)?.attemptCount, 3)
    }

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

private func schedulerProtectedEffects(_ fixture: ProbeLiveFixture) -> LifecycleLiveEffects {
    LifecycleLiveEffects(
        adapter: fixture.adapter,
        state: fixture.effects.state,
        store: fixture.store,
        probeStore: fixture.probeStore,
        environment: fixture.effects.environment,
        interactiveExecutor: fixture.effects.interactiveExecutor,
        probeNetworkClient: fixture.effects.probeNetworkClient,
        nowMilliseconds: fixture.effects.nowMilliseconds,
        sleepMilliseconds: fixture.effects.sleepMilliseconds
    )
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

    func set(milliseconds value: Int64) {
        lock.withLock { milliseconds = value }
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
        preconditions: [LifecyclePlanCondition] = [],
        postcondition: LifecyclePlanCondition,
        providerID: RuntimeProviderID = .appleContainerCLI,
        timeoutSeconds: Int = 20,
        planCommand: LifecycleCommand? = nil,
        nativeRestartPair: Bool = false,
        nativeFenceObservation: Bool = false,
        interactive: ProbeLiveInteractiveExecutor,
        clock: ProbeLiveClock = ProbeLiveClock()
    ) throws {
        let native = nativeRestartPair || nativeFenceObservation
        directory = native
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".hwnf-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true
            )
            : FileManager.default.temporaryDirectory.appendingPathComponent(
                "hostwright-probe-live-\(UUID().uuidString)", isDirectory: true
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
                version: 3,
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
        let nodeFence = "44444444-4444-4444-8444-444444444444"
        let operationFence = native
            ? "88888888-8888-4888-8888-888888888888" : nodeFence
        let leaseOwner = "probe-live-test"
        let leaseExpiresAt = "2099-01-01T00:00:00Z"
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

        let capability = native
            ? nativeFenceCapability() : probeLiveCapability(providerID: providerID)
        node = try LifecyclePlanNode(
            key: "web-\(action.rawValue.replacingOccurrences(of: "-", with: "_"))",
            action: action,
            serviceName: desired.identity.serviceName,
            resourceIdentifier: binding.resourceIdentifier,
            resourceUUID: binding.resourceUUID,
            resourceGeneration: binding.resourceGeneration,
            fencingToken: nodeFence,
            preconditions: preconditions,
            postconditions: [postcondition],
            timeoutSeconds: timeoutSeconds,
            compensation: native && action == .stop
                ? LifecycleCompensation(action: .start, timeoutSeconds: timeoutSeconds) : nil
        )
        let nodes: [LifecyclePlanNode]
        if nativeRestartPair {
            nodes = [node, try LifecyclePlanNode(
                key: "web-start", action: .start,
                serviceName: desired.identity.serviceName,
                resourceIdentifier: binding.resourceIdentifier,
                resourceUUID: binding.resourceUUID,
                resourceGeneration: binding.resourceGeneration,
                fencingToken: nodeFence,
                dependencies: [node.key],
                postconditions: [LifecyclePlanCondition(
                    kind: "lifecycle", subject: desired.identity.displayName, expectedValue: "running"
                )],
                timeoutSeconds: timeoutSeconds,
                compensation: LifecycleCompensation(action: .stop, timeoutSeconds: timeoutSeconds)
            )]
        } else {
            nodes = [node]
        }
        let plan = try LifecyclePlan(
            command: planCommand ?? (action == .restart ? .restart : .up),
            projectID: "project-phase04",
            projectName: desired.identity.projectName,
            projectResourceUUID: binding.projectResourceUUID,
            projectGeneration: binding.projectGeneration,
            providerID: providerID,
            providerGeneration: binding.providerGeneration,
            manifestSHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            capabilitySHA256: capability.canonicalSHA256,
            nodes: nodes
        )
        let groupID = "55555555-5555-4555-8555-555555555555"
        let operationID = "66666666-6666-4666-8666-666666666666"
        context = LifecycleSagaContext(
            plan: plan,
            operationID: operationID,
            groupID: groupID,
            fencingToken: operationFence,
            leaseOwner: leaseOwner,
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
                lockOwner: leaseOwner,
                lockExpiresAt: leaseExpiresAt,
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "",
                createdAt: "2026-07-23T12:00:00Z",
                updatedAt: "2026-07-23T12:00:00Z",
                metadataJSONRedacted: "{}",
                fencingToken: operationFence,
                intentJSONRedacted: providerID == .appleContainerization
                    ? try LifecyclePersistedIntentCodec.encode(plan) : try plan.canonicalJSON(),
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
            desiredByNode: Dictionary(uniqueKeysWithValues: nodes.map { ($0.key, desired) })
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
            schedulerActivationValidator: { _ in },
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
    updatePolicy: RuntimeUpdatePolicy = RuntimeUpdatePolicy(),
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
        updatePolicy: updatePolicy,
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

private func nativeFenceFixture(
    command: LifecycleCommand = .restart,
    action: LifecyclePlanAction = .stop
) throws -> ProbeLiveFixture {
    try ProbeLiveFixture(
        action: action, desired: probeLiveDesired(),
        postcondition: LifecyclePlanCondition(
            kind: "lifecycle", subject: "phase04/web", expectedValue: action == .delete ? "missing" : "stopped"
        ),
        providerID: .appleContainerization, planCommand: command,
        nativeRestartPair: command == .restart,
        nativeFenceObservation: true,
        interactive: ProbeLiveInteractiveExecutor(outcomes: [])
    )
}

private func nativeFenceCompletedHint(
    fixture: ProbeLiveFixture,
    nodes: [LifecyclePlanNode],
    fencingToken: String
) throws -> (hint: RuntimeOwnedResourceHint, ownership: OwnershipRecord, group: OperationGroupRecord) {
    let previous = fixture.context.plan
    let plan = try LifecyclePlan(
        command: .restart, projectID: previous.projectID, projectName: previous.projectName,
        projectResourceUUID: previous.projectResourceUUID, projectGeneration: previous.projectGeneration,
        providerID: previous.providerID, providerGeneration: previous.providerGeneration,
        manifestSHA256: previous.manifestSHA256, observationSHA256: previous.observationSHA256,
        capabilitySHA256: previous.capabilitySHA256, nodes: nodes
    )
    let group = OperationGroupRecord(
        id: fixture.context.groupID, operationID: fixture.context.operationID, groupKind: "lifecycle-v1",
        projectID: plan.projectID, serviceName: nil, plannedActionType: plan.command.rawValue,
        status: .succeeded, groupIdempotencyKey: plan.planSHA256, planHash: plan.planSHA256,
        checkpoint: "complete", lockOwner: nil, lockExpiresAt: nil,
        rollbackAvailable: true, manualRecoveryHintRedacted: "",
        createdAt: "2026-10-03T10:00:00Z", updatedAt: "2026-10-03T10:00:00Z",
        metadataJSONRedacted: "{}", fencingToken: fixture.context.fencingToken,
        intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(plan),
        compensationJSONRedacted: "[]", verificationJSONRedacted: "{}"
    )
    let record = try fixture.exactOwnership()
    func projecting(metadata: String) -> OwnershipRecord {
        OwnershipRecord(
            id: record.id, resourceIdentifier: record.resourceIdentifier,
            resourceType: record.resourceType, projectID: record.projectID,
            serviceName: record.serviceName, runtimeAdapter: record.runtimeAdapter,
            createdAt: record.createdAt, observedAt: record.observedAt,
            cleanupEligible: record.cleanupEligible, metadataJSONRedacted: metadata,
            identityVersion: record.identityVersion, resourceUUID: record.resourceUUID,
            resourceGeneration: record.resourceGeneration, projectResourceUUID: record.projectResourceUUID,
            projectGeneration: record.projectGeneration, providerGeneration: record.providerGeneration,
            fencingToken: fencingToken
        )
    }
    let projected = projecting(metadata: record.metadataJSONRedacted)
    let authority = try OwnershipAuthorityRecord.lifecycle(
        ownership: projected, operationGroup: group, finalizerState: .active, handoffGeneration: 1
    )
    let ownership = projecting(metadata: try OwnershipAuthorityMetadata.encode(authority, into: record.metadataJSONRedacted))
    let binding = try LifecycleResourceBinding(
        record: ownership, identity: fixture.binding.identity, providerID: .appleContainerization
    )
    let hint = RuntimeOwnedResourceHint(
        resourceIdentifier: binding.resourceIdentifier, identity: binding.identity,
        identityVersion: binding.identityVersion, ownership: binding.ownershipEvidence
    )
    return (hint, ownership, group)
}

private func nativeFenceNextOperation(
    fixture: ProbeLiveFixture,
    adapter: any RuntimeAdapter,
    observed: ObservedRuntimeState
) async throws -> (effects: LifecycleLiveEffects, context: LifecycleSagaContext) {
    let previous = fixture.context.plan
    let inventory = try await adapter.inventory()
    let plan = try LifecyclePlan(
        command: .restart, projectID: previous.projectID, projectName: previous.projectName,
        projectResourceUUID: previous.projectResourceUUID, projectGeneration: previous.projectGeneration,
        providerID: previous.providerID, providerGeneration: previous.providerGeneration,
        manifestSHA256: previous.manifestSHA256, observationSHA256: inventory.semanticSHA256,
        capabilitySHA256: previous.capabilitySHA256, nodes: previous.nodes
    )
    let context = LifecycleSagaContext(
        plan: plan, operationID: HostwrightResourceUUID.generate(),
        groupID: HostwrightResourceUUID.generate(), fencingToken: HostwrightResourceUUID.generate(),
        leaseOwner: "native-next-test", attempt: 1
    )
    let acquired = try fixture.store.operationGroups.acquire(OperationGroupRecord(
        id: context.groupID, operationID: context.operationID, groupKind: "lifecycle-v1",
        projectID: plan.projectID, serviceName: nil, plannedActionType: plan.command.rawValue,
        status: .active, groupIdempotencyKey: plan.planSHA256, planHash: plan.planSHA256,
        checkpoint: "intent-persisted", lockOwner: context.leaseOwner, lockExpiresAt: "2099-01-01T00:00:00Z",
        rollbackAvailable: true, manualRecoveryHintRedacted: "",
        createdAt: "2026-10-03T10:00:00Z", updatedAt: "2026-10-03T10:00:00Z",
        metadataJSONRedacted: "{}", fencingToken: context.fencingToken,
        intentJSONRedacted: LifecyclePersistedIntentCodec.encode(plan), compensationJSONRedacted: "[]", verificationJSONRedacted: "{}"
    ))
    guard acquired.acquired != nil else {
        throw StateStoreError.invalidRecord("The completed native lifecycle must release its operation group.")
    }
    let binding = try LifecycleResourceBinding(
        record: fixture.exactOwnership(), identity: fixture.binding.identity, providerID: plan.providerID
    )
    let state = LifecycleRuntimeExecutionState(
        projectID: plan.projectID, providerID: plan.providerID, capabilitySHA256: plan.capabilitySHA256,
        desiredState: DesiredRuntimeState(projectName: plan.projectName, services: [probeLiveDesired()]),
        observedState: observed, bindings: [binding],
        desiredByNode: Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.key, probeLiveDesired()) })
    )
    return (LifecycleLiveEffects(
        adapter: adapter, state: state, store: fixture.store, probeStore: fixture.probeStore,
        environment: .live, schedulerActivationValidator: { _ in }
    ), context)
}

private func nativeFenceEffects(
    fixture: ProbeLiveFixture,
    helper: NativeFenceLifecycleHelper,
    nowMilliseconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
) throws -> LifecycleLiveEffects {
    let executable = fixture.directory.appendingPathComponent("hostwright-containerization-helper")
    let configuration = fixture.directory.appendingPathComponent("containerization-helper.json")
    guard FileManager.default.createFile(
        atPath: executable.path, contents: Data("helper".utf8),
        attributes: [.posixPermissions: 0o700]
    ), FileManager.default.createFile(
        atPath: configuration.path, contents: Data("{}".utf8),
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let client = ContainerizationHelperClient(
        configuration: try ContainerizationHelperClientConfiguration(
            executableURL: executable,
            configurationURL: configuration,
            runtimeDirectoryURL: fixture.directory.appendingPathComponent("runtime"),
            launchTimeoutMilliseconds: 500,
            requestTimeoutMilliseconds: 2_000
        ),
        launcher: ContainerizationHelperProcessLauncher { _ in
            ContainerizationHelperProcessLease(processID: 7, isRunning: { true }, terminate: {})
        },
        transport: ContainerizationHelperClientTransport { frame, _, _, _ in
            try await helper.exchange(frame)
        }
    )
    return LifecycleLiveEffects(
        adapter: AppleContainerizationRuntimeAdapter(client: client),
        state: fixture.effects.state,
        store: fixture.store,
        probeStore: fixture.probeStore,
        environment: .live,
        schedulerActivationValidator: { _ in },
        nowMilliseconds: nowMilliseconds
    )
}

private func nativeFenceCapability() -> RuntimeCapabilitySnapshot {
    let implemented: Set<RuntimeProviderFeature> = [
        .observation, .lifecycle, .processControl, .images, .cancellation,
        .timeouts, .errors, .cleanup
    ]
    return RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: .appleContainerization,
            components: [
                RuntimeProviderComponent(
                    identifier: .appleContainerizationHelper,
                    version: "0.0.2", build: "test", fingerprint: String(repeating: "a", count: 64)
                ),
                RuntimeProviderComponent(
                    identifier: .containerizationHelperProtocolV1,
                    version: "1", build: "test", fingerprint: String(repeating: "b", count: 64)
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerizationFramework,
                    version: "0.35.0", build: "test", fingerprint: String(repeating: "c", count: 64)
                )
            ],
            minimumMacOSVersion: .init(major: 26), supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: .init(major: 26), macOSBuild: "test", architecture: .arm64
        ),
        features: RuntimeProviderFeature.knownValues.map { feature in
            implemented.contains(feature)
                ? RuntimeProviderFeatureStatus(
                    feature: feature, state: .experimental, reason: .qualificationIncomplete
                )
                : RuntimeProviderFeatureStatus(
                    feature: feature, state: .unavailable, reason: .notImplemented
                )
        }
    )
}

private actor NativeFenceLifecycleHelper {
    private struct RoutingEnvelope: Decodable {
        let operation: ContainerizationHelperOperation
    }

    private let binding: LifecycleResourceBinding
    private var operationID: String
    private let capability: RuntimeCapabilitySnapshot
    private var ownership: RuntimeInventoryOwnershipEvidence
    private var lifecycle: RuntimeInventoryLifecycleState = .running
    private var recordedMutations: [ContainerizationHelperOperation] = []
    private var ignoresNextMutation = false
    private var rotatesFenceOnIgnoredMutation = false

    init(fixture: ProbeLiveFixture) {
        binding = fixture.binding
        operationID = fixture.context.operationID
        capability = nativeFenceCapability()
        ownership = fixture.binding.ownershipEvidence
    }

    func mutations() -> [ContainerizationHelperOperation] { recordedMutations }
    func ignoreNextMutation(rotatingFence: Bool = false) {
        ignoresNextMutation = true
        rotatesFenceOnIgnoredMutation = rotatingFence
    }
    func setOwnership(_ value: RuntimeInventoryOwnershipEvidence) { ownership = value }
    func setLifecycle(_ value: RuntimeInventoryLifecycleState) { lifecycle = value }

    func inventory() throws -> RuntimeInventory {
        let context = RuntimeMutationContext(
            providerID: ownership.providerID,
            capabilitySHA256: capability.canonicalSHA256,
            operationID: operationID,
            resourceUUID: ownership.resourceUUID,
            resourceGeneration: ownership.resourceGeneration,
            projectResourceUUID: ownership.projectUUID,
            projectGeneration: ownership.projectGeneration,
            providerGeneration: ownership.providerGeneration,
            fencingToken: ownership.fencingToken
        )
        let labels = try RuntimeManagedResourceIdentity.labels(
            for: binding.identity, resourceIdentifier: binding.resourceIdentifier, context: context
        ).map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running, operatingSystem: "macOS", architecture: "arm64", runtimeVersion: "0.35.0",
                services: [RuntimeInventoryService(
                    identifier: "hostwright-containerization-helper", state: .running, required: true
                )]
            ),
            containers: lifecycle == .missing ? [] : [RuntimeInventoryContainer(
                runtimeID: binding.resourceIdentifier, name: binding.resourceIdentifier,
                imageReference: "local/phase04:latest", lifecycle: lifecycle,
                health: RuntimeInventoryHealth(availability: .unsupported),
                labels: labels, ownership: ownership,
                initConfiguration: RuntimeInventoryInitConfiguration(
                    executable: "/usr/bin/service", arguments: [], environment: []
                ),
                ports: [], mounts: [], networks: [], services: []
            )],
            images: [], networks: [], volumes: []
        )
    }

    func exchange(_ frame: Data) throws -> ContainerizationHelperTransportResponse {
        let payload = try ContainerizationHelperFraming.decodeSingleFrame(frame)
        let route = try JSONDecoder().decode(RoutingEnvelope.self, from: payload)
        switch route.operation {
        case .negotiate:
            let request = try ContainerizationHelperCanonicalJSON.decodeRequest(
                ContainerizationHelperEmptyPayload.self, from: payload
            )
            return try response(request, result: capability)
        case .observe:
            let request = try ContainerizationHelperCanonicalJSON.decodeRequest(
                ContainerizationHelperObservePayload.self, from: payload
            )
            return try response(request, result: ContainerizationHelperObservation(inventory: inventory()))
        case .logs:
            let request = try ContainerizationHelperCanonicalJSON.decodeRequest(
                ContainerizationHelperLogsRequest.self, from: payload
            )
            return try response(request, result: ContainerizationHelperLogs(
                resourceIdentifier: request.payload.resourceIdentifier,
                text: "native lifecycle output", lineLimit: request.payload.lineLimit
            ))
        case .stop, .start, .delete:
            let request = try ContainerizationHelperCanonicalJSON.decodeRequest(
                ContainerizationHelperMutationPayload.self, from: payload
            )
            guard let context = request.mutationContext,
                  request.payload.resourceIdentifier == binding.resourceIdentifier,
                  request.payload.resourceUUID == ownership.resourceUUID,
                  request.payload.expectedOwnership == ownership else {
                throw RuntimeAdapterError.outputParseFailed("Native test mutation lost exact prior ownership.")
            }
            recordedMutations.append(route.operation)
            if ignoresNextMutation {
                ignoresNextMutation = false
                if rotatesFenceOnIgnoredMutation {
                    adoptOwnership(context)
                    rotatesFenceOnIgnoredMutation = false
                }
                return try response(request, result: ContainerizationHelperMutationResult(
                    resourceIdentifier: binding.resourceIdentifier, lifecycle: lifecycle, verified: true
                ))
            }
            adoptOwnership(context)
            lifecycle = route.operation == .delete ? .missing : (route.operation == .stop ? .stopped : .running)
            return try response(request, result: ContainerizationHelperMutationResult(
                resourceIdentifier: binding.resourceIdentifier, lifecycle: lifecycle, verified: true
            ))
        default:
            throw RuntimeAdapterError.outputParseFailed("Unexpected native lifecycle test operation.")
        }
    }

    private func adoptOwnership(_ context: RuntimeMutationContext) {
        operationID = context.operationID
        ownership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: context.resourceUUID, projectUUID: context.projectResourceUUID,
            resourceGeneration: context.resourceGeneration, projectGeneration: context.projectGeneration,
            providerID: context.providerID, providerGeneration: context.providerGeneration,
            fencingToken: context.fencingToken
        )
    }

    private func response<Payload: Codable & Sendable, Result: Codable & Sendable>(
        _ request: ContainerizationHelperRequest<Payload>, result: Result
    ) throws -> ContainerizationHelperTransportResponse {
        let payload = try ContainerizationHelperCanonicalJSON.encode(ContainerizationHelperResultEnvelope(
            requestID: request.requestID, operation: request.operation, result: result
        ))
        return ContainerizationHelperTransportResponse(
            frame: try ContainerizationHelperFraming.frame(payload), peerProcessID: 7
        )
    }
}
