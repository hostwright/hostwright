#if HOSTWRIGHT_TEST_RUNTIME
import CryptoKit
import Foundation
import HostwrightCluster
import HostwrightRuntime
@testable import HostwrightDaemon

/// A deterministic test transport around the production lease and fence evaluators.
/// Each worker uses the daemon's recording runtime and its own on-disk home.
@MainActor
final class SimulatedClusterHarness {
    enum Fault: Error {
        case invalidNodeCount
        case unknownNode(ClusterNodeID)
        case offline(ClusterNodeID)
        case invalidClock
        case unexpectedLeaseTransition
        case invalidMutationBinding
    }

    enum DeliveryOrder: Equatable {
        case enqueued
        case reversedAtSameTime
    }

    enum Outcome: Equatable {
        case applied
        case replay
        case partitioned
        case offline
        case leaseExpired
        case rejected(ClusterMutationFenceRejection)
    }

    struct Event: Equatable {
        let time: UInt64
        let destination: ClusterNodeID
        let mutationID: String
        let outcome: Outcome
    }

    fileprivate struct Workload: Encodable, Sendable {
        let destination: ClusterNodeID
        let project: String
        let service: String
        let image: String

        func digest() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return SHA256.hash(data: try encoder.encode(self))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Message: Sendable {
        fileprivate let source: ClusterNodeID
        fileprivate let token: UInt64
        fileprivate let workload: Workload
        fileprivate let id: String
        fileprivate let proof: Data
    }

    private struct Link: Hashable {
        let endpoints: Set<ClusterNodeID>
    }

    private struct Node {
        let home: URL
        var runtime: HostwrightTestRecordingRuntime?
        var clockSkew: Int64 = 0

        var lastFenceURL: URL { home.appending(path: "simulated-mutation-fence.json") }

        func lastFence() throws -> ClusterMutationProof? {
            do {
                return try ClusterMutationFenceWireContract.decodeProof(Data(contentsOf: lastFenceURL))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
        }
    }

    private struct Pending {
        let time: UInt64
        let message: Message
    }

    static let leaseLifetime: UInt64 = 100
    private static let initialTime: UInt64 = 1_000
    private static let project = "simulated"
    private static let image = "registry.invalid/simulated@sha256:" + String(repeating: "a", count: 64)

    let nodeIDs: [ClusterNodeID]
    var controlNode: ClusterNodeID { lease.leaderNodeID }
    private(set) var time: UInt64
    private(set) var events: [Event] = []

    private var nodes: [ClusterNodeID: Node] = [:]
    private var partitionedLinks: Set<Link> = []
    private var pending: [Pending] = []
    private var lease: ClusterControlPlaneLeaseRecord
    private var leaseHistory: [UInt64: ClusterControlPlaneLeaseRecord]

    init(nodeCount: Int, homeDirectory: URL) throws {
        guard (1...65_535).contains(nodeCount) else { throw Fault.invalidNodeCount }
        let ids = try (1...nodeCount).map { index in
            try ClusterNodeID("5ad0370a-ddf0-4d69-8290-" + String(format: "%012llx", UInt64(index)))
        }
        nodeIDs = ids
        time = Self.initialTime
        let initial = try ClusterControlPlaneLeaseRecord(
            clusterID: ClusterID("67e15bad-b3a8-4147-966d-e0dd5feda009"),
            leaderNodeID: ids[0],
            membershipEpoch: ClusterMembershipEpoch(1),
            fencingToken: 1,
            term: 1,
            sequence: 1,
            issuedAtMilliseconds: Self.initialTime,
            expiresAtMilliseconds: Self.initialTime + Self.leaseLifetime,
            predecessorRecordSHA256: nil
        )
        lease = initial
        leaseHistory = [initial.fencingToken: initial]
        guard case .acquire = try Self.evaluateLease(initial, previous: nil, at: time) else {
            throw Fault.unexpectedLeaseTransition
        }
        for id in ids {
            let home = homeDirectory.appending(path: id.rawValue, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            nodes[id] = Node(home: home, runtime: HostwrightTestRecordingRuntime(homeDirectory: home))
        }
    }

    func replaceExpiredAuthority() throws {
        let next = try ClusterControlPlaneLeaseRecord(
            clusterID: lease.clusterID,
            leaderNodeID: lease.leaderNodeID,
            membershipEpoch: lease.membershipEpoch,
            fencingToken: lease.fencingToken + 1,
            term: lease.term + 1,
            sequence: 1,
            issuedAtMilliseconds: time,
            expiresAtMilliseconds: try adding(Self.leaseLifetime, to: time),
            predecessorRecordSHA256: lease.canonicalSHA256()
        )
        guard case .replaceExpired = try Self.evaluateLease(next, previous: lease, at: time) else {
            throw Fault.unexpectedLeaseTransition
        }
        lease = next
        leaseHistory[next.fencingToken] = next
    }

    func message(_ id: String, service: String, to destination: ClusterNodeID) throws -> Message {
        _ = try node(destination)
        let workload = Workload(destination: destination, project: Self.project, service: service, image: Self.image)
        let proof = try ClusterMutationProof(
            mutationID: id, mutationSHA256: workload.digest(), controlPlaneLease: lease
        )
        return Message(
            source: lease.leaderNodeID, token: lease.fencingToken, workload: workload,
            id: id, proof: try proof.canonicalJSON()
        )
    }

    func enqueue(_ message: Message, delay: UInt64 = 0, duplicate: Bool = false) throws {
        let delivery = Pending(time: try adding(delay, to: time), message: message)
        pending.append(delivery)
        if duplicate {
            pending.append(delivery)
        }
    }

    func setPartition(_ partitioned: Bool, between first: ClusterNodeID, and second: ClusterNodeID) throws {
        _ = try node(first)
        _ = try node(second)
        let link = Link(endpoints: [first, second])
        if partitioned {
            partitionedLinks.insert(link)
        } else {
            partitionedLinks.remove(link)
        }
    }

    func setClockSkew(_ milliseconds: Int64, on id: ClusterNodeID) throws {
        _ = try node(id)
        nodes[id]?.clockSkew = milliseconds
    }

    // Crash injection happens between deliveries. Both the recorder and replay fence reopen from disk.
    func crash(_ id: ClusterNodeID) throws {
        _ = try node(id)
        nodes[id]?.runtime = nil
    }

    func reopen(_ id: ClusterNodeID) throws {
        let home = try node(id).home
        nodes[id]?.runtime = HostwrightTestRecordingRuntime(homeDirectory: home)
    }

    func observedState(on id: ClusterNodeID) async throws -> ObservedRuntimeState {
        try await runtime(on: id).observe(desiredState: DesiredRuntimeState(projectName: Self.project, services: []))
    }

    func recordedActions(on id: ClusterNodeID) async throws -> [HostwrightTestRecordingRuntime.Action] {
        try await runtime(on: id).recordedActions()
    }

    func advance(by milliseconds: UInt64, order: DeliveryOrder = .enqueued) async throws {
        let end = try adding(milliseconds, to: time)
        let ready = pending.enumerated().filter { $0.element.time <= end }.sorted { left, right in
            if left.element.time != right.element.time {
                return left.element.time < right.element.time
            }
            switch order {
            case .enqueued: return left.offset < right.offset
            case .reversedAtSameTime: return left.offset > right.offset
            }
        }
        pending.removeAll { $0.time <= end }
        for (_, delivery) in ready {
            time = delivery.time
            let message = delivery.message
            let outcome = try await deliver(message)
            events.append(Event(
                time: time, destination: message.workload.destination,
                mutationID: message.id, outcome: outcome
            ))
        }
        time = end
    }

    private func deliver(_ message: Message) async throws -> Outcome {
        let destination = message.workload.destination
        guard !partitionedLinks.contains(Link(endpoints: [message.source, destination])) else { return .partitioned }
        let worker = try node(destination)
        guard let runtime = worker.runtime else { return .offline }
        let localTime = worker.clockSkew >= 0
            ? try adding(UInt64(worker.clockSkew), to: time)
            : time - min(time, worker.clockSkew.magnitude)
        guard !lease.isExpired(atMilliseconds: time), !lease.isExpired(atMilliseconds: localTime) else {
            return .leaseExpired
        }
        guard let sourceLease = leaseHistory[message.token], sourceLease.leaderNodeID == message.source else {
            throw Fault.invalidMutationBinding
        }

        let previousFence = try worker.lastFence()
        let authority = try ClusterMutationAuthoritySnapshot(controlPlaneLease: lease)
        let source = try ClusterMutationSourceRecordBinding(controlPlaneLease: sourceLease)
        let decision = ClusterMutationFenceEvaluator().evaluate(
            current: previousFence, encodedProposed: message.proof,
            expectedAuthority: authority, expectedSourceRecord: source
        )
        switch decision {
        case .rejected(let rejection): return .rejected(rejection)
        case .exactReplay: return .replay
        case .accepted(let proof):
            guard proof.mutationID == message.id, proof.mutationSHA256 == (try message.workload.digest()) else {
                throw Fault.invalidMutationBinding
            }
            let workload = message.workload
            let identity = RuntimeServiceIdentity(projectName: workload.project, serviceName: workload.service)
            let desired = DesiredRuntimeState(
                projectName: workload.project, services: [DesiredRuntimeService(identity: identity, image: workload.image)]
            )
            let observed = try await runtime.observe(desiredState: desired)
            let plan = try await runtime.plan(desiredState: desired, observedState: observed)
            try await RuntimeActivationAuthority.$validator.withValue({
                guard !Task.isCancelled else { throw CancellationError() }
                guard ClusterMutationFenceEvaluator().evaluate(
                    current: previousFence, proposed: proof,
                    expectedAuthority: authority, expectedSourceRecord: source
                ) == .accepted(proof) else { throw Fault.invalidMutationBinding }
            }) {
                for action in plan.actions {
                    _ = try await runtime.execute(
                        action,
                        confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "simulated cluster fence")
                    )
                }
            }
            try proof.canonicalJSON().write(to: worker.lastFenceURL, options: .atomic)
            return .applied
        }
    }

    private func node(_ id: ClusterNodeID) throws -> Node {
        guard let node = nodes[id] else { throw Fault.unknownNode(id) }
        return node
    }

    private func runtime(on id: ClusterNodeID) throws -> HostwrightTestRecordingRuntime {
        guard let runtime = try node(id).runtime else { throw Fault.offline(id) }
        return runtime
    }

    private func adding(_ amount: UInt64, to value: UInt64) throws -> UInt64 {
        let (result, overflow) = value.addingReportingOverflow(amount)
        guard !overflow else { throw Fault.invalidClock }
        return result
    }

    private static func evaluateLease(
        _ next: ClusterControlPlaneLeaseRecord, previous: ClusterControlPlaneLeaseRecord?, at time: UInt64
    ) throws -> ClusterControlPlaneLeaseDisposition {
        let expectation: ClusterControlPlaneLeaseExpectation
        if let previous {
            expectation = try .record(term: previous.term, recordSHA256: previous.canonicalSHA256())
        } else {
            expectation = .absent
        }
        return try ClusterControlPlaneLeaseDecisionEvaluator().decide(
            current: previous,
            proposal: ClusterControlPlaneLeaseProposal(expectation: expectation, next: next),
            authority: ClusterControlPlaneLeaseAuthority(
                clusterID: next.clusterID, nodeID: next.leaderNodeID,
                membershipEpoch: next.membershipEpoch, fencingToken: next.fencingToken
            ),
            nowMilliseconds: time
        )
    }
}
#endif
