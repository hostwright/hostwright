import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightCore
@testable import HostwrightScheduler
@testable import HostwrightState

final class SchedulerAdmissionRepositoryTests: XCTestCase {
    private let createdAt = "2026-08-05T12:00:00Z"
    private let expiry = "2026-08-05T12:04:00Z"
    private let projectUUID = "00000000-0000-0000-0000-0000000000a1"

    func testStableKeysUseStructuredTokensAndCanonicalInterpolation() throws {
        let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let error = SchedulerAdmissionError.staleFence(
            nodeID: nodeID,
            expected: try token(epoch: 2, sequence: 4),
            actual: try token(epoch: 3, sequence: 9)
        )
        XCTAssertEqual(
            error.stableKey,
            "stale-fence:00000000-0000-0000-0000-000000000301:2:4:3:9"
        )
        XCTAssertEqual(error.description, error.stableKey)
        XCTAssertEqual(
            SchedulerAdmissionError.invalidBinding(field: "input-digest").stableKey,
            "invalid-binding:input-digest"
        )
    }

    func testPreemptionHasOneRepositoryAuthorityAndDiagnosticsBindFieldNames() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HostwrightState/SchedulerAdmissionRepository.swift")
        let source = try String(contentsOf: repositoryURL, encoding: .utf8)

        XCTAssertFalse(source.contains("public func reserveAndFence"))
        XCTAssertFalse(source.contains("public func recordPreemptionIntent("))
        XCTAssertFalse(source.contains("public func recordPreemptionIntentAfterFence"))
        XCTAssertEqual(
            source.components(separatedBy: "public func completePreemptionDecision").count - 1,
            1
        )
        XCTAssertTrue(source.contains("scheduler-schema-missing:\\(table)"))
        XCTAssertTrue(source.contains("scheduler-schema-columns:\\(table)"))
        XCTAssertTrue(source.contains("scheduler-query-limit:\\(field)"))
        XCTAssertTrue(source.contains("scheduler-json-size:\\(field)"))
        XCTAssertTrue(source.contains("scheduler-json-canonicality:\\(field)"))
        XCTAssertTrue(source.contains("scheduler-json-shape:\\(field)"))
        XCTAssertFalse(source.contains("scheduler-query-limit:(field)"))
    }

    func testCodableDecodingRejectsInvalidSchedulerAdmissionInputs() throws {
        let decoder = JSONDecoder()
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        let digestC = String(repeating: "c", count: 64)
        let digestD = String(repeating: "d", count: 64)
        let digestE = String(repeating: "e", count: 64)

        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerFencingToken.self,
                from: Data(#"{"nodeEpoch":0,"reservationSequence":1}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "node-epoch")
            )
        }
        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerFencingToken.self,
                from: Data(#"{"nodeEpoch":1,"reservationSequence":0}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "reservation-sequence")
            )
        }

        let bindingJSON = """
        {
          "decisionID":"00000000-0000-0000-0000-000000000121",
          "workloadID":"00000000-0000-0000-0000-000000000221",
          "nodeID":"00000000-0000-0000-0000-000000000321",
          "resources":{"cpu":1},
          "nodeCapacityDigest":"\(digestA)",
          "nodeCapacityGeneration":1,
          "inputDigest":"\(digestB)",
          "configDigest":"\(digestC)",
          "profileDigest":"\(digestD)",
          "lifecyclePlanDigest":"\(digestE)",
          "ownerSubjectID":"owner",
          "projectUUID":"00000000-0000-0000-0000-0000000000a1",
          "createdAt":"2026-08-05T12:00:00Z",
          "expiresAt":"2026-08-05T12:04:00Z"
        }
        """
        let malformedBinding = bindingJSON.replacingOccurrences(
            of: String(repeating: "b", count: 64),
            with: "bad-digest"
        )
        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerAdmissionBinding.self,
                from: Data(malformedBinding.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "input-digest")
            )
        }
        let malformedBindingTimestamp = bindingJSON.replacingOccurrences(
            of: "2026-08-05T12:00:00Z",
            with: "not-a-timestamp"
        )
        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerAdmissionBinding.self,
                from: Data(malformedBindingTimestamp.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "created-at")
            )
        }

        let authorityJSON = """
        {
          "nodeCapacityDigest":"\(digestA)",
          "nodeCapacityGeneration":1,
          "inputDigest":"\(digestB)",
          "configDigest":"\(digestC)",
          "profileDigest":"\(digestD)",
          "lifecyclePlanDigest":"\(digestE)",
          "expectedNodeEpoch":0
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerAdmissionAuthority.self,
                from: Data(authorityJSON.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "expected-node-epoch")
            )
        }

        let recoveryJSON = """
        {
          "nodeID":"00000000-0000-0000-0000-000000000321",
          "expectedNodeEpoch":1,
          "newNodeEpoch":2,
          "evidenceDigest":"bad-digest",
          "verifiedAt":"not-a-timestamp"
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerNodeRecoveryEvidence.self,
                from: Data(recoveryJSON.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "recovery-evidence-digest")
            )
        }

        let fenceJSON = """
        {
          "token":{"nodeEpoch":1,"reservationSequence":1},
          "reservationID":"00000000-0000-0000-0000-000000000121",
          "workloadID":"00000000-0000-0000-0000-000000000221",
          "evidenceDigest":"bad-digest",
          "verifiedAt":"not-a-timestamp"
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerFenceEvidence.self,
                from: Data(fenceJSON.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "fence-evidence-digest")
            )
        }

        let releaseJSON = """
        {
          "verifiedRuntimeAbsence":{
            "evidenceDigest":"bad-digest",
            "verifiedAt":"not-a-timestamp"
          }
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(
                SchedulerReleaseEvidence.self,
                from: Data(releaseJSON.utf8)
            )
        ) { error in
            XCTAssertEqual(
                admissionError(from: error),
                .invalidBinding(field: "release-evidence-digest")
            )
        }
    }

    func testCodableDecodingRejectsInvalidStoredProofLineage() throws {
        try withRepository { repository, _ in
            let capacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000322",
                capacity: ["cpu": 2]
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let binding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000122",
                workload: "00000000-0000-0000-0000-000000000222",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let reservation = try reserve(repository: repository,
                binding: binding,
                authority: try self.authority(binding: binding, expectedNodeEpoch: 1)
            )
            _ = try repository.recoverNode(
                evidence: try SchedulerNodeRecoveryEvidence(
                    nodeID: capacity.nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: String(repeating: "f", count: 64),
                    verifiedAt: "2026-08-05T12:01:00Z"
                )
            )
            let fenced = try repository.fence(
                reservationID: reservation.reservationID,
                evidence: try SchedulerFenceEvidence(
                    token: try token(epoch: 2, sequence: reservation.fencingToken.reservationSequence),
                    reservationID: reservation.reservationID,
                    workloadID: reservation.workloadID,
                    evidenceDigest: String(repeating: "a", count: 64),
                    verifiedAt: "2026-08-05T12:02:00Z"
                )
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(fenced),
                    options: []
                ) as? [String: Any]
            )
            var fenceObject = try XCTUnwrap(object["fenceEvidence"] as? [String: Any])
            fenceObject["reservationID"] = "00000000-0000-0000-0000-000000000999"
            object["fenceEvidence"] = fenceObject
            let tampered = try JSONSerialization.data(
                withJSONObject: object,
                options: []
            )
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    SchedulerReservationRecord.self,
                    from: tampered
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .stateInvariant("fence-proof-order")
                )
            }
        }
    }

    func testReserveBindsCanonicalSnapshotAndReplaySurvivesSiblingReservation() throws {
        try withRepository { repository, _ in
            let nodeCapacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000301",
                capacity: ["cpu": 4, "memory": 8]
            )
            _ = try repository.recordNodeCapacity(snapshot: nodeCapacity)
            let bindingA = try self.binding(
                decision: "00000000-0000-0000-0000-000000000101",
                workload: "00000000-0000-0000-0000-000000000201",
                node: nodeCapacity.nodeID.uuidString,
                resources: ["memory": 4, "cpu": 2],
                nodeCapacity: nodeCapacity
            )
            let bindingB = try self.binding(
                decision: "00000000-0000-0000-0000-000000000102",
                workload: "00000000-0000-0000-0000-000000000202",
                node: nodeCapacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: nodeCapacity
            )
            let reservationA = try reserve(repository: repository,
                binding: bindingA,
                authority: try self.authority(binding: bindingA, expectedNodeEpoch: 1)
            )
            let reservationB = try reserve(repository: repository,
                binding: bindingB,
                authority: try self.authority(binding: bindingB, expectedNodeEpoch: 1)
            )
            let replay = try reserve(repository: repository,
                binding: bindingA,
                authority: try self.authority(binding: bindingA, expectedNodeEpoch: 1)
            )

            XCTAssertEqual(reservationA.fencingToken, try token(epoch: 1, sequence: 1))
            XCTAssertEqual(reservationB.fencingToken, try token(epoch: 1, sequence: 2))
            XCTAssertEqual(replay, reservationA)
            XCTAssertEqual(
                try repository.fencingState(nodeID: nodeCapacity.nodeID),
                try SchedulerFenceStateSnapshot(
                    nodeID: nodeCapacity.nodeID,
                    nodeEpoch: 1,
                    nextReservationSequence: 3,
                    updatedAt: self.createdAt,
                    recoveryEvidenceDigest: nil,
                    recoveryEvidenceAt: nil
                )
            )
            XCTAssertEqual(
                try repository.activeCapacity(nodeID: nodeCapacity.nodeID).values,
                ["cpu": 3, "memory": 4]
            )
        }
    }

    func testAdmissionRejectsStaleInputDuplicateWorkloadCapacityAndEpoch() throws {
        try withRepository { repository, _ in
            let nodeCapacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000302",
                capacity: ["cpu": 4]
            )
            _ = try repository.recordNodeCapacity(snapshot: nodeCapacity)
            let binding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000103",
                workload: "00000000-0000-0000-0000-000000000203",
                node: nodeCapacity.nodeID.uuidString,
                resources: ["cpu": 2],
                nodeCapacity: nodeCapacity
            )
            XCTAssertThrowsError(
                try reserve(repository: repository,
                    binding: binding,
                    authority: try self.authority(
                        binding: binding,
                        inputDigest: String(repeating: "f", count: 64),
                        expectedNodeEpoch: 1
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleInput(field: "input-digest")
                )
            }

            let first = try reserve(repository: repository,
                binding: binding,
                authority: try self.authority(binding: binding, expectedNodeEpoch: 1)
            )
            let duplicate = try self.binding(
                decision: "00000000-0000-0000-0000-000000000104",
                workload: binding.workloadID.uuidString,
                node: binding.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: nodeCapacity
            )
            XCTAssertThrowsError(
                try reserve(repository: repository,
                    binding: duplicate,
                    authority: try self.authority(
                        binding: duplicate,
                        expectedNodeEpoch: first.fencingToken.nodeEpoch
                    )
                )
            ) { error in
                guard case .duplicateActiveWorkload(let workloadID, let decisionID) =
                    error as? SchedulerAdmissionError else {
                    return XCTFail("Expected duplicate workload, got \(error)")
                }
                XCTAssertEqual(workloadID, binding.workloadID)
                XCTAssertEqual(decisionID, binding.decisionID)
            }

            let tooLarge = try self.binding(
                decision: "00000000-0000-0000-0000-000000000105",
                workload: "00000000-0000-0000-0000-000000000205",
                node: binding.nodeID.uuidString,
                resources: ["cpu": 3],
                nodeCapacity: nodeCapacity
            )
            XCTAssertThrowsError(
                try reserve(repository: repository,
                    binding: tooLarge,
                    authority: try self.authority(binding: tooLarge, expectedNodeEpoch: 1)
                )
            ) { error in
                guard case .insufficientCapacity(let nodeID, _, let available) =
                    error as? SchedulerAdmissionError else {
                    return XCTFail("Expected insufficient capacity, got \(error)")
                }
                XCTAssertEqual(nodeID, binding.nodeID)
                XCTAssertEqual(available.values, ["cpu": 2])
            }

            XCTAssertThrowsError(
                try repository.commit(
                    reservationID: first.reservationID,
                    expectedToken: try token(epoch: 1, sequence: 2),
                    updatedAt: "2026-08-05T12:01:00Z"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleFence(
                        nodeID: binding.nodeID,
                        expected: try! self.token(epoch: 1, sequence: 2),
                        actual: first.fencingToken
                    )
                )
            }

            let inflatedCapacity = try self.nodeCapacity(
                node: binding.nodeID.uuidString,
                capacity: ["cpu": 100],
                generation: 2,
                observedAt: "2026-08-05T12:02:00Z"
            )
            let inflatedBinding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000106",
                workload: "00000000-0000-0000-0000-000000000206",
                node: binding.nodeID.uuidString,
                resources: ["cpu": 3],
                nodeCapacity: inflatedCapacity
            )
            XCTAssertThrowsError(
                try reserve(repository: repository,
                    binding: inflatedBinding,
                    authority: try self.authority(
                        binding: inflatedBinding,
                        expectedNodeEpoch: 1
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleInput(field: "node-capacity-snapshot")
                )
            }
        }
    }

    func testHistoricalCapacityReplayIsAllowedButNewAdmissionRequiresLatestGeneration() throws {
        try withRepository { repository, _ in
            let generationOne = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000307",
                capacity: ["cpu": 4]
            )
            _ = try repository.recordNodeCapacity(snapshot: generationOne)
            let binding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000107",
                workload: "00000000-0000-0000-0000-000000000207",
                node: generationOne.nodeID.uuidString,
                resources: ["cpu": 2],
                nodeCapacity: generationOne
            )
            let first = try reserve(repository: repository,
                binding: binding,
                authority: try self.authority(binding: binding, expectedNodeEpoch: 1)
            )

            let generationTwo = try self.nodeCapacity(
                node: generationOne.nodeID.uuidString,
                capacity: ["cpu": 8],
                generation: 2,
                observedAt: "2026-08-05T12:02:00Z"
            )
            _ = try repository.recordNodeCapacity(snapshot: generationTwo)
            XCTAssertEqual(
                try reserve(repository: repository,
                    binding: binding,
                    authority: try self.authority(binding: binding, expectedNodeEpoch: 1)
                ),
                first
            )

            let staleNewBinding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000108",
                workload: "00000000-0000-0000-0000-000000000208",
                node: generationOne.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: generationOne
            )
            XCTAssertThrowsError(
                try reserve(repository: repository,
                    binding: staleNewBinding,
                    authority: try self.authority(
                        binding: staleNewBinding,
                        expectedNodeEpoch: 1
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleInput(field: "node-capacity-snapshot")
                )
            }
        }
    }

    func testReservationsOnSameNodeCommitAndReleaseWithIndependentTokens() throws {
        try withRepository { repository, _ in
            let capacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000308",
                capacity: ["cpu": 4]
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let bindingA = try self.binding(
                decision: "00000000-0000-0000-0000-000000000109",
                workload: "00000000-0000-0000-0000-000000000209",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let bindingB = try self.binding(
                decision: "00000000-0000-0000-0000-000000000110",
                workload: "00000000-0000-0000-0000-000000000210",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let reservationA = try reserve(repository: repository,
                binding: bindingA,
                authority: try self.authority(binding: bindingA, expectedNodeEpoch: 1)
            )
            let reservationB = try reserve(repository: repository,
                binding: bindingB,
                authority: try self.authority(binding: bindingB, expectedNodeEpoch: 1)
            )
            XCTAssertEqual(reservationA.fencingToken, try token(epoch: 1, sequence: 1))
            XCTAssertEqual(reservationB.fencingToken, try token(epoch: 1, sequence: 2))

            XCTAssertEqual(
                try repository.commit(
                    reservationID: reservationA.reservationID,
                    expectedToken: reservationA.fencingToken,
                    updatedAt: "2026-08-05T12:01:00Z"
                ).status,
                .committed
            )
            XCTAssertEqual(
                try repository.commit(
                    reservationID: reservationB.reservationID,
                    expectedToken: reservationB.fencingToken,
                    updatedAt: "2026-08-05T12:02:00Z"
                ).status,
                .committed
            )
            XCTAssertEqual(
                try repository.requestRelease(
                    reservationID: reservationA.reservationID,
                    expectedToken: reservationA.fencingToken,
                    updatedAt: "2026-08-05T12:03:00Z"
                ).status,
                .releasePending
            )
            XCTAssertEqual(
                try repository.requestRelease(
                    reservationID: reservationB.reservationID,
                    expectedToken: reservationB.fencingToken,
                    updatedAt: "2026-08-05T12:04:00Z"
                ).status,
                .releasePending
            )
            _ = try repository.release(
                reservationID: reservationA.reservationID,
                expectedToken: reservationA.fencingToken,
                evidence: .verifiedRuntimeAbsence(
                    evidenceDigest: String(repeating: "a", count: 64),
                    verifiedAt: "2026-08-05T12:05:00Z"
                )
            )
            _ = try repository.release(
                reservationID: reservationB.reservationID,
                expectedToken: reservationB.fencingToken,
                evidence: .verifiedRuntimeAbsence(
                    evidenceDigest: String(repeating: "b", count: 64),
                    verifiedAt: "2026-08-05T12:06:00Z"
                )
            )
            XCTAssertEqual(try repository.activeCapacity(nodeID: capacity.nodeID), .zero)
            XCTAssertEqual(
                try repository.fencingState(nodeID: capacity.nodeID).nodeEpoch,
                1
            )
            XCTAssertEqual(
                try repository.fencingState(nodeID: capacity.nodeID).nextReservationSequence,
                3
            )
        }
    }

    func testSiblingTokenCannotMutateAnotherReservationLineage() throws {
        try withRepository { repository, _ in
            let capacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000309",
                capacity: ["cpu": 4]
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let bindingA = try self.binding(
                decision: "00000000-0000-0000-0000-000000000115",
                workload: "00000000-0000-0000-0000-000000000215",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let bindingB = try self.binding(
                decision: "00000000-0000-0000-0000-000000000116",
                workload: "00000000-0000-0000-0000-000000000216",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let reservationA = try reserve(
                repository: repository,
                binding: bindingA,
                authority: try self.authority(binding: bindingA, expectedNodeEpoch: 1)
            )
            let reservationB = try reserve(
                repository: repository,
                binding: bindingB,
                authority: try self.authority(binding: bindingB, expectedNodeEpoch: 1)
            )

            XCTAssertThrowsError(
                try repository.commit(
                    reservationID: reservationA.reservationID,
                    expectedToken: reservationB.fencingToken,
                    updatedAt: "2026-08-05T12:01:00Z"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleFence(
                        nodeID: capacity.nodeID,
                        expected: reservationB.fencingToken,
                        actual: reservationA.fencingToken
                    )
                )
            }
            XCTAssertThrowsError(
                try repository.requestRelease(
                    reservationID: reservationA.reservationID,
                    expectedToken: reservationB.fencingToken,
                    updatedAt: "2026-08-05T12:01:00Z"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleFence(
                        nodeID: capacity.nodeID,
                        expected: reservationB.fencingToken,
                        actual: reservationA.fencingToken
                    )
                )
            }
            XCTAssertThrowsError(
                try repository.release(
                    reservationID: reservationA.reservationID,
                    expectedToken: reservationB.fencingToken,
                    evidence: .verifiedRuntimeAbsence(
                        evidenceDigest: String(repeating: "a", count: 64),
                        verifiedAt: "2026-08-05T12:02:00Z"
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleFence(
                        nodeID: capacity.nodeID,
                        expected: reservationB.fencingToken,
                        actual: reservationA.fencingToken
                    )
                )
            }

            _ = try repository.recoverNode(
                evidence: try SchedulerNodeRecoveryEvidence(
                    nodeID: capacity.nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: String(repeating: "b", count: 64),
                    verifiedAt: "2026-08-05T12:03:00Z"
                )
            )
            XCTAssertThrowsError(
                try repository.fence(
                    reservationID: reservationA.reservationID,
                    evidence: try SchedulerFenceEvidence(
                        token: try self.token(
                            epoch: 2,
                            sequence: reservationB.fencingToken.reservationSequence
                        ),
                        reservationID: reservationB.reservationID,
                        workloadID: reservationB.workloadID,
                        evidenceDigest: String(repeating: "c", count: 64),
                        verifiedAt: "2026-08-05T12:04:00Z"
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .invalidEvidence("fence-lineage")
                )
            }
        }
    }

    func testRecoveryEpochBumpRejectsOldMutationsAndRequiresSameLineageProof() throws {
        try withRepository { repository, store in
            let capacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000305",
                capacity: ["cpu": 4]
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let bindingA = try self.binding(
                decision: "00000000-0000-0000-0000-000000000111",
                workload: "00000000-0000-0000-0000-000000000211",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let bindingB = try self.binding(
                decision: "00000000-0000-0000-0000-000000000112",
                workload: "00000000-0000-0000-0000-000000000212",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let reservationA = try reserve(repository: repository,
                binding: bindingA,
                authority: try self.authority(binding: bindingA, expectedNodeEpoch: 1)
            )
            let reservationB = try reserve(repository: repository,
                binding: bindingB,
                authority: try self.authority(binding: bindingB, expectedNodeEpoch: 1)
            )
            _ = try repository.commit(
                reservationID: reservationA.reservationID,
                expectedToken: reservationA.fencingToken,
                updatedAt: "2026-08-05T12:01:00Z"
            )

            let recovery = try SchedulerNodeRecoveryEvidence(
                nodeID: capacity.nodeID,
                expectedNodeEpoch: 1,
                newNodeEpoch: 2,
                evidenceDigest: String(repeating: "5", count: 64),
                verifiedAt: "2026-08-05T12:02:00Z"
            )
            let state = try repository.recoverNode(evidence: recovery)
            XCTAssertEqual(state.nodeEpoch, 2)
            XCTAssertEqual(state.nextReservationSequence, 3)
            XCTAssertEqual(
                try repository.recoverNode(evidence: recovery),
                state
            )

            XCTAssertThrowsError(
                try repository.commit(
                    reservationID: reservationA.reservationID,
                    expectedToken: reservationA.fencingToken,
                    updatedAt: "2026-08-05T12:03:00Z"
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleNodeEpoch(nodeID: capacity.nodeID, expected: 1, actual: 2)
                )
            }
            let staleEpochBinding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000113",
                workload: "00000000-0000-0000-0000-000000000213",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            XCTAssertThrowsError(
                try reserve(repository: repository,
                    binding: staleEpochBinding,
                    authority: try self.authority(
                        binding: staleEpochBinding,
                        expectedNodeEpoch: 1
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .staleNodeEpoch(nodeID: capacity.nodeID, expected: 1, actual: 2)
                )
            }

            let siblingEvidence = try SchedulerFenceEvidence(
                token: try token(epoch: 2, sequence: reservationB.fencingToken.reservationSequence),
                reservationID: reservationB.reservationID,
                workloadID: reservationB.workloadID,
                evidenceDigest: String(repeating: "e", count: 64),
                verifiedAt: "2026-08-05T12:03:00Z"
            )
            XCTAssertThrowsError(
                try repository.fence(
                    reservationID: reservationA.reservationID,
                    evidence: siblingEvidence
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .invalidEvidence("fence-lineage")
                )
            }

            let tooEarlyFence = try SchedulerFenceEvidence(
                token: try token(epoch: 2, sequence: reservationA.fencingToken.reservationSequence),
                reservationID: reservationA.reservationID,
                workloadID: reservationA.workloadID,
                evidenceDigest: String(repeating: "e", count: 64),
                verifiedAt: "2026-08-05T12:00:59Z"
            )
            XCTAssertThrowsError(
                try repository.fence(
                    reservationID: reservationA.reservationID,
                    evidence: tooEarlyFence
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .invalidEvidence("fence-evidence-at")
                )
            }

            let fenceEvidence = try SchedulerFenceEvidence(
                token: try token(epoch: 2, sequence: reservationA.fencingToken.reservationSequence),
                reservationID: reservationA.reservationID,
                workloadID: reservationA.workloadID,
                evidenceDigest: String(repeating: "e", count: 64),
                verifiedAt: "2026-08-05T12:03:00Z"
            )
            let fenced = try repository.fence(
                reservationID: reservationA.reservationID,
                evidence: fenceEvidence
            )
            XCTAssertEqual(fenced.status, .fenced)
            XCTAssertEqual(fenced.fenceEvidence, fenceEvidence)

            let tooEarlyRelease = SchedulerReleaseEvidence.authoritativeFence(
                token: fenceEvidence.token,
                reservationID: reservationA.reservationID,
                workloadID: reservationA.workloadID,
                evidenceDigest: String(repeating: "d", count: 64),
                verifiedAt: "2026-08-05T12:02:59Z"
            )
            XCTAssertThrowsError(
                try repository.release(
                    reservationID: reservationA.reservationID,
                    expectedToken: reservationA.fencingToken,
                    evidence: tooEarlyRelease
                )
            ) { error in
                XCTAssertEqual(
                    error as? SchedulerAdmissionError,
                    .invalidEvidence("fence-verified-at")
                )
            }

            let releaseEvidence = SchedulerReleaseEvidence.authoritativeFence(
                token: fenceEvidence.token,
                reservationID: reservationA.reservationID,
                workloadID: reservationA.workloadID,
                evidenceDigest: String(repeating: "d", count: 64),
                verifiedAt: "2026-08-05T12:04:00Z"
            )
            let released = try repository.release(
                reservationID: reservationA.reservationID,
                expectedToken: reservationA.fencingToken,
                evidence: releaseEvidence
            )
            XCTAssertEqual(released.status, .released)
            XCTAssertEqual(released.updatedAt, "2026-08-05T12:04:00Z")
            XCTAssertEqual(try repository.activeCapacity(nodeID: capacity.nodeID), try ResourceVector(["cpu": 1]))

            let reopened = SQLiteStateStore(path: store.path)
            let reopenedRecord = try reopened.schedulerAdmissions.reservation(
                id: reservationA.reservationID
            )
            XCTAssertEqual(reopenedRecord, released)
        }
    }

    func testVerifiedRuntimeAbsenceIsAnExplicitReleaseProof() throws {
        try withRepository { repository, _ in
            let capacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000306",
                capacity: ["cpu": 2]
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let binding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000114",
                workload: "00000000-0000-0000-0000-000000000214",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let reservation = try reserve(repository: repository,
                binding: binding,
                authority: try self.authority(binding: binding, expectedNodeEpoch: 1)
            )
            let evidence = SchedulerReleaseEvidence.verifiedRuntimeAbsence(
                evidenceDigest: String(repeating: "c", count: 64),
                verifiedAt: "2026-08-05T12:01:00Z"
            )
            let released = try repository.release(
                reservationID: reservation.reservationID,
                expectedToken: reservation.fencingToken,
                evidence: evidence
            )
            XCTAssertEqual(released.status, .released)
            XCTAssertEqual(released.releaseEvidence, evidence)
        }
    }

    func testReleaseAcceptsLaterCurrentEpochForSameReservationLineage() throws {
        try withRepository { repository, _ in
            let capacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000323",
                capacity: ["cpu": 2]
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let binding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000123",
                workload: "00000000-0000-0000-0000-000000000223",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let reservation = try reserve(repository: repository,
                binding: binding,
                authority: try self.authority(binding: binding, expectedNodeEpoch: 1)
            )
            _ = try repository.recoverNode(
                evidence: try SchedulerNodeRecoveryEvidence(
                    nodeID: capacity.nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: String(repeating: "a", count: 64),
                    verifiedAt: "2026-08-05T12:01:00Z"
                )
            )
            let fenceEvidence = try SchedulerFenceEvidence(
                token: try token(epoch: 2, sequence: reservation.fencingToken.reservationSequence),
                reservationID: reservation.reservationID,
                workloadID: reservation.workloadID,
                evidenceDigest: String(repeating: "b", count: 64),
                verifiedAt: "2026-08-05T12:02:00Z"
            )
            _ = try repository.fence(
                reservationID: reservation.reservationID,
                evidence: fenceEvidence
            )
            _ = try repository.recoverNode(
                evidence: try SchedulerNodeRecoveryEvidence(
                    nodeID: capacity.nodeID,
                    expectedNodeEpoch: 2,
                    newNodeEpoch: 3,
                    evidenceDigest: String(repeating: "c", count: 64),
                    verifiedAt: "2026-08-05T12:03:00Z"
                )
            )
            let released = try repository.release(
                reservationID: reservation.reservationID,
                expectedToken: reservation.fencingToken,
                evidence: .authoritativeFence(
                    token: try token(epoch: 3, sequence: reservation.fencingToken.reservationSequence),
                    reservationID: reservation.reservationID,
                    workloadID: reservation.workloadID,
                    evidenceDigest: String(repeating: "d", count: 64),
                    verifiedAt: "2026-08-05T12:04:00Z"
                )
            )
            XCTAssertEqual(released.status, .released)
            XCTAssertEqual(try repository.activeCapacity(nodeID: capacity.nodeID), .zero)
        }
    }

    func testSchemaRejectsReleaseProofOlderThanFenceEpoch() throws {
        try withRepository { repository, store in
            let capacity = try self.nodeCapacity(
                node: "00000000-0000-0000-0000-000000000324",
                capacity: ["cpu": 2]
            )
            _ = try repository.recordNodeCapacity(snapshot: capacity)
            let binding = try self.binding(
                decision: "00000000-0000-0000-0000-000000000124",
                workload: "00000000-0000-0000-0000-000000000224",
                node: capacity.nodeID.uuidString,
                resources: ["cpu": 1],
                nodeCapacity: capacity
            )
            let reservation = try reserve(repository: repository,
                binding: binding,
                authority: try self.authority(binding: binding, expectedNodeEpoch: 1)
            )
            _ = try repository.recoverNode(
                evidence: try SchedulerNodeRecoveryEvidence(
                    nodeID: capacity.nodeID,
                    expectedNodeEpoch: 1,
                    newNodeEpoch: 2,
                    evidenceDigest: String(repeating: "a", count: 64),
                    verifiedAt: "2026-08-05T12:01:00Z"
                )
            )
            _ = try repository.recoverNode(
                evidence: try SchedulerNodeRecoveryEvidence(
                    nodeID: capacity.nodeID,
                    expectedNodeEpoch: 2,
                    newNodeEpoch: 3,
                    evidenceDigest: String(repeating: "b", count: 64),
                    verifiedAt: "2026-08-05T12:02:00Z"
                )
            )
            _ = try repository.fence(
                reservationID: reservation.reservationID,
                evidence: try SchedulerFenceEvidence(
                    token: try token(epoch: 3, sequence: reservation.fencingToken.reservationSequence),
                    reservationID: reservation.reservationID,
                    workloadID: reservation.workloadID,
                    evidenceDigest: String(repeating: "c", count: 64),
                    verifiedAt: "2026-08-05T12:03:00Z"
                )
            )

            try store.withValidatedConnection { connection in
                XCTAssertThrowsError(
                    try connection.run(
                        """
                        UPDATE scheduler_reservations
                        SET status = 'released', updated_at = ?,
                            release_evidence_kind = 'authoritative-fence',
                            release_evidence_digest = ?, release_evidence_at = ?,
                            release_evidence_node_epoch = ?,
                            release_evidence_reservation_sequence = ?,
                            release_evidence_reservation_id = ?,
                            release_evidence_workload_uuid = ?
                        WHERE reservation_id = ?
                        """,
                        bindings: [
                            .text("2026-08-05T12:04:00Z"),
                            .text(String(repeating: "d", count: 64)),
                            .text("2026-08-05T12:04:00Z"),
                            .int64(2),
                            .int64(reservation.fencingToken.reservationSequence),
                            .text(reservation.reservationID.uuidString.lowercased()),
                            .text(reservation.workloadID.uuidString.lowercased()),
                            .text(reservation.reservationID.uuidString.lowercased()),
                        ]
                    )
                )
            }
        }
    }

    private func admissionError(from error: Error) -> SchedulerAdmissionError? {
        if let admissionError = error as? SchedulerAdmissionError {
            return admissionError
        }
        guard let decodingError = error as? DecodingError,
              case .dataCorrupted(let context) = decodingError,
              let underlyingError = context.underlyingError else {
            return nil
        }
        return admissionError(from: underlyingError)
    }

    private func withRepository(
        _ body: (SchedulerAdmissionRepository, SQLiteStateStore) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-scheduler-admission-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
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
                    .text("phase10-project"), .text("phase10-project"), .null,
                    .text(String(repeating: "a", count: 64)), .text(createdAt), .text(createdAt),
                    .text(projectUUID), .int(1), .null, .int(0),
                ]
            )
        }
        try body(SchedulerAdmissionRepository(store: store), store)
    }

    private func binding(
        decision: String,
        workload: String,
        node: String,
        resources: [String: Int64],
        nodeCapacity: SchedulerNodeCapacitySnapshot,
        createdAt: String? = nil,
        expiresAt: String? = nil
    ) throws -> SchedulerAdmissionBinding {
        try SchedulerAdmissionBinding(
            decisionID: UUID(uuidString: decision)!,
            workloadID: UUID(uuidString: workload)!,
            nodeID: UUID(uuidString: node)!,
            resources: ResourceVector(resources),
            nodeCapacityDigest: nodeCapacity.capacityDigest,
            nodeCapacityGeneration: nodeCapacity.generation,
            inputDigest: String(repeating: "1", count: 64),
            configDigest: String(repeating: "2", count: 64),
            profileDigest: String(repeating: "3", count: 64),
            lifecyclePlanDigest: String(repeating: "4", count: 64),
            ownerSubjectID: "owner",
            projectUUID: projectUUID,
            createdAt: createdAt ?? self.createdAt,
            expiresAt: expiresAt ?? expiry
        )
    }

    private func authority(
        binding: SchedulerAdmissionBinding,
        inputDigest: String? = nil,
        expectedNodeEpoch: Int64
    ) throws -> SchedulerAdmissionAuthority {
        try SchedulerAdmissionAuthority(
            nodeCapacityDigest: binding.nodeCapacityDigest,
            nodeCapacityGeneration: binding.nodeCapacityGeneration,
            inputDigest: inputDigest ?? binding.inputDigest,
            configDigest: binding.configDigest,
            profileDigest: binding.profileDigest,
            lifecyclePlanDigest: binding.lifecyclePlanDigest,
            expectedNodeEpoch: expectedNodeEpoch
        )
    }

    private func reserve(
        repository: SchedulerAdmissionRepository,
        binding: SchedulerAdmissionBinding,
        authority: SchedulerAdmissionAuthority
    ) throws -> SchedulerReservationRecord {
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
                summary: "state qualification placement"
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
        return try repository.reserve(binding: binding, authority: authority)
    }

    private func token(epoch: Int64, sequence: Int64) throws -> SchedulerFencingToken {
        try SchedulerFencingToken(nodeEpoch: epoch, reservationSequence: sequence)
    }

    private func nodeCapacity(
        node: String,
        capacity: [String: Int64],
        generation: Int64 = 1,
        observedAt: String? = nil
    ) throws -> SchedulerNodeCapacitySnapshot {
        try SchedulerNodeCapacitySnapshot(
            nodeID: UUID(uuidString: node)!,
            capacity: ResourceVector(capacity),
            generation: generation,
            observedAt: observedAt ?? createdAt
        )
    }
}
