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

    private func request(
        id: String,
        operation: PodSandboxTransition,
        requestID: String,
        spec: Bool = false
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
