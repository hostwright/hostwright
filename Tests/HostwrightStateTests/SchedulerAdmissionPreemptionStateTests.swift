import Foundation
import XCTest
import HostwrightControlPlane

@testable import HostwrightCore
@testable import HostwrightScheduler
@testable import HostwrightState

final class SchedulerAdmissionPreemptionStateTests: XCTestCase {
    private let projectUUID = "00000000-0000-0000-0000-000000000905"

    func testAuthorityRecordsRoundTripWithStableDigests() throws {
        let pressureRecord = try SchedulerHostPressureRecord(
            nodeID: nodeID,
            posture: SchedulerHostPosture(
                pressure: .elevated,
                energy: .constrained
            ),
            generation: 1,
            observedAt: timestamp(0),
            evidenceDigest: digest("e"),
            policyState: try pressurePolicyState(
                reasonCodes: [.lowPowerMode],
                nextPosture: .deweighted
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SchedulerHostPressureRecord.self,
                from: JSONEncoder().encode(pressureRecord)
            ),
            pressureRecord
        )

    }

    func testRepositoryAuthorityApisAreAvailableAfterTheV22AuthorityAppend() throws {
        try withTemporaryStore { store in
            let nodeSnapshot = try SchedulerNodeCapacitySnapshot(
                nodeID: nodeID,
                capacity: try ResourceVector(["cpu": 2]),
                generation: 1,
                observedAt: timestamp(0)
            )
            _ = try store.schedulerAdmissions.recordNodeCapacity(snapshot: nodeSnapshot)
            let pressure = try SchedulerHostPressureRecord(
                nodeID: nodeID,
                posture: SchedulerHostPosture(pressure: .nominal, energy: .balanced),
                generation: 1,
                observedAt: timestamp(0),
                evidenceDigest: digest("a"),
                policyState: try pressurePolicyState(
                    reasonCodes: [.allowed],
                    nextPosture: .allowed
                )
            )
            XCTAssertEqual(
                try store.schedulerAdmissions.recordHostPressure(record: pressure),
                pressure
            )

        }
    }
    func testDecisionArtifactIsIndependentFromReservationsAndReplayKeepsFirstTimestamps() throws {
        try withRepository { repository, store in
            let fixture = try makePlacedFixture()
            _ = try store.schedulerAdmissions.recordNodeCapacity(
                snapshot: fixture.nodeSnapshot
            )
            let first = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            XCTAssertEqual(try repository.decisionArtifact(id: first.decisionID), first)
            XCTAssertNil(try repository.decision(id: first.decisionID))

            let replay = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: timestamp(2),
                updatedAt: timestamp(3)
            )
            XCTAssertEqual(replay, first)
            XCTAssertEqual(replay.createdAt, timestamp(0))
            XCTAssertEqual(replay.updatedAt, timestamp(1))
            let artifactJSON = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(first)
            ) as? [String: Any]
            let bindingJSON = try XCTUnwrap(
                (artifactJSON?["workloadBindings"] as? [[String: Any]])?.first
            )
            XCTAssertNil(bindingJSON["createdAt"])
            XCTAssertNil(bindingJSON["expiresAt"])

            let columns = try store.withConnection(createIfNeeded: false, readOnly: true) {
                connection in
                Set(
                    try connection.query("PRAGMA table_info(scheduler_decisions)")
                        .compactMap { $0.count > 1 ? $0[1] : nil }
                )
            }
            XCTAssertFalse(columns.contains("reservation_id"))
            XCTAssertTrue(columns.contains("workload_bindings_json"))
            let reservationCount = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                try connection.query("SELECT COUNT(*) FROM scheduler_reservations")
                    .first?.first
            }
            XCTAssertEqual(reservationCount, "0")
        }
    }

    func testApplyReloadsArtifactAndCreatesOnlyPendingReservation() throws {
        try withRepository { repository, store in
            let fixture = try makePlacedFixture()
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            _ = try repository.recordNodeCapacity(snapshot: fixture.nodeSnapshot)

            let applied = try repository.applyDecision(
                decisionID: fixture.artifact.decisionID,
                projectUUID: fixture.artifact.projectUUID,
                workloadID: fixture.binding.workloadID,
                expectedInputDigest: fixture.artifact.inputDigest,
                currentAuthority: fixture.currentAuthority
            )
            let reservation = try XCTUnwrap(applied.reservation)
            XCTAssertEqual(reservation.status, .pending)
            XCTAssertNil(applied.preemptionIntent)
            XCTAssertNil(reservation.fenceEvidence)
            XCTAssertEqual(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: try SchedulerAdmissionCurrentAuthority(
                        nodeCapacityDigest: fixture.nodeSnapshot.capacityDigest,
                        nodeCapacityGeneration: fixture.nodeSnapshot.generation,
                        configDigest: fixture.artifact.configDigest,
                        profileDigest: fixture.artifact.profileDigest,
                        lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                        expectedNodeEpoch: 1,
                        expectedPressureGeneration: 1,
                        expectedPressureEvidenceDigest: digest("a"),
                        expectedPressurePosture: .nominal,
                        leaseCreatedAt: timestamp(3),
                        leaseExpiresAt: timestamp(5)
                    )
                ),
                applied
            )
            let snapshot = try XCTUnwrap(
                repository.decisionState(
                    id: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID
                )
            )
            XCTAssertEqual(snapshot.artifact, fixture.artifact)
            XCTAssertEqual(snapshot.reservations, [reservation])
            XCTAssertThrowsError(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: digest("e"),
                    currentAuthority: fixture.currentAuthority
                )
            )
            _ = store
        }
    }

    func testApplyPressureGenerationCASFailsClosedAndAllowsOnlyNominalOrElevated() throws {
        try withRepository { repository, store in
            let fixture = try makePlacedFixture()
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            _ = try repository.recordNodeCapacity(snapshot: fixture.nodeSnapshot)

            let critical = try SchedulerHostPressureRecord(
                nodeID: fixture.binding.nodeID,
                posture: SchedulerHostPosture(
                    pressure: .critical,
                    energy: .balanced
                ),
                generation: 2,
                observedAt: timestamp(1),
                evidenceDigest: digest("b"),
                policyState: try pressurePolicyState(
                    reasonCodes: [.memoryCritical],
                    nextPosture: .blocked
                )
            )
            _ = try repository.recordHostPressure(record: critical)

            XCTAssertThrowsError(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: fixture.currentAuthority
                )
            ) { error in
                XCTAssertEqual(
                    (error as? SchedulerAdmissionError)?.stableKey,
                    "stale-input:pressure-snapshot"
                )
            }

            let criticalAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: fixture.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: fixture.nodeSnapshot.generation,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                expectedNodeEpoch: 1,
                expectedPressureGeneration: critical.generation,
                expectedPressureEvidenceDigest: critical.evidenceDigest,
                expectedPressurePosture: .critical,
                leaseCreatedAt: timestamp(2),
                leaseExpiresAt: timestamp(4)
            )
            XCTAssertThrowsError(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: criticalAuthority
                )
            ) { error in
                XCTAssertEqual(
                    (error as? SchedulerAdmissionError)?.stableKey,
                    "invalid-binding:pressure-not-admissible"
                )
            }

            let elevated = try SchedulerHostPressureRecord(
                nodeID: fixture.binding.nodeID,
                posture: SchedulerHostPosture(
                    pressure: .elevated,
                    energy: .balanced
                ),
                generation: 3,
                observedAt: timestamp(2),
                evidenceDigest: digest("e"),
                policyState: try pressurePolicyState(
                    reasonCodes: [.memoryWarning],
                    nextPosture: .deweighted
                )
            )
            _ = try repository.recordHostPressure(record: elevated)
            let elevatedAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: fixture.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: fixture.nodeSnapshot.generation,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                expectedNodeEpoch: 1,
                expectedPressureGeneration: elevated.generation,
                expectedPressureEvidenceDigest: elevated.evidenceDigest,
                expectedPressurePosture: .elevated,
                leaseCreatedAt: timestamp(3),
                leaseExpiresAt: timestamp(5)
            )
            XCTAssertNotNil(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: elevatedAuthority
                ).reservation
            )
            _ = store
        }
    }

    func testProjectResolverAndProjectScopedArtifactLookupAreExplicit() throws {
        try withRepository { repository, _ in
            XCTAssertEqual(
                try repository.projectResourceUUID(forProjectID: "project-a"),
                projectUUID
            )
            XCTAssertEqual(
                try repository.projectAuthority(forProjectID: "project-a")?.resourceUUID,
                projectUUID
            )
            XCTAssertEqual(
                try repository.projectAuthority(forResourceUUID: projectUUID)?.projectID,
                "project-a"
            )
            XCTAssertNil(try repository.projectResourceUUID(forProjectID: "missing-project"))
            let fixture = try makePlacedFixture()
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            XCTAssertThrowsError(
                try repository.decisionArtifact(
                    id: fixture.artifact.decisionID,
                    projectUUID: "00000000-0000-0000-0000-000000000906"
                )
            )
        }
    }

    func testFenceReleaseRoundTripUsesReservationLineageAndExactEvidenceTimes() throws {
        try withRepository { repository, _ in
            let fixture = try makePlacedFixture()
            _ = try repository.recordNodeCapacity(snapshot: fixture.nodeSnapshot)
            _ = try repository.recordDecisionArtifact(
                decision: fixture.artifact.decision,
                workloadBindings: fixture.artifact.workloadBindings,
                projectUUID: fixture.artifact.projectUUID,
                configDigest: fixture.artifact.configDigest,
                profileDigest: fixture.artifact.profileDigest,
                lifecyclePlanDigest: fixture.artifact.lifecyclePlanDigest,
                createdAt: fixture.artifact.createdAt,
                updatedAt: fixture.artifact.updatedAt
            )
            let pending = try XCTUnwrap(
                try repository.applyDecision(
                    decisionID: fixture.artifact.decisionID,
                    projectUUID: fixture.artifact.projectUUID,
                    workloadID: fixture.binding.workloadID,
                    expectedInputDigest: fixture.artifact.inputDigest,
                    currentAuthority: fixture.currentAuthority
                ).reservation
            )
            _ = try repository.recoverNode(
                evidence: SchedulerNodeRecoveryEvidence(
                    nodeID: pending.nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: digest("c"),
                    verifiedAt: timestamp(2)
                )
            )
            let fenceEvidence = try SchedulerFenceEvidence(
                token: SchedulerFencingToken(
                    nodeEpoch: 2,
                    reservationSequence: pending.fencingToken.reservationSequence
                ),
                reservationID: pending.reservationID,
                workloadID: pending.workloadID,
                evidenceDigest: digest("f"),
                verifiedAt: timestamp(2)
            )
            let fenced = try repository.fence(
                reservationID: pending.reservationID,
                evidence: fenceEvidence
            )
            XCTAssertEqual(fenced.status, .fenced)
            XCTAssertEqual(fenced.updatedAt, fenceEvidence.verifiedAt)
            let reopenedFenced = try XCTUnwrap(
                repository.reservation(id: pending.reservationID)
            )
            XCTAssertEqual(reopenedFenced, fenced)

            let released = try repository.release(
                reservationID: pending.reservationID,
                expectedToken: pending.fencingToken,
                evidence: .authoritativeFence(
                    token: fenceEvidence.token,
                    reservationID: pending.reservationID,
                    workloadID: pending.workloadID,
                    evidenceDigest: digest("d"),
                    verifiedAt: timestamp(3)
                )
            )
            XCTAssertEqual(released.status, .released)
            XCTAssertEqual(released.updatedAt, timestamp(3))
            XCTAssertLessThanOrEqual(
                ISO8601DateFormatter().date(from: fenceEvidence.verifiedAt)!,
                ISO8601DateFormatter().date(from: released.updatedAt)!
            )
            XCTAssertEqual(
                try JSONDecoder().decode(
                    SchedulerReservationRecord.self,
                    from: JSONEncoder().encode(released)
                ),
                released
            )

            let reopenedFixture = try makePlacedFixture(
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000913")!,
                nodeID: pending.nodeID
            )
            _ = try repository.recordDecisionArtifact(
                decision: reopenedFixture.artifact.decision,
                workloadBindings: reopenedFixture.artifact.workloadBindings,
                projectUUID: reopenedFixture.artifact.projectUUID,
                configDigest: reopenedFixture.artifact.configDigest,
                profileDigest: reopenedFixture.artifact.profileDigest,
                lifecyclePlanDigest: reopenedFixture.artifact.lifecyclePlanDigest,
                createdAt: reopenedFixture.artifact.createdAt,
                updatedAt: reopenedFixture.artifact.updatedAt
            )
            let currentEpochAuthority = try SchedulerAdmissionCurrentAuthority(
                nodeCapacityDigest: reopenedFixture.nodeSnapshot.capacityDigest,
                nodeCapacityGeneration: reopenedFixture.nodeSnapshot.generation,
                configDigest: reopenedFixture.artifact.configDigest,
                profileDigest: reopenedFixture.artifact.profileDigest,
                lifecyclePlanDigest: reopenedFixture.artifact.lifecyclePlanDigest,
                expectedNodeEpoch: 2,
                expectedPressureGeneration: 1,
                expectedPressureEvidenceDigest: digest("a"),
                expectedPressurePosture: .nominal,
                leaseCreatedAt: timestamp(5),
                leaseExpiresAt: timestamp(6)
            )
            let reopened = try XCTUnwrap(
                try repository.applyDecision(
                    decisionID: reopenedFixture.artifact.decisionID,
                    projectUUID: projectUUID,
                    workloadID: reopenedFixture.binding.workloadID,
                    expectedInputDigest: reopenedFixture.artifact.inputDigest,
                    currentAuthority: currentEpochAuthority
                ).reservation
            )
            let verifiedAbsence = try repository.release(
                reservationID: reopened.reservationID,
                expectedToken: reopened.fencingToken,
                evidence: .verifiedRuntimeAbsence(
                    evidenceDigest: digest("d"),
                    verifiedAt: timestamp(6)
                )
            )
            XCTAssertEqual(verifiedAbsence.status, .released)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    SchedulerReservationRecord.self,
                    from: JSONEncoder().encode(verifiedAbsence)
                ),
                verifiedAbsence
            )
        }
    }

    private struct PlacedFixture {
        let artifact: SchedulerDecisionArtifactRecord
        let binding: SchedulerDecisionWorkloadBinding
        let nodeSnapshot: SchedulerNodeCapacitySnapshot
        let currentAuthority: SchedulerAdmissionCurrentAuthority
    }

    private func makePlacedFixture(
        workloadID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
        nodeID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
        capacity: ResourceVector? = nil
    ) throws -> PlacedFixture {
        let workload = try SchedulerWorkload(
            requirements: try WorkloadPlacementRequirements(
                workloadID: workloadID,
                request: try ResourceVector(["cpu": 1]),
                requiredArchitectures: ["arm64"]
            ),
            priority: 10,
            subjectID: "owner",
            projectID: "project-a"
        )
        let nodeCapacity: ResourceVector
        if let capacity {
            nodeCapacity = capacity
        } else {
            nodeCapacity = try ResourceVector(["cpu": 4])
        }
        let node = try SchedulerNode(
            snapshot: try NodePlacementSnapshot(
                nodeID: nodeID,
                capacity: nodeCapacity,
                allocation: try ResourceVector(["cpu": 0]),
                architecture: "arm64",
                runtime: "linux-vm",
                provider: "provider"
            )
        )
        let decision = try SchedulerEngine().plan(
            SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node]
            )
        )
        let selected = try XCTUnwrap(decision.workloadDecisions.first)
        let selectedNodeID = try XCTUnwrap(selected.chosenNodeID)
        let nodeSnapshot = try SchedulerNodeCapacitySnapshot(
            nodeID: nodeID,
            capacity: nodeCapacity,
            generation: 1,
            observedAt: timestamp(0)
        )
        let binding = try SchedulerDecisionWorkloadBinding(
            workloadID: workloadID,
            nodeID: selectedNodeID,
            resources: workload.request,
            capacityDigest: nodeSnapshot.capacityDigest,
            capacityGeneration: nodeSnapshot.generation,
            ownerSubjectID: "owner",
            projectUUID: projectUUID
        )
        let artifact = try SchedulerDecisionArtifactRecord(
            decision: decision,
            workloadBindings: [binding],
            projectUUID: projectUUID,
            configDigest: digest("c"),
            profileDigest: digest("a"),
            lifecyclePlanDigest: digest("d"),
            createdAt: timestamp(0),
            updatedAt: timestamp(1)
        )
        let currentAuthority = try SchedulerAdmissionCurrentAuthority(
            nodeCapacityDigest: nodeSnapshot.capacityDigest,
            nodeCapacityGeneration: nodeSnapshot.generation,
            configDigest: artifact.configDigest,
            profileDigest: artifact.profileDigest,
            lifecyclePlanDigest: artifact.lifecyclePlanDigest,
            expectedNodeEpoch: 1,
            expectedPressureGeneration: 1,
            expectedPressureEvidenceDigest: digest("a"),
            expectedPressurePosture: .nominal,
            leaseCreatedAt: timestamp(2),
            leaseExpiresAt: timestamp(4)
        )
        return PlacedFixture(
            artifact: artifact,
            binding: binding,
            nodeSnapshot: nodeSnapshot,
            currentAuthority: currentAuthority
        )
    }

    private func withRepository(
        _ body: (SchedulerAdmissionRepository, SQLiteStateStore) throws -> Void
    ) throws {
        try withTemporaryStore { store in
            try insertProject(in: store)
            try store.controlIdentities.bootstrap(
                ControlPeerIdentityRecord(
                    subjectID: "owner",
                    userID: 501,
                    codeIdentity: CodeIdentity(
                        teamIdentifier: "993YC3JY4Q",
                        signingIdentifier: "hostwright",
                        codeDirectoryHash: String(repeating: "a", count: 40),
                        validationMode: .installedRequirement
                    ),
                    declaredBySubjectID: "owner",
                    declaredAt: timestamp(0),
                    updatedAt: timestamp(0)
                )
            )
            _ = try store.schedulerAdmissions.recordHostPressure(
                record: try SchedulerHostPressureRecord(
                    nodeID: nodeID,
                    posture: SchedulerHostPosture(
                        pressure: .nominal,
                        energy: .balanced
                    ),
                    generation: 1,
                    observedAt: timestamp(0),
                    evidenceDigest: digest("a"),
                    policyState: try pressurePolicyState(
                        reasonCodes: [.allowed],
                        nextPosture: .allowed
                    )
                )
            )
            try body(store.schedulerAdmissions, store)
        }
    }

    private func withTemporaryStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-scheduler-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        // The v22 authority append is covered by the dedicated migration
        // tests; repository behavior must reopen against the current v23
        // production schema.
        try MigrationRunner().apply(
            to: store,
            throughVersion: MigrationRunner.latestSchemaVersion
        )
        try body(store)
    }

    private func insertProject(in store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash, created_at, updated_at,
                    resource_uuid, manifest_version, mutation_provider, provider_generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text("project-a"),
                    .text("project-a"),
                    .null,
                    .text(String(repeating: "a", count: 64)),
                    .text(timestamp(0)),
                    .text(timestamp(0)),
                    .text("00000000-0000-0000-0000-000000000905"),
                    .int(1),
                    .null,
                    .int(0),
                ]
            )
        }
    }

    private func pressurePolicyState(
        reasonCodes: [SchedulerHostPressureReasonCode],
        nextPosture: SchedulerHostPressurePolicyPosture,
        clearObservations: Int = 0
    ) throws -> SchedulerHostPressurePolicyState {
        try SchedulerHostPressurePolicyState(
            version: SchedulerHostPressurePolicyState.currentVersion,
            reasonCodes: reasonCodes,
            nextHysteresisState: try SchedulerHostPressureHysteresisState(
                posture: nextPosture,
                consecutiveClearObservations: clearObservations,
                version: SchedulerHostPressurePolicyState.currentVersion
            )
        )
    }

    private func timestamp(_ offset: Int) -> String {
        "2026-08-05T12:0\(offset):00Z"
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private var nodeID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
    }

}
