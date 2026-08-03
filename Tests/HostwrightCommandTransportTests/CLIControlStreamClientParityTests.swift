import Darwin
import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
@testable import HostwrightControlTransport
import HostwrightCore
import HostwrightRuntime

final class CLIControlStreamClientParityTests: XCTestCase {
    func testCommandRunnerExecUsesTheRealStreamClientAndPreservesOutputExitAndHalfClose() throws {
        let output = StreamParityOutput()
        let received = StreamParityFrames()
        let fixture = try StreamParityFixture { descriptor in
            let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
            let preparationData = try ControlFrameCodec.read(
                kind: .request,
                descriptor: descriptor,
                deadline: deadline
            )
            let preparationRequest = try JSONDecoder().decode(
                ControlRequestEnvelope.self,
                from: preparationData
            )
            XCTAssertEqual(
                preparationRequest.operation,
                CLIControlStreamPreparationContract.operation
            )
            let preparation = try CLIControlStreamPreparation(
                source: .exec,
                target: "api",
                filter: nil,
                cursor: nil,
                timeoutMilliseconds: 2_000,
                output: .text
            )
            try Self.write(
                ControlResponseEnvelope(
                    requestID: preparationRequest.requestID,
                    status: .completed,
                    reasonCode: .completed,
                    result: try ControlStreamFrameContract.value(preparation)
                ),
                kind: .response,
                descriptor: descriptor,
                deadline: deadline
            )

            let open = try Self.readClientFrame(
                descriptor: descriptor,
                deadline: deadline
            )
            received.append(open)
            XCTAssertEqual(open.kind, .open)
            let streamID = open.streamID
            let acceptance = ControlStreamAcceptance(
                source: .exec,
                resumed: false,
                heartbeatMilliseconds: 15_000,
                inputCredit: 16,
                operationRef: "stream:0123456789abcdef0123456789abcdef",
                auditHealth: .healthy
            )
            try Self.write(
                StreamFrame(
                    streamID: streamID,
                    sequence: 1,
                    kind: .open,
                    payload: try ControlStreamFrameContract.value(acceptance)
                ),
                kind: .frame,
                descriptor: descriptor,
                deadline: deadline
            )

            let standardOutput = try RuntimeStreamEnvelope(
                sequence: 1,
                stream: .standardOutput,
                payload: Data("streamed output\n".utf8)
            )
            let exit = try RuntimeStreamEnvelope(
                sequence: 2,
                stream: .control,
                payload: try JSONSerialization.data(withJSONObject: [
                    "exitStatus": 7,
                    "kind": "cli-stream-result",
                    "schemaVersion": 1,
                ], options: [.sortedKeys])
            )
            for (sequence, envelope) in [(UInt64(2), standardOutput), (UInt64(3), exit)] {
                try Self.write(
                    StreamFrame(
                        streamID: streamID,
                        sequence: sequence,
                        kind: .data,
                        payload: try ControlStreamFrameContract.value(envelope)
                    ),
                    kind: .frame,
                    descriptor: descriptor,
                    deadline: deadline
                )
            }
            try Self.write(
                StreamFrame(streamID: streamID, sequence: 4, kind: .end),
                kind: .frame,
                descriptor: descriptor,
                deadline: deadline
            )

            for _ in 0..<3 {
                received.append(try Self.readClientFrame(
                    descriptor: descriptor,
                    deadline: deadline
                ))
            }
        }
        defer { fixture.close() }
        let environment = HostwrightCommandTransportEnvironment(
            socketPath: { "/private/tmp/hostwright-stream-parity.sock" },
            persistentSend: { _, _ in throw StreamParityError.unexpectedRoute },
            bootstrapSend: { _ in throw StreamParityError.unexpectedRoute },
            streamRun: { socketPath, route, requestID in
                try CLIControlStreamClient(
                    socketPath: socketPath,
                    inputDescriptor: -1,
                    outputWriter: { data, descriptor in
                        output.append(data, descriptor: descriptor)
                    },
                    sessionFactory: { _ in fixture.session }
                ).run(route: route, preparationRequestID: requestID)
            },
            requestID: { "stream-parity" },
            workingDirectory: { FileManager.default.temporaryDirectory.path }
        )

        let result = HostwrightCommandRunner.run(
            arguments: ["exec", "api", "--no-stdin", "--", "/bin/true"],
            environment: environment
        )

        XCTAssertEqual(result, CLIRunResult(exitCode: 7))
        XCTAssertEqual(output.standardOutput, Data("streamed output\n".utf8))
        XCTAssertTrue(output.standardError.isEmpty)
        XCTAssertTrue(fixture.waitForExit())
        XCTAssertNil(fixture.serverError)
        XCTAssertEqual(received.frames.map(\.kind), [.open, .end, .ack, .ack])
        XCTAssertEqual(received.frames.filter { $0.kind == .ack }.map(\.credit), [1, 1])
    }

    func testEventRetentionGapReturnsRawCursorsAcceptedByTheCLIContract() throws {
        let requested = try Self.eventCursor(id: "removed-event")
        let earliest = try Self.eventCursor(id: "earliest-event")
        let latest = try Self.eventCursor(id: "latest-event")
        let fixture = try StreamParityFixture { descriptor in
            let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
            let preparationData = try ControlFrameCodec.read(
                kind: .request,
                descriptor: descriptor,
                deadline: deadline
            )
            let preparationRequest = try JSONDecoder().decode(
                ControlRequestEnvelope.self,
                from: preparationData
            )
            let preparation = try CLIControlStreamPreparation(
                source: .events,
                target: nil,
                filter: nil,
                cursor: "signed-requested-cursor",
                timeoutMilliseconds: 2_000,
                output: .json
            )
            try Self.write(
                ControlResponseEnvelope(
                    requestID: preparationRequest.requestID,
                    status: .completed,
                    reasonCode: .completed,
                    result: try ControlStreamFrameContract.value(preparation)
                ),
                kind: .response,
                descriptor: descriptor,
                deadline: deadline
            )

            let open = try Self.readClientFrame(descriptor: descriptor, deadline: deadline)
            let streamID = open.streamID
            try Self.write(
                StreamFrame(
                    streamID: streamID,
                    sequence: 1,
                    kind: .open,
                    payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
                        source: .events,
                        resumed: true,
                        heartbeatMilliseconds: 15_000,
                        inputCredit: 0,
                        operationRef: nil,
                        auditHealth: .healthy
                    ))
                ),
                kind: .frame,
                descriptor: descriptor,
                deadline: deadline
            )
            try Self.write(
                StreamFrame(
                    streamID: streamID,
                    sequence: 2,
                    cursor: "signed-earliest-frame-cursor",
                    kind: .gap,
                    payload: try ControlStreamFrameContract.value(ControlStreamGap(
                        reason: "retention.compacted",
                        earliestCursor: earliest,
                        latestCursor: latest
                    ))
                ),
                kind: .frame,
                descriptor: descriptor,
                deadline: deadline
            )
        }
        defer { fixture.close() }
        let environment = HostwrightCommandTransportEnvironment(
            socketPath: { "/private/tmp/hostwright-stream-parity.sock" },
            persistentSend: { _, _ in throw StreamParityError.unexpectedRoute },
            bootstrapSend: { _ in throw StreamParityError.unexpectedRoute },
            streamRun: { socketPath, route, requestID in
                try CLIControlStreamClient(
                    socketPath: socketPath,
                    inputDescriptor: -1,
                    sessionFactory: { _ in fixture.session }
                ).run(route: route, preparationRequestID: requestID)
            },
            requestID: { "event-gap-parity" },
            workingDirectory: { FileManager.default.temporaryDirectory.path }
        )

        let result = HostwrightCommandRunner.run(
            arguments: ["events", "--cursor", requested, "--output", "json"],
            environment: environment
        )

        XCTAssertEqual(result.exitCode, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(object["status"] as? String, "retention-gap")
        let gap = try XCTUnwrap(object["retentionGap"] as? [String: Any])
        XCTAssertEqual(gap["requestedCursor"] as? String, requested)
        XCTAssertEqual(gap["earliestAvailableCursor"] as? String, earliest)
        XCTAssertEqual(gap["latestAvailableCursor"] as? String, latest)
        XCTAssertFalse(result.standardOutput.contains("signed-earliest-frame-cursor"))
        XCTAssertTrue(fixture.waitForExit())
        XCTAssertNil(fixture.serverError)
    }

    private static func readClientFrame(
        descriptor: Int32,
        deadline: ControlTransportDeadline
    ) throws -> StreamFrame {
        try JSONDecoder().decode(
            StreamFrame.self,
            from: ControlFrameCodec.read(
                kind: .request,
                descriptor: descriptor,
                deadline: deadline
            )
        )
    }

    private static func write<Value: Encodable>(
        _ value: Value,
        kind: ControlPayloadKind,
        descriptor: Int32,
        deadline: ControlTransportDeadline
    ) throws {
        try ControlFrameCodec.write(
            try ControlPlaneCanonicalJSON.encode(value),
            kind: kind,
            descriptor: descriptor,
            deadline: deadline
        )
    }

    private static func eventCursor(id: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "eventID": id,
            "eventSHA256": String(repeating: "a", count: 64),
            "schemaVersion": 1,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        return "hwe1." + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum StreamParityError: Error {
    case unexpectedRoute
}

private final class StreamParityFixture: @unchecked Sendable {
    let session: PersistentControlClientSession
    private let finished = DispatchSemaphore(value: 0)
    private let errorBox = StreamParityErrorBox()
    private let exitBox = StreamParityExitBox()
    private var closed = false

    init(server: @escaping @Sendable (Int32) throws -> Void) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
        }
        try ControlFrameCodec.configureNoSigPipe(descriptor: descriptors[0])
        try ControlFrameCodec.configureNoSigPipe(descriptor: descriptors[1])
        session = PersistentControlClientSession(descriptor: descriptors[0])
        let serverDescriptor = descriptors[1]
        DispatchQueue.global().async { [errorBox, exitBox, finished] in
            defer {
                _ = Darwin.close(serverDescriptor)
                exitBox.markExited()
                finished.signal()
            }
            do {
                try server(serverDescriptor)
            } catch {
                errorBox.store(error)
            }
        }
        session.start()
    }

    var serverError: Error? { errorBox.error }

    func waitForExit(timeout: TimeInterval = 2) -> Bool {
        if exitBox.hasExited { return true }
        return finished.wait(timeout: .now() + timeout) == .success
    }

    func close() {
        guard !closed else { return }
        closed = true
        session.close()
        _ = waitForExit()
    }
}

private final class StreamParityOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    var standardOutput: Data { lock.withLock { stdout } }
    var standardError: Data { lock.withLock { stderr } }

    func append(_ data: Data, descriptor: Int32) {
        lock.withLock {
            if descriptor == STDERR_FILENO {
                stderr.append(data)
            } else {
                stdout.append(data)
            }
        }
    }
}

private final class StreamParityFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StreamFrame] = []

    var frames: [StreamFrame] { lock.withLock { storage } }
    func append(_ frame: StreamFrame) { lock.withLock { storage.append(frame) } }
}

private final class StreamParityErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Error?

    var error: Error? { lock.withLock { storage } }
    func store(_ error: Error) { lock.withLock { storage = error } }
}

private final class StreamParityExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false

    var hasExited: Bool { lock.withLock { exited } }
    func markExited() { lock.withLock { exited = true } }
}
