import Foundation
import XCTest

import HostwrightControlPlane
import HostwrightCore
import HostwrightScheduler
// @testable is setup-only for the isolated SQLite project/peer seed; all
// control, reservation, recovery, and capability assertions use public APIs.
@testable import HostwrightState

final class Phase10ControlCompatibilityQualificationTests: XCTestCase {
    private let createdAt = "2026-08-05T12:00:00Z"
    private let expiry = "2026-08-05T12:04:00Z"
    private let projectUUID = "00000000-0000-0000-0000-0000000000a1"

    func testRevisionWindowKeepsSchedulerCurrentAndAuthenticationFrozen() throws {
        XCTAssertTrue(
            ControlProtocolCompatibility.supportsRequestRevision(.previous)
        )
        XCTAssertTrue(
            ControlProtocolCompatibility.supportsRequestRevision(.current)
        )
        XCTAssertFalse(
            ControlProtocolCompatibility.supportsRequestRevision(.legacy)
        )
        XCTAssertEqual(
            ControlProtocolCompatibility.requiredRevision(for: "scheduler.plan"),
            .current
        )
        XCTAssertEqual(
            ControlProtocolCompatibility.requiredRevision(for: "scheduler.simulate"),
            .current
        )
        XCTAssertTrue(
            ControlProtocolCompatibility.acceptsRequest(
                operation: "scheduler.plan",
                revision: .current
            )
        )
        XCTAssertFalse(
            ControlProtocolCompatibility.acceptsRequest(
                operation: "scheduler.plan",
                revision: .previous
            )
        )
        XCTAssertNoThrow(
            try ControlProtocolCompatibility.validateAuthenticationRevision(.previous)
        )
        XCTAssertThrowsError(
            try ControlProtocolCompatibility.validateAuthenticationRevision(.current)
        )
        XCTAssertEqual(
            ControlProtocolCompatibility.credentialProofLabel(for: .previous),
            ControlProtocolCompatibility.frozenAuthenticationProtocolLabel
        )
        XCTAssertNil(
            ControlProtocolCompatibility.credentialProofLabel(for: .current)
        )
    }

    func testEverySchedulerOperationRequiresCurrentRevision() throws {
        for operation in SchedulerControlOperation.allCases {
            XCTAssertEqual(
                ControlProtocolCompatibility.requiredRevision(for: operation.rawValue),
                .current,
                operation.rawValue
            )
            XCTAssertTrue(
                ControlProtocolCompatibility.acceptsRequest(
                    operation: operation.rawValue,
                    revision: .current
                ),
                operation.rawValue
            )
            XCTAssertFalse(
                ControlProtocolCompatibility.acceptsRequest(
                    operation: operation.rawValue,
                    revision: .previous
                ),
                operation.rawValue
            )
        }
    }

    func testSchedulerWireAndEnvelopeBoundariesRejectUnexpectedFields() throws {
        let input: ControlPlaneJSONValue = .object([
            "pendingWorkloads": .array([]),
            "nodes": .array([]),
        ])
        let body: ControlPlaneJSONValue = .object([
            "projectID": .string("phase10-project"),
            "input": input,
        ])
        let scoped = try SchedulerControlWireContract.scopedInputData(from: body)
        XCTAssertEqual(scoped.projectID, "phase10-project")
        XCTAssertFalse(scoped.inputData.isEmpty)
        XCTAssertLessThanOrEqual(
            scoped.inputData.count,
            SchedulerControlWireContract.maximumInputBytes
        )

        XCTAssertThrowsError(
            try SchedulerControlWireContract.scopedInputData(from: .object([
                "projectID": .string("phase10-project"),
                "input": input,
                "unexpected": .bool(true),
            ]))
        )
        XCTAssertThrowsError(
            try SchedulerControlWireContract.scopedInputData(from: .object([
                "projectID": .string("phase10-project"),
                "input": .object([
                    "pendingWorkloads": .array([]),
                    "nodes": .array([]),
                    "unexpected": .null,
                ]),
            ]))
        )
        XCTAssertThrowsError(
            try SchedulerControlWireContract.scopedInputData(from: .object([
                "projectID": .string("phase10 project"),
                "input": input,
            ]))
        )
        XCTAssertThrowsError(
            try SchedulerControlWireContract.scopedInputData(from: .object([
                "projectID": .string(
                    String(repeating: "p", count: SchedulerControlWireContract.maximumProjectIDBytes + 1)
                ),
                "input": input,
            ]))
        )

        XCTAssertNoThrow(
            try ControlRequestEnvelope(
                protocolRevision: nil,
                requestID: "legacy-health",
                operation: "health.get"
            ).validate()
        )
        XCTAssertThrowsError(
            try ControlRequestEnvelope(
                protocolRevision: nil,
                requestID: "legacy-scheduler",
                operation: "scheduler.plan"
            ).validate()
        )
        XCTAssertThrowsError(
            try ControlRequestEnvelope(
                apiVersion: ControlPlaneContract.apiVersion + 1,
                protocolRevision: .current,
                requestID: "bad-api",
                operation: "health.get",
                timeoutMilliseconds: 1
            ).validate()
        )
        XCTAssertThrowsError(
            try Phase09StrictDecoder.validateNoDuplicateKeys(
                Data("{\"nodes\":[],\"nodes\":[]}".utf8)
            )
        )
    }

    func testSchedulerReservationRaceCommitsOnlyOneCapacityWinner() async throws {
        let (repository, sandbox) = try makeRepository()
        defer { cleanupQualificationRoot(sandbox) }

        let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000720")!
        let capacity = try SchedulerNodeCapacitySnapshot(
            nodeID: nodeID,
            capacity: try ResourceVector(["cpu": 100]),
            generation: 1,
            observedAt: createdAt
        )
        _ = try repository.recordNodeCapacity(snapshot: capacity)

        let bindingA = try binding(
            decision: "00000000-0000-0000-0000-000000000721",
            workload: "00000000-0000-0000-0000-000000000731",
            nodeID: nodeID,
            resources: ["cpu": 60],
            capacity: capacity
        )
        let bindingB = try binding(
            decision: "00000000-0000-0000-0000-000000000722",
            workload: "00000000-0000-0000-0000-000000000732",
            nodeID: nodeID,
            resources: ["cpu": 60],
            capacity: capacity
        )
        try recordArtifact(for: bindingA, repository: repository)
        try recordArtifact(for: bindingB, repository: repository)
        let requests = [
            (bindingA, try authority(for: bindingA)),
            (bindingB, try authority(for: bindingB)),
        ]

        let outcomes = await withTaskGroup(
            of: ReservationRaceOutcome.self,
            returning: [ReservationRaceOutcome].self
        ) { group in
            for (binding, authority) in requests {
                group.addTask {
                    do {
                        _ = try repository.reserve(
                            binding: binding,
                            authority: authority
                        )
                        return ReservationRaceOutcome(
                            succeeded: true,
                            errorCode: nil
                        )
                    } catch let error as SchedulerAdmissionError {
                        return ReservationRaceOutcome(
                            succeeded: false,
                            errorCode: error.code
                        )
                    } catch {
                        return ReservationRaceOutcome(
                            succeeded: false,
                            errorCode: nil
                        )
                    }
                }
            }

            var collected: [ReservationRaceOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        XCTAssertEqual(outcomes.filter(\.succeeded).count, 1)
        XCTAssertEqual(
            outcomes.filter { $0.errorCode == .insufficientCapacity }.count,
            1
        )
        XCTAssertEqual(try repository.reservations(nodeID: nodeID).count, 1)
        XCTAssertEqual(
            try repository.availableCapacity(nodeID: nodeID).values,
            ["cpu": 40]
        )
    }

    func testSchedulerRecoveryReleaseAndReplayRequireFreshLineageEvidence() throws {
        let (repository, sandbox) = try makeRepository()
        defer { cleanupQualificationRoot(sandbox) }

        let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000740")!
        let capacity = try SchedulerNodeCapacitySnapshot(
            nodeID: nodeID,
            capacity: try ResourceVector(["cpu": 4]),
            generation: 1,
            observedAt: createdAt
        )
        _ = try repository.recordNodeCapacity(snapshot: capacity)
        let binding = try binding(
            decision: "00000000-0000-0000-0000-000000000741",
            workload: "00000000-0000-0000-0000-000000000751",
            nodeID: nodeID,
            resources: ["cpu": 2],
            capacity: capacity
        )
        try recordArtifact(for: binding, repository: repository)
        let reservation = try repository.reserve(
            binding: binding,
            authority: try authority(for: binding)
        )
        _ = try repository.commit(
            reservationID: reservation.reservationID,
            expectedToken: reservation.fencingToken,
            updatedAt: "2026-08-05T12:01:00Z"
        )
        _ = try repository.requestRelease(
            reservationID: reservation.reservationID,
            expectedToken: reservation.fencingToken,
            updatedAt: "2026-08-05T12:02:00Z"
        )

        XCTAssertThrowsError(
            try repository.release(
                reservationID: reservation.reservationID,
                expectedToken: try SchedulerFencingToken(
                    nodeEpoch: 1,
                    reservationSequence: reservation.fencingToken.reservationSequence + 1
                ),
                evidence: .verifiedRuntimeAbsence(
                    evidenceDigest: String(repeating: "c", count: 64),
                    verifiedAt: "2026-08-05T12:03:00Z"
                )
            )
        ) { error in
            guard case .staleFence = error as? SchedulerAdmissionError else {
                return XCTFail("Expected stale fence, got \(error)")
            }
        }

        let evidence = SchedulerReleaseEvidence.verifiedRuntimeAbsence(
            evidenceDigest: String(repeating: "d", count: 64),
            verifiedAt: "2026-08-05T12:03:00Z"
        )
        let released = try repository.release(
            reservationID: reservation.reservationID,
            expectedToken: reservation.fencingToken,
            evidence: evidence
        )
        XCTAssertEqual(released.status, .released)
        XCTAssertEqual(try repository.release(
            reservationID: reservation.reservationID,
            expectedToken: reservation.fencingToken,
            evidence: evidence
        ), released)
        XCTAssertEqual(try repository.availableCapacity(nodeID: nodeID).values, ["cpu": 4])

        let recovery = try SchedulerNodeRecoveryEvidence(
            nodeID: nodeID,
            expectedNodeEpoch: 1,
            newNodeEpoch: 2,
            evidenceDigest: String(repeating: "e", count: 64),
            verifiedAt: "2026-08-05T12:04:00Z"
        )
        let recovered = try repository.recoverNode(evidence: recovery)
        XCTAssertEqual(recovered.nodeEpoch, 2)
        XCTAssertEqual(try repository.recoverNode(evidence: recovery), recovered)

        XCTAssertThrowsError(
            try repository.recoverNode(
                evidence: try SchedulerNodeRecoveryEvidence(
                    nodeID: nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 3,
                    evidenceDigest: String(repeating: "f", count: 64),
                    verifiedAt: "2026-08-05T12:05:00Z"
                )
            )
        ) { error in
            guard case .staleNodeEpoch = error as? SchedulerAdmissionError else {
                return XCTFail("Expected stale node epoch, got \(error)")
            }
        }
    }

    func testG15CapabilityCatalogKeepsOptimizationAndHostNativePending() throws {
        let capabilities = HostwrightCapabilityCatalog.report.capabilities
        XCTAssertEqual(
            capabilities.first(where: { $0.identifier == "scheduler.optimization" })?.state,
            .unavailable
        )
        XCTAssertEqual(
            capabilities.first(where: { $0.identifier == "accelerators.host-native" })?.state,
            .unavailable
        )
    }

    private struct ReservationRaceOutcome: Sendable {
        let succeeded: Bool
        let errorCode: SchedulerAdmissionErrorCode?
    }

    private struct QualificationSandbox {
        let root: URL
        let ownedRoot: URL
        let sentinel: URL
    }

    private func makeRepository() throws -> (
        repository: SchedulerAdmissionRepository,
        sandbox: QualificationSandbox
    ) {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let root = temporaryRoot.appendingPathComponent(
            "hostwright-phase10-qualification-\(UUID().uuidString)",
            isDirectory: true
        )
        let normalized = root.standardizedFileURL.path.lowercased()
        guard root.standardizedFileURL.path.hasPrefix(
            temporaryRoot.standardizedFileURL.path
        ), !normalized.contains("phase08"),
        !normalized.contains("phase09"), !normalized.contains("evidence") else {
            throw QualificationIsolationError.invalidRoot(root.path)
        }
        var prepared = false
        defer {
            if !prepared {
                try? FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = root.appendingPathComponent("qualification-sentinel")
        try Data("phase10-sentinel".utf8).write(to: sentinel, options: .atomic)
        let ownedRoot = root.appendingPathComponent("owned-state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ownedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = SQLiteStateStore(
            path: ownedRoot.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        try store.controlIdentities.bootstrap(
            ControlPeerIdentityRecord(
                subjectID: "phase10-qualification",
                userID: 501,
                codeIdentity: CodeIdentity(
                    teamIdentifier: "993YC3JY4Q",
                    signingIdentifier: "hostwright.phase10.qualification",
                    codeDirectoryHash: String(repeating: "a", count: 40),
                    validationMode: .installedRequirement
                ),
                declaredBySubjectID: "phase10-qualification",
                declaredAt: createdAt,
                updatedAt: createdAt
            )
        )
        try store.withValidatedConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash, created_at, updated_at,
                    resource_uuid, manifest_version, mutation_provider, provider_generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text("phase10-project"),
                    .text("phase10-project"),
                    .null,
                    .text(String(repeating: "a", count: 64)),
                    .text(createdAt),
                    .text(createdAt),
                    .text(projectUUID),
                    .int(1),
                    .null,
                    .int(0),
                ]
            )
        }
        prepared = true
        return (
            store.schedulerAdmissions,
            QualificationSandbox(root: root, ownedRoot: ownedRoot, sentinel: sentinel)
        )
    }

    private func cleanupQualificationRoot(_ sandbox: QualificationSandbox) {
        try? FileManager.default.removeItem(at: sandbox.ownedRoot)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandbox.ownedRoot.path),
            "Only the owned Phase 10 state child may be removed during cleanup."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sandbox.sentinel.path),
            "The cleanup sentinel must survive owned-child removal."
        )
        try? FileManager.default.removeItem(at: sandbox.sentinel)
        try? FileManager.default.removeItem(at: sandbox.root)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandbox.root.path),
            "Phase 10 qualification state must not leave temporary inventory behind."
        )
    }

    private func binding(
        decision: String,
        workload: String,
        nodeID: UUID,
        resources: [String: Int64],
        capacity: SchedulerNodeCapacitySnapshot
    ) throws -> SchedulerAdmissionBinding {
        try SchedulerAdmissionBinding(
            decisionID: UUID(uuidString: decision)!,
            workloadID: UUID(uuidString: workload)!,
            nodeID: nodeID,
            resources: try ResourceVector(resources),
            nodeCapacityDigest: capacity.capacityDigest,
            nodeCapacityGeneration: capacity.generation,
            inputDigest: String(repeating: "1", count: 64),
            configDigest: String(repeating: "2", count: 64),
            profileDigest: String(repeating: "3", count: 64),
            lifecyclePlanDigest: String(repeating: "4", count: 64),
            ownerSubjectID: "phase10-qualification",
            projectUUID: projectUUID,
            createdAt: createdAt,
            expiresAt: expiry
        )
    }

    private func authority(
        for binding: SchedulerAdmissionBinding
    ) throws -> SchedulerAdmissionAuthority {
        try SchedulerAdmissionAuthority(
            nodeCapacityDigest: binding.nodeCapacityDigest,
            nodeCapacityGeneration: binding.nodeCapacityGeneration,
            inputDigest: binding.inputDigest,
            configDigest: binding.configDigest,
            profileDigest: binding.profileDigest,
            lifecyclePlanDigest: binding.lifecyclePlanDigest,
            expectedNodeEpoch: 1
        )
    }

    private func recordArtifact(
        for binding: SchedulerAdmissionBinding,
        repository: SchedulerAdmissionRepository
    ) throws {
        let workloadDecision = try SchedulerWorkloadDecision(
            workloadID: binding.workloadID,
            outcome: .placed,
            chosenNodeID: binding.nodeID,
            scoreComponents: .zero,
            feasibleAlternatives: [],
            filterFailures: [],
            preemption: nil,
            explanation: try SchedulerDecisionExplanation(
                code: .placed,
                summary: "phase10 qualification placement"
            )
        )
        let decision = try SchedulerDecision(
            decisionID: binding.decisionID,
            inputDigest: binding.inputDigest,
            orderedWorkloadIDs: [binding.workloadID],
            workloadDecisions: [workloadDecision]
        )
        let artifactBinding = try SchedulerDecisionWorkloadBinding(
            workloadID: binding.workloadID,
            nodeID: binding.nodeID,
            resources: binding.resources,
            capacityDigest: binding.nodeCapacityDigest,
            capacityGeneration: binding.nodeCapacityGeneration,
            ownerSubjectID: binding.ownerSubjectID,
            projectUUID: binding.projectUUID
        )
        _ = try repository.recordDecisionArtifact(
            decision: decision,
            workloadBindings: [artifactBinding],
            projectUUID: binding.projectUUID,
            configDigest: binding.configDigest,
            profileDigest: binding.profileDigest,
            lifecyclePlanDigest: binding.lifecyclePlanDigest,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private enum QualificationIsolationError: Error {
        case invalidRoot(String)
    }
}
