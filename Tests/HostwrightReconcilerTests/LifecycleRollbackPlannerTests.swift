import XCTest
@testable import HostwrightCore
@testable import HostwrightReconciler
@testable import HostwrightRuntime

final class LifecycleRollbackPlannerTests: XCTestCase {
    func testVerifiedHealthyRevisionRecordIsRedactedAndDigestBound() throws {
        let service = desired(
            image: "local/web@sha256:old",
            environment: [
                RuntimeEnvironmentValue(
                    name: "API_TOKEN",
                    value: "plain-secret",
                    isSensitive: true
                )
            ]
        )
        let record = try healthyRecord(for: service)

        XCTAssertFalse(record.desiredSpecificationJSONRedacted.contains("plain-secret"))
        XCTAssertTrue(record.desiredSpecificationJSONRedacted.contains("[REDACTED]"))
        XCTAssertEqual(
            record.revisionSHA256,
            try LifecycleRevisionCodec.revisionSHA256(for: service)
        )
        XCTAssertEqual(record.identity, service.identity)
    }

    func testAutomaticAndManualRollbackNeverRecreateRedactedSensitiveRevision() throws {
        let secret = "prior-secret-value"
        let fixture = try makeFixture(
            healthyEnvironment: [
                RuntimeEnvironmentValue(
                    name: "API_TOKEN",
                    value: secret,
                    isSensitive: true
                )
            ]
        )
        let completed = Set(fixture.plan.nodes.map(\.idempotencyKey))
        let recreateEffect = try XCTUnwrap(
            fixture.plan.nodes.first {
                $0.compensation?.action == .create
            }
        )

        for request in [
            LifecycleRecoveryRequest.automatic,
            .rollback
        ] {
            let decision = try LifecycleRollbackPlanner().decide(
                updatePlan: fixture.plan,
                healthyRevisions: [fixture.healthy],
                proof: proof(for: fixture.plan, completed: completed),
                context: LifecycleRollbackRequestContext(
                    request: request,
                    failure: .readiness,
                    completedUpdateNodeIdempotencyKeys: completed
                )
            )

            guard case .safeHold(let hold) = decision else {
                return XCTFail(
                    "\(request) must not recreate a revision from redacted secrets."
                )
            }
            XCTAssertTrue(hold.reason.contains(recreateEffect.key))
            XCTAssertTrue(hold.reason.contains("cannot be reconstructed exactly"))
            XCTAssertFalse(hold.reason.contains(secret))
            XCTAssertFalse(hold.reason.contains("[REDACTED]"))
            XCTAssertEqual(
                hold.operatorCommands,
                [
                    "hostwright inspect --output json",
                    "hostwright recovery --output json",
                    "hostwright update --dry-run"
                ]
            )
            XCTAssertTrue(
                hold.operatorCommands.allSatisfy {
                    !$0.contains(secret) && !$0.contains("[REDACTED]")
                }
            )
        }
    }

    func testAutomaticStartupFailureBuildsExactReverseCompensations() throws {
        let fixture = try makeFixture()
        let completed = Set(fixture.plan.nodes.map(\.idempotencyKey))
        let decision = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: proof(for: fixture.plan, completed: completed),
            context: LifecycleRollbackRequestContext(
                request: .automatic,
                failure: .startup,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )

        guard case .rollback(let rollback, let resume) = decision else {
            return XCTFail("Expected exact automatic rollback.")
        }
        let effected = fixture.plan.nodes.filter {
            completed.contains($0.idempotencyKey) && $0.action.mutatesRuntime
        }
        XCTAssertEqual(rollback.nodes.count, effected.count)
        XCTAssertEqual(resume.pendingNodes, rollback.nodes)
        XCTAssertTrue(resume.satisfiedNodeKeys.isEmpty)
        XCTAssertEqual(
            rollback.restoredRevisionSHA256ByIdentity[fixture.healthy.identity.displayName],
            fixture.healthy.revisionSHA256
        )
        XCTAssertEqual(
            rollback.nodes.first?.action,
            effected.last?.compensation?.action
        )
        XCTAssertEqual(
            rollback.nodes.last?.action,
            effected.first?.compensation?.action
        )
        for (index, node) in rollback.nodes.enumerated() {
            XCTAssertEqual(
                node.dependencies,
                index == 0 ? [] : [rollback.nodes[index - 1].key]
            )
        }
    }

    func testAmbiguousRuntimeEffectEntersSafeHoldWithoutRollback() throws {
        let fixture = try makeFixture()
        let completed = Set(fixture.plan.nodes.prefix(4).map(\.idempotencyKey))
        let exact = proof(for: fixture.plan, completed: completed)
        let decision = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: LifecycleRollbackProof(
                certainty: .ambiguous,
                exactlyOwnedResourceUUIDs: exact.exactlyOwnedResourceUUIDs,
                exactlyInvertibleNodeIdempotencyKeys:
                    exact.exactlyInvertibleNodeIdempotencyKeys
            ),
            context: LifecycleRollbackRequestContext(
                request: .automatic,
                failure: .runtime,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )

        guard case .safeHold(let hold) = decision else {
            return XCTFail("Ambiguous effects must enter safe hold.")
        }
        XCTAssertTrue(hold.reason.contains("ambiguous"))
        XCTAssertFalse(hold.operatorCommands.isEmpty)
        XCTAssertTrue(hold.operatorCommands.allSatisfy { !$0.contains("secret") })
    }

    func testCompletedHookIsIrreversibleAndEntersSafeHold() throws {
        let fixture = try makeFixture(
            hooks: RuntimeLifecycleHooks(postStart: ["/bin/configure"])
        )
        let hookIndex = try XCTUnwrap(
            fixture.plan.nodes.firstIndex { $0.action == .runHook }
        )
        let completed = Set(
            fixture.plan.nodes.prefix(through: hookIndex).map(\.idempotencyKey)
        )
        let decision = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: proof(for: fixture.plan, completed: completed),
            context: LifecycleRollbackRequestContext(
                request: .rollback,
                failure: .readiness,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )

        guard case .safeHold(let hold) = decision else {
            return XCTFail("Completed hooks cannot be automatically inverted.")
        }
        XCTAssertTrue(hold.reason.contains("Hook"))
    }

    func testMissingOwnershipOrInverseProofEntersSafeHold() throws {
        let fixture = try makeFixture()
        let mutating = try XCTUnwrap(
            fixture.plan.nodes.first { $0.action.mutatesRuntime }
        )
        let completed: Set<String> = [mutating.idempotencyKey]

        let missingOwnership = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: LifecycleRollbackProof(
                certainty: .exact,
                exactlyOwnedResourceUUIDs: [],
                exactlyInvertibleNodeIdempotencyKeys: completed
            ),
            context: LifecycleRollbackRequestContext(
                request: .rollback,
                failure: .sqlite,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )
        guard case .safeHold(let ownershipHold) = missingOwnership else {
            return XCTFail("Missing ownership must enter safe hold.")
        }
        XCTAssertTrue(ownershipHold.reason.contains("ownership"))

        let missingInverse = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: LifecycleRollbackProof(
                certainty: .exact,
                exactlyOwnedResourceUUIDs: [mutating.resourceUUID],
                exactlyInvertibleNodeIdempotencyKeys: []
            ),
            context: LifecycleRollbackRequestContext(
                request: .rollback,
                failure: .sqlite,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )
        guard case .safeHold(let inverseHold) = missingInverse else {
            return XCTFail("Missing inverse must enter safe hold.")
        }
        XCTAssertTrue(inverseHold.reason.contains("inverse"))
    }

    func testRecreateInverseRequiresTheExactVerifiedHealthyResource() throws {
        let fixture = try makeFixture()
        let completed = Set(fixture.plan.nodes.map(\.idempotencyKey))
        let previous = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(
            fixture.healthy.desiredSpecificationJSONRedacted
        )
        let wrongHealthyResource = try LifecycleHealthyRevisionRecord(
            service: previous,
            resourceIdentifier: "hostwright-demo-web-different",
            resourceUUID: HostwrightResourceUUID.legacy(
                kind: "service-revision",
                identifier: "demo/web:different"
            ),
            resourceGeneration: fixture.healthy.resourceGeneration,
            readinessVerified: true,
            ownershipVerified: true
        )

        let decision = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [wrongHealthyResource],
            proof: proof(for: fixture.plan, completed: completed),
            context: LifecycleRollbackRequestContext(
                request: .automatic,
                failure: .runtime,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )

        guard case .safeHold(let hold) = decision else {
            return XCTFail("A different healthy resource must not satisfy exact rollback.")
        }
        XCTAssertTrue(hold.reason.contains("exact verified healthy revision"))
        XCTAssertFalse(hold.affectedNodeKeys.isEmpty)
    }

    func testProcessTerminationResumesFromDurableUpdateCheckpoint() throws {
        let fixture = try makeFixture()
        let completed = Set(fixture.plan.nodes.prefix(3).map(\.idempotencyKey))
        let decision = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: proof(for: fixture.plan, completed: completed),
            context: LifecycleRollbackRequestContext(
                request: .automatic,
                failure: .processTermination,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )

        guard case .resume(let resumed) = decision else {
            return XCTFail("Process termination should resume the durable update plan.")
        }
        XCTAssertEqual(resumed.satisfiedNodeKeys, fixture.plan.nodes.prefix(3).map(\.key).sorted())
        XCTAssertEqual(
            resumed.pendingNodes.map(\.idempotencyKey),
            Array(fixture.plan.nodes.dropFirst(3)).map(\.idempotencyKey)
        )
    }

    func testAutomaticFailureBeforeAnyMutationResumesWithoutRollback() throws {
        let fixture = try makeFixture()
        let prepare = try XCTUnwrap(
            fixture.plan.nodes.first { !$0.action.mutatesRuntime }
        )
        let decision = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: LifecycleRollbackProof(
                certainty: .exact,
                exactlyOwnedResourceUUIDs: [],
                exactlyInvertibleNodeIdempotencyKeys: []
            ),
            context: LifecycleRollbackRequestContext(
                request: .automatic,
                failure: .sqlite,
                completedUpdateNodeIdempotencyKeys: [prepare.idempotencyKey]
            )
        )

        guard case .resume(let resume) = decision else {
            return XCTFail("A failure before runtime mutation should resume, not roll back.")
        }
        XCTAssertTrue(resume.satisfiedNodeKeys.contains(prepare.key))
    }

    func testRollbackCanResumeAfterInterruptionAtEveryCheckpoint() throws {
        let fixture = try makeFixture()
        let completed = Set(fixture.plan.nodes.map(\.idempotencyKey))
        let initial = try LifecycleRollbackPlanner().decide(
            updatePlan: fixture.plan,
            healthyRevisions: [fixture.healthy],
            proof: proof(for: fixture.plan, completed: completed),
            context: LifecycleRollbackRequestContext(
                request: .rollback,
                failure: .runtime,
                completedUpdateNodeIdempotencyKeys: completed
            )
        )
        guard case .rollback(let rollback, _) = initial else {
            return XCTFail("Expected rollback plan.")
        }

        for checkpoint in 0...rollback.nodes.count {
            let completedRollback = Set(
                rollback.nodes.prefix(checkpoint).map(\.idempotencyKey)
            )
            let resumedDecision = try LifecycleRollbackPlanner().decide(
                updatePlan: fixture.plan,
                healthyRevisions: [fixture.healthy],
                proof: proof(for: fixture.plan, completed: completed),
                context: LifecycleRollbackRequestContext(
                    request: .rollback,
                    failure: .runtime,
                    completedUpdateNodeIdempotencyKeys: completed,
                    completedRollbackNodeIdempotencyKeys: completedRollback
                )
            )
            guard case .rollback(let rebuilt, let resume) = resumedDecision else {
                return XCTFail("Expected rollback at checkpoint \(checkpoint).")
            }
            XCTAssertEqual(rebuilt, rollback)
            XCTAssertEqual(resume.satisfiedNodeKeys.count, checkpoint)
            XCTAssertEqual(resume.pendingNodes.count, rollback.nodes.count - checkpoint)
            XCTAssertTrue(
                resume.pendingNodes.allSatisfy {
                    !completedRollback.contains($0.idempotencyKey)
                }
            )
        }
    }

    func testFailureKindsChooseRollbackWithoutInventingNewEffects() throws {
        let fixture = try makeFixture()
        let completed = Set(fixture.plan.nodes.map(\.idempotencyKey))

        for failure in [
            LifecycleRolloutFailureKind.startup,
            .readiness,
            .runtime,
            .sqlite,
            .cancellation
        ] {
            let decision = try LifecycleRollbackPlanner().decide(
                updatePlan: fixture.plan,
                healthyRevisions: [fixture.healthy],
                proof: proof(for: fixture.plan, completed: completed),
                context: LifecycleRollbackRequestContext(
                    request: .automatic,
                    failure: failure,
                    completedUpdateNodeIdempotencyKeys: completed
                )
            )
            guard case .rollback = decision else {
                return XCTFail("\(failure) should roll back proven effects.")
            }
        }
    }

    func testUnknownEffectCheckpointIsRejected() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(
            try LifecycleRollbackPlanner().decide(
                updatePlan: fixture.plan,
                healthyRevisions: [fixture.healthy],
                proof: LifecycleRollbackProof(
                    certainty: .exact,
                    exactlyOwnedResourceUUIDs: [],
                    exactlyInvertibleNodeIdempotencyKeys: []
                ),
                context: LifecycleRollbackRequestContext(
                    request: .resume,
                    failure: .processTermination,
                    completedUpdateNodeIdempotencyKeys: ["not-a-real-node"]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LifecycleRollbackPlanningError,
                .invalidEffectReference("not-a-real-node")
            )
        }
    }

    private struct Fixture {
        let plan: LifecycleUpdatePlan
        let healthy: LifecycleHealthyRevisionRecord
    }

    private func makeFixture(
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks(),
        healthyEnvironment: [RuntimeEnvironmentValue] = []
    ) throws -> Fixture {
        let old = desired(
            image: "local/web@sha256:old",
            environment: healthyEnvironment
        )
        let new = desired(image: "local/web@sha256:new", hooks: hooks)
        let resource = updateResource(for: new)
        let plan = try LifecycleUpdatePlanner().plan(
            previous: DesiredRuntimeState(projectName: "demo", services: [old]),
            desired: DesiredRuntimeState(projectName: "demo", services: [new]),
            resources: [new.identity: resource],
            fencingToken: HostwrightResourceUUID.legacy(
                kind: "update-fence",
                identifier: "rollback-tests"
            )
        )
        return Fixture(
            plan: plan,
            healthy: try LifecycleHealthyRevisionRecord(
                service: old,
                resourceIdentifier: resource.currentResourceIdentifier,
                resourceUUID: resource.currentResourceUUID,
                resourceGeneration: resource.currentGeneration,
                readinessVerified: true,
                ownershipVerified: true
            )
        )
    }

    private func desired(
        image: String,
        environment: [RuntimeEnvironmentValue] = [],
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks()
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "web"
            ),
            image: image,
            environment: environment,
            probes: RuntimeProbeSet(
                startup: RuntimeProbeConfiguration(
                    action: .exec(RuntimeProbeExecAction(command: ["/bin/startup"]))
                ),
                readiness: RuntimeProbeConfiguration(
                    action: .exec(RuntimeProbeExecAction(command: ["/bin/ready"]))
                )
            ),
            updatePolicy: RuntimeUpdatePolicy(
                strategy: .rolling,
                maxSurge: 1,
                maxUnavailable: 0,
                progressDeadlineSeconds: 120
            ),
            hooks: hooks,
            virtualization: false
        )
    }

    private func updateResource(
        for service: DesiredRuntimeService
    ) -> LifecycleUpdateResourceIdentity {
        LifecycleUpdateResourceIdentity(
            identity: service.identity,
            currentResourceIdentifier: "hostwright-demo-web-old",
            currentResourceUUID: HostwrightResourceUUID.legacy(
                kind: "service-revision",
                identifier: "\(service.identity.displayName):old"
            ),
            currentGeneration: 1,
            candidateResourceIdentifier: "hostwright-demo-web-candidate",
            candidateResourceUUID: HostwrightResourceUUID.legacy(
                kind: "service-revision",
                identifier: "\(service.identity.displayName):candidate"
            ),
            candidateGeneration: 2
        )
    }

    private func healthyRecord(
        for service: DesiredRuntimeService
    ) throws -> LifecycleHealthyRevisionRecord {
        let resource = updateResource(for: service)
        return try LifecycleHealthyRevisionRecord(
            service: service,
            resourceIdentifier: resource.currentResourceIdentifier,
            resourceUUID: resource.currentResourceUUID,
            resourceGeneration: resource.currentGeneration,
            readinessVerified: true,
            ownershipVerified: true
        )
    }

    private func proof(
        for plan: LifecycleUpdatePlan,
        completed: Set<String>
    ) -> LifecycleRollbackProof {
        let mutating = plan.nodes.filter {
            completed.contains($0.idempotencyKey) && $0.action.mutatesRuntime
        }
        return LifecycleRollbackProof(
            certainty: .exact,
            exactlyOwnedResourceUUIDs: Set(mutating.map(\.resourceUUID)),
            exactlyInvertibleNodeIdempotencyKeys:
                Set(mutating.map(\.idempotencyKey))
        )
    }
}
