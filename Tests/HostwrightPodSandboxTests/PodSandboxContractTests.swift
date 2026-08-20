import Darwin
import Foundation
import HostwrightPodSandbox
import XCTest

final class PodSandboxContractTests: XCTestCase {
    func testBoundedPublicTypesRejectInvalidIdentifiersAndResources() throws {
        XCTAssertThrowsError(try PodSandboxID("../sandbox"))
        XCTAssertThrowsError(try PodSandboxID(String(repeating: "a", count: 129)))
        let id = try PodSandboxID("sandbox-one")
        XCTAssertThrowsError(
            try PodSandboxSpec(
                id: id,
                ownerID: "owner",
                generation: 0
            )
        )
        XCTAssertThrowsError(
            try PodSandboxSpec(
                id: id,
                ownerID: "owner",
                generation: 1,
                cpuCount: 0
            )
        )
        XCTAssertThrowsError(
            try PodSandboxRecoveryEvidence(
                id: id,
                ownerID: "owner",
                generation: 1,
                resourcePresent: false,
                prepared: true,
                running: false
            )
        )
    }

    func testLifecycleCoversCreatePrepareStartStopRestartAndExactTeardown() throws {
        let machine = PodSandboxLifecycleStateMachine()
        let id = try PodSandboxID("sandbox-one")
        let spec = try PodSandboxSpec(
            id: id,
            ownerID: "controller-a",
            generation: 1,
            cpuCount: 2,
            memoryMiB: 512
        )

        let created = try machine.apply(
            .create,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "create-1",
            spec: spec
        )
        XCTAssertEqual(created.snapshot.state, .created)
        XCTAssertEqual(created.snapshot.cleanupResourceCount, 1)

        let replay = try machine.apply(
            .create,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "create-1",
            spec: spec
        )
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.snapshot, created.snapshot)

        let prepared = try machine.apply(
            .prepare,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "prepare-1"
        )
        XCTAssertEqual(prepared.snapshot.state, .prepared)

        let running = try machine.apply(
            .start,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "start-1"
        )
        XCTAssertEqual(running.snapshot.state, .running)
        XCTAssertEqual(running.snapshot.cleanupResourceCount, 3)

        let stopped = try machine.apply(
            .stop,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "stop-1"
        )
        XCTAssertEqual(stopped.snapshot.state, .stopped)

        let restarted = try machine.apply(
            .restart,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "restart-1"
        )
        XCTAssertEqual(restarted.snapshot.state, .running)

        let teardown = try machine.apply(
            .teardown,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "teardown-1"
        )
        XCTAssertTrue(teardown.cleanupPerformed)
        XCTAssertTrue(teardown.snapshot.cleanupComplete)
        XCTAssertEqual(teardown.snapshot.state, .absent)
        XCTAssertEqual(teardown.snapshot.cleanupResourceCount, 0)

        let teardownReplay = try machine.apply(
            .teardown,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "teardown-2"
        )
        XCTAssertTrue(teardownReplay.replayed)
        XCTAssertFalse(teardownReplay.cleanupPerformed)
    }

    func testLifecycleRejectsInvalidTransitionsOwnershipAndGenerationFence() throws {
        let machine = PodSandboxLifecycleStateMachine()
        let id = try PodSandboxID("sandbox-two")
        let spec = try PodSandboxSpec(id: id, ownerID: "controller-a", generation: 4)

        XCTAssertThrowsError(
            try machine.apply(
                .start,
                id: id,
                ownerID: spec.ownerID,
                generation: spec.generation,
                requestID: "start-before-create"
            )
        ) { error in
            XCTAssertEqual(
                error as? PodSandboxLifecycleError,
                .sandboxNotFound
            )
        }

        _ = try machine.apply(
            .create,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "create-1",
            spec: spec
        )

        XCTAssertThrowsError(
            try machine.apply(
                .prepare,
                id: id,
                ownerID: "controller-b",
                generation: spec.generation,
                requestID: "prepare-owner-mismatch"
            )
        ) { error in
            XCTAssertEqual(error as? PodSandboxLifecycleError, .ownershipMismatch)
        }
        XCTAssertThrowsError(
            try machine.apply(
                .prepare,
                id: id,
                ownerID: spec.ownerID,
                generation: spec.generation + 1,
                requestID: "prepare-generation-mismatch"
            )
        ) { error in
            XCTAssertEqual(error as? PodSandboxLifecycleError, .generationMismatch)
        }
        XCTAssertThrowsError(
            try machine.apply(
                .start,
                id: id,
                ownerID: spec.ownerID,
                generation: spec.generation,
                requestID: "start-before-prepare"
            )
        ) { error in
            XCTAssertEqual(
                error as? PodSandboxLifecycleError,
                .invalidTransition(.start, .created)
            )
        }
    }

    func testRestartRecoveryAndCancellationCleanPartialResources() throws {
        let machine = PodSandboxLifecycleStateMachine()
        let id = try PodSandboxID("sandbox-recovery")
        let evidence = try PodSandboxRecoveryEvidence(
            id: id,
            ownerID: "controller-a",
            generation: 9,
            resourcePresent: true,
            prepared: true,
            running: true
        )
        let recovering = try machine.markRecoveryRequired(evidence)
        XCTAssertEqual(recovering.state, .recovering)

        let recovered = try machine.apply(
            .recover,
            id: id,
            ownerID: evidence.ownerID,
            generation: evidence.generation,
            requestID: "recover-1"
        )
        XCTAssertEqual(recovered.snapshot.state, .running)

        let cancelled = try machine.apply(
            .cancel,
            id: id,
            ownerID: evidence.ownerID,
            generation: evidence.generation,
            requestID: "cancel-1"
        )
        XCTAssertTrue(cancelled.cleanupPerformed)
        XCTAssertEqual(cancelled.snapshot.state, .absent)
        XCTAssertTrue(cancelled.snapshot.cleanupComplete)
    }

    func testPersistentRecoveryFencesGenerationsAndReplaysAcrossRestart() throws {
        let root = try makeRecoveryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FilePodSandboxRecoveryStore(
            fileURL: root.appendingPathComponent("recovery.json")
        )
        let id = try PodSandboxID("sandbox-persisted")
        let spec = try PodSandboxSpec(
            id: id,
            ownerID: "controller-a",
            generation: 7,
            cpuCount: 2,
            memoryMiB: 512
        )

        let first = try PodSandboxLifecycleStateMachine(recoveryStore: store)
        _ = try first.apply(
            .create,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "persist-create",
            spec: spec
        )
        _ = try first.apply(
            .prepare,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "persist-prepare"
        )
        let recovering = try first.markRecoveryRequired(
            try PodSandboxRecoveryEvidence(
                id: id,
                ownerID: spec.ownerID,
                generation: spec.generation,
                resourcePresent: true,
                prepared: true,
                running: true
            )
        )
        XCTAssertEqual(recovering.state, .recovering)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
            0o600
        )

        let afterRestart = try PodSandboxLifecycleStateMachine(recoveryStore: store)
        XCTAssertEqual(afterRestart.snapshot(for: id)?.state, .recovering)
        let replay = try afterRestart.apply(
            .create,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "persist-create",
            spec: spec
        )
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.snapshot.state, .created)
        let recovered = try afterRestart.apply(
            .recover,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "persist-recover"
        )
        XCTAssertEqual(recovered.snapshot.state, .running)

        let teardown = try afterRestart.apply(
            .teardown,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "persist-teardown"
        )
        XCTAssertTrue(teardown.cleanupPerformed)

        let restoredAgain = try PodSandboxLifecycleStateMachine(recoveryStore: store)
        let teardownReplay = try restoredAgain.apply(
            .teardown,
            id: id,
            ownerID: spec.ownerID,
            generation: spec.generation,
            requestID: "persist-teardown"
        )
        XCTAssertTrue(teardownReplay.replayed)
        XCTAssertFalse(teardownReplay.cleanupPerformed)
        XCTAssertThrowsError(
            try restoredAgain.apply(
                .create,
                id: id,
                ownerID: spec.ownerID,
                generation: spec.generation,
                requestID: "stale-create",
                spec: spec
            )
        ) { error in
            XCTAssertEqual(error as? PodSandboxLifecycleError, .generationConflict)
        }

        let newerSpec = try PodSandboxSpec(
            id: id,
            ownerID: spec.ownerID,
            generation: 8,
            cpuCount: spec.cpuCount,
            memoryMiB: spec.memoryMiB
        )
        let newer = try restoredAgain.apply(
            .create,
            id: id,
            ownerID: newerSpec.ownerID,
            generation: newerSpec.generation,
            requestID: "new-generation",
            spec: newerSpec
        )
        XCTAssertEqual(newer.snapshot.generation, 8)
    }

    func testRecoveryPersistenceFailureRollsBackLifecycleMutation() throws {
        let store = FailingRecoveryStore()
        let machine = try PodSandboxLifecycleStateMachine(recoveryStore: store)
        let id = try PodSandboxID("sandbox-persistence-failure")
        let spec = try PodSandboxSpec(
            id: id,
            ownerID: "controller-a",
            generation: 1
        )
        store.shouldFail = true
        XCTAssertThrowsError(
            try machine.apply(
                .create,
                id: id,
                ownerID: spec.ownerID,
                generation: spec.generation,
                requestID: "persistence-failure-create",
                spec: spec
            )
        ) { error in
            XCTAssertEqual(error as? PodSandboxLifecycleError, .recoveryPersistenceFailed)
        }
        XCTAssertNil(machine.snapshot(for: id))

        store.shouldFail = false
        XCTAssertEqual(
            try machine.apply(
                .create,
                id: id,
                ownerID: spec.ownerID,
                generation: spec.generation,
                requestID: "persistence-success-create",
                spec: spec
            ).snapshot.state,
            .created
        )
    }

    func testRecoveryStoreRejectsUnknownAndNonCanonicalJournalData() throws {
        let root = try makeRecoveryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recovery.json")
        try Data("{\"schemaVersion\":1,\"records\":[],\"tombstones\":[],\"unknown\":true}".utf8)
            .write(to: file)
        let store = try FilePodSandboxRecoveryStore(fileURL: file)
        XCTAssertThrowsError(try PodSandboxLifecycleStateMachine(recoveryStore: store)) { error in
            XCTAssertEqual(error as? PodSandboxRecoveryStoreError, .unknownField("unknown"))
        }

        try Data("{\"tombstones\":[],\"schemaVersion\":1,\"records\":[]}".utf8)
            .write(to: file)
        XCTAssertThrowsError(try PodSandboxLifecycleStateMachine(recoveryStore: store)) { error in
            XCTAssertEqual(error as? PodSandboxRecoveryStoreError, .nonCanonical)
        }
    }

    func testCanonicalEnvelopeRejectsUnknownDuplicateUnsupportedAndOversizedRequests() throws {
        let envelope = try request(
            id: "sandbox-protocol",
            operation: .create,
            requestID: "request-1",
            spec: true
        )
        let canonical = try GuestAgentEnvelopeCodec.encode(envelope)
        XCTAssertEqual(try GuestAgentEnvelopeCodec.decode(canonical), envelope)

        var unknown = canonical
        unknown.removeLast()
        unknown.append(Data(",\"unknown\":true}".utf8))
        XCTAssertThrowsError(try GuestAgentEnvelopeCodec.decode(unknown)) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .unknownField("unknown"))
        }

        let duplicate = Data(
            "{\"apiVersion\":1,\"apiVersion\":1}".utf8
        )
        XCTAssertThrowsError(try GuestAgentEnvelopeCodec.decode(duplicate)) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .duplicateField("apiVersion"))
        }

        let unsupported = String(decoding: canonical, as: UTF8.self).replacingOccurrences(
            of: "\"apiVersion\":1",
            with: "\"apiVersion\":2"
        )
        XCTAssertThrowsError(try GuestAgentEnvelopeCodec.decode(Data(unsupported.utf8))) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .unsupportedVersion(2))
        }

        let oversized = Data(repeating: 0x20, count: GuestAgentProtocolV1.maximumRequestBytes + 1)
        XCTAssertThrowsError(try GuestAgentEnvelopeCodec.decode(oversized)) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .frameTooLarge)
        }
    }

    func testUnauthenticatedDispatchFailsClosedWithoutLifecycleMutation() throws {
        let machine = PodSandboxLifecycleStateMachine()
        let dispatcher = GuestAgentDispatcher(
            machine: machine,
            authenticationBoundary: UnavailableGuestAgentAuthenticationBoundary()
        )
        let request = try request(
            id: "sandbox-auth",
            operation: .create,
            requestID: "auth-1",
            spec: true
        )

        let response = dispatcher.dispatch(request)
        XCTAssertEqual(response.error, .unauthenticated)
        XCTAssertNil(machine.snapshot(for: request.sandboxID))
    }

    func testAuthenticatedBoundaryExercisesLifecycleDispatcherAndReplay() throws {
        let machine = PodSandboxLifecycleStateMachine()
        let dispatcher = GuestAgentDispatcher(
            machine: machine,
            authenticationBoundary: TestAuthenticatedSessionBoundary()
        )
        let create = try request(
            id: "sandbox-dispatch",
            operation: .create,
            requestID: "dispatch-create",
            spec: true
        )
        XCTAssertEqual(dispatcher.dispatch(create).result, .accepted)
        XCTAssertEqual(dispatcher.dispatch(create).result, .replayed)

        let invalidStart = try request(
            id: "sandbox-dispatch",
            operation: .start,
            requestID: "dispatch-start"
        )
        XCTAssertEqual(dispatcher.dispatch(invalidStart).error, .invalidTransition)

        let teardown = try request(
            id: "sandbox-dispatch",
            operation: .teardown,
            requestID: "dispatch-teardown"
        )
        let teardownResponse = dispatcher.dispatch(teardown)
        XCTAssertEqual(teardownResponse.result, .teardownComplete)
        XCTAssertEqual(teardownResponse.state, .absent)
    }

    func testAuthenticatedGuestServerRunsLifecycleOverRealSocketPairs() throws {
        let hostToGuest = try socketPair()
        let guestToHost = try socketPair()
        let machine = PodSandboxLifecycleStateMachine()
        let server = GuestAgentServer(
            dispatcher: GuestAgentDispatcher(
                machine: machine,
                authenticationBoundary: TestAuthenticatedSessionBoundary()
            )
        )
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { finished.signal() }
            try? server.run(
                inputDescriptor: hostToGuest.1,
                outputDescriptor: guestToHost.0
            )
        }
        defer {
            _ = Darwin.close(hostToGuest.0)
            _ = Darwin.close(guestToHost.1)
            _ = finished.wait(timeout: .now() + 2)
            _ = Darwin.close(hostToGuest.1)
            _ = Darwin.close(guestToHost.0)
        }

        try GuestAgentFrameCodec.configureConnectedSocket(descriptor: hostToGuest.0)
        try GuestAgentFrameCodec.configureConnectedSocket(descriptor: guestToHost.1)

        func send(_ request: GuestAgentEnvelope) throws -> GuestAgentEnvelope {
            let deadline = try GuestAgentDeadline(timeoutMilliseconds: 1_000)
            try GuestAgentFrameCodec.write(
                try GuestAgentEnvelopeCodec.encode(request),
                kind: .request,
                descriptor: hostToGuest.0,
                deadline: deadline
            )
            let response = try GuestAgentFrameCodec.read(
                kind: .response,
                descriptor: guestToHost.1,
                deadline: deadline
            )
            return try GuestAgentEnvelopeCodec.decode(response, expectedKind: .response)
        }

        let create = try request(
            id: "sandbox-socket",
            operation: .create,
            requestID: "socket-create",
            spec: true
        )
        let created = try send(create)
        XCTAssertEqual(created.result, .accepted)
        XCTAssertEqual(created.state, .created)

        let prepare = try request(
            id: "sandbox-socket",
            operation: .prepare,
            requestID: "socket-prepare"
        )
        let prepared = try send(prepare)
        XCTAssertEqual(prepared.result, .accepted)
        XCTAssertEqual(prepared.state, .prepared)

        let teardown = try request(
            id: "sandbox-socket",
            operation: .teardown,
            requestID: "socket-teardown"
        )
        let tornDown = try send(teardown)
        XCTAssertEqual(tornDown.result, .teardownComplete)
        XCTAssertEqual(tornDown.state, .absent)
        XCTAssertEqual(machine.snapshot(for: try PodSandboxID("sandbox-socket"))?.state, .absent)
    }

    func testRealGuestServerHandlesFragmentationReplayCreditCancellationAndLifecycleCancel() throws {
        let machine = PodSandboxLifecycleStateMachine()
        let server = try GuestServerHarness(machine: machine)
        defer { server.close() }

        let create = try request(
            id: "sandbox-real-protocol",
            operation: .create,
            requestID: "real-create",
            spec: true
        )
        let created = try server.sendFragmented(create, chunkSize: 1)
        XCTAssertEqual(created.result, .accepted)
        XCTAssertEqual(created.credit, 0)

        let exhaustedPrepare = try request(
            id: "sandbox-real-protocol",
            operation: .prepare,
            requestID: "real-prepare-exhausted",
            credit: 0
        )
        XCTAssertEqual(try server.send(exhaustedPrepare).error, .creditExhausted)

        let prepare = try request(
            id: "sandbox-real-protocol",
            operation: .prepare,
            requestID: "real-prepare",
            credit: 1
        )
        let prepared = try server.send(prepare)
        XCTAssertEqual(prepared.result, .accepted)
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(try server.send(prepare).result, .replayed)

        let cancellation = try request(
            id: "sandbox-real-protocol",
            operation: .cancel,
            requestID: "real-cancel-control",
            credit: 0,
            cancellationOfRequestID: "real-start-cancelled"
        )
        XCTAssertEqual(try server.send(cancellation).result, .cancelled)

        let cancelledStart = try request(
            id: "sandbox-real-protocol",
            operation: .start,
            requestID: "real-start-cancelled"
        )
        XCTAssertEqual(try server.send(cancelledStart).error, .cancelled)

        let lifecycleCancel = try request(
            id: "sandbox-real-protocol",
            operation: .cancel,
            requestID: "real-lifecycle-cancel"
        )
        let cancelled = try server.send(lifecycleCancel)
        XCTAssertEqual(cancelled.result, .cancelled)
        XCTAssertEqual(cancelled.state, .absent)

        let teardownReplay = try request(
            id: "sandbox-real-protocol",
            operation: .teardown,
            requestID: "real-teardown-replay",
            credit: 0
        )
        let replayedTeardown = try server.send(teardownReplay)
        XCTAssertEqual(replayedTeardown.result, .replayed)
        XCTAssertEqual(replayedTeardown.state, .absent)
    }

    func testRealGuestServerRejectsMalformedOversizedAndDeadlineFrames() throws {
        let malformed = try GuestServerHarness(machine: PodSandboxLifecycleStateMachine())
        try malformed.sendRawPayload(Data("{}".utf8))
        XCTAssertTrue(malformed.waitForExit())
        malformed.close()

        let oversized = try GuestServerHarness(machine: PodSandboxLifecycleStateMachine())
        var length = UInt32(GuestAgentProtocolV1.maximumRequestBytes + 1).bigEndian
        var prefix = Data()
        withUnsafeBytes(of: &length) { prefix.append(contentsOf: $0) }
        try oversized.sendRawBytes(prefix)
        XCTAssertTrue(oversized.waitForExit())
        oversized.close()

        let deadline = try GuestServerHarness(
            machine: PodSandboxLifecycleStateMachine(),
            readTimeoutMilliseconds: 10
        )
        try deadline.sendRawBytes(Data([0, 0]))
        XCTAssertTrue(deadline.waitForExit(timeout: 1))
        deadline.close()
    }

    func testRealGuestServerRestoresRecoveryAndTeardownAfterRestart() throws {
        let root = try makeRecoveryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FilePodSandboxRecoveryStore(
            fileURL: root.appendingPathComponent("recovery.json")
        )
        let firstMachine = try PodSandboxLifecycleStateMachine(recoveryStore: store)
        let firstServer = try GuestServerHarness(machine: firstMachine)
        let create = try request(
            id: "sandbox-server-restart",
            operation: .create,
            requestID: "server-create",
            spec: true
        )
        XCTAssertEqual(try firstServer.send(create).result, .accepted)
        let prepare = try request(
            id: "sandbox-server-restart",
            operation: .prepare,
            requestID: "server-prepare"
        )
        XCTAssertEqual(try firstServer.send(prepare).state, .prepared)
        firstServer.close()

        let secondMachine = try PodSandboxLifecycleStateMachine(recoveryStore: store)
        let recovering = try secondMachine.markRecoveryRequired(
            try PodSandboxRecoveryEvidence(
                id: try PodSandboxID("sandbox-server-restart"),
                ownerID: "controller-a",
                generation: 1,
                resourcePresent: true,
                prepared: true,
                running: true
            )
        )
        XCTAssertEqual(recovering.state, .recovering)
        let secondServer = try GuestServerHarness(machine: secondMachine)
        let recover = try request(
            id: "sandbox-server-restart",
            operation: .recover,
            requestID: "server-recover"
        )
        XCTAssertEqual(try secondServer.send(recover).state, .running)
        let teardown = try request(
            id: "sandbox-server-restart",
            operation: .teardown,
            requestID: "server-teardown"
        )
        XCTAssertEqual(try secondServer.send(teardown).result, .teardownComplete)
        secondServer.close()

        let thirdMachine = try PodSandboxLifecycleStateMachine(recoveryStore: store)
        let thirdServer = try GuestServerHarness(machine: thirdMachine)
        defer { thirdServer.close() }
        let replayedTeardown = try request(
            id: "sandbox-server-restart",
            operation: .teardown,
            requestID: "server-teardown",
            credit: 0
        )
        XCTAssertEqual(try thirdServer.send(replayedTeardown).result, .replayed)

        let staleCreate = try request(
            id: "sandbox-server-restart",
            operation: .create,
            requestID: "server-stale-create",
            spec: true
        )
        XCTAssertEqual(try thirdServer.send(staleCreate).error, .generationConflict)
    }

    func testDeadlineCancellationAndCreditExhaustionAreBounded() throws {
        XCTAssertThrowsError(try GuestAgentDeadline(timeoutMilliseconds: 0)) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .invalidDeadline)
        }

        var window = try GuestAgentCreditWindow()
        XCTAssertThrowsError(try window.consume()) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .creditExhausted)
        }
        try window.grant(2)
        try window.consume()
        XCTAssertEqual(window.available, 1)

        let descriptors = try socketPair()
        defer {
            _ = Darwin.close(descriptors.0)
            _ = Darwin.close(descriptors.1)
        }
        let deadline = try GuestAgentDeadline(timeoutMilliseconds: 5)
        XCTAssertThrowsError(
            try GuestAgentFrameCodec.read(
                kind: .request,
                descriptor: descriptors.0,
                deadline: deadline
            )
        ) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .deadlineExceeded)
        }

        let cancellation = GuestAgentCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try GuestAgentFrameCodec.read(
                kind: .request,
                descriptor: descriptors.0,
                deadline: try GuestAgentDeadline(timeoutMilliseconds: 1_000),
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .cancelled)
        }

        let machine = PodSandboxLifecycleStateMachine()
        let dispatcher = GuestAgentDispatcher(
            machine: machine,
            authenticationBoundary: TestAuthenticatedSessionBoundary()
        )
        let clock = TestClock()
        let expiredDeadline = try GuestAgentDeadline(
            timeoutMilliseconds: 1,
            monotonicNow: { clock.value }
        )
        clock.value = 2_000_000
        let expiredRequest = try request(
            id: "sandbox-deadline",
            operation: .create,
            requestID: "deadline-request",
            spec: true
        )
        XCTAssertEqual(
            dispatcher.dispatch(expiredRequest, deadline: expiredDeadline).error,
            .deadlineExceeded
        )
        XCTAssertNil(machine.snapshot(for: expiredRequest.sandboxID))
    }

    func testFrameCodecRejectsMalformedAndOversizedLengthsBeforeAllocation() throws {
        let descriptors = try socketPair()
        defer {
            _ = Darwin.close(descriptors.0)
            _ = Darwin.close(descriptors.1)
        }
        try GuestAgentFrameCodec.configureConnectedSocket(descriptor: descriptors.1)
        var length = UInt32(GuestAgentProtocolV1.maximumRequestBytes + 1).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            _ = Darwin.write(descriptors.1, bytes.baseAddress, bytes.count)
        }
        XCTAssertThrowsError(
            try GuestAgentFrameCodec.read(
                kind: .request,
                descriptor: descriptors.0,
                deadline: try GuestAgentDeadline(timeoutMilliseconds: 1_000)
            )
        ) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .frameTooLarge)
        }

        XCTAssertThrowsError(
            try GuestAgentFrameCodec.encodedFrame(
                payload: Data(repeating: 0xA5, count: GuestAgentProtocolV1.maximumRequestBytes + 1),
                kind: .request
            )
        ) { error in
            XCTAssertEqual(error as? GuestAgentProtocolError, .frameTooLarge)
        }
    }

    func testRealGuestExecutableUsesSocketTransportAndFailsClosedAtAuthBoundary() throws {
        let executable = try guestExecutableURL()
        let transport = try GuestAgentProcessTransport(executableURL: executable)
        defer { transport.close() }
        let request = try request(
            id: "sandbox-process",
            operation: .create,
            requestID: "process-create",
            spec: true
        )

        let response = try transport.send(request)
        XCTAssertEqual(response.error, .unauthenticated)
        XCTAssertTrue(transport.isRunning)
        transport.close()
        XCTAssertFalse(transport.isRunning)
    }

    func testRealGuestExecutableWiresRecoveryFileWithoutAuthBypass() throws {
        let root = try makeRecoveryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryFile = root.appendingPathComponent("recovery.json")
        let executable = try guestExecutableURL()
        let transport = try GuestAgentProcessTransport(
            executableURL: executable,
            arguments: ["--recovery-file", recoveryFile.path]
        )
        defer { transport.close() }
        let request = try request(
            id: "sandbox-process-recovery",
            operation: .create,
            requestID: "process-recovery-create",
            spec: true
        )
        XCTAssertEqual(try transport.send(request).error, .unauthenticated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryFile.path))
    }

    private func request(
        id: String,
        operation: PodSandboxTransition,
        requestID: String,
        spec: Bool = false,
        credit: Int = 1,
        deadlineMilliseconds: Int = 5_000,
        cancellationOfRequestID: String? = nil
    ) throws -> GuestAgentEnvelope {
        let sandboxID = try PodSandboxID(id)
        let sandboxSpec = spec
            ? try PodSandboxSpec(
                id: sandboxID,
                ownerID: "controller-a",
                generation: 1,
                cpuCount: 2,
                memoryMiB: 512
            )
            : nil
        return try GuestAgentEnvelope.request(
            requestID: requestID,
            operation: operation,
            sandboxID: sandboxID,
            ownerID: "controller-a",
            generation: 1,
            deadlineMilliseconds: deadlineMilliseconds,
            credit: credit,
            cancellationOfRequestID: cancellationOfRequestID,
            spec: sandboxSpec
        )
    }

    private func socketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: "PodSandboxContractTests", code: Int(errno))
        }
        return (descriptors[0], descriptors[1])
    }

    private func makeRecoveryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-pod-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func guestExecutableURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["HOSTWRIGHT_POD_SANDBOX_GUEST_EXECUTABLE"] {
            return URL(fileURLWithPath: path)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/hostwright-pod-sandbox-guest"),
            root.appendingPathComponent(".build/debug/hostwright-pod-sandbox-guest")
        ]
        if let candidate = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return candidate
        }
        throw NSError(
            domain: "PodSandboxContractTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Build hostwright-pod-sandbox-guest before running integration tests."]
        )
    }
}

private struct TestAuthenticatedSessionBoundary: GuestAgentAuthenticationBoundary {
    func authorize(_ request: GuestAgentEnvelope) throws {}
}

private final class TestClock: @unchecked Sendable {
    var value: UInt64 = 0
}

private final class FailingRecoveryStore: @unchecked Sendable, PodSandboxRecoveryStore {
    var data: Data?
    var shouldFail = false

    func load() throws -> Data? {
        data
    }

    func save(_ data: Data) throws {
        if shouldFail {
            throw PodSandboxRecoveryStoreError.ioFailure
        }
        self.data = data
    }
}

private final class GuestServerHarness: @unchecked Sendable {
    private let hostInput: Int32
    private let guestInput: Int32
    private let guestOutput: Int32
    private let hostOutput: Int32
    private let finished = DispatchSemaphore(value: 0)
    private var closed = false
    private var finishedObserved = false

    init(
        machine: PodSandboxLifecycleStateMachine,
        readTimeoutMilliseconds: Int = GuestAgentProtocolV1.maximumDeadlineMilliseconds
    ) throws {
        let inputPair = try makeUnixSocketPair()
        let outputPair = try makeUnixSocketPair()
        self.hostInput = inputPair.0
        self.guestInput = inputPair.1
        self.guestOutput = outputPair.0
        self.hostOutput = outputPair.1
        try GuestAgentFrameCodec.configureConnectedSocket(descriptor: hostOutput)

        let dispatcher = GuestAgentDispatcher(
            machine: machine,
            authenticationBoundary: TestAuthenticatedSessionBoundary()
        )
        let server: GuestAgentServer
        if readTimeoutMilliseconds == GuestAgentProtocolV1.maximumDeadlineMilliseconds {
            server = GuestAgentServer(dispatcher: dispatcher)
        } else {
            server = try GuestAgentServer(
                dispatcher: dispatcher,
                readTimeoutMilliseconds: readTimeoutMilliseconds
            )
        }
        Thread.detachNewThread { [server, guestInput, guestOutput] in
            defer { self.finished.signal() }
            try? server.run(inputDescriptor: guestInput, outputDescriptor: guestOutput)
        }
    }

    func send(_ request: GuestAgentEnvelope) throws -> GuestAgentEnvelope {
        try sendFrame(
            try GuestAgentFrameCodec.encodedFrame(
                payload: GuestAgentEnvelopeCodec.encode(request),
                kind: .request
            ),
            deadlineMilliseconds: request.deadlineMilliseconds
        )
    }

    func sendFragmented(
        _ request: GuestAgentEnvelope,
        chunkSize: Int
    ) throws -> GuestAgentEnvelope {
        guard chunkSize > 0 else {
            throw GuestAgentProtocolError.invalidFrameLength
        }
        let frame = try GuestAgentFrameCodec.encodedFrame(
            payload: GuestAgentEnvelopeCodec.encode(request),
            kind: .request
        )
        try sendRawBytes(frame, chunkSize: chunkSize)
        return try receive(deadlineMilliseconds: request.deadlineMilliseconds)
    }

    func sendRawPayload(_ payload: Data) throws {
        try sendRawBytes(
            try GuestAgentFrameCodec.encodedFrame(payload: payload, kind: .request),
            chunkSize: payload.count + GuestAgentFrameCodec.prefixBytes
        )
    }

    func sendRawBytes(_ bytes: Data, chunkSize: Int? = nil) throws {
        guard !bytes.isEmpty else {
            throw GuestAgentProtocolError.invalidFrameLength
        }
        let chunk = chunkSize ?? bytes.count
        guard chunk > 0 else {
            throw GuestAgentProtocolError.invalidFrameLength
        }
        var offset = 0
        try bytes.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else {
                throw GuestAgentProtocolError.transportFailure
            }
            while offset < source.count {
                let count = min(chunk, source.count - offset)
                let written = Darwin.write(
                    hostInput,
                    baseAddress.advanced(by: offset),
                    count
                )
                guard written > 0 else {
                    throw GuestAgentProtocolError.transportFailure
                }
                offset += written
            }
        }
    }

    func waitForExit(timeout: TimeInterval = 2) -> Bool {
        let result = finished.wait(timeout: .now() + timeout) == .success
        if result {
            finishedObserved = true
        }
        return result
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = Darwin.close(hostInput)
        if !finishedObserved {
            _ = waitForExit(timeout: 2)
        }
        _ = Darwin.close(hostOutput)
        _ = Darwin.close(guestInput)
        _ = Darwin.close(guestOutput)
    }

    deinit {
        close()
    }

    private func sendFrame(
        _ frame: Data,
        deadlineMilliseconds: Int
    ) throws -> GuestAgentEnvelope {
        _ = deadlineMilliseconds
        try sendRawBytes(frame)
        return try receive(deadlineMilliseconds: deadlineMilliseconds)
    }

    private func receive(deadlineMilliseconds: Int) throws -> GuestAgentEnvelope {
        let response = try GuestAgentFrameCodec.read(
            kind: .response,
            descriptor: hostOutput,
            deadline: try GuestAgentDeadline(timeoutMilliseconds: deadlineMilliseconds)
        )
        return try GuestAgentEnvelopeCodec.decode(response, expectedKind: .response)
    }
}

private func makeUnixSocketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw NSError(domain: "PodSandboxContractTests", code: Int(errno))
    }
    return (descriptors[0], descriptors[1])
}
