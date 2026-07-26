import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightNetworking
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class ProjectDNSLifecycleCoordinatorTests: XCTestCase {
    func testCreatePersistsIntentBuildsExactInfrastructureAndIsIdempotent()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }

        let result = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )

        let dnsID = dnsTestUUID(
            kind: "project-dns",
            fixture.preparation.projectResourceUUID
        )
        XCTAssertEqual(result.newlyCreatedDNSUUIDs, [dnsID])
        let record = try XCTUnwrap(
            try fixture.store.projectDNS.load(id: dnsID)
        )
        XCTAssertEqual(record.lifecycleState, .available)
        XCTAssertEqual(record.finalizerState, .active)
        XCTAssertNotNil(record.observedSHA256)
        XCTAssertNotNil(record.lastReadyRecordSHA256)
        XCTAssertEqual(
            try fixture.store.operationGroups.loadAll()
                .filter { $0.groupKind == "project-dns" }
                .map(\.status),
            [.succeeded]
        )
        let audit = await fixture.runtime.audit()
        XCTAssertEqual(audit.kinds, [.create, .start])
        XCTAssertEqual(audit.intentPersisted, [true, true])
        let service = try XCTUnwrap(audit.createdService)
        XCTAssertEqual(
            service.image,
            CoreDNSInfrastructureImage
                .immutableLinuxARM64Reference
        )
        XCTAssertEqual(service.ports, [])
        XCTAssertEqual(
            Set(service.networks.map(\.networkRuntimeIdentifier)),
            Set(
                fixture.preparation.desiredState.networks.map {
                    $0.identity.runtimeIdentifier
                }
            )
        )
        XCTAssertEqual(service.mounts.count, 1)
        XCTAssertEqual(service.mounts[0].access, .readOnly)
        XCTAssertEqual(service.mounts[0].target, "/etc/coredns")
        XCTAssertTrue(service.mounts[0].source.hasSuffix("/active"))
        XCTAssertEqual(
            service.command,
            ["-conf", "/etc/coredns/Corefile"]
        )
        XCTAssertTrue(
            RuntimeProjectDNSContract.isInfrastructure(
                service.labels
            )
        )

        let repeated = try await ProjectDNSLifecycleCoordinator
            .reconcile(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("d"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
        )
        XCTAssertEqual(repeated.newlyCreatedDNSUUIDs, [])
        let repeatedAudit = await fixture.runtime.audit()
        XCTAssertEqual(
            repeatedAudit.kinds,
            [.create, .start]
        )
    }

    func testPreMutationPrerequisitesRejectBeforeIntentOrEffects()
        async throws
    {
        let fixture = try makeDNSFixture(seedNetworks: false)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            _ = try await ProjectDNSLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("d"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        XCTAssertTrue(
            try fixture.store.operationGroups.loadAll()
                .filter { $0.groupKind == "project-dns" }
                .isEmpty
        )
        let firstAudit = await fixture.runtime.audit()
        let firstApplyCount = await fixture.helper.applyCount()
        XCTAssertEqual(firstAudit.kinds, [])
        XCTAssertEqual(firstApplyCount, 0)

        let containerization = fixture.preparation.replacingProvider(
            .appleContainerization
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await ProjectDNSLifecycleCoordinator.reconcile(
                preparation: containerization,
                planSHA256: dnsTestDigest("e"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        let secondAudit = await fixture.runtime.audit()
        XCTAssertEqual(secondAudit.kinds, [])
    }

    func testConflictingRuntimeOwnerQuarantinesWithoutMutation()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }
        await fixture.runtime.seedConflict(
            projectUUID: fixture.preparation.projectResourceUUID,
            projectName:
                fixture.preparation.desiredState.projectName
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await ProjectDNSLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("d"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }

        let record = try XCTUnwrap(
            try fixture.store.projectDNS.load(
                id: dnsTestUUID(
                    kind: "project-dns",
                    fixture.preparation.projectResourceUUID
                )
            )
        )
        XCTAssertEqual(record.lifecycleState, .faulted)
        XCTAssertEqual(record.finalizerState, .quarantined)
        let conflictAudit = await fixture.runtime.audit()
        XCTAssertEqual(conflictAudit.kinds, [])
    }

    func testInterruptedAbsentCreateResumesFromPersistedIntent()
        async throws
    {
        let fixture = try makeDNSFixture(
            behavior: .failCreateOnce
        )
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            _ = try await ProjectDNSLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("d"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        let interrupted = try XCTUnwrap(
            try fixture.store.operationGroups.loadAll()
                .first { $0.groupKind == "project-dns" }
        )
        XCTAssertEqual(interrupted.status, .interrupted)

        let result = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        XCTAssertEqual(result.newlyCreatedDNSUUIDs.count, 1)
        XCTAssertEqual(
            try fixture.store.projectDNS.list()
                .map(\.lifecycleState),
            [.available]
        )
        let recoveryAudit = await fixture.runtime.audit()
        XCTAssertEqual(
            recoveryAudit.kinds,
            [.create, .create, .start]
        )
    }

    func testRefreshRetainsPriorValidConfigurationOnApplyFailureThenCommits()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        let id = dnsTestUUID(
            kind: "project-dns",
            fixture.preparation.projectResourceUUID
        )
        let before = try XCTUnwrap(
            try fixture.store.projectDNS.load(id: id)
        )
        let helperBefore = await fixture.helper.snapshot()
        await fixture.helper.failNextApply()
        let observed = fixture.readyObservedState

        await XCTAssertThrowsErrorAsync {
            try await ProjectDNSLifecycleCoordinator.refresh(
                preparation: fixture.preparation,
                observedState: observed,
                planSHA256: dnsTestDigest("e"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        XCTAssertEqual(
            try fixture.store.projectDNS.load(id: id),
            before
        )
        let helperAfterFailure = await fixture.helper.snapshot()
        XCTAssertEqual(helperAfterFailure, helperBefore)

        try await ProjectDNSLifecycleCoordinator.refresh(
            preparation: fixture.preparation,
            observedState: observed,
            planSHA256: dnsTestDigest("f"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        let refreshed = try XCTUnwrap(
            try fixture.store.projectDNS.load(id: id)
        )
        XCTAssertEqual(refreshed.generation, before.generation + 1)
        XCTAssertNotEqual(
            refreshed.lastReadyRecordSHA256,
            before.lastReadyRecordSHA256
        )
        XCTAssertNotEqual(
            refreshed.fencingToken,
            before.fencingToken
        )
        let predecessorFences =
            await fixture.helper.appliedPredecessorFencingTokens()
        XCTAssertEqual(
            predecessorFences,
            [nil, before.fencingToken, before.fencingToken]
        )
        let refreshAudit = await fixture.runtime.audit()
        XCTAssertEqual(refreshAudit.kinds, [.create, .start])
    }

    func testInterruptedRefreshAfterHelperApplyResumesWithoutFenceMismatch()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        let id = dnsTestUUID(
            kind: "project-dns",
            fixture.preparation.projectResourceUUID
        )
        let before = try XCTUnwrap(
            try fixture.store.projectDNS.load(id: id)
        )
        await fixture.runtime.failInventory(
            afterSuccessfulCalls: 1
        )

        await XCTAssertThrowsErrorAsync {
            try await ProjectDNSLifecycleCoordinator.refresh(
                preparation: fixture.preparation,
                observedState: fixture.readyObservedState,
                planSHA256: dnsTestDigest("e"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        let interrupted = try XCTUnwrap(
            try fixture.store.operationGroups.loadAll()
                .first {
                    $0.groupKind == "project-dns" &&
                        $0.plannedActionType == "refresh"
                }
        )
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(
            try fixture.store.projectDNS.load(id: id),
            before
        )
        let interruptedHelperIdentity =
            await fixture.helper.activeIdentity()
        let interruptedHelper = try XCTUnwrap(
            interruptedHelperIdentity
        )
        XCTAssertEqual(
            interruptedHelper.generation,
            before.generation + 1
        )
        XCTAssertEqual(
            interruptedHelper.fencingToken,
            interrupted.fencingToken
        )

        try await ProjectDNSLifecycleCoordinator.refresh(
            preparation: fixture.preparation,
            observedState: fixture.readyObservedState,
            planSHA256: dnsTestDigest("e"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )

        let refreshed = try XCTUnwrap(
            try fixture.store.projectDNS.load(id: id)
        )
        let activeHelperIdentity =
            await fixture.helper.activeIdentity()
        let helperIdentity = try XCTUnwrap(activeHelperIdentity)
        XCTAssertEqual(refreshed.generation, before.generation + 1)
        XCTAssertEqual(refreshed.operationGroupID, interrupted.id)
        XCTAssertEqual(helperIdentity.generation, refreshed.generation)
        XCTAssertEqual(
            helperIdentity.fencingToken,
            refreshed.fencingToken
        )
        XCTAssertEqual(
            try fixture.store.operationGroups.load(
                id: interrupted.id
            )?.status,
            .succeeded
        )
    }

    func testRemoveDeletesExactRuntimeAndHelperBeforeState()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )

        try await ProjectDNSLifecycleCoordinator.remove(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("e"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )

        XCTAssertTrue(try fixture.store.projectDNS.list().isEmpty)
        let removedContainer = await fixture.runtime.currentContainer()
        let removedHelper = await fixture.helper.snapshot()
        let removeAudit = await fixture.runtime.audit()
        XCTAssertNil(removedContainer)
        XCTAssertNil(removedHelper)
        XCTAssertEqual(
            removeAudit.kinds,
            [.create, .start, .stop, .remove]
        )
    }

    func testCommittedDeleteAllowsMonotonicRecreateWithoutReplayingCreate()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        let dnsID = dnsTestUUID(
            kind: "project-dns",
            fixture.preparation.projectResourceUUID
        )
        let first = try XCTUnwrap(
            try fixture.store.projectDNS.load(id: dnsID)
        )
        let firstHelperObservation =
            await fixture.helper.activeIdentity()
        let firstHelper = try XCTUnwrap(firstHelperObservation)
        let firstRuntimeObservation =
            await fixture.runtime.currentContainer()
        let firstRuntime = try XCTUnwrap(firstRuntimeObservation)
        XCTAssertEqual(firstHelper.generation, first.generation)
        XCTAssertEqual(
            firstRuntime.ownership.map {
                Int64($0.resourceGeneration)
            },
            first.generation
        )

        try await ProjectDNSLifecycleCoordinator.remove(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("e"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        XCTAssertNil(try fixture.store.projectDNS.load(id: dnsID))

        let recreated = try await ProjectDNSLifecycleCoordinator
            .reconcile(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("d"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )

        XCTAssertEqual(recreated.newlyCreatedDNSUUIDs, [dnsID])
        let second = try XCTUnwrap(
            try fixture.store.projectDNS.load(id: dnsID)
        )
        let secondHelperObservation =
            await fixture.helper.activeIdentity()
        let secondHelper = try XCTUnwrap(secondHelperObservation)
        let secondRuntimeObservation =
            await fixture.runtime.currentContainer()
        let secondRuntime = try XCTUnwrap(secondRuntimeObservation)
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertNotEqual(second.fencingToken, first.fencingToken)
        XCTAssertEqual(secondHelper.generation, second.generation)
        XCTAssertEqual(
            secondHelper.fencingToken,
            second.fencingToken
        )
        XCTAssertEqual(
            secondRuntime.ownership.map {
                Int64($0.resourceGeneration)
            },
            second.generation
        )
        XCTAssertEqual(
            secondRuntime.ownership?.fencingToken,
            second.fencingToken
        )
        let audit = await fixture.runtime.audit()
        XCTAssertEqual(
            audit.kinds,
            [.create, .start, .stop, .remove, .create, .start]
        )
        let createGroups = try fixture.store.operationGroups.loadAll()
            .filter {
                $0.groupKind == "project-dns" &&
                    $0.plannedActionType == "create"
            }
        XCTAssertEqual(createGroups.count, 2)
        XCTAssertEqual(Set(createGroups.map(\.id)).count, 2)
        XCTAssertTrue(
            createGroups.allSatisfy { $0.status == .succeeded }
        )
    }

    func testInterruptedStopEffectResumesWithDeleteWithoutDuplicateStop()
        async throws
    {
        let fixture = try makeDNSFixture(
            behavior: .failStopAfterEffectOnce
        )
        defer { fixture.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        let available = try XCTUnwrap(
            try fixture.store.projectDNS.list().first
        )

        await XCTAssertThrowsErrorAsync {
            try await ProjectDNSLifecycleCoordinator.remove(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("e"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        let interrupted = try XCTUnwrap(
            try fixture.store.projectDNS.list().first
        )
        XCTAssertEqual(interrupted.lifecycleState, .deleting)
        XCTAssertEqual(interrupted.finalizerState, .releasing)
        let stoppedContainer =
            await fixture.runtime.currentContainer()
        let interruptedAudit =
            await fixture.runtime.audit()
        XCTAssertEqual(
            stoppedContainer?.lifecycle,
            .exited
        )
        XCTAssertEqual(
            Set(stoppedContainer?.networks.map(\.networkID) ?? []),
            Set(
                fixture.preparation.desiredState.networks.map {
                    $0.identity.runtimeIdentifier
                }
            )
        )
        XCTAssertTrue(
            stoppedContainer?.networks.allSatisfy {
                $0.addresses.isEmpty
            } ?? false
        )
        XCTAssertNotEqual(
            interrupted.fencingToken,
            available.fencingToken
        )
        XCTAssertEqual(
            stoppedContainer?.ownership?.fencingToken,
            available.fencingToken
        )
        XCTAssertNotEqual(
            stoppedContainer?.ownership?.fencingToken,
            interrupted.fencingToken
        )
        XCTAssertEqual(
            interruptedAudit.kinds,
            [.create, .start, .stop]
        )

        try await ProjectDNSLifecycleCoordinator.remove(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("e"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )

        XCTAssertTrue(try fixture.store.projectDNS.list().isEmpty)
        let removedContainer =
            await fixture.runtime.currentContainer()
        let removedHelper =
            await fixture.helper.snapshot()
        let completedAudit =
            await fixture.runtime.audit()
        XCTAssertNil(removedContainer)
        XCTAssertNil(removedHelper)
        XCTAssertEqual(
            completedAudit.kinds,
            [.create, .start, .stop, .remove]
        )
    }

    func testDeleteAfterRefreshResumesWithDistinctRuntimeAndHelperAuthority()
        async throws
    {
        let fixture = try makeDNSFixture(
            behavior: .failStopAfterEffectOnce
        )
        defer { fixture.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        let created = try XCTUnwrap(
            try fixture.store.projectDNS.list().first
        )
        try await ProjectDNSLifecycleCoordinator.refresh(
            preparation: fixture.preparation,
            observedState: fixture.readyObservedState,
            planSHA256: dnsTestDigest("e"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        let refreshed = try XCTUnwrap(
            try fixture.store.projectDNS.list().first
        )
        let runtimeBeforeDelete =
            await fixture.runtime.currentContainer()
        let runtimeOwnership = try XCTUnwrap(
            runtimeBeforeDelete?.ownership
        )
        XCTAssertGreaterThan(refreshed.generation, created.generation)
        XCTAssertNotEqual(
            refreshed.fencingToken,
            runtimeOwnership.fencingToken
        )
        XCTAssertLessThan(
            Int64(runtimeOwnership.resourceGeneration),
            refreshed.generation
        )

        await XCTAssertThrowsErrorAsync {
            try await ProjectDNSLifecycleCoordinator.remove(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("f"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        try await ProjectDNSLifecycleCoordinator.remove(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("f"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )

        XCTAssertTrue(try fixture.store.projectDNS.list().isEmpty)
        let finalRuntime = await fixture.runtime.currentContainer()
        let finalHelper = await fixture.helper.activeIdentity()
        XCTAssertNil(finalRuntime)
        XCTAssertNil(finalHelper)
        let audit = await fixture.runtime.audit()
        XCTAssertEqual(
            audit.kinds,
            [.create, .start, .stop, .remove]
        )
    }

    func testInterruptedRemoveAfterRuntimeDeletionResumesExactDeletion()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        await fixture.helper.failNextRemove()

        await XCTAssertThrowsErrorAsync {
            try await ProjectDNSLifecycleCoordinator.remove(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("e"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }
        let deleting = try XCTUnwrap(
            try fixture.store.projectDNS.list().first
        )
        XCTAssertEqual(deleting.lifecycleState, .deleting)
        XCTAssertEqual(deleting.finalizerState, .releasing)
        let interruptedContainer =
            await fixture.runtime.currentContainer()
        let retainedHelper = await fixture.helper.snapshot()
        XCTAssertNil(interruptedContainer)
        XCTAssertNotNil(retainedHelper)
        XCTAssertEqual(
            try fixture.store.operationGroups.load(
                id: deleting.operationGroupID
            )?.status,
            .interrupted
        )

        try await ProjectDNSLifecycleCoordinator.remove(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("e"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )

        XCTAssertTrue(try fixture.store.projectDNS.list().isEmpty)
        let removedHelper = await fixture.helper.snapshot()
        XCTAssertNil(removedHelper)
        XCTAssertEqual(
            try fixture.store.operationGroups.load(
                id: deleting.operationGroupID
            )?.status,
            .succeeded
        )
        let audit = await fixture.runtime.audit()
        XCTAssertEqual(
            audit.kinds,
            [.create, .start, .stop, .remove]
        )
    }

    func testCompensationRemovesOnlyDNSCreatedByThisExecution()
        async throws
    {
        let fixture = try makeDNSFixture()
        defer { fixture.cleanup() }
        let created = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: fixture.preparation,
            planSHA256: dnsTestDigest("d"),
            store: fixture.store,
            helper: fixture.helper,
            runtime: fixture.runtime
        )
        try await ProjectDNSLifecycleCoordinator
            .compensateNewlyCreated(
                created,
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("e"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        let compensatedContainer =
            await fixture.runtime.currentContainer()
        XCTAssertNil(compensatedContainer)

        let second = try makeDNSFixture()
        defer { second.cleanup() }
        _ = try await ProjectDNSLifecycleCoordinator.reconcile(
            preparation: second.preparation,
            planSHA256: dnsTestDigest("d"),
            store: second.store,
            helper: second.helper,
            runtime: second.runtime
        )
        try await ProjectDNSLifecycleCoordinator
            .compensateNewlyCreated(
                ProjectDNSLifecycleReconciliationResult(
                    newlyCreatedDNSUUIDs: []
                ),
                preparation: second.preparation,
                planSHA256: dnsTestDigest("e"),
                store: second.store,
                helper: second.helper,
                runtime: second.runtime
            )
        let retainedContainer =
            await second.runtime.currentContainer()
        XCTAssertNotNil(retainedContainer)
    }

    func testCancellationLeavesResumableIntentAndNoCreatedEffects()
        async throws
    {
        let fixture = try makeDNSFixture(behavior: .cancelCreate)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            _ = try await ProjectDNSLifecycleCoordinator.reconcile(
                preparation: fixture.preparation,
                planSHA256: dnsTestDigest("d"),
                store: fixture.store,
                helper: fixture.helper,
                runtime: fixture.runtime
            )
        }

        let cancelledContainer =
            await fixture.runtime.currentContainer()
        let cancelledHelper = await fixture.helper.snapshot()
        XCTAssertNil(cancelledContainer)
        XCTAssertNil(cancelledHelper)
        let record = try XCTUnwrap(
            try fixture.store.projectDNS.list().first
        )
        XCTAssertEqual(record.lifecycleState, .creating)
        let group = try XCTUnwrap(
            try fixture.store.operationGroups.load(
                id: record.operationGroupID
            )
        )
        XCTAssertEqual(group.status, .interrupted)
    }
}

private enum DNSRuntimeMutationKind: Equatable, Sendable {
    case create
    case start
    case stop
    case remove
}

private struct DNSRuntimeAudit: Sendable {
    let kinds: [DNSRuntimeMutationKind]
    let intentPersisted: [Bool]
    let createdService: DesiredRuntimeService?
}

private enum DNSRuntimeBehavior: Sendable {
    case succeed
    case failCreateOnce
    case cancelCreate
    case failStopAfterEffectOnce
}

private enum DNSCoordinatorInjectedError: Error {
    case create
    case stopAfterEffect
    case helperApply
    case helperRemove
    case inventory
}

private actor DNSRuntimeDriver: ProjectDNSRuntimeDriving {
    private let store: SQLiteStateStore
    private let capabilitySHA256: String
    private var behavior: DNSRuntimeBehavior
    private var container: RuntimeInventoryContainer?
    private var kinds: [DNSRuntimeMutationKind] = []
    private var intentPersisted: [Bool] = []
    private var createdService: DesiredRuntimeService?
    private var inventoryFailureCountdown: Int?

    init(
        store: SQLiteStateStore,
        capabilitySHA256: String,
        behavior: DNSRuntimeBehavior
    ) {
        self.store = store
        self.capabilitySHA256 = capabilitySHA256
        self.behavior = behavior
    }

    func currentCapabilitySHA256() -> String {
        capabilitySHA256
    }

    func coreDNSImageEvidence()
        -> CoreDNSInfrastructureImageEvidence
    {
        CoreDNSInfrastructureImageEvidence(
            resolvedReference:
                CoreDNSInfrastructureImage
                    .immutableLinuxARM64Reference,
            descriptorDigest:
                "sha256:\(dnsTestDigest("a"))",
            variantDigest:
                CoreDNSInfrastructureImage.linuxARM64Digest,
            operatingSystem: "linux",
            architecture: "arm64",
            localImageAvailable: true,
            phase05PolicyAccepted: true,
            evidenceSHA256: dnsTestDigest("b")
        )
    }

    func inventory() throws -> RuntimeInventory {
        if let inventoryFailureCountdown {
            if inventoryFailureCountdown == 0 {
                self.inventoryFailureCountdown = nil
                throw DNSCoordinatorInjectedError.inventory
            }
            self.inventoryFailureCountdown =
                inventoryFailureCountdown - 1
        }
        return try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: []
            ),
            containers: container.map { [$0] } ?? [],
            images: [],
            networks: [],
            volumes: []
        )
    }

    func mutate(_ mutation: ProjectDNSRuntimeMutation) throws {
        switch mutation {
        case .create(
            let service,
            let resourceIdentifier,
            let context,
            _
        ):
            kinds.append(.create)
            intentPersisted.append(
                hasIntent(context: context, lifecycle: .creating)
            )
            switch behavior {
            case .failCreateOnce:
                behavior = .succeed
                throw DNSCoordinatorInjectedError.create
            case .cancelCreate:
                throw CancellationError()
            case .succeed, .failStopAfterEffectOnce:
                break
            }
            createdService = service
            container = try makeContainer(
                service: service,
                resourceIdentifier: resourceIdentifier,
                context: context,
                lifecycle: .created
            )
        case .start(
            _,
            let resourceIdentifier,
            let context,
            _
        ):
            kinds.append(.start)
            intentPersisted.append(
                hasIntent(context: context, lifecycle: .creating)
            )
            guard let existing = container,
                  existing.runtimeID == resourceIdentifier else {
                throw DNSCoordinatorInjectedError.create
            }
            container = replacingLifecycle(
                existing,
                .running
            )
        case .stop(
            _,
            let resourceIdentifier,
            let expectedOwnership,
            let context,
            _
        ):
            kinds.append(.stop)
            intentPersisted.append(
                hasIntent(context: context, lifecycle: .deleting) ||
                    hasIntent(context: context, lifecycle: .creating)
            )
            guard let existing = container,
                  existing.runtimeID == resourceIdentifier,
                  existing.ownership == expectedOwnership else {
                throw DNSCoordinatorInjectedError.create
            }
            let stoppedNetworks = existing.networks.map {
                RuntimeInventoryNetworkAttachment(
                    networkID: $0.networkID,
                    interfaceName: $0.interfaceName,
                    addresses: [],
                    gateway: $0.gateway,
                    macAddress: $0.macAddress
                )
            }
            container = replacingLifecycle(
                existing,
                .exited,
                networks: stoppedNetworks
            )
            if behavior == .failStopAfterEffectOnce {
                behavior = .succeed
                throw DNSCoordinatorInjectedError.stopAfterEffect
            }
        case .remove(
            _,
            let resourceIdentifier,
            let expectedOwnership,
            let context,
            _
        ):
            kinds.append(.remove)
            intentPersisted.append(
                hasIntent(context: context, lifecycle: .deleting)
            )
            guard container?.runtimeID == resourceIdentifier,
                  container?.ownership == expectedOwnership else {
                throw DNSCoordinatorInjectedError.create
            }
            container = nil
        }
    }

    func seedConflict(
        projectUUID: String,
        projectName: String
    ) {
        let identity = RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: "hostwright-dns"
        )
        container = RuntimeInventoryContainer(
            runtimeID: identity.managedResourceIdentifier,
            name: identity.managedResourceIdentifier,
            imageReference: "unmanaged.invalid/example",
            lifecycle: .running,
            health: RuntimeInventoryHealth(
                availability: .notConfigured
            ),
            labels: [],
            ownership: nil,
            initConfiguration: RuntimeInventoryInitConfiguration(
                executable: "example",
                arguments: [],
                environment: []
            ),
            ports: [],
            mounts: [],
            networks: [],
            services: []
        )
        _ = projectUUID
    }

    func audit() -> DNSRuntimeAudit {
        DNSRuntimeAudit(
            kinds: kinds,
            intentPersisted: intentPersisted,
            createdService: createdService
        )
    }

    func currentContainer() -> RuntimeInventoryContainer? {
        container
    }

    func failInventory(afterSuccessfulCalls count: Int) {
        inventoryFailureCountdown = count
    }

    private func hasIntent(
        context: RuntimeMutationContext,
        lifecycle: NetworkStateResourceLifecycle
    ) -> Bool {
        guard let record = try? store.projectDNS.load(
            id: context.resourceUUID
        ),
        record.lifecycleState == lifecycle,
        record.fencingToken == context.fencingToken,
        let group = try? store.operationGroups.load(
            id: record.operationGroupID
        ),
        group.status == .active,
        group.intentJSONRedacted.contains(
            context.capabilitySHA256
        ) else {
            return false
        }
        return true
    }

    private func makeContainer(
        service: DesiredRuntimeService,
        resourceIdentifier: String,
        context: RuntimeMutationContext,
        lifecycle: RuntimeInventoryLifecycleState
    ) throws -> RuntimeInventoryContainer {
        var labels = try RuntimeManagedResourceIdentity.labels(
            for: service.identity,
            resourceIdentifier: resourceIdentifier,
            context: context
        )
        labels.merge(service.labels) { _, desired in desired }
        return RuntimeInventoryContainer(
            runtimeID: resourceIdentifier,
            name: resourceIdentifier,
            imageReference: service.image,
            lifecycle: lifecycle,
            health: RuntimeInventoryHealth(
                availability: .notConfigured
            ),
            labels: labels.sorted {
                $0.key < $1.key
            }.map {
                RuntimeInventoryLabel(
                    key: $0.key,
                    value: $0.value
                )
            },
            ownership: RuntimeInventoryOwnershipEvidence(
                resourceUUID: context.resourceUUID,
                projectUUID: context.projectResourceUUID,
                resourceGeneration: context.resourceGeneration,
                projectGeneration: context.projectGeneration,
                providerID: context.providerID,
                providerGeneration:
                    context.providerGeneration,
                fencingToken: context.fencingToken
            ),
            initConfiguration: RuntimeInventoryInitConfiguration(
                executable: "coredns",
                arguments: service.command,
                environment: []
            ),
            ports: [],
            mounts: service.mounts.map {
                RuntimeInventoryMount(
                    source: $0.source,
                    target: $0.target,
                    kind: .bind,
                    access: .readOnly
                )
            },
            networks: service.networks.map {
                RuntimeInventoryNetworkAttachment(
                    networkID: $0.networkRuntimeIdentifier,
                    addresses: [
                        "192.168.70.53",
                    ]
                )
            },
            services: []
        )
    }

    private func replacingLifecycle(
        _ value: RuntimeInventoryContainer,
        _ lifecycle: RuntimeInventoryLifecycleState,
        networks:
            [RuntimeInventoryNetworkAttachment]? = nil
    ) -> RuntimeInventoryContainer {
        RuntimeInventoryContainer(
            runtimeID: value.runtimeID,
            name: value.name,
            imageID: value.imageID,
            imageReference: value.imageReference,
            lifecycle: lifecycle,
            health: value.health,
            labels: value.labels,
            ownership: value.ownership,
            initConfiguration: value.initConfiguration,
            ports: value.ports,
            mounts: value.mounts,
            networks: networks ?? value.networks,
            allocation: value.allocation,
            usage: value.usage,
            services: value.services
        )
    }
}

private actor DNSHelperDriver: ProjectDNSHelperDriving {
    private let root: String
    private var active:
        (identity: ProjectDNSHelperIdentity, observation: ProjectDNSHelperObservation)?
    private var shouldFailNextApply = false
    private var shouldFailNextRemove = false
    private var applications = 0
    private var predecessorFencingTokens: [String?] = []

    init(root: String) {
        self.root = root
    }

    func status(
        identity: ProjectDNSHelperIdentity
    ) -> ProjectDNSHelperObservation {
        guard let active else {
            return ProjectDNSHelperObservation(
                disposition: .absent,
                corefilePath: nil,
                corefileSHA256: nil
            )
        }
        guard active.identity == identity else {
            return ProjectDNSHelperObservation(
                disposition: .conflicting,
                corefilePath: nil,
                corefileSHA256: nil
            )
        }
        return active.observation
    }

    func apply(
        identity: ProjectDNSHelperIdentity,
        corefile: String,
        predecessorFencingToken: String?
    ) throws -> ProjectDNSHelperObservation {
        applications += 1
        predecessorFencingTokens.append(
            predecessorFencingToken
        )
        if shouldFailNextApply {
            shouldFailNextApply = false
            throw DNSCoordinatorInjectedError.helperApply
        }
        if let active {
            if active.identity == identity,
               active.observation.corefileSHA256 ==
                dnsTestSHA256(corefile) {
                return active.observation
            }
            guard active.identity.projectUUID ==
                    identity.projectUUID,
                  active.identity.dnsUUID == identity.dnsUUID,
                  active.identity.generation <
                    identity.generation,
                  predecessorFencingToken ==
                    active.identity.fencingToken else {
                return ProjectDNSHelperObservation(
                    disposition: .conflicting,
                    corefilePath: nil,
                    corefileSHA256: nil
                )
            }
        } else if predecessorFencingToken != nil {
            return ProjectDNSHelperObservation(
                disposition: .conflicting,
                corefilePath: nil,
                corefileSHA256: nil
            )
        }
        let observation = ProjectDNSHelperObservation(
            disposition: .active,
            corefilePath:
                "\(root)/\(identity.projectUUID)/\(identity.dnsUUID)/active/Corefile",
            corefileSHA256: dnsTestSHA256(corefile)
        )
        active = (identity, observation)
        return observation
    }

    func remove(
        identity: ProjectDNSHelperIdentity
    ) throws -> ProjectDNSHelperObservation {
        if shouldFailNextRemove {
            shouldFailNextRemove = false
            throw DNSCoordinatorInjectedError.helperRemove
        }
        guard let active else {
            return ProjectDNSHelperObservation(
                disposition: .absent,
                corefilePath: nil,
                corefileSHA256: nil
            )
        }
        guard active.identity == identity else {
            return ProjectDNSHelperObservation(
                disposition: .conflicting,
                corefilePath: nil,
                corefileSHA256: nil
            )
        }
        self.active = nil
        return ProjectDNSHelperObservation(
            disposition: .absent,
            corefilePath: nil,
            corefileSHA256: nil
        )
    }

    func failNextApply() {
        shouldFailNextApply = true
    }

    func failNextRemove() {
        shouldFailNextRemove = true
    }

    func snapshot() -> ProjectDNSHelperObservation? {
        active?.observation
    }

    func activeIdentity() -> ProjectDNSHelperIdentity? {
        active?.identity
    }

    func applyCount() -> Int {
        applications
    }

    func appliedPredecessorFencingTokens() -> [String?] {
        predecessorFencingTokens
    }
}

private struct DNSCoordinatorFixture {
    let root: URL
    let store: SQLiteStateStore
    let preparation: LifecycleCommandPreparation
    let readyObservedState: ObservedRuntimeState
    let helper: DNSHelperDriver
    let runtime: DNSRuntimeDriver

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeDNSFixture(
    seedNetworks: Bool = true,
    behavior: DNSRuntimeBehavior = .succeed
) throws -> DNSCoordinatorFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "hostwright-project-dns-\(UUID().uuidString)",
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
    let projectID = "project-dns-coordinator"
    try store.desiredStates.saveManifestSnapshot(
        projectID: projectID,
        manifestPath: "hostwright.yaml",
        manifestHash: dnsTestDigest("a"),
        desiredGeneration: 1,
        manifest: HostwrightManifest(
            version: 2,
            project: "dns-coordinator",
            services: []
        ),
        timestamp: "2026-07-26T12:00:00Z",
        mutationProvider:
            RuntimeProviderID.appleContainerCLI.rawValue
    )
    let projectUUID = try store.desiredStates
        .loadProject(id: projectID).resourceUUID
    let network = try DesiredRuntimeNetwork(
        identity: RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: projectUUID
        ),
        mode: .nat,
        ipv4: .automatic,
        ipv6: .automatic
    )
    if seedNetworks {
        try seedAvailableDNSNetwork(
            network,
            projectID: projectID,
            projectUUID: projectUUID,
            store: store
        )
    }
    let attachment = try RuntimeDesiredNetworkAttachment(
        network: network.identity,
        aliases: ["api-internal"]
    )
    let service = DesiredRuntimeService(
        identity: RuntimeServiceIdentity(
            projectName: "dns-coordinator",
            serviceName: "api",
            instanceName: "api-0"
        ),
        logicalServiceName: "api",
        image: "example.invalid/api@sha256:\(dnsTestDigest("c"))",
        networks: [attachment]
    )
    let observed = ObservedRuntimeState(
        projectName: "dns-coordinator",
        services: []
    )
    let readyObserved = ObservedRuntimeState(
        projectName: "dns-coordinator",
        services: [
            ObservedRuntimeService(
                identity: service.identity,
                resourceIdentifier:
                    service.identity.managedResourceIdentifier,
                image: service.image,
                lifecycleState: .running,
                healthState: .notConfigured,
                networks: [
                    RuntimeNetworkAttachment(
                        name: network.identity.runtimeIdentifier,
                        ipv4Address: "192.168.70.20"
                    ),
                ]
            ),
        ]
    )
    let preparation = LifecycleCommandPreparation(
        manifestSHA256: dnsTestDigest("a"),
        manifestBaseDirectory: root.path,
        desiredState: DesiredRuntimeState(
            projectName: "dns-coordinator",
            networks: [network],
            services: [service]
        ),
        observedState: observed,
        observationSHA256: dnsTestDigest("b"),
        projectID: projectID,
        projectResourceUUID: projectUUID,
        projectGeneration: 1,
        providerID: .appleContainerCLI,
        providerGeneration: 1,
        capabilitySHA256: dnsTestDigest("d"),
        planFencingToken: dnsTestUUID(
            kind: "plan-fence",
            projectID
        )
    )
    let helperRoot = root
        .appendingPathComponent("helper", isDirectory: true)
        .path
    return DNSCoordinatorFixture(
        root: root,
        store: store,
        preparation: preparation,
        readyObservedState: readyObserved,
        helper: DNSHelperDriver(root: helperRoot),
        runtime: DNSRuntimeDriver(
            store: store,
            capabilitySHA256: preparation.capabilitySHA256,
            behavior: behavior
        )
    )
}

private func seedAvailableDNSNetwork(
    _ network: DesiredRuntimeNetwork,
    projectID: String,
    projectUUID: String,
    store: SQLiteStateStore
) throws {
    let groupID = dnsTestUUID(
        kind: "network-seed-operation",
        network.identity.resourceUUID
    )
    let fence = dnsTestUUID(
        kind: "network-seed-fence",
        network.identity.resourceUUID
    )
    let now = "2026-07-26T12:00:00Z"
    let group = OperationGroupRecord(
        id: groupID,
        operationID: groupID,
        groupKind: "network-resource",
        projectID: projectID,
        serviceName: nil,
        plannedActionType: "create",
        status: .active,
        groupIdempotencyKey: dnsTestDigest("e"),
        planHash: dnsTestDigest("f"),
        checkpoint: "intent-persisted",
        lockOwner: "test",
        lockExpiresAt: "2026-07-27T12:00:00Z",
        rollbackAvailable: true,
        manualRecoveryHintRedacted: "",
        createdAt: now,
        updatedAt: now,
        metadataJSONRedacted: "{}",
        fencingToken: fence,
        intentJSONRedacted: "{}",
        compensationJSONRedacted: "[]",
        verificationJSONRedacted: "{}"
    )
    _ = try XCTUnwrap(
        store.operationGroups.acquire(group).acquired
    )
    let creating = NetworkStateResourceRecord(
        id: network.identity.resourceUUID,
        projectUUID: projectUUID,
        name: network.identity.logicalName,
        runtimeName: network.identity.runtimeIdentifier,
        generation: 1,
        providerID: RuntimeProviderID.appleContainerCLI.rawValue,
        providerGeneration: 1,
        fencingToken: fence,
        driver: .nat,
        requestedIPv4: .auto,
        requestedIPv6: .auto,
        observedIPv4: [],
        observedIPv6: [],
        desiredSHA256: dnsTestDigest("a"),
        observedSHA256: nil,
        lifecycleState: .creating,
        finalizerState: .pending,
        operationGroupID: groupID,
        createdAt: now,
        updatedAt: now
    )
    try store.networks.saveNetwork(creating)
    let available = NetworkStateResourceRecord(
        id: creating.id,
        projectUUID: creating.projectUUID,
        name: creating.name,
        runtimeName: creating.runtimeName,
        generation: 2,
        providerID: creating.providerID,
        providerGeneration: creating.providerGeneration,
        fencingToken: creating.fencingToken,
        driver: creating.driver,
        requestedIPv4: creating.requestedIPv4,
        requestedIPv6: creating.requestedIPv6,
        observedIPv4: ["192.168.70.2"],
        observedIPv6: [],
        desiredSHA256: creating.desiredSHA256,
        observedSHA256: dnsTestDigest("b"),
        lifecycleState: .available,
        finalizerState: .active,
        operationGroupID: groupID,
        createdAt: now,
        updatedAt: now
    )
    try store.networks.saveNetwork(
        available,
        replacing: NetworkStateExpectedVersion(
            generation: 1,
            fencingToken: fence
        )
    )
    try store.operationGroups.finish(
        groupID: groupID,
        status: .succeeded,
        checkpoint: "state-committed",
        manualRecoveryHintRedacted: "",
        updatedAt: now,
        metadataJSONRedacted: "{}"
    )
}

private extension LifecycleCommandPreparation {
    func replacingProvider(
        _ providerID: RuntimeProviderID
    ) -> LifecycleCommandPreparation {
        LifecycleCommandPreparation(
            manifestSHA256: manifestSHA256,
            manifestBaseDirectory: manifestBaseDirectory,
            mappingIssues: mappingIssues,
            desiredState: desiredState,
            previousDesiredState: previousDesiredState,
            observedState: observedState,
            observationSHA256: observationSHA256,
            projectID: projectID,
            projectResourceUUID: projectResourceUUID,
            projectGeneration: projectGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            capabilitySHA256: capabilitySHA256,
            planFencingToken: planFencingToken,
            resourceBindings: resourceBindings,
            unmanagedResourceIdentifiers:
                unmanagedResourceIdentifiers
        )
    }
}

private func dnsTestDigest(
    _ character: Character
) -> String {
    String(repeating: String(character), count: 64)
}

private func dnsTestUUID(
    kind: String,
    _ identifier: String
) -> String {
    HostwrightResourceUUID.legacy(
        kind: kind,
        identifier: identifier
    )
}

private func dnsTestSHA256(
    _ value: String
) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail(
            "Expected async expression to throw.",
            file: file,
            line: line
        )
    } catch {}
}
