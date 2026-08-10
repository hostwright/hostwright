import Foundation
import XCTest

import HostwrightControlPlane
import HostwrightCore
import HostwrightScheduler
// @testable is setup-only for the isolated SQLite project/peer seed; the
// admission, reservation, recovery, and fencing assertions use public APIs.
@testable import HostwrightState

final class Phase10StateRecoveryQualificationAdmissionTests: XCTestCase {
    private let createdAt = "2026-08-05T12:00:00Z"
    private let expiry = "2026-08-05T12:04:00Z"
    private let projectUUID = "00000000-0000-0000-0000-0000000000a1"

    func testPhase10SchedulerAdmissionReservationRaceHasOneWinnerPerBoundedRound() async throws {
        let rounds = ProcessInfo.processInfo.environment[
            "HOSTWRIGHT_PHASE10_FULL_MATRIX"
        ] == "1" ? 8 : 1

        for round in 0..<rounds {
            try await withRepositoryAsync { repository, _ in
                let capacity = try nodeCapacity(
                    nodeID: UUID(),
                    cpu: 1
                )
                _ = try repository.recordNodeCapacity(snapshot: capacity)

                let firstBinding = try binding(
                    decisionID: UUID(),
                    workloadID: UUID(),
                    capacity: capacity
                )
                let secondBinding = try binding(
                    decisionID: UUID(),
                    workloadID: UUID(),
                    capacity: capacity
                )
                try recordArtifact(for: firstBinding, repository: repository)
                try recordArtifact(for: secondBinding, repository: repository)
                let firstAuthority = try authority(for: firstBinding)
                let secondAuthority = try authority(for: secondBinding)
                let startGate = Phase10StartGate()

                let outcomes = await withTaskGroup(of: Phase10RaceOutcome.self) {
                    group in
                    group.addTask {
                        await startGate.wait()
                        do {
                            let reservation = try repository.reserve(
                                binding: firstBinding,
                                authority: firstAuthority
                            )
                            return .won(reservation.reservationID)
                        } catch let error as SchedulerAdmissionError {
                            return .failed(error)
                        } catch {
                            return .unexpected(String(describing: error))
                        }
                    }
                    group.addTask {
                        await startGate.wait()
                        do {
                            let reservation = try repository.reserve(
                                binding: secondBinding,
                                authority: secondAuthority
                            )
                            return .won(reservation.reservationID)
                        } catch let error as SchedulerAdmissionError {
                            return .failed(error)
                        } catch {
                            return .unexpected(String(describing: error))
                        }
                    }

                    var collected: [Phase10RaceOutcome] = []
                    for await outcome in group {
                        collected.append(outcome)
                    }
                    return collected
                }

                let winners = outcomes.compactMap { outcome -> UUID? in
                    guard case .won(let reservationID) = outcome else { return nil }
                    return reservationID
                }
                XCTAssertEqual(winners.count, 1, "round \(round): \(outcomes)")
                XCTAssertEqual(
                    outcomes.filter { outcome in
                        guard case .failed(.insufficientCapacity(_, _, _)) = outcome else {
                            return false
                        }
                        return true
                    }.count,
                    1,
                    "round \(round): \(outcomes)"
                )
                XCTAssertFalse(
                    outcomes.contains { outcome in
                        if case .unexpected = outcome { return true }
                        return false
                    },
                    "round \(round): \(outcomes)"
                )
                XCTAssertEqual(
                    try repository.activeCapacity(nodeID: capacity.nodeID),
                    try ResourceVector(["cpu": 1])
                )
            }
        }
    }

    func testPhase10SchedulerRecoveryFencesStaleReservationAndReleasesWithEvidence() throws {
        try withRepository { repository, store in
            let capacity = try nodeCapacity(
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000a01")!,
                cpu: 2
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let binding = try binding(
                decisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000a11")!,
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000a21")!,
                capacity: capacity
            )
            try recordArtifact(for: binding, repository: repository)
            let reservation = try repository.reserve(
                binding: binding,
                authority: try authority(for: binding)
            )

            let recoveryEvidence = try SchedulerNodeRecoveryEvidence(
                nodeID: capacity.nodeID,
                expectedNodeEpoch: 1,
                newNodeEpoch: 2,
                evidenceDigest: String(repeating: "a", count: 64),
                verifiedAt: "2026-08-05T12:01:00Z"
            )
            let recovered = try repository.recoverNode(evidence: recoveryEvidence)
            XCTAssertEqual(recovered.nodeEpoch, 2)
            XCTAssertEqual(recovered.nextReservationSequence, 2)
            XCTAssertEqual(
                try repository.recoverNode(evidence: recoveryEvidence),
                recovered
            )

            XCTAssertThrowsError(
                try repository.commit(
                    reservationID: reservation.reservationID,
                    expectedToken: reservation.fencingToken,
                    updatedAt: "2026-08-05T12:02:00Z"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleNodeEpoch(nodeID: capacity.nodeID, expected: 1, actual: 2)
                )
            }

            let currentToken = try SchedulerFencingToken(
                nodeEpoch: 2,
                reservationSequence: reservation.fencingToken.reservationSequence
            )
            let fenceEvidence = try SchedulerFenceEvidence(
                token: currentToken,
                reservationID: reservation.reservationID,
                workloadID: reservation.workloadID,
                evidenceDigest: String(repeating: "b", count: 64),
                verifiedAt: "2026-08-05T12:03:00Z"
            )
            let fenced = try repository.fence(
                reservationID: reservation.reservationID,
                evidence: fenceEvidence
            )
            XCTAssertEqual(fenced.status, .fenced)

            let released = try repository.release(
                reservationID: reservation.reservationID,
                expectedToken: reservation.fencingToken,
                evidence: .authoritativeFence(
                    token: currentToken,
                    reservationID: reservation.reservationID,
                    workloadID: reservation.workloadID,
                    evidenceDigest: String(repeating: "c", count: 64),
                    verifiedAt: "2026-08-05T12:04:00Z"
                )
            )
            XCTAssertEqual(released.status, .released)
            XCTAssertEqual(try repository.activeCapacity(nodeID: capacity.nodeID), .zero)

            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(
                try reopened.schedulerAdmissions.reservation(
                    id: reservation.reservationID
                ),
                released
            )
            XCTAssertEqual(
                try reopened.schedulerAdmissions.fencingState(nodeID: capacity.nodeID)
                    .nodeEpoch,
                2
            )
        }
    }

    func testPhase10PendingReservationSurvivesCrashReopenWithoutExpiryReuse() throws {
        try withRepository { repository, store in
            let capacity = try nodeCapacity(
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000a41")!,
                cpu: 1
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)

            let firstBinding = try binding(
                decisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000a42")!,
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000a43")!,
                capacity: capacity
            )
            try recordArtifact(for: firstBinding, repository: repository)
            let pending = try repository.reserve(
                binding: firstBinding,
                authority: try authority(for: firstBinding)
            )

            // A fresh repository instance is the crash/restart boundary. The
            // pending lease remains authoritative and continues charging the
            // node; expiration alone never frees capacity.
            let reopened = SQLiteStateStore(path: store.path)
            let reopenedRepository = reopened.schedulerAdmissions
            XCTAssertEqual(
                try reopenedRepository.reservation(id: pending.reservationID),
                pending
            )
            XCTAssertEqual(
                try reopenedRepository.activeCapacity(nodeID: capacity.nodeID),
                try ResourceVector(["cpu": 1])
            )

            let secondBinding = try binding(
                decisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000a44")!,
                workloadID: UUID(uuidString: "00000000-0000-0000-0000-000000000a45")!,
                capacity: capacity
            )
            try recordArtifact(for: secondBinding, repository: reopenedRepository)
            XCTAssertThrowsError(
                try reopenedRepository.reserve(
                    binding: secondBinding,
                    authority: try authority(for: secondBinding)
                )
            ) { error in
                guard let admissionError = error as? SchedulerAdmissionError,
                      case .insufficientCapacity = admissionError else {
                    return XCTFail("Expected pending reservation to retain capacity, got \(error).")
                }
            }

            let committed = try reopenedRepository.commit(
                reservationID: pending.reservationID,
                expectedToken: pending.fencingToken,
                updatedAt: "2026-08-05T12:05:00Z"
            )
            XCTAssertEqual(committed.status, .committed)
            XCTAssertEqual(
                try reopenedRepository.activeCapacity(nodeID: capacity.nodeID),
                try ResourceVector(["cpu": 1])
            )
        }
    }

    private enum Phase10RaceOutcome: Sendable, CustomStringConvertible {
        case won(UUID)
        case failed(SchedulerAdmissionError)
        case unexpected(String)

        var description: String {
            switch self {
            case .won(let reservationID):
                return "won:\(reservationID.uuidString.lowercased())"
            case .failed(let error):
                return "failed:\(error)"
            case .unexpected(let message):
                return "unexpected:\(message)"
            }
        }
    }

    private func nodeCapacity(
        nodeID: UUID,
        cpu: Int64
    ) throws -> SchedulerNodeCapacitySnapshot {
        try SchedulerNodeCapacitySnapshot(
            nodeID: nodeID,
            capacity: ResourceVector(["cpu": cpu]),
            generation: 1,
            observedAt: createdAt
        )
    }

    private func binding(
        decisionID: UUID,
        workloadID: UUID,
        capacity: SchedulerNodeCapacitySnapshot
    ) throws -> SchedulerAdmissionBinding {
        try SchedulerAdmissionBinding(
            decisionID: decisionID,
            workloadID: workloadID,
            nodeID: capacity.nodeID,
            resources: try ResourceVector(["cpu": 1]),
            nodeCapacityDigest: capacity.capacityDigest,
            nodeCapacityGeneration: capacity.generation,
            inputDigest: String(repeating: "1", count: 64),
            configDigest: String(repeating: "2", count: 64),
            profileDigest: String(repeating: "3", count: 64),
            lifecyclePlanDigest: String(repeating: "4", count: 64),
            ownerSubjectID: "owner",
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
            createdAt: binding.createdAt,
            updatedAt: binding.createdAt
        )
    }

    private func withRepository<T>(
        _ body: (SchedulerAdmissionRepository, SQLiteStateStore) throws -> T
    ) throws -> T {
        let root = try makeRepositoryRoot()
        defer { cleanupRepositoryRoot(root) }
        let store = try makeStore(at: root)
        return try body(SchedulerAdmissionRepository(store: store), store)
    }

    private func withRepositoryAsync<T>(
        _ body: (SchedulerAdmissionRepository, SQLiteStateStore) async throws -> T
    ) async throws -> T {
        let root = try makeRepositoryRoot()
        defer { cleanupRepositoryRoot(root) }
        let store = try makeStore(at: root)
        return try await body(SchedulerAdmissionRepository(store: store), store)
    }

    private func makeRepositoryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-phase10-admission-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = parent.appendingPathComponent("phase10-admission", isDirectory: true)
        try validatePhase10Root(parent, ownedChild: root)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = parent.appendingPathComponent("caller-owned-sentinel")
        try Data("caller-owned".utf8).write(to: sentinel)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sentinel.path
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func cleanupRepositoryRoot(_ root: URL) {
        let parent = root.deletingLastPathComponent()
        let sentinel = parent.appendingPathComponent("caller-owned-sentinel")
        removeIfPresent(root)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "Phase10 temporary root leaked: \(root.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path),
            "Caller-owned sentinel was removed by Phase10 cleanup: \(sentinel.path)"
        )
        removeIfPresent(sentinel)
        removeIfPresent(parent)
    }

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {
            XCTFail("Phase10 cleanup failed for \(url.path): \(error)")
        }
    }

    private func makeStore(at root: URL) throws -> SQLiteStateStore {
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try store.controlIdentities.bootstrap(
            ControlPeerIdentityRecord(
                subjectID: "owner",
                userID: 501,
                codeIdentity: CodeIdentity(
                    teamIdentifier: "993YC3JY4Q",
                    signingIdentifier: "hostwright.phase10.qualification",
                    codeDirectoryHash: String(repeating: "a", count: 40),
                    validationMode: .installedRequirement
                ),
                declaredBySubjectID: "owner",
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
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, 1, NULL, 0)
                """,
                bindings: [
                    .text("phase10-project"),
                    .text("phase10-project"),
                    .text(String(repeating: "a", count: 64)),
                    .text(createdAt),
                    .text(createdAt),
                    .text(projectUUID),
                ]
            )
        }
        return store
    }

    private func validatePhase10Root(_ parent: URL, ownedChild: URL) throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let normalizedParent = parent.standardizedFileURL.path.lowercased()
        let normalizedChild = ownedChild.standardizedFileURL.path.lowercased()
        guard parent.standardizedFileURL.path.hasPrefix(temporaryRoot.path),
              normalizedParent.contains("hostwright-phase10"),
              normalizedChild.contains("phase10-admission"),
              !normalizedParent.contains("phase08"),
              !normalizedParent.contains("phase09"),
              !normalizedParent.contains("evidence") else {
            throw NSError(
                domain: "HostwrightPhase10Isolation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Phase10 admission qualification root (parent.path)"]
            )
        }
    }
}

private actor Phase10StartGate {
    private var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        waiting += 1
        if waiting == 2 {
            let pending = continuations
            continuations.removeAll(keepingCapacity: false)
            pending.forEach { $0.resume() }
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
