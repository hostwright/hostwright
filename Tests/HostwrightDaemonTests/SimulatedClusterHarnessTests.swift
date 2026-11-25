#if HOSTWRIGHT_TEST_RUNTIME
import Foundation
import HostwrightCluster
import XCTest
@testable import HostwrightDaemon

@MainActor
final class SimulatedClusterHarnessTests: XCTestCase {
    func testPartitionDropsOnlyTheBlockedLinkAndHealingRestoresDelivery() async throws {
        try await withCluster { cluster in
            let workerA = cluster.nodeIDs[1]
            let workerB = cluster.nodeIDs[2]
            let first = try cluster.message("a", service: "api", to: workerA)
            try cluster.setPartition(true, between: cluster.controlNode, and: workerA)
            try cluster.enqueue(first)
            try cluster.enqueue(cluster.message("b", service: "api", to: workerB))
            try await cluster.advance(by: 0)

            XCTAssertEqual(cluster.events.map(\.outcome), [.partitioned, .applied])
            try await assertRecorded([], on: workerA, in: cluster)
            try await assertRecorded(["api"], on: workerB, in: cluster)

            try cluster.setPartition(false, between: cluster.controlNode, and: workerA)
            try cluster.enqueue(first)
            try await cluster.advance(by: 0)
            XCTAssertEqual(cluster.events.last?.outcome, .applied)
            try await assertRecorded(["api"], on: workerA, in: cluster)
            try await assertRecorded([], on: cluster.controlNode, in: cluster)
        }
    }

    func testCrashAndReopenRecoverObservationAndReplayFence() async throws {
        try await withCluster { cluster in
            let worker = cluster.nodeIDs[1]
            let message = try cluster.message("create-api", service: "api", to: worker)
            try cluster.enqueue(message)
            try await cluster.advance(by: 0)

            try cluster.crash(worker)
            try cluster.enqueue(message)
            try await cluster.advance(by: 0)
            try cluster.reopen(worker)

            let observed = try await cluster.observedState(on: worker)
            XCTAssertEqual(observed.services.map(\.identity.serviceName), ["api"])
            try cluster.enqueue(message)
            try await cluster.advance(by: 0)
            XCTAssertEqual(cluster.events.map(\.outcome), [.applied, .offline, .replay])
            try await assertRecorded(["api"], on: worker, in: cluster)

            try await cluster.advance(by: SimulatedClusterHarness.leaseLifetime)
            try cluster.replaceExpiredAuthority()
            try cluster.enqueue(cluster.message("reconcile-api", service: "api", to: worker))
            try await cluster.advance(by: 0)
            XCTAssertEqual(cluster.events.last?.outcome, .applied)
            try await assertRecorded(["api"], on: worker, in: cluster)
        }
    }

    func testDelayDeliversAtTheRequestedLogicalTime() async throws {
        try await withCluster { cluster in
            let worker = cluster.nodeIDs[1]
            let started = cluster.time
            try cluster.enqueue(cluster.message("delayed", service: "api", to: worker), delay: 5)
            try await cluster.advance(by: 4)
            XCTAssertTrue(cluster.events.isEmpty)
            try await assertRecorded([], on: worker, in: cluster)

            try await cluster.advance(by: 1)
            XCTAssertEqual(cluster.events.map(\.time), [started + 5])
            XCTAssertEqual(cluster.events.map(\.outcome), [.applied])
            try await assertRecorded(["api"], on: worker, in: cluster)
        }
    }

    func testCrashAfterRecordingRecoversWithoutRepeatingCreate() async throws {
        try await withCluster { cluster in
            let worker = cluster.nodeIDs[1]
            let message = try cluster.message("create-api", service: "api", to: worker)
            try cluster.crashBeforeNextFenceWrite(on: worker)
            try cluster.enqueue(message, duplicate: true)
            try await cluster.advance(by: 0)
            XCTAssertEqual(cluster.events.map(\.outcome), [.crashedBeforeFenceWrite, .offline])

            try cluster.reopen(worker)
            let observed = try await cluster.observedState(on: worker)
            XCTAssertEqual(observed.services.map(\.identity.serviceName), ["api"])
            try await assertRecorded(["api"], on: worker, in: cluster)

            try cluster.enqueue(message, duplicate: true)
            try await cluster.advance(by: 0)
            XCTAssertEqual(cluster.events.map(\.outcome), [.crashedBeforeFenceWrite, .offline, .applied, .replay])
            try await assertRecorded(["api"], on: worker, in: cluster)
        }
    }

    func testDuplicateDeliveryRecordsExactlyOneAction() async throws {
        try await withCluster { cluster in
            let worker = cluster.nodeIDs[1]
            try cluster.enqueue(cluster.message("duplicate", service: "api", to: worker), duplicate: true)
            try await cluster.advance(by: 0)

            XCTAssertEqual(cluster.events.map(\.mutationID), ["duplicate", "duplicate"])
            XCTAssertEqual(cluster.events.map(\.outcome), [.applied, .replay])
            try await assertRecorded(["api"], on: worker, in: cluster)
        }
    }

    func testReorderingSameTimeDeliveriesChangesWhichMutationWins() async throws {
        for order: SimulatedClusterHarness.DeliveryOrder in [.enqueued, .reversedAtSameTime] {
            let expectedServices = order == .enqueued ? ["first", "second"] : ["second", "first"]
            try await withCluster { cluster in
                let worker = cluster.nodeIDs[1]
                try cluster.enqueue(cluster.message("first", service: "first", to: worker))
                try cluster.enqueue(cluster.message("second", service: "second", to: worker))
                try await cluster.advance(by: 0, order: order)

                XCTAssertEqual(cluster.events.map(\.time), [cluster.time, cluster.time])
                XCTAssertEqual(cluster.events.map(\.mutationID), expectedServices)
                XCTAssertEqual(cluster.events.map(\.outcome), [
                    .applied,
                    .rejected(.fencingTokenReplayConflict(
                        currentMutationID: expectedServices[0], proposedMutationID: expectedServices[1]
                    )),
                ])
                try await assertRecorded([expectedServices[0]], on: worker, in: cluster)
            }
        }
    }

    func testClockSkewExpiresLeaseOnOnlyOneNode() async throws {
        try await withCluster { cluster in
            let workerA = cluster.nodeIDs[1]
            let workerB = cluster.nodeIDs[2]
            let request = try cluster.message("a", service: "api", to: workerA)
            try cluster.setClockSkew(Int64(SimulatedClusterHarness.leaseLifetime), on: workerA)
            try cluster.enqueue(request)
            try cluster.enqueue(cluster.message("b", service: "api", to: workerB))
            try await cluster.advance(by: 0)

            XCTAssertEqual(cluster.events.map(\.outcome), [.leaseExpired, .applied])
            try await assertRecorded([], on: workerA, in: cluster)
            try await assertRecorded(["api"], on: workerB, in: cluster)

            try cluster.setClockSkew(0, on: workerA)
            try cluster.enqueue(request)
            try await cluster.advance(by: 0)
            XCTAssertEqual(cluster.events.last?.outcome, .applied)
            try await assertRecorded(["api"], on: workerA, in: cluster)
        }
    }

    func testSlowClockAcceptsLeaseUntilReplacementFencesIt() async throws {
        try await withCluster { cluster in
            let slowWorker = cluster.nodeIDs[1]
            let onTimeWorker = cluster.nodeIDs[2]
            let lifetime = SimulatedClusterHarness.leaseLifetime
            try cluster.setClockSkew(-Int64(lifetime), on: slowWorker)
            try cluster.enqueue(cluster.message("slow-clock", service: "api", to: slowWorker), delay: lifetime)
            try cluster.enqueue(cluster.message("on-time", service: "api", to: onTimeWorker), delay: lifetime)
            let pendingOldFence = try cluster.message("old-fence", service: "stale", to: slowWorker)
            try await cluster.advance(by: lifetime)
            XCTAssertEqual(cluster.events.map(\.outcome), [.applied, .leaseExpired])
            try await assertRecorded(["api"], on: slowWorker, in: cluster)
            try await assertRecorded([], on: onTimeWorker, in: cluster)

            try cluster.replaceExpiredAuthority()
            try cluster.enqueue(pendingOldFence)
            try await cluster.advance(by: 0)
            XCTAssertEqual(cluster.events.last?.outcome, .rejected(.staleFencingToken(expected: 2, actual: 1)))
            try await assertRecorded(["api"], on: slowWorker, in: cluster)
        }
    }

    func testDelayedOldFenceIsRejectedAndScenarioReplaysDeterministically() async throws {
        func runScenario(_ cluster: SimulatedClusterHarness) async throws -> [SimulatedClusterHarness.Event] {
            let worker = cluster.nodeIDs[1]
            let lifetime = SimulatedClusterHarness.leaseLifetime
            let old = try cluster.message("old-fence", service: "stale", to: worker)
            try cluster.enqueue(old, delay: lifetime + 1)
            try await cluster.advance(by: lifetime)
            XCTAssertTrue(cluster.events.isEmpty)

            try cluster.replaceExpiredAuthority()
            try cluster.enqueue(cluster.message("new-fence", service: "api", to: worker), duplicate: true)
            try await cluster.advance(by: 1)
            XCTAssertEqual(cluster.events.map(\.mutationID), ["new-fence", "new-fence", "old-fence"])
            XCTAssertEqual(cluster.events.map(\.outcome), [
                .applied, .replay, .rejected(.staleFencingToken(expected: 2, actual: 1)),
            ])
            try await assertRecorded(["api"], on: worker, in: cluster)
            return cluster.events
        }

        let first = try await withCluster(runScenario)
        let replay = try await withCluster(runScenario)
        XCTAssertEqual(first, replay)
    }

    private func assertRecorded(
        _ services: [String], on node: ClusterNodeID, in cluster: SimulatedClusterHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actions = try await cluster.recordedActions(on: node)
        XCTAssertEqual(actions.map(\.service), services, file: file, line: line)
        XCTAssertEqual(actions.map(\.kind), services.map { _ in "create" }, file: file, line: line)
    }

    private func withCluster<T>(_ body: @MainActor (SimulatedClusterHarness) async throws -> T) async throws -> T {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".hostwright-simulated-cluster-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(SimulatedClusterHarness(nodeCount: 3, homeDirectory: root))
    }
}
#endif
