import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class RuntimeProviderMigrationTests: XCTestCase {
    func testDryRunIsDeterministicAndContainsExactEffectsAndRollback() async throws {
        let fixture = try MigrationFixture()
        let first = try await fixture.engine.dryRun(
            request: fixture.request,
            source: fixture.source,
            target: fixture.target
        )
        let second = try await fixture.engine.dryRun(
            request: fixture.request,
            source: fixture.source,
            target: fixture.target
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.confirmationToken.hasPrefix(RuntimeProviderMigrationPlan.confirmationPrefix))
        XCTAssertEqual(first.confirmationToken.count, RuntimeProviderMigrationPlan.confirmationPrefix.count + 64)
        XCTAssertEqual(first.sourceObservationSHA256.count, 64)
        XCTAssertEqual(first.targetObservationSHA256.count, 64)
        XCTAssertEqual(first.targetProviderGeneration, 2)
        XCTAssertEqual(first.resources.map(\.resourceUUID), [fixture.resourceUUID])
        XCTAssertEqual(first.requiredLocalImages.map(\.reference), [fixture.imageReference])
        XCTAssertEqual(first.plannedEffects.map(\.kind), [
            .quiesceSource,
            .createTarget,
            .restoreTargetRunningState,
            .commitProviderBinding,
            .retireSource
        ])
        XCTAssertEqual(first.rollbackActions.map(\.kind), [
            .removeVerifiedTarget,
            .restoreSourceRunningState
        ])

        let encoded = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeProviderMigrationPlan.self, from: encoded), first)
    }

    func testDryRunRejectsActiveWorkStaleCapabilitiesOwnershipCollisionAndMissingImages() async throws {
        let fixture = try MigrationFixture()
        let active = fixture.request(activeOperationIDs: ["operation-active"])
        await assertMigrationError(.activeOperations(["operation-active"])) {
            _ = try await fixture.engine.dryRun(
                request: active,
                source: fixture.source,
                target: fixture.target
            )
        }

        let stale = fixture.request(
            expectedSourceCapabilitySHA256: String(repeating: "0", count: 64)
        )
        do {
            _ = try await fixture.engine.dryRun(
                request: stale,
                source: fixture.source,
                target: fixture.target
            )
            XCTFail("Expected stale capability rejection.")
        } catch let error as RuntimeProviderMigrationError {
            guard case .staleCapability(let providerID, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, .appleContainerCLI)
        }

        let collisionTarget = MigrationTestAdapter(
            providerID: .appleContainerization,
            snapshot: fixture.targetSnapshot,
            resources: [
                MigrationTestResource(
                    desiredService: fixture.service,
                    ownership: nil,
                    lifecycle: .stopped,
                    runtimeID: "unmanaged-collision"
                )
            ],
            localImages: [fixture.imageReference: fixture.imageEvidence]
        )
        await assertMigrationError(.targetCollision(fixture.service.identity.managedResourceIdentifier)) {
            _ = try await fixture.engine.dryRun(
                request: fixture.request,
                source: fixture.source,
                target: collisionTarget
            )
        }

        let ambiguousSource = MigrationTestAdapter(
            providerID: .appleContainerCLI,
            snapshot: fixture.sourceSnapshot,
            resources: [
                MigrationTestResource(
                    desiredService: fixture.service,
                    ownership: nil,
                    lifecycle: .running,
                    runtimeID: "unmanaged-source-collision"
                )
            ],
            localImages: [:]
        )
        await assertMigrationError(.ambiguousOwnership(fixture.service.identity.managedResourceIdentifier)) {
            _ = try await fixture.engine.dryRun(
                request: fixture.request,
                source: ambiguousSource,
                target: fixture.target
            )
        }

        let missingImageTarget = MigrationTestAdapter(
            providerID: .appleContainerization,
            snapshot: fixture.targetSnapshot,
            resources: [],
            localImages: [:]
        )
        await assertMigrationError(.missingLocalImage(fixture.imageReference)) {
            _ = try await fixture.engine.dryRun(
                request: fixture.request,
                source: fixture.source,
                target: missingImageTarget
            )
        }

        let capabilityGapTarget = MigrationTestAdapter(
            providerID: .appleContainerization,
            snapshot: migrationSnapshot(
                providerID: .appleContainerization,
                unavailableFeature: .cleanup
            ),
            resources: [],
            localImages: [fixture.imageReference: fixture.imageEvidence]
        )
        do {
            _ = try await fixture.engine.dryRun(
                request: fixture.request,
                source: fixture.source,
                target: capabilityGapTarget
            )
            XCTFail("Expected target capability-gap rejection.")
        } catch let error as RuntimeProviderMigrationError {
            guard case .incompatibleProvider(let providerID, let findings) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, .appleContainerization)
            XCTAssertTrue(findings.contains {
                $0.feature == .cleanup && $0.reason == .featureUnavailable
            })
        }
    }

    func testDryRunRejectsUnsupportedTargetCreateSubsetBeforeJournalOrRuntimeMutation() async throws {
        let identity = RuntimeServiceIdentity(projectName: "sample", serviceName: "api")
        let unsupportedTargetService = DesiredRuntimeService(
            identity: identity,
            image: "registry.example/api:1.0.0",
            ports: [RuntimePortMapping(hostPort: 8_080, containerPort: 80)]
        )
        let fixture = try MigrationFixture(desiredService: unsupportedTargetService)

        await assertMigrationError(
            .unsupportedOwnedResource(identity.managedResourceIdentifier)
        ) {
            _ = try await fixture.engine.dryRun(
                request: fixture.request,
                source: fixture.source,
                target: fixture.target
            )
        }

        let sourceMutationKinds = await fixture.source.mutationKinds
        let targetMutationKinds = await fixture.target.mutationKinds
        let journalIntent = await fixture.journal.intent
        XCTAssertEqual(sourceMutationKinds, [])
        XCTAssertEqual(targetMutationKinds, [])
        XCTAssertNil(journalIntent)
    }

    func testDryRunDoesNotRequireTargetNetworksForAppleRuntimeDefaultAttachment() async throws {
        let fixture = try MigrationFixture(
            sourceNetworks: [
                RuntimeInventoryNetworkAttachment(
                    networkID: "default",
                    interfaceName: "eth0",
                    addresses: ["192.0.2.2"]
                )
            ],
            targetUnavailableFeature: .networks
        )

        let plan = try await fixture.engine.dryRun(
            request: fixture.request,
            source: fixture.source,
            target: fixture.target
        )

        XCTAssertEqual(plan.resources.map(\.resourceUUID), [fixture.resourceUUID])
        XCTAssertEqual(plan.targetProviderID, .appleContainerization)
    }

    func testDecodedPlanTamperingInvalidatesConfirmationBeforeJournalOrRuntimeMutation() async throws {
        let fixture = try MigrationFixture()
        let plan = try await fixture.plan()
        let encoded = try JSONEncoder().encode(plan)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["sourceObservationSHA256"] = String(repeating: "0", count: 64)
        let tampered = try JSONDecoder().decode(
            RuntimeProviderMigrationPlan.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        await assertMigrationError(.planChanged) {
            _ = try await fixture.engine.execute(
                plan: tampered,
                request: fixture.request,
                confirmationToken: tampered.confirmationToken,
                operationID: "migration-operation",
                fencingToken: "33333333-3333-4333-8333-333333333333",
                source: fixture.source,
                target: fixture.target
            )
        }
        let sourceMutationKinds = await fixture.source.mutationKinds
        let targetMutationKinds = await fixture.target.mutationKinds
        let journalIntent = await fixture.journal.intent
        XCTAssertEqual(sourceMutationKinds, [])
        XCTAssertEqual(targetMutationKinds, [])
        XCTAssertNil(journalIntent)
    }

    func testMigrationQuiescesCreatesVerifiesRestoresAndAtomicallyCommitsBinding() async throws {
        let fixture = try MigrationFixture()
        let plan = try await fixture.plan()
        let operationID = "migration-operation"
        let fence = "33333333-3333-4333-8333-333333333333"

        let result = try await fixture.engine.execute(
            plan: plan,
            request: fixture.request,
            confirmationToken: plan.confirmationToken,
            operationID: operationID,
            fencingToken: fence,
            source: fixture.source,
            target: fixture.target
        )

        XCTAssertEqual(result.providerID, .appleContainerization)
        XCTAssertEqual(result.providerGeneration, 2)
        XCTAssertEqual(result.checkpoint, .sourceRetired)
        XCTAssertFalse(result.resumed)
        let sourceLifecycle = await fixture.source.lifecycle(resourceUUID: fixture.resourceUUID)
        let targetLifecycle = await fixture.target.lifecycle(resourceUUID: fixture.resourceUUID)
        XCTAssertNil(sourceLifecycle)
        XCTAssertEqual(targetLifecycle, .running)
        let targetOwnership = await fixture.target.ownership(resourceUUID: fixture.resourceUUID)
        XCTAssertEqual(targetOwnership?.resourceUUID, fixture.resourceUUID)
        XCTAssertEqual(targetOwnership?.providerID, .appleContainerization)
        XCTAssertEqual(targetOwnership?.providerGeneration, 2)
        XCTAssertEqual(targetOwnership?.fencingToken, fence)
        let terminalStatus = await fixture.journal.terminalStatus
        let commit = await fixture.journal.commit
        let journalCheckpoint = await fixture.journal.checkpoint
        let maximumConcurrentMutations = await fixture.probe.maximumConcurrentMutations
        XCTAssertEqual(terminalStatus, .succeeded)
        XCTAssertEqual(commit?.targetProviderID, .appleContainerization)
        XCTAssertEqual(journalCheckpoint, .sourceRetired)
        XCTAssertEqual(maximumConcurrentMutations, 1)

        let sourceContexts = await fixture.source.mutationContexts
        let targetContexts = await fixture.target.mutationContexts
        XCTAssertTrue(sourceContexts.allSatisfy {
            $0.providerID == .appleContainerCLI && $0.providerGeneration == 1
        })
        XCTAssertTrue(targetContexts.allSatisfy {
            $0.providerID == .appleContainerization && $0.providerGeneration == 2
        })
    }

    func testExecuteAcceptsUsageOnlyObservationChangeAndStillRejectsLifecycleDrift() async throws {
        let usageFixture = try MigrationFixture(sourceUsageCounter: 1)
        let usagePlan = try await usageFixture.plan()
        let usageResult = try await usageFixture.engine.execute(
            plan: usagePlan,
            request: usageFixture.request,
            confirmationToken: usagePlan.confirmationToken,
            operationID: "usage-only-migration",
            fencingToken: "33333333-3333-4333-8333-333333333333",
            source: usageFixture.source,
            target: usageFixture.target
        )
        XCTAssertEqual(usageResult.checkpoint, .sourceRetired)

        let driftFixture = try MigrationFixture()
        let driftPlan = try await driftFixture.plan()
        await driftFixture.source.setLifecycle(.stopped, resourceUUID: driftFixture.resourceUUID)
        do {
            _ = try await driftFixture.engine.execute(
                plan: driftPlan,
                request: driftFixture.request,
                confirmationToken: driftPlan.confirmationToken,
                operationID: "lifecycle-drift-migration",
                fencingToken: "44444444-4444-4444-8444-444444444444",
                source: driftFixture.source,
                target: driftFixture.target
            )
            XCTFail("Expected lifecycle drift to invalidate the observation.")
        } catch let error as RuntimeProviderMigrationError {
            guard case .observationChanged(let providerID, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, .appleContainerCLI)
        }
        let sourceMutationKinds = await driftFixture.source.mutationKinds
        let targetMutationKinds = await driftFixture.target.mutationKinds
        let terminalStatus = await driftFixture.journal.terminalStatus
        XCTAssertEqual(sourceMutationKinds, [])
        XCTAssertEqual(targetMutationKinds, [])
        XCTAssertEqual(terminalStatus, .failed)
    }

    func testFenceLossBeforeFirstMutationIsNotMisreportedAsCompensationFailure() async throws {
        let fixture = try MigrationFixture()
        let plan = try await fixture.plan()
        await fixture.journal.rejectFenceVerification()

        await assertMigrationError(.fenceLost) {
            _ = try await fixture.engine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: plan.confirmationToken,
                operationID: "lost-initial-fence",
                fencingToken: "33333333-3333-4333-8333-333333333333",
                source: fixture.source,
                target: fixture.target
            )
        }

        let sourceMutationKinds = await fixture.source.mutationKinds
        let targetMutationKinds = await fixture.target.mutationKinds
        let terminalStatus = await fixture.journal.terminalStatus
        XCTAssertEqual(sourceMutationKinds, [])
        XCTAssertEqual(targetMutationKinds, [])
        XCTAssertNil(terminalStatus)
    }

    func testTargetFailureRemovesOnlyVerifiedTargetAndRestoresSource() async throws {
        let fixture = try MigrationFixture(targetFailure: .start)
        let plan = try await fixture.plan()
        let fence = "33333333-3333-4333-8333-333333333333"

        await assertMigrationError(
            .providerFailure(providerID: .appleContainerization, checkpoint: .targetVerified)
        ) {
            _ = try await fixture.engine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: plan.confirmationToken,
                operationID: "migration-operation",
                fencingToken: fence,
                source: fixture.source,
                target: fixture.target
            )
        }

        let sourceLifecycle = await fixture.source.lifecycle(resourceUUID: fixture.resourceUUID)
        let targetLifecycle = await fixture.target.lifecycle(resourceUUID: fixture.resourceUUID)
        let terminalStatus = await fixture.journal.terminalStatus
        let commit = await fixture.journal.commit
        let targetMutationKinds = await fixture.target.mutationKinds
        XCTAssertEqual(sourceLifecycle, .running)
        XCTAssertNil(targetLifecycle)
        XCTAssertEqual(terminalStatus, .failed)
        XCTAssertNil(commit)
        XCTAssertEqual(targetMutationKinds, [.create, .start, .remove])
    }

    func testCompensationRefusesTargetWhoseOwnershipWasReplaced() async throws {
        let fixture = try MigrationFixture(targetTamperAfterCreate: true)
        let plan = try await fixture.plan()

        await assertMigrationError(.compensationFailed) {
            _ = try await fixture.engine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: plan.confirmationToken,
                operationID: "migration-operation",
                fencingToken: "33333333-3333-4333-8333-333333333333",
                source: fixture.source,
                target: fixture.target
            )
        }

        let targetLifecycle = await fixture.target.lifecycle(resourceUUID: fixture.resourceUUID)
        let targetMutationKinds = await fixture.target.mutationKinds
        let commit = await fixture.journal.commit
        XCTAssertNotNil(targetLifecycle)
        XCTAssertFalse(targetMutationKinds.contains(.remove))
        XCTAssertNil(commit)
    }

    func testResumeFromTargetCreatedDoesNotDuplicateEffects() async throws {
        let fixture = try MigrationFixture()
        let plan = try await fixture.plan()
        let operationID = "migration-operation"
        let fence = "33333333-3333-4333-8333-333333333333"
        await fixture.source.setLifecycle(.stopped, resourceUUID: fixture.resourceUUID)
        await fixture.target.install(
            fixture.service,
            ownership: fixture.targetOwnership(fencingToken: fence),
            lifecycle: .stopped,
            runtimeID: "target-existing"
        )
        await fixture.journal.seed(
            intent: fixture.intent(plan: plan, operationID: operationID, fencingToken: fence),
            checkpoint: .targetCreated
        )

        let result = try await fixture.engine.execute(
            plan: plan,
            request: fixture.request,
            confirmationToken: plan.confirmationToken,
            operationID: operationID,
            fencingToken: fence,
            source: fixture.source,
            target: fixture.target
        )

        XCTAssertTrue(result.resumed)
        let sourceMutationKinds = await fixture.source.mutationKinds
        let targetMutationKinds = await fixture.target.mutationKinds
        let targetLifecycle = await fixture.target.lifecycle(resourceUUID: fixture.resourceUUID)
        let terminalStatus = await fixture.journal.terminalStatus
        XCTAssertEqual(sourceMutationKinds, [.remove])
        XCTAssertEqual(targetMutationKinds, [.start])
        XCTAssertEqual(targetLifecycle, .running)
        XCTAssertEqual(terminalStatus, .succeeded)
    }

    func testEveryDurableCheckpointResumesWithoutDuplicateOrLostIdentity() async throws {
        let checkpoints = RuntimeProviderMigrationCheckpoint.allCases
        for checkpoint in checkpoints {
            let fixture = try MigrationFixture()
            let plan = try await fixture.plan()
            let operationID = "migration-\(checkpoint.rawValue)"
            let fence = "33333333-3333-4333-8333-333333333333"
            if checkpoint >= .sourceQuiesced {
                await fixture.source.setLifecycle(.stopped, resourceUUID: fixture.resourceUUID)
            }
            if checkpoint >= .targetCreated {
                await fixture.target.install(
                    fixture.service,
                    ownership: fixture.targetOwnership(fencingToken: fence),
                    lifecycle: checkpoint >= .targetRunningRestored ? .running : .stopped,
                    runtimeID: "target-existing"
                )
            }
            if checkpoint >= .sourceRetired {
                await fixture.source.discard(resourceUUID: fixture.resourceUUID)
            }
            await fixture.journal.seed(
                intent: fixture.intent(
                    plan: plan,
                    operationID: operationID,
                    fencingToken: fence
                ),
                checkpoint: checkpoint
            )

            let result = try await fixture.engine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: plan.confirmationToken,
                operationID: operationID,
                fencingToken: fence,
                source: fixture.source,
                target: fixture.target
            )

            let targetOwnership = await fixture.target.ownership(resourceUUID: fixture.resourceUUID)
            let targetLifecycle = await fixture.target.lifecycle(resourceUUID: fixture.resourceUUID)
            let sourceLifecycle = await fixture.source.lifecycle(resourceUUID: fixture.resourceUUID)
            let terminalStatus = await fixture.journal.terminalStatus
            XCTAssertTrue(result.resumed, "Expected resume at \(checkpoint).")
            XCTAssertEqual(targetOwnership?.resourceUUID, fixture.resourceUUID, "Checkpoint \(checkpoint)")
            XCTAssertEqual(targetOwnership?.providerGeneration, 2, "Checkpoint \(checkpoint)")
            XCTAssertEqual(targetOwnership?.fencingToken, fence, "Checkpoint \(checkpoint)")
            XCTAssertEqual(targetLifecycle, .running, "Checkpoint \(checkpoint)")
            XCTAssertNil(sourceLifecycle, "Checkpoint \(checkpoint)")
            XCTAssertEqual(terminalStatus, .succeeded, "Checkpoint \(checkpoint)")
        }
    }

    func testConcurrentMigrationLosesFenceBeforeAnySecondMutation() async throws {
        let journal = MigrationTestJournal()
        let probe = MigrationMutationProbe()
        let fixture = try MigrationFixture(
            journal: journal,
            probe: probe,
            mutationDelayNanoseconds: 150_000_000
        )
        let plan = try await fixture.plan()
        let firstEngine = RuntimeProviderMigrationEngine(journal: journal)
        let secondEngine = RuntimeProviderMigrationEngine(journal: journal)

        let first = Task {
            try await firstEngine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: plan.confirmationToken,
                operationID: "migration-one",
                fencingToken: "33333333-3333-4333-8333-333333333333",
                source: fixture.source,
                target: fixture.target
            )
        }
        try await Task.sleep(nanoseconds: 25_000_000)
        do {
            _ = try await secondEngine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: plan.confirmationToken,
                operationID: "migration-two",
                fencingToken: "44444444-4444-4444-8444-444444444444",
                source: fixture.source,
                target: fixture.target
            )
            XCTFail("Expected the second migration to lose the operation fence.")
        } catch let error as RuntimeProviderMigrationError {
            XCTAssertEqual(error, .fencingConflict(activeOperationID: "migration-one"))
        }
        _ = try await first.value

        let maximumConcurrentMutations = await probe.maximumConcurrentMutations
        let sourceMutationKinds = await fixture.source.mutationKinds
        let targetMutationKinds = await fixture.target.mutationKinds
        XCTAssertEqual(maximumConcurrentMutations, 1)
        XCTAssertEqual(sourceMutationKinds, [.stop, .remove])
        XCTAssertEqual(targetMutationKinds, [.create, .start])
    }

    func testCancellationCompensatesAndConfirmationMismatchNeverMutates() async throws {
        let fixture = try MigrationFixture(sourceCancelsAfterStop: true)
        let plan = try await fixture.plan()

        await assertMigrationError(.confirmationMismatch) {
            _ = try await fixture.engine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: "hostwright-migrate-v1:" + String(repeating: "0", count: 64),
                operationID: "migration-operation",
                fencingToken: "33333333-3333-4333-8333-333333333333",
                source: fixture.source,
                target: fixture.target
            )
        }
        let mutationKindsBeforeConfirmation = await fixture.source.mutationKinds
        XCTAssertEqual(mutationKindsBeforeConfirmation, [])

        await assertMigrationError(.cancelledAfterCompensation) {
            _ = try await fixture.engine.execute(
                plan: plan,
                request: fixture.request,
                confirmationToken: plan.confirmationToken,
                operationID: "migration-operation",
                fencingToken: "33333333-3333-4333-8333-333333333333",
                source: fixture.source,
                target: fixture.target
            )
        }
        let sourceLifecycle = await fixture.source.lifecycle(resourceUUID: fixture.resourceUUID)
        let terminalStatus = await fixture.journal.terminalStatus
        XCTAssertEqual(sourceLifecycle, .running)
        XCTAssertEqual(terminalStatus, .cancelled)
    }

    private func assertMigrationError(
        _ expected: RuntimeProviderMigrationError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected migration error \(expected).")
        } catch let error as RuntimeProviderMigrationError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct MigrationFixture {
    let projectUUID = "11111111-1111-4111-8111-111111111111"
    let resourceUUID = "22222222-2222-4222-8222-222222222222"
    let sourceFence = "99999999-9999-4999-8999-999999999999"
    let imageReference = "registry.example/api:1.0.0"
    let service: DesiredRuntimeService
    let sourceOwnership: RuntimeInventoryOwnershipEvidence
    let sourceSnapshot: RuntimeCapabilitySnapshot
    let targetSnapshot: RuntimeCapabilitySnapshot
    let imageEvidence: RuntimeLocalImageEvidence
    let source: MigrationTestAdapter
    let target: MigrationTestAdapter
    let journal: MigrationTestJournal
    let probe: MigrationMutationProbe
    let engine: RuntimeProviderMigrationEngine

    init(
        journal: MigrationTestJournal = MigrationTestJournal(),
        probe: MigrationMutationProbe = MigrationMutationProbe(),
        desiredService: DesiredRuntimeService? = nil,
        targetFailure: PlannedRuntimeActionKind? = nil,
        targetTamperAfterCreate: Bool = false,
        sourceCancelsAfterStop: Bool = false,
        sourceNetworks: [RuntimeInventoryNetworkAttachment] = [],
        targetUnavailableFeature: RuntimeProviderFeature? = nil,
        sourceUsageCounter: UInt64? = nil,
        mutationDelayNanoseconds: UInt64 = 0
    ) throws {
        let identity = RuntimeServiceIdentity(projectName: "sample", serviceName: "api")
        self.service = desiredService ?? DesiredRuntimeService(
            identity: identity,
            image: imageReference,
            restartPolicy: .unlessStopped
        )
        self.sourceOwnership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            resourceGeneration: 1,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            fencingToken: sourceFence
        )
        self.sourceSnapshot = migrationSnapshot(providerID: .appleContainerCLI)
        self.targetSnapshot = migrationSnapshot(
            providerID: .appleContainerization,
            unavailableFeature: targetUnavailableFeature
        )
        self.imageEvidence = RuntimeLocalImageEvidence(
            reference: imageReference,
            descriptorDigest: digest("a"),
            variantDigest: digest("b"),
            architecture: "arm64",
            operatingSystem: "linux"
        )
        self.probe = probe
        self.journal = journal
        self.source = MigrationTestAdapter(
            providerID: .appleContainerCLI,
            snapshot: sourceSnapshot,
            resources: [
                MigrationTestResource(
                    desiredService: service,
                    ownership: sourceOwnership,
                    lifecycle: .running,
                    runtimeID: "source-container",
                    networks: sourceNetworks
                )
            ],
            localImages: [:],
            probe: probe,
            cancelAfterStop: sourceCancelsAfterStop,
            usageCounter: sourceUsageCounter,
            mutationDelayNanoseconds: mutationDelayNanoseconds
        )
        self.target = MigrationTestAdapter(
            providerID: .appleContainerization,
            snapshot: targetSnapshot,
            resources: [],
            localImages: [imageReference: imageEvidence],
            probe: probe,
            failOnAction: targetFailure,
            tamperAfterCreate: targetTamperAfterCreate,
            mutationDelayNanoseconds: mutationDelayNanoseconds
        )
        self.engine = RuntimeProviderMigrationEngine(journal: journal)
    }

    var request: RuntimeProviderMigrationRequest { request() }

    func request(
        activeOperationIDs: [String] = [],
        expectedSourceCapabilitySHA256: String? = nil
    ) -> RuntimeProviderMigrationRequest {
        RuntimeProviderMigrationRequest(
            projectName: "sample",
            projectUUID: projectUUID,
            projectGeneration: 1,
            sourceProviderID: .appleContainerCLI,
            sourceProviderGeneration: 1,
            targetProviderID: .appleContainerization,
            resources: [
                RuntimeProviderMigrationResource(
                    desiredService: service,
                    ownership: sourceOwnership
                )
            ],
            activeOperationIDs: activeOperationIDs,
            expectedSourceCapabilitySHA256: expectedSourceCapabilitySHA256
        )
    }

    func plan() async throws -> RuntimeProviderMigrationPlan {
        try await engine.dryRun(request: request, source: source, target: target)
    }

    func targetOwnership(fencingToken: String) -> RuntimeInventoryOwnershipEvidence {
        RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            resourceGeneration: 1,
            projectGeneration: 1,
            providerID: .appleContainerization,
            providerGeneration: 2,
            fencingToken: fencingToken
        )
    }

    func intent(
        plan: RuntimeProviderMigrationPlan,
        operationID: String,
        fencingToken: String
    ) -> RuntimeProviderMigrationIntent {
        RuntimeProviderMigrationIntent(
            operationID: operationID,
            fencingToken: fencingToken,
            confirmationToken: plan.confirmationToken,
            projectUUID: projectUUID,
            projectGeneration: 1,
            sourceProviderID: .appleContainerCLI,
            sourceProviderGeneration: 1,
            targetProviderID: .appleContainerization,
            targetProviderGeneration: 2
        )
    }
}

private struct MigrationTestResource: Sendable {
    let desiredService: DesiredRuntimeService
    var ownership: RuntimeInventoryOwnershipEvidence?
    var lifecycle: RuntimeInventoryLifecycleState
    let runtimeID: String
    var networks: [RuntimeInventoryNetworkAttachment] = []
}

private actor MigrationTestAdapter: RuntimeAdapter {
    let providerID: RuntimeProviderID
    let snapshot: RuntimeCapabilitySnapshot
    var resources: [MigrationTestResource]
    let localImages: [String: RuntimeLocalImageEvidence]
    let probe: MigrationMutationProbe
    let failOnAction: PlannedRuntimeActionKind?
    let tamperAfterCreate: Bool
    let cancelAfterStop: Bool
    let mutationDelayNanoseconds: UInt64
    private var usageCounter: UInt64?
    private(set) var mutationKinds: [PlannedRuntimeActionKind] = []
    private(set) var mutationContexts: [RuntimeMutationContext] = []

    init(
        providerID: RuntimeProviderID,
        snapshot: RuntimeCapabilitySnapshot,
        resources: [MigrationTestResource],
        localImages: [String: RuntimeLocalImageEvidence],
        probe: MigrationMutationProbe = MigrationMutationProbe(),
        failOnAction: PlannedRuntimeActionKind? = nil,
        tamperAfterCreate: Bool = false,
        cancelAfterStop: Bool = false,
        usageCounter: UInt64? = nil,
        mutationDelayNanoseconds: UInt64 = 0
    ) {
        self.providerID = providerID
        self.snapshot = snapshot
        self.resources = resources
        self.localImages = localImages
        self.probe = probe
        self.failOnAction = failOnAction
        self.tamperAfterCreate = tamperAfterCreate
        self.cancelAfterStop = cancelAfterStop
        self.usageCounter = usageCounter
        self.mutationDelayNanoseconds = mutationDelayNanoseconds
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: providerID,
            adapterName: "MigrationTestAdapter",
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

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot { snapshot }

    func inventory() async throws -> RuntimeInventory {
        let usage: RuntimeInventoryUsage?
        if let current = usageCounter {
            usage = RuntimeInventoryUsage(
                cpuUsageMicroseconds: current,
                memoryUsageBytes: current,
                memoryLimitBytes: 1_024,
                networkReceiveBytes: current,
                networkTransmitBytes: current,
                blockReadBytes: current,
                blockWriteBytes: current,
                processCount: Int(current)
            )
            usageCounter = current + 1
        } else {
            usage = nil
        }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.0.0",
                services: [
                    RuntimeInventoryService(identifier: "api-server", state: .running, required: true)
                ]
            ),
            containers: resources.map { container($0, usage: usage) },
            images: localImages.values.map {
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
        guard let context = confirmation?.context,
              confirmation?.confirmed == true,
              context.providerID == providerID else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Missing migration context.")
        }
        await probe.enter(providerID)
        do {
            if mutationDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: mutationDelayNanoseconds)
            }
            mutationKinds.append(action.kind)
            mutationContexts.append(context)
            if failOnAction == action.kind {
                throw RuntimeAdapterError.commandFailed(
                    exitStatus: 1,
                    message: "Injected action failure.",
                    standardError: ""
                )
            }
            switch action.kind {
            case .create:
                guard let desired = action.desiredService else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: .mutating,
                        message: "Create requires desired state."
                    )
                }
                var ownership = RuntimeInventoryOwnershipEvidence(
                    resourceUUID: context.resourceUUID,
                    projectUUID: context.projectResourceUUID,
                    resourceGeneration: context.resourceGeneration,
                    projectGeneration: context.projectGeneration,
                    providerID: context.providerID,
                    providerGeneration: context.providerGeneration,
                    fencingToken: context.fencingToken
                )
                if tamperAfterCreate {
                    ownership = RuntimeInventoryOwnershipEvidence(
                        resourceUUID: ownership.resourceUUID,
                        projectUUID: ownership.projectUUID,
                        resourceGeneration: ownership.resourceGeneration,
                        projectGeneration: ownership.projectGeneration,
                        providerID: ownership.providerID,
                        providerGeneration: ownership.providerGeneration,
                        fencingToken: "77777777-7777-4777-8777-777777777777"
                    )
                }
                resources.append(
                    MigrationTestResource(
                        desiredService: desired,
                        ownership: ownership,
                        lifecycle: .stopped,
                        runtimeID: "target-\(context.resourceUUID)"
                    )
                )
            case .start:
                try updateLifecycle(.running, resourceUUID: context.resourceUUID)
            case .stop:
                try updateLifecycle(.stopped, resourceUUID: context.resourceUUID)
                if cancelAfterStop {
                    await probe.leave(providerID)
                    throw CancellationError()
                }
            case .remove:
                guard let index = resources.firstIndex(where: {
                    $0.ownership?.resourceUUID == context.resourceUUID
                }), resources[index].ownership?.fencingToken == context.fencingToken else {
                    throw RuntimeAdapterError.mutationUnavailableByPolicy(
                        "Target removal is not covered by the migration fence."
                    )
                }
                resources.remove(at: index)
            case .restart, .update, .noOp:
                break
            }
            await probe.leave(providerID)
            return RuntimeEvent(
                identity: action.identity,
                message: action.summary,
                resourceIdentifier: action.resourceIdentifier
            )
        } catch {
            if !(error is CancellationError && cancelAfterStop) {
                await probe.leave(providerID)
            }
            throw error
        }
    }

    func lifecycle(resourceUUID: String) -> RuntimeInventoryLifecycleState? {
        resources.first { $0.ownership?.resourceUUID == resourceUUID }?.lifecycle
    }

    func ownership(resourceUUID: String) -> RuntimeInventoryOwnershipEvidence? {
        resources.first { $0.ownership?.resourceUUID == resourceUUID }?.ownership
    }

    func setLifecycle(_ lifecycle: RuntimeInventoryLifecycleState, resourceUUID: String) {
        guard let index = resources.firstIndex(where: {
            $0.ownership?.resourceUUID == resourceUUID
        }) else { return }
        resources[index].lifecycle = lifecycle
    }

    func install(
        _ service: DesiredRuntimeService,
        ownership: RuntimeInventoryOwnershipEvidence,
        lifecycle: RuntimeInventoryLifecycleState,
        runtimeID: String
    ) {
        resources.append(
            MigrationTestResource(
                desiredService: service,
                ownership: ownership,
                lifecycle: lifecycle,
                runtimeID: runtimeID
            )
        )
    }

    func discard(resourceUUID: String) {
        resources.removeAll { $0.ownership?.resourceUUID == resourceUUID }
    }

    private func updateLifecycle(
        _ lifecycle: RuntimeInventoryLifecycleState,
        resourceUUID: String
    ) throws {
        guard let index = resources.firstIndex(where: {
            $0.ownership?.resourceUUID == resourceUUID
        }) else {
            throw RuntimeAdapterError.outputParseFailed("Resource is absent.")
        }
        resources[index].lifecycle = lifecycle
    }

    private func container(
        _ resource: MigrationTestResource,
        usage: RuntimeInventoryUsage?
    ) -> RuntimeInventoryContainer {
        let labels: [RuntimeInventoryLabel]
        if let ownership = resource.ownership {
            let context = RuntimeMutationContext(
                providerID: ownership.providerID,
                capabilitySHA256: snapshot.canonicalSHA256,
                operationID: "inventory",
                resourceUUID: ownership.resourceUUID,
                resourceGeneration: ownership.resourceGeneration,
                projectResourceUUID: ownership.projectUUID,
                projectGeneration: ownership.projectGeneration,
                providerGeneration: ownership.providerGeneration,
                fencingToken: ownership.fencingToken
            )
            labels = (try! RuntimeManagedResourceIdentity.labels(
                for: resource.desiredService.identity,
                context: context
            )).map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
        } else {
            labels = []
        }
        return RuntimeInventoryContainer(
            runtimeID: resource.runtimeID,
            name: resource.desiredService.identity.managedResourceIdentifier,
            imageReference: resource.desiredService.image,
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
            networks: resource.networks,
            usage: usage,
            services: []
        )
    }
}

private actor MigrationMutationProbe {
    private var activeMutations = 0
    private(set) var maximumConcurrentMutations = 0

    func enter(_ providerID: RuntimeProviderID) {
        _ = providerID
        activeMutations += 1
        maximumConcurrentMutations = max(maximumConcurrentMutations, activeMutations)
    }

    func leave(_ providerID: RuntimeProviderID) {
        _ = providerID
        activeMutations -= 1
    }
}

private actor MigrationTestJournal: RuntimeProviderMigrationJournaling {
    private(set) var intent: RuntimeProviderMigrationIntent?
    private(set) var checkpoint: RuntimeProviderMigrationCheckpoint = .intentPersisted
    private(set) var terminalStatus: RuntimeProviderMigrationTerminalStatus?
    private(set) var commit: RuntimeProviderMigrationBindingCommit?
    private var rejectFence = false

    func beginOrResume(
        _ proposed: RuntimeProviderMigrationIntent
    ) async throws -> RuntimeProviderMigrationAcquireResult {
        if let intent {
            if terminalStatus == nil,
               intent.operationID == proposed.operationID,
               intent.fencingToken == proposed.fencingToken,
               intent.confirmationToken == proposed.confirmationToken {
                return .resumed(
                    RuntimeProviderMigrationLease(
                        operationID: intent.operationID,
                        fencingToken: intent.fencingToken,
                        confirmationToken: intent.confirmationToken,
                        checkpoint: checkpoint
                    )
                )
            }
            return .conflict(activeOperationID: intent.operationID)
        }
        intent = proposed
        checkpoint = .intentPersisted
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
        !rejectFence &&
            intent?.operationID == operationID &&
            intent?.fencingToken == fencingToken &&
            terminalStatus == nil
    }

    func rejectFenceVerification() {
        rejectFence = true
    }

    func recordCheckpoint(
        operationID: String,
        fencingToken: String,
        checkpoint proposed: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws {
        guard try await verifyFence(operationID: operationID, fencingToken: fencingToken),
              proposed >= checkpoint,
              !verificationSHA256.isEmpty else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        checkpoint = proposed
    }

    func commitProviderBinding(
        _ proposed: RuntimeProviderMigrationBindingCommit
    ) async throws -> RuntimeProviderMigrationBindingCommitResult {
        guard try await verifyFence(
            operationID: proposed.operationID,
            fencingToken: proposed.fencingToken
        ) else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        if commit == proposed { return .alreadyCommitted }
        guard commit == nil else { throw RuntimeProviderMigrationError.fenceLost }
        commit = proposed
        return .committed
    }

    func finish(
        operationID: String,
        fencingToken: String,
        status: RuntimeProviderMigrationTerminalStatus,
        checkpoint proposed: RuntimeProviderMigrationCheckpoint
    ) async throws {
        guard try await verifyFence(operationID: operationID, fencingToken: fencingToken) else {
            throw RuntimeProviderMigrationError.fenceLost
        }
        terminalStatus = status
        checkpoint = proposed
    }

    func seed(
        intent: RuntimeProviderMigrationIntent,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) {
        self.intent = intent
        self.checkpoint = checkpoint
        self.terminalStatus = nil
        if checkpoint >= .bindingCommitted {
            self.commit = RuntimeProviderMigrationBindingCommit(
                operationID: intent.operationID,
                fencingToken: intent.fencingToken,
                projectUUID: intent.projectUUID,
                projectGeneration: intent.projectGeneration,
                expectedSourceProviderID: intent.sourceProviderID,
                expectedSourceProviderGeneration: intent.sourceProviderGeneration,
                targetProviderID: intent.targetProviderID,
                targetProviderGeneration: intent.targetProviderGeneration,
                confirmationToken: intent.confirmationToken
            )
        } else {
            self.commit = nil
        }
    }
}

private func migrationSnapshot(
    providerID: RuntimeProviderID,
    unavailableFeature: RuntimeProviderFeature? = nil
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
        features: RuntimeProviderFeature.knownValues.map { feature in
            RuntimeProviderFeatureStatus(
                feature: feature,
                state: feature == unavailableFeature ? .unavailable : .available,
                reason: feature == unavailableFeature ? .notImplemented : .implemented
            )
        }
    )
}

private func digest(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
}
