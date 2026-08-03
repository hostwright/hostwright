import Darwin
import Foundation
import XCTest
@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightControlTransport
@testable import HostwrightState

final class PersistentControlStreamIntegrationTests: XCTestCase {
  func testAuthenticatedStreamOpenDataAcknowledgementCreditAndEnd() throws {
    let harness = StreamITProducerHarness(expectedStreamIDs: ["events-1"])
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(
      streamID: "events-1",
      request: ControlStreamOpenRequest(source: .events),
      initialCredit: 1
    )
    XCTAssertEqual(try session.nextFrame(streamID: "events-1").kind, .open)
    XCTAssertTrue(harness.waitForOpen("events-1"))

    XCTAssertEqual(
      harness.emit(
        streamID: "events-1",
        emission: .data(cursor: "event-1", payload: .object(["event": .string("one")]))
      ),
      .accepted
    )
    let data = try session.nextFrame(streamID: "events-1")
    XCTAssertEqual(data.kind, .data)
    XCTAssertEqual(data.cursor, "event-1")

    try session.acknowledge(streamID: "events-1", credit: 1, cursor: "event-1")
    XCTAssertEqual(harness.waitForCredit(streamID: "events-1"), 1)

    XCTAssertEqual(
      harness.emit(streamID: "events-1", emission: .end(cursor: "event-1")),
      .accepted
    )
    XCTAssertEqual(try session.nextFrame(streamID: "events-1").kind, .end)
  }

  func testTwoMultiplexedStreamsProgressWhileUnaryResponseIsInFlight() throws {
    let harness = StreamITProducerHarness(expectedStreamIDs: ["events-1", "metrics-1"])
    let unaryStarted = DispatchSemaphore(value: 0)
    let releaseUnary = DispatchSemaphore(value: 0)
    let fixture = try makeFixture(producerHarness: harness) { _, request, _ in
      unaryStarted.signal()
      _ = releaseUnary.wait(timeout: .now() + 2)
      return ControlResponseEnvelope(
        requestID: request.requestID, status: .completed, reasonCode: .completed
      )
    }
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    let response = StreamITResponseBox()
    let completed = expectation(description: "in-flight unary completes")
    DispatchQueue.global().async {
      defer { completed.fulfill() }
      response.result = Result {
        try session.send(
          ControlRequestEnvelope(
            requestID: "unary-1", operation: "health.get", timeoutMilliseconds: 2_000
          )
        )
      }
    }
    XCTAssertEqual(unaryStarted.wait(timeout: .now() + 1), .success)

    for streamID in ["events-1", "metrics-1"] {
      try session.openStream(
        streamID: streamID,
        request: ControlStreamOpenRequest(source: streamID == "events-1" ? .events : .metrics)
      )
      XCTAssertEqual(try session.nextFrame(streamID: streamID).kind, .open)
      XCTAssertTrue(harness.waitForOpen(streamID))
      XCTAssertEqual(
        harness.emit(
          streamID: streamID,
          emission: .data(cursor: "cursor-\(streamID)", payload: .object(["stream": .string(streamID)]))
        ),
        .accepted
      )
      XCTAssertEqual(try session.nextFrame(streamID: streamID).kind, .data)
      XCTAssertEqual(
        harness.emit(streamID: streamID, emission: .end(cursor: "cursor-\(streamID)")),
        .accepted
      )
      XCTAssertEqual(try session.nextFrame(streamID: streamID).kind, .end)
    }

    releaseUnary.signal()
    wait(for: [completed], timeout: 2)
    XCTAssertEqual(try response.value().requestID, "unary-1")
  }

  func testClientCancellationInvokesProducerCancellation() throws {
    let harness = StreamITProducerHarness(expectedStreamIDs: ["cancel-1"])
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(streamID: "cancel-1", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "cancel-1").kind, .open)
    XCTAssertTrue(harness.waitForOpen("cancel-1"))

    try session.cancel(streamID: "cancel-1")
    XCTAssertTrue(harness.waitForCancellation("cancel-1"))
  }

  func testConcurrentAcknowledgementsAndCancellationRemainOrderedAndConnectionUsable() throws {
    let harness = StreamITProducerHarness(expectedStreamIDs: ["race-1", "after-race"])
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(streamID: "race-1", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "race-1").kind, .open)
    XCTAssertTrue(harness.waitForOpen("race-1"))

    let start = DispatchSemaphore(value: 0)
    let completed = DispatchGroup()
    let results = StreamITVoidResultsBox()
    for _ in 0..<16 {
      completed.enter()
      DispatchQueue.global().async {
        _ = start.wait(timeout: .now() + 1)
        results.append(Result { try session.acknowledge(streamID: "race-1", credit: 1) })
        completed.leave()
      }
    }
    completed.enter()
    DispatchQueue.global().async {
      _ = start.wait(timeout: .now() + 1)
      results.append(Result { try session.cancel(streamID: "race-1") })
      completed.leave()
    }
    for _ in 0..<17 { start.signal() }
    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(harness.waitForCancellation("race-1"))
    XCTAssertTrue(results.errors.allSatisfy {
      ($0 as? PersistentControlClientError) == .invalidResponse
    })

    // A receiver accepts only consecutive client sequences. Opening another stream
    // proves the concurrent ACK/cancel control frames did not tear down the session.
    try session.openStream(
      streamID: "after-race", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "after-race").kind, .open)
    XCTAssertTrue(harness.waitForOpen("after-race"))
    try session.cancel(streamID: "after-race")
    XCTAssertTrue(harness.waitForCancellation("after-race"))
    XCTAssertNil(fixture.serverError)
  }

  func testLateUnaryResponseIsDiscardedWithoutClosingActiveStream() throws {
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "late-stream", sequence: 1, kind: .open,
          payload: .object([
            "source": .string(ControlStreamSource.events.rawValue),
            "resumed": .bool(false),
            "heartbeatMilliseconds": .integer(15_000),
            "inputCredit": .integer(0),
            "auditHealth": .string("healthy"),
          ])
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      Thread.sleep(forTimeInterval: 0.150)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(ControlResponseEnvelope(
          requestID: "late-unary", status: .completed, reasonCode: .completed
        )),
        kind: .response, descriptor: descriptor, deadline: deadline
      )
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "late-stream", sequence: 2, cursor: "after-late-response",
          kind: .data, payload: .string("still-open")
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "late-stream", sequence: 3, cursor: "after-late-response", kind: .end
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
    }
    defer { fixture.close() }

    let session = fixture.session
    try session.openStream(streamID: "late-stream", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "late-stream").kind, .open)
    XCTAssertThrowsError(
      try session.send(ControlRequestEnvelope(
        requestID: "late-unary", operation: "health.get", timeoutMilliseconds: 50
      ))
    ) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .deadlineExceeded)
    }
    let data = try session.nextFrame(streamID: "late-stream")
    XCTAssertEqual(data.kind, .data)
    XCTAssertEqual(data.payload, .string("still-open"))
    try session.acknowledge(streamID: "late-stream", credit: 1, cursor: data.cursor)
    XCTAssertEqual(try session.nextFrame(streamID: "late-stream").kind, .end)
    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNil(fixture.serverError)
  }

  func testMismatchedStreamAcceptanceClosesOnlyTheUntrustedConnection() throws {
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "mismatched-acceptance", sequence: 1, kind: .open,
          payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
            source: .metrics, resumed: false, heartbeatMilliseconds: 15_000,
            inputCredit: 0, auditHealth: .healthy
          ))
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
    }
    defer { fixture.close() }

    try fixture.session.openStream(
      streamID: "mismatched-acceptance", request: ControlStreamOpenRequest(source: .events))
    XCTAssertThrowsError(
      try fixture.session.nextFrame(streamID: "mismatched-acceptance", timeoutMilliseconds: 500)
    ) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .connectionClosed)
    }
    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNil(fixture.serverError)
  }

  func testPreAcceptanceServerFramesAreRejectedExceptTerminalError() throws {
    let gap = try ControlStreamFrameContract.value(
      ControlStreamGap(reason: "preacceptance-gap")
    )
    let rejected: [(String, StreamFrame)] = [
      ("data", StreamFrame(
        streamID: "preacceptance", sequence: 1, kind: .data, payload: .string("unexpected")
      )),
      ("ack", StreamFrame(
        streamID: "preacceptance", sequence: 1, kind: .ack, credit: 1
      )),
      ("heartbeat", StreamFrame(
        streamID: "preacceptance", sequence: 1, kind: .heartbeat
      )),
      ("gap", StreamFrame(
        streamID: "preacceptance", sequence: 1, kind: .gap, payload: gap
      )),
      ("end", StreamFrame(
        streamID: "preacceptance", sequence: 1, kind: .end
      )),
    ]
    for (name, frame) in rejected {
      let fixture = try StreamITRawClientFixture { descriptor in
        let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
        _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(frame),
          kind: .frame, descriptor: descriptor, deadline: deadline
        )
      }
      defer { fixture.close() }
      try fixture.session.openStream(
        streamID: "preacceptance", request: ControlStreamOpenRequest(source: .events))
      XCTAssertThrowsError(
        try fixture.session.nextFrame(streamID: "preacceptance", timeoutMilliseconds: 500),
        "\(name) before acceptance must be fatal"
      ) { error in
        XCTAssertEqual(error as? PersistentControlClientError, .connectionClosed)
      }
      XCTAssertTrue(fixture.waitForExit())
      XCTAssertNil(fixture.serverError)
    }

    let terminal = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "preacceptance-error", sequence: 1, kind: .error,
          error: SanitizedError(code: "streamRejected", message: "safe")
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
    }
    defer { terminal.close() }
    try terminal.session.openStream(
      streamID: "preacceptance-error", request: ControlStreamOpenRequest(source: .events))
    let error = try terminal.session.nextFrame(streamID: "preacceptance-error")
    XCTAssertEqual(error.kind, .error)
    XCTAssertEqual(error.error?.code, "streamRejected")
    XCTAssertTrue(terminal.waitForExit())
    XCTAssertNil(terminal.serverError)
  }

  func testMoreThanUnaryConcurrencyLimitLateResponsesRemainTombstonedForFiveMinutes() throws {
    let requestCount = ControlPlaneContract.maximumOutstandingUnary
    let requestsReceived = DispatchSemaphore(value: 0)
    let releaseLateResponses = DispatchSemaphore(value: 0)
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "late-tombstones", sequence: 1, kind: .open,
          payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
            source: .events, resumed: false, heartbeatMilliseconds: 15_000,
            inputCredit: 0, auditHealth: .healthy
          ))
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      for _ in 0..<requestCount {
        _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      }
      requestsReceived.signal()
      guard releaseLateResponses.wait(timeout: .now() + 2) == .success else {
        throw POSIXError(.ETIMEDOUT)
      }
      for index in 0..<requestCount {
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(ControlResponseEnvelope(
            requestID: "late-tombstone-\(index)", status: .completed, reasonCode: .completed
          )),
          kind: .response, descriptor: descriptor, deadline: deadline
        )
      }
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "late-tombstones", sequence: 2, cursor: "after-tombstones",
          kind: .data, payload: .string("stream-survived")
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "late-tombstones", sequence: 3, cursor: "after-tombstones", kind: .end
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
    }
    defer { fixture.close() }

    let session = fixture.session
    try session.openStream(
      streamID: "late-tombstones", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "late-tombstones").kind, .open)
    for index in 0..<requestCount {
      XCTAssertThrowsError(try session.send(ControlRequestEnvelope(
        requestID: "late-tombstone-\(index)", operation: "health.get", timeoutMilliseconds: 5
      ))) { error in
        XCTAssertEqual(error as? PersistentControlClientError, .deadlineExceeded)
      }
    }
    XCTAssertThrowsError(try session.send(ControlRequestEnvelope(
      requestID: "late-tombstone-over-limit", operation: "health.get", timeoutMilliseconds: 5
    ))) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .concurrencyLimit)
    }
    XCTAssertEqual(requestsReceived.wait(timeout: .now() + 1), .success)
    releaseLateResponses.signal()
    let data = try session.nextFrame(streamID: "late-tombstones", timeoutMilliseconds: 5_000)
    XCTAssertEqual(data.kind, .data)
    XCTAssertEqual(data.payload, .string("stream-survived"))
    try session.acknowledge(streamID: "late-tombstones", credit: 1, cursor: data.cursor)
    XCTAssertEqual(try session.nextFrame(streamID: "late-tombstones").kind, .end)
    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNil(fixture.serverError)
  }

  func testServerCannotDeliverMoreDataThanClientGranted() throws {
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "over-delivery", sequence: 1, kind: .open,
          payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
            source: .events, resumed: false, heartbeatMilliseconds: 15_000,
            inputCredit: 0, auditHealth: .healthy
          ))
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      for sequence in 2...3 {
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(StreamFrame(
            streamID: "over-delivery", sequence: UInt64(sequence),
            kind: .data, payload: .string("event-\(sequence)")
          )),
          kind: .frame, descriptor: descriptor, deadline: deadline
        )
      }
    }
    defer { fixture.close() }
    try fixture.session.openStream(
      streamID: "over-delivery",
      request: ControlStreamOpenRequest(source: .events),
      initialCredit: 1
    )
    XCTAssertEqual(try fixture.session.nextFrame(streamID: "over-delivery").kind, .open)
    XCTAssertEqual(try fixture.session.nextFrame(streamID: "over-delivery").kind, .data)
    XCTAssertThrowsError(
      try fixture.session.nextFrame(streamID: "over-delivery", timeoutMilliseconds: 1_000)
    ) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .connectionClosed)
    }
    XCTAssertTrue(fixture.waitForExit())
  }

  func testInvalidAndOverflowAcknowledgementsDoNotCorruptLiveCredit() throws {
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "ack-bounds", sequence: 1, kind: .open,
          payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
            source: .events, resumed: false, heartbeatMilliseconds: 15_000,
            inputCredit: 0, auditHealth: .healthy
          ))
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      let valid = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      XCTAssertEqual(valid.kind, .ack)
      XCTAssertEqual(valid.credit, 1)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "ack-bounds", sequence: 2, kind: .data, payload: .string("safe")
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
    }
    defer { fixture.close() }
    try fixture.session.openStream(
      streamID: "ack-bounds", request: ControlStreamOpenRequest(source: .events),
      initialCredit: 1)
    XCTAssertEqual(try fixture.session.nextFrame(streamID: "ack-bounds").kind, .open)
    XCTAssertThrowsError(try fixture.session.acknowledge(streamID: "ack-bounds", credit: -1))
    XCTAssertThrowsError(try fixture.session.acknowledge(
      streamID: "ack-bounds", credit: ControlPlaneContract.maximumStreamCredit))
    try fixture.session.acknowledge(streamID: "ack-bounds", credit: 1)
    XCTAssertEqual(try fixture.session.nextFrame(streamID: "ack-bounds").payload, .string("safe"))
    XCTAssertTrue(fixture.waitForExit())
  }

  func testReauthorizationRevocationDuringEmissionTerminatesOnlyThatStream() throws {
    let gate = StreamITReauthorizationGate()
    let harness = StreamITProducerHarness(expectedStreamIDs: ["revoked-emission"])
    let fixture = try makeFixture(producerHarness: harness, streamReauthorizer: { _, _, _ in
      gate.decision()
    })
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(
      streamID: "revoked-emission", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "revoked-emission").kind, .open)
    XCTAssertTrue(harness.waitForOpen("revoked-emission"))
    gate.revoke()

    XCTAssertEqual(
      harness.emit(
        streamID: "revoked-emission",
        emission: .data(cursor: "revoked", payload: .string("must-not-deliver"))
      ),
      .terminated
    )
    let terminal = try session.nextFrame(streamID: "revoked-emission")
    XCTAssertEqual(terminal.kind, .error)
    XCTAssertEqual(terminal.error?.code, "streamAuthorizationRevoked")
    XCTAssertTrue(harness.waitForCancellation("revoked-emission"))
    XCTAssertNil(fixture.serverError)
  }

  func testReauthorizationRevocationDuringControlClosesConnectionBeforeForwardingCredit() throws {
    let gate = StreamITReauthorizationGate()
    let harness = StreamITProducerHarness(expectedStreamIDs: ["revoked-control"])
    let fixture = try makeFixture(producerHarness: harness, streamReauthorizer: { _, _, _ in
      gate.decision()
    })
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(
      streamID: "revoked-control", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "revoked-control").kind, .open)
    XCTAssertTrue(harness.waitForOpen("revoked-control"))
    gate.revoke()
    try session.acknowledge(streamID: "revoked-control", credit: 1)

    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNotNil(fixture.serverError)
    XCTAssertNil(harness.waitForCredit(streamID: "revoked-control", timeout: 0.100))
    XCTAssertTrue(harness.waitForCancellation("revoked-control"))
  }

  func testFullDuplexInputUsesBoundedCreditsAndServerAcknowledgements() throws {
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "exec-input", sequence: 1, kind: .open,
          payload: .object([
            "source": .string(ControlStreamSource.exec.rawValue),
            "resumed": .bool(false),
            "heartbeatMilliseconds": .integer(15_000),
            "inputCredit": .integer(16),
            "operationRef": .string("stream:" + String(repeating: "a", count: 32)),
            "auditHealth": .string("healthy"),
          ])
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      for expectedSequence in 2...17 {
        let input = try ControlStreamFrameContract.decode(
          ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
        XCTAssertEqual(input.kind, .data)
        XCTAssertEqual(input.sequence, UInt64(expectedSequence))
      }
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "exec-input", sequence: 2, kind: .ack, credit: 1
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      let secondInput = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      XCTAssertEqual(secondInput.kind, .data)
      XCTAssertEqual(secondInput.sequence, 18)
      let inputEnd = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      XCTAssertEqual(inputEnd.kind, .end)
      XCTAssertEqual(inputEnd.sequence, 19)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "exec-input", sequence: 3, kind: .end
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
    }
    defer { fixture.close() }

    let session = fixture.session
    try session.openStream(
      streamID: "exec-input",
      request: ControlStreamOpenRequest(
        source: .exec, target: "resource-1", requestID: "exec-request", idempotencyKey: "exec-key")
    )
    XCTAssertEqual(try session.nextFrame(streamID: "exec-input").kind, .open)
    let input: ControlPlaneJSONValue = .object([
      "kind": .string("stdin"), "payloadBase64": .string("Zmlyc3Q=")
    ])
    for _ in 0..<16 { try session.sendStreamInput(streamID: "exec-input", payload: input) }
    XCTAssertThrowsError(try session.sendStreamInput(streamID: "exec-input", payload: input)) {
      XCTAssertEqual($0 as? PersistentControlClientError, .invalidResponse)
    }
    XCTAssertEqual(try session.nextFrame(streamID: "exec-input").kind, .ack)
    try session.sendStreamInput(streamID: "exec-input", payload: input)
    try session.finishStreamInput(streamID: "exec-input")
    XCTAssertThrowsError(try session.sendStreamInput(streamID: "exec-input", payload: input)) {
      XCTAssertEqual($0 as? PersistentControlClientError, .invalidResponse)
    }
    XCTAssertEqual(try session.nextFrame(streamID: "exec-input").kind, .end)
    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNil(fixture.serverError)
  }

  func testWriteHalfCloseDrainsFiniteFramesBeforeServerExit() throws {
    let harness = StreamITProducerHarness(
      automaticEmissions: [
        "finite-1": [
          .data(cursor: "finite-cursor", payload: .string("payload")),
          .end(cursor: "finite-cursor"),
        ]
      ],
      expectedStreamIDs: ["finite-1"]
    )
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(streamID: "finite-1", request: ControlStreamOpenRequest(source: .events))
    try session.halfCloseWrites()

    XCTAssertEqual(try session.nextFrame(streamID: "finite-1").kind, .open)
    XCTAssertEqual(try session.nextFrame(streamID: "finite-1").kind, .data)
    XCTAssertEqual(try session.nextFrame(streamID: "finite-1").kind, .end)
    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNil(fixture.serverError)
  }

  func testConcurrentInteractiveSendersReserveEachInputCreditExactlyOnce() throws {
    let firstReceived = DispatchSemaphore(value: 0)
    let permitSecondCredit = DispatchSemaphore(value: 0)
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      let open = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: open.streamID,
          sequence: 1,
          kind: .open,
          payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
            source: .exec, resumed: false,
            heartbeatMilliseconds: ControlPlaneContract.streamHeartbeatMilliseconds,
            inputCredit: 16,
            operationRef: "stream:" + String(repeating: "a", count: 32),
            auditHealth: .healthy
          ))
        )),
        kind: .frame,
        descriptor: descriptor,
        deadline: deadline
      )
      for expectedSequence in 2...16 {
        let preliminary = try ControlStreamFrameContract.decode(
          ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
        XCTAssertEqual(preliminary.kind, .data)
        XCTAssertEqual(preliminary.sequence, UInt64(expectedSequence))
      }
      let first = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      XCTAssertEqual(first.kind, .data)
      firstReceived.signal()

      var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      XCTAssertEqual(poll(&state, 1, 150), 0, "one ACK must release exactly one sender")
      XCTAssertEqual(permitSecondCredit.wait(timeout: .now() + 1), .success)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: open.streamID, sequence: 2, kind: .ack, credit: 1
        )),
        kind: .frame,
        descriptor: descriptor,
        deadline: deadline
      )
      let second = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      XCTAssertEqual(second.kind, .data)
      XCTAssertEqual(Set([first.sequence, second.sequence]), Set([17, 18]))
    }
    defer { fixture.close() }
    try fixture.session.openStream(
      streamID: "credit-reservation",
      request: ControlStreamOpenRequest(
        source: .exec, target: "resource-1", requestID: "credit-request",
        idempotencyKey: "credit-key")
    )
    XCTAssertEqual(try fixture.session.nextFrame(streamID: "credit-reservation").kind, .open)

    let preliminary: ControlPlaneJSONValue = .object([
      "kind": .string("stdin"), "payloadBase64": .string("cHJlbGltaW5hcnk=")
    ])
    for _ in 0..<15 {
      try fixture.session.sendStreamInput(
        streamID: "credit-reservation", payload: preliminary)
    }
    let payloads: [ControlPlaneJSONValue] = [
      .object(["kind": .string("stdin"), "payloadBase64": .string("YQ==")]),
      .object(["kind": .string("signal"), "signal": .integer(Int64(SIGTERM))]),
    ]
    let group = DispatchGroup()
    let results = StreamITVoidResultsBox()
    for payload in payloads {
      group.enter()
      DispatchQueue.global().async {
        results.append(Result {
          try fixture.session.sendStreamInputWhenCreditAvailable(
            streamID: "credit-reservation", payload: payload, timeoutMilliseconds: 1_000)
        })
        group.leave()
      }
    }
    XCTAssertEqual(firstReceived.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(group.wait(timeout: .now() + 0.100), .timedOut)
    permitSecondCredit.signal()
    XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(results.errors.isEmpty)
    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNil(fixture.serverError)
  }

  func testPrewriteValidationFailureRefundsReservedInteractiveInputCredit() throws {
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      let open = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: open.streamID,
          sequence: 1,
          kind: .open,
          payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
            source: .exec,
            resumed: false,
            heartbeatMilliseconds: ControlPlaneContract.streamHeartbeatMilliseconds,
            inputCredit: ControlPlaneContract.maximumInteractiveStreamInputCredit,
            operationRef: "stream:" + String(repeating: "a", count: 32),
            auditHealth: .healthy
          ))
        )),
        kind: .frame,
        descriptor: descriptor,
        deadline: deadline
      )
      for sequence in 2...17 {
        let input = try ControlStreamFrameContract.decode(
          ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
        XCTAssertEqual(input.sequence, UInt64(sequence))
        XCTAssertEqual(input.kind, .data)
      }
    }
    defer { fixture.close() }
    try fixture.session.openStream(
      streamID: "credit-refund",
      request: ControlStreamOpenRequest(
        source: .exec,
        target: "resource-1",
        requestID: "credit-refund-request",
        idempotencyKey: "credit-refund-key"
      )
    )
    XCTAssertEqual(try fixture.session.nextFrame(streamID: "credit-refund").kind, .open)

    let preliminary: ControlPlaneJSONValue = .object([
      "kind": .string("stdin"),
      "payloadBase64": .string("cHJlbGltaW5hcnk="),
    ])
    for _ in 0..<15 {
      try fixture.session.sendStreamInput(streamID: "credit-refund", payload: preliminary)
    }

    XCTAssertThrowsError(try fixture.session.sendStreamInputWhenCreditAvailable(
      streamID: "credit-refund",
      payload: .object([
        "kind": .string("stdin"),
        "payloadBase64": .string(String(repeating: "A", count: 2 * 1_024 * 1_024)),
      ])
    ))
    try fixture.session.sendStreamInputWhenCreditAvailable(
      streamID: "credit-refund",
      payload: .object([
        "kind": .string("stdin"),
        "payloadBase64": .string("b2s="),
      ])
    )
    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNil(fixture.serverError)
  }

  func testThirtyThirdStreamIsRefusedAndFiniteStreamsTerminallyClose() throws {
    let emissions: [String: [ControlStreamEmission]] = Dictionary(
      uniqueKeysWithValues: (1...ControlPlaneContract.maximumStreams).map { index in
        ("stream-\(index)", [.end(cursor: "end-\(index)")])
      }
    )
    let harness = StreamITProducerHarness(
      automaticEmissions: emissions,
      expectedStreamIDs: (1...ControlPlaneContract.maximumStreams).map { "stream-\($0)" }
    )
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    for index in 1...ControlPlaneContract.maximumStreams {
      try session.openStream(
        streamID: "stream-\(index)", request: ControlStreamOpenRequest(source: .events)
      )
    }
    XCTAssertThrowsError(
      try session.openStream(streamID: "stream-33", request: ControlStreamOpenRequest(source: .events))
    ) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .streamLimit)
    }

    for index in 1...ControlPlaneContract.maximumStreams {
      let streamID = "stream-\(index)"
      XCTAssertEqual(try session.nextFrame(streamID: streamID).kind, StreamFrameKind.open)
      XCTAssertEqual(try session.nextFrame(streamID: streamID).kind, StreamFrameKind.end)
    }
  }

  func testInactiveSessionClosesTheActiveStreamConnection() throws {
    let harness = StreamITProducerHarness(expectedStreamIDs: ["revoke-1"])
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(streamID: "revoke-1", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "revoke-1").kind, .open)
    XCTAssertTrue(harness.waitForOpen("revoke-1"))

    fixture.sessionStore.deactivate()
    _ = try? session.acknowledge(streamID: "revoke-1", credit: 1)

    XCTAssertTrue(fixture.waitForExit())
    XCTAssertNotNil(fixture.serverError)
    XCTAssertTrue(harness.waitForCancellation("revoke-1"))
    XCTAssertThrowsError(try session.nextFrame(streamID: "revoke-1", timeoutMilliseconds: 250)) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .connectionClosed)
    }
  }

  func testReadOnlySourcesRejectInputEndDataAndInputAcknowledgements() throws {
    let readOnly: [(ControlStreamSource, String?)] = [(.events, nil), (.metrics, nil), (.logs, "log-target")]
    let input: ControlPlaneJSONValue = .object([
      "kind": .string("stdin"), "payloadBase64": .string("aGVsbG8=")
    ])

    for (source, target) in readOnly {
      let harness = StreamITProducerHarness(expectedStreamIDs: ["readonly-\(source.rawValue)"])
      let fixture = try makeFixture(producerHarness: harness)
      defer { fixture.close() }
      let session = try fixture.authenticate()
      defer { session.close() }
      let streamID = "readonly-\(source.rawValue)"
      try session.openStream(
        streamID: streamID, request: ControlStreamOpenRequest(source: source, target: target))
      XCTAssertEqual(try session.nextFrame(streamID: streamID).kind, .open)
      XCTAssertTrue(harness.waitForOpen(streamID))
      XCTAssertThrowsError(try session.sendStreamInput(streamID: streamID, payload: input)) {
        XCTAssertEqual($0 as? PersistentControlClientError, .invalidResponse)
      }

      // END is structurally valid in the generic grammar, but must be rejected locally once
      // the accepted source is known to be read-only.
      XCTAssertThrowsError(try session.finishStreamInput(streamID: streamID)) {
        XCTAssertEqual($0 as? PersistentControlClientError, .invalidResponse)
      }
    }

    for (source, target) in readOnly {
      let fixture = try StreamITRawClientFixture { descriptor in
        let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
        _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(StreamFrame(
            streamID: "readonly-ack-\(source.rawValue)", sequence: 1, kind: .open,
            payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
              source: source, resumed: false, heartbeatMilliseconds: 15_000,
              inputCredit: 0, auditHealth: .healthy
            ))
          )),
          kind: .frame, descriptor: descriptor, deadline: deadline
        )
        // A server ACK grants reverse-input credit. Read-only sources must reject it even
        // though the generic frame grammar permits an ACK.
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(StreamFrame(
            streamID: "readonly-ack-\(source.rawValue)", sequence: 2, kind: .ack, credit: 1
          )),
          kind: .frame, descriptor: descriptor, deadline: deadline
        )
        Thread.sleep(forTimeInterval: 0.250)
      }
      defer { fixture.close() }
      let streamID = "readonly-ack-\(source.rawValue)"
      try fixture.session.openStream(
        streamID: streamID, request: ControlStreamOpenRequest(source: source, target: target))
      XCTAssertEqual(try fixture.session.nextFrame(streamID: streamID).kind, .open)
      XCTAssertThrowsError(try fixture.session.nextFrame(streamID: streamID, timeoutMilliseconds: 500)) {
        XCTAssertEqual($0 as? PersistentControlClientError, .connectionClosed)
      }
    }
  }

  func testAggregateUnreadFrameBudgetIsEnforcedAcrossStreams() throws {
    let fixture = try StreamITRawClientFixture { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      for _ in 0..<2 {
        _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      }
      for streamID in ["aggregate-a", "aggregate-b"] {
        try ControlFrameCodec.write(
          try ControlPlaneCanonicalJSON.encode(StreamFrame(
            streamID: streamID, sequence: 1, kind: .open,
            payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
              source: .events, resumed: false, heartbeatMilliseconds: 15_000,
              inputCredit: 0, auditHealth: .healthy
            ))
          )),
          kind: .frame, descriptor: descriptor, deadline: deadline
        )
        for sequence in 2...65 {
          try ControlFrameCodec.write(
            try ControlPlaneCanonicalJSON.encode(StreamFrame(
              streamID: streamID, sequence: UInt64(sequence), kind: .data,
              payload: .string("unread-\(streamID)-\(sequence)")
            )),
            kind: .frame, descriptor: descriptor, deadline: deadline
          )
        }
      }
      Thread.sleep(forTimeInterval: 0.250)
    }
    defer { fixture.close() }
    for streamID in ["aggregate-a", "aggregate-b"] {
      try fixture.session.openStream(
        streamID: streamID, request: ControlStreamOpenRequest(source: .events), initialCredit: 128)
    }
    // Let the client reader accumulate both producers before checking state; the transport
    // retains already accepted frames for drain, but must refuse every later operation.
    Thread.sleep(forTimeInterval: 0.350)
    XCTAssertThrowsError(try fixture.session.openStream(
      streamID: "aggregate-after-limit", request: ControlStreamOpenRequest(source: .events))) {
      XCTAssertEqual($0 as? PersistentControlClientError, .connectionClosed)
    }
  }

  func testSlowReverseInputAcknowledgesOnlyAfterConsumptionAndThenRecovers() throws {
    let inputHarness = StreamITInputConsumptionHarness()
    let harness = StreamITProducerHarness(
      expectedStreamIDs: ["slow-input"], inputHandler: inputHarness.accept)
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }
    let input: ControlPlaneJSONValue = .object([
      "kind": .string("stdin"), "payloadBase64": .string("aGVsbG8=")
    ])
    try session.openStream(
      streamID: "slow-input",
      request: ControlStreamOpenRequest(
        source: .exec, target: "resource-1", requestID: "slow-input-request",
        idempotencyKey: "slow-input-key")
    )
    XCTAssertEqual(try session.nextFrame(streamID: "slow-input").kind, .open)
    XCTAssertTrue(harness.waitForOpen("slow-input"))
    try session.sendStreamInput(streamID: "slow-input", payload: input)
    XCTAssertTrue(inputHarness.waitForInput())
    XCTAssertThrowsError(try session.nextFrame(streamID: "slow-input", timeoutMilliseconds: 100)) {
      XCTAssertEqual($0 as? PersistentControlClientError, .deadlineExceeded)
    }
    inputHarness.consumeNext()
    XCTAssertEqual(try session.nextFrame(streamID: "slow-input").kind, .ack)

    try session.sendStreamInput(streamID: "slow-input", payload: input)
    XCTAssertTrue(inputHarness.waitForInput(count: 2))
    inputHarness.consumeNext()
    XCTAssertEqual(try session.nextFrame(streamID: "slow-input").kind, .ack)
  }

  func testSessionFaultRejectsLaterOpenAndCancelsExistingProducerWithoutLeak() throws {
    let harness = StreamITProducerHarness(expectedStreamIDs: ["before-fault"])
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(streamID: "before-fault", request: ControlStreamOpenRequest(source: .events))
    XCTAssertEqual(try session.nextFrame(streamID: "before-fault").kind, .open)
    XCTAssertTrue(harness.waitForOpen("before-fault"))
    fixture.sessionStore.deactivate()
    try session.openStream(streamID: "after-fault", request: ControlStreamOpenRequest(source: .events))
    XCTAssertThrowsError(try session.nextFrame(streamID: "after-fault", timeoutMilliseconds: 500)) {
      XCTAssertEqual($0 as? PersistentControlClientError, .connectionClosed)
    }
    XCTAssertTrue(harness.waitForCancellation("before-fault"))
    XCTAssertFalse(harness.waitForOpen("after-fault", timeout: 0.100))
  }

  func testOpenWriteFailureWithConcurrentControlNeverPublishesUsableStream() throws {
    let writer = StreamITFailingFirstWriter()
    let session = PersistentControlClientSession(descriptor: -1, frameWriter: writer.write)
    let group = DispatchGroup()
    let results = StreamITVoidResultsBox()
    group.enter()
    DispatchQueue.global().async {
      results.append(Result {
        try session.openStream(
          streamID: "partial-open", request: ControlStreamOpenRequest(source: .events))
      })
      group.leave()
    }
    XCTAssertEqual(writer.firstWriteStarted.wait(timeout: .now() + 1), .success)

    group.enter()
    DispatchQueue.global().async {
      results.append(Result { try session.acknowledge(streamID: "partial-open", credit: 1) })
      group.leave()
    }
    writer.releaseFirstWrite.signal()
    XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(results.errors.count, 2)
    XCTAssertTrue(results.errors.contains { $0 as? ControlTransportError == .ioFailure })
    XCTAssertTrue(results.errors.contains { $0 as? PersistentControlClientError == .connectionClosed })
    XCTAssertThrowsError(try session.openStream(
      streamID: "partial-open", request: ControlStreamOpenRequest(source: .events))) {
      XCTAssertEqual($0 as? PersistentControlClientError, .connectionClosed)
    }
  }

  func testShortDeadlineUnaryIncludesClientWriterHeadOfLineWait() throws {
    let writer = StreamITHOLWriter()
    let session = PersistentControlClientSession(descriptor: -1, frameWriter: writer.write)
    let firstFinished = DispatchGroup()
    firstFinished.enter()
    DispatchQueue.global().async {
      defer { firstFinished.leave() }
      _ = try? session.send(ControlRequestEnvelope(
        requestID: "hol-long", operation: "health.get", timeoutMilliseconds: 1_000))
    }
    XCTAssertEqual(writer.firstWriteStarted.wait(timeout: .now() + 1), .success)

    let shortFinished = DispatchSemaphore(value: 0)
    let short = StreamITErrorBox()
    DispatchQueue.global().async {
      defer { shortFinished.signal() }
      do {
        _ = try session.send(ControlRequestEnvelope(
          requestID: "hol-short", operation: "health.get", timeoutMilliseconds: 20))
      } catch {
        short.error = error
      }
    }
    let completedBeforeRelease = shortFinished.wait(timeout: .now() + 0.250) == .success

    writer.releaseFirstWrite.signal()
    session.close()
    XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(completedBeforeRelease, "short unary deadline must include writer lock wait")
    if !completedBeforeRelease {
      XCTAssertEqual(shortFinished.wait(timeout: .now() + 1), .success)
    }
    XCTAssertEqual(short.error as? ControlTransportError, .deadlineExceeded)
  }

  func testNearDeadlineSuccessfulWriteDoesNotResetUnaryResponseDeadline() throws {
    let fixture = try StreamITRawClientFixture(
      frameWriter: { data, kind, descriptor, deadline in
        Thread.sleep(forTimeInterval: 0.220)
        try defaultControlFrameWrite(data, kind, descriptor, deadline)
      }
    ) { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      let requestData = try ControlFrameCodec.read(
        kind: .request, descriptor: descriptor, deadline: deadline)
      let request = try Phase09StrictDecoder.decode(
        ControlRequestEnvelope.self,
        from: requestData,
        allowedKeys: [
          "apiVersion", "protocolRevision", "requestID", "operation",
          "timeoutMilliseconds", "idempotencyKey", "body",
        ],
        requiredKeys: [
          "apiVersion", "protocolRevision", "requestID", "operation", "timeoutMilliseconds",
        ]
      )
      Thread.sleep(forTimeInterval: 0.160)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(ControlResponseEnvelope(
          requestID: request.requestID, status: .completed, reasonCode: .completed)),
        kind: .response, descriptor: descriptor, deadline: deadline
      )
      Thread.sleep(forTimeInterval: 0.100)
    }
    defer { fixture.close() }

    let start = Date()
    XCTAssertThrowsError(try fixture.session.send(ControlRequestEnvelope(
      requestID: "single-deadline", operation: "health.get", timeoutMilliseconds: 300
    ))) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .deadlineExceeded)
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.350)
    XCTAssertTrue(fixture.waitForExit(timeout: 1))
    XCTAssertNil(fixture.serverError)
  }

  func testHalfCloseSerializesBehindInFlightFrameAndPermanentlyRejectsWrites() throws {
    let writer = StreamITHalfCloseWriter()
    let serverReadFullControl = DispatchSemaphore(value: 0)
    let fixture = try StreamITRawClientFixture(frameWriter: writer.write) { descriptor in
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: 2_000)
      _ = try ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline)
      try ControlFrameCodec.write(
        try ControlPlaneCanonicalJSON.encode(StreamFrame(
          streamID: "half-close-race", sequence: 1, kind: .open,
          payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
            source: .events, resumed: false, heartbeatMilliseconds: 15_000,
            inputCredit: 0, auditHealth: .healthy
          ))
        )),
        kind: .frame, descriptor: descriptor, deadline: deadline
      )
      let control = try ControlStreamFrameContract.decode(
        ControlFrameCodec.read(kind: .request, descriptor: descriptor, deadline: deadline))
      XCTAssertEqual(control.streamID, "half-close-race")
      XCTAssertEqual(control.sequence, 2)
      XCTAssertEqual(control.kind, .ack)
      XCTAssertEqual(control.credit, 1)
      serverReadFullControl.signal()
      XCTAssertThrowsError(try ControlFrameCodec.read(
        kind: .request, descriptor: descriptor, deadline: deadline
      )) { error in
        XCTAssertEqual(error as? ControlTransportError, .peerClosed)
      }
    }
    defer { fixture.close() }
    let session = fixture.session
    try session.openStream(
      streamID: "half-close-race", request: ControlStreamOpenRequest(source: .events),
      initialCredit: 1)
    XCTAssertEqual(try session.nextFrame(streamID: "half-close-race").kind, .open)

    let ackDone = DispatchSemaphore(value: 0)
    let ackError = StreamITErrorBox()
    DispatchQueue.global().async {
      defer { ackDone.signal() }
      do { try session.acknowledge(streamID: "half-close-race", credit: 1) }
      catch { ackError.error = error }
    }
    XCTAssertEqual(writer.inFlightFrameStarted.wait(timeout: .now() + 1), .success)

    let halfCloseDone = DispatchSemaphore(value: 0)
    let halfCloseError = StreamITErrorBox()
    DispatchQueue.global().async {
      defer { halfCloseDone.signal() }
      do { try session.halfCloseWrites() }
      catch { halfCloseError.error = error }
    }
    XCTAssertEqual(halfCloseDone.wait(timeout: .now() + 0.100), .timedOut)
    writer.releaseInFlightFrame.signal()
    XCTAssertEqual(ackDone.wait(timeout: .now() + 1), .success)
    XCTAssertNil(ackError.error)
    XCTAssertEqual(halfCloseDone.wait(timeout: .now() + 1), .success)
    XCTAssertNil(halfCloseError.error)
    XCTAssertEqual(serverReadFullControl.wait(timeout: .now() + 1), .success)

    XCTAssertThrowsError(try session.send(ControlRequestEnvelope(
      requestID: "after-half-close", operation: "health.get", timeoutMilliseconds: 100
    ))) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .connectionClosed)
    }
    XCTAssertThrowsError(try session.openStream(
      streamID: "after-half-close", request: ControlStreamOpenRequest(source: .events)
    )) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .connectionClosed)
    }
    XCTAssertThrowsError(try session.acknowledge(streamID: "half-close-race", credit: 1)) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .connectionClosed)
    }
    XCTAssertTrue(fixture.waitForExit(timeout: 1))
    XCTAssertNil(fixture.serverError)
  }

  func testBlockedUnaryWriterAndHandlerOverrunExpireWithinFiveSecondBound() throws {
    let blockingWriter = StreamITDeadlineBlockingWriter()
    let context = ControlStreamConnectionContext(
      descriptor: -1,
      globalBudget: ControlStreamGlobalBudget(),
      frameWriter: blockingWriter.write,
      validateSession: {}
    )
    let response = ControlResponseEnvelope(
      requestID: "blocked-unary", status: .completed, reasonCode: .completed)
    let blocked = StreamITErrorBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      do {
        try context.writeResponse(
          response, deadline: try ControlTransportDeadline(timeoutMilliseconds: 300_000))
      } catch {
        blocked.error = error
      }
    }
    XCTAssertEqual(blockingWriter.entered.wait(timeout: .now() + 1), .success)

    let peer = streamITPeer()
    let openPayload = try ControlStreamFrameContract.value(ControlStreamOpenRequest(source: .events))
    let open = StreamFrame(
      streamID: "writer-eviction", sequence: 1, kind: .open, credit: 1,
      payload: openPayload
    )
    let start = Date()
    XCTAssertThrowsError(try context.open(
      frame: open,
      peer: peer,
      authorizer: { _, _, _, _ in ControlStreamAuthorization(decision: streamITAllowDecision()) },
      cursorValidator: { _, _, _ in },
      reauthorizer: { _, _, _ in streamITAllowDecision() },
      opener: { _, _, _, _ in ControlStreamProducerHandle(cancel: {}) },
      now: Date()
    )) { error in
      XCTAssertEqual(error as? ControlTransportError, .deadlineExceeded)
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 5.75)
    XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(blocked.error as? ControlTransportError, .deadlineExceeded)
    context.cancelAll()

    let countingWriter = StreamITCountingWriter()
    let overrunContext = ControlStreamConnectionContext(
      descriptor: -1,
      globalBudget: ControlStreamGlobalBudget(),
      frameWriter: countingWriter.write,
      validateSession: {}
    )
    let dispatcher = ControlUnaryDispatcher(
      descriptor: -1,
      context: overrunContext,
      processor: { request in
        let deadline = try ControlTransportDeadline(timeoutMilliseconds: 1)
        Thread.sleep(forTimeInterval: 0.025)
        return (
          ControlResponseEnvelope(
            requestID: request.requestID, status: .completed, reasonCode: .completed),
          deadline
        )
      }
    )
    try dispatcher.submit(ControlRequestEnvelope(
      requestID: "handler-overrun", operation: "health.get", timeoutMilliseconds: 1_000))
    dispatcher.drain(timeoutMilliseconds: 1_000)
    XCTAssertEqual(countingWriter.writeCount, 0)
    overrunContext.cancelAll()
  }

  func testDeterministicDuplexOrderingUnderHeartbeatInputAndCancellationStress() throws {
    let inputHarness = StreamITInputConsumptionHarness()
    let harness = StreamITProducerHarness(
      expectedStreamIDs: ["ordered-duplex"], inputHandler: inputHarness.accept)
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }
    let request = ControlStreamOpenRequest(
      source: .exec, target: "resource-1", requestID: "ordered-request",
      idempotencyKey: "ordered-key")
    let input: ControlPlaneJSONValue = .object([
      "kind": .string("stdin"), "payloadBase64": .string("aGVsbG8=")
    ])
    try session.openStream(streamID: "ordered-duplex", request: request, initialCredit: 2)
    XCTAssertEqual(try session.nextFrame(streamID: "ordered-duplex").kind, .open)
    XCTAssertTrue(harness.waitForOpen("ordered-duplex"))

    XCTAssertEqual(harness.emit(streamID: "ordered-duplex", emission: .heartbeat), .accepted)
    XCTAssertEqual(harness.emit(
      streamID: "ordered-duplex", emission: .data(cursor: "ordered-1", payload: .string("output"))),
      .accepted)
    try session.sendStreamInput(streamID: "ordered-duplex", payload: input)
    XCTAssertTrue(inputHarness.waitForInput())
    inputHarness.consumeNext()

    XCTAssertEqual(try session.nextFrame(streamID: "ordered-duplex").kind, .heartbeat)
    let data = try session.nextFrame(streamID: "ordered-duplex")
    XCTAssertEqual(data.kind, .data)
    XCTAssertEqual(data.cursor, "ordered-1")
    XCTAssertEqual(try session.nextFrame(streamID: "ordered-duplex").kind, .ack)

    try session.cancel(streamID: "ordered-duplex")
    XCTAssertTrue(harness.waitForCancellation("ordered-duplex"))
    XCTAssertEqual(
      harness.emit(streamID: "ordered-duplex", emission: .data(cursor: "late", payload: .string("late"))),
      .terminated
    )
    XCTAssertEqual(try session.nextFrame(streamID: "ordered-duplex").kind, .end)
  }

  func testDuplicateOpenRejectsOnlyDuplicateAndOriginalStreamStaysLive() throws {
    let harness = StreamITProducerHarness(expectedStreamIDs: ["duplicate-live"])
    let fixture = try makeFixture(producerHarness: harness)
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }
    let request = ControlStreamOpenRequest(source: .events)
    try session.openStream(streamID: "duplicate-live", request: request)
    XCTAssertEqual(try session.nextFrame(streamID: "duplicate-live").kind, .open)
    XCTAssertTrue(harness.waitForOpen("duplicate-live"))
    XCTAssertThrowsError(try session.openStream(streamID: "duplicate-live", request: request)) {
      XCTAssertEqual($0 as? PersistentControlClientError, .invalidResponse)
    }
    XCTAssertEqual(harness.emit(
      streamID: "duplicate-live", emission: .data(cursor: "still-live", payload: .string("live"))),
      .accepted
    )
    XCTAssertEqual(try session.nextFrame(streamID: "duplicate-live").payload, .string("live"))
    try session.cancel(streamID: "duplicate-live")
    XCTAssertTrue(harness.waitForCancellation("duplicate-live"))
    XCTAssertEqual(try session.nextFrame(streamID: "duplicate-live").kind, .end)
  }

  func testCursorValidationPrecedesAuthorizationAndProducerOpen() throws {
    let tracker = StreamITCursorOrderingTracker()
    let harness = StreamITProducerHarness(expectedStreamIDs: ["valid-cursor-stream"])
    let fixture = try makeFixture(
      producerHarness: harness,
      streamAuthorizer: { _, _, request, _ in
        tracker.recordAuthorization()
        return ControlStreamAuthorization(
          decision: streamITAllowDecision(),
          operationReference: request.source == .exec || request.source == .attach
            ? "stream:" + String(repeating: "a", count: 32)
            : nil
        )
      },
      streamCursorValidator: { _, _, cursor in
        try tracker.validate(cursor: cursor)
      },
      streamOpener: { peer, request, cursor, emit in
        tracker.recordOpener()
        return try harness.open(peer: peer, request: request, cursor: cursor, emit: emit)
      }
    )
    defer { fixture.close() }
    let session = try fixture.authenticate()
    defer { session.close() }

    try session.openStream(
      streamID: "forged-cursor-stream",
      request: ControlStreamOpenRequest(source: .events),
      cursor: "forged-cursor"
    )
    let rejected = try session.nextFrame(streamID: "forged-cursor-stream")
    XCTAssertEqual(rejected.sequence, 1)
    XCTAssertEqual(rejected.kind, .error)
    XCTAssertEqual(rejected.error?.code, "invalidStreamCursor")
    XCTAssertEqual(tracker.authorizationCount, 0)
    XCTAssertEqual(tracker.openerCount, 0)
    XCTAssertEqual(tracker.order, ["validate:forged-cursor"])
    XCTAssertThrowsError(try session.nextFrame(
      streamID: "forged-cursor-stream", timeoutMilliseconds: 100
    )) { error in
      XCTAssertEqual(error as? PersistentControlClientError, .invalidResponse)
    }

    try session.openStream(
      streamID: "valid-cursor-stream",
      request: ControlStreamOpenRequest(source: .events),
      cursor: "valid-cursor"
    )
    let accepted = try session.nextFrame(streamID: "valid-cursor-stream")
    XCTAssertEqual(accepted.kind, .open)
    XCTAssertTrue(harness.waitForOpen("valid-cursor-stream"))
    XCTAssertEqual(tracker.authorizationCount, 1)
    XCTAssertEqual(tracker.openerCount, 1)
    XCTAssertEqual(
      tracker.order,
      ["validate:forged-cursor", "validate:valid-cursor", "authorize", "open"]
    )
    try session.cancel(streamID: "valid-cursor-stream")
    XCTAssertTrue(harness.waitForCancellation("valid-cursor-stream"))
    XCTAssertEqual(try session.nextFrame(streamID: "valid-cursor-stream").kind, .end)
  }

  private func makeFixture(
    producerHarness: StreamITProducerHarness,
    handler: @escaping PersistentControlConnectionServer.Handler = { _, request, _ in
      ControlResponseEnvelope(requestID: request.requestID, status: .completed, reasonCode: .completed)
    },
    streamReauthorizer: @escaping ControlStreamReauthorizer = { _, _, _ in
      RBACDecision(
        effect: .allow,
        ruleIdentifiers: ["allow-stream"],
        reasonCode: "authorization.allowed"
      )
    },
    streamAuthorizer: @escaping ControlStreamAuthorizer = { _, _, request, _ in
      ControlStreamAuthorization(
        decision: RBACDecision(
          effect: .allow,
          ruleIdentifiers: ["allow-stream"],
          reasonCode: "authorization.allowed"
        ),
        operationReference: request.source == .exec || request.source == .attach
          ? "stream:" + String(repeating: "a", count: 32)
          : nil
      )
    },
    streamCursorValidator: @escaping ControlStreamCursorValidator = { _, _, _ in },
    streamOpener: ControlStreamOpener? = nil
  ) throws -> StreamITFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("hw-p09-stream-it-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let identity = CodeIdentity(
      signingIdentifier: "hostwright-stream-integration",
      codeDirectoryHash: String(repeating: "a", count: 40),
      validationMode: .pinnedAdHoc
    )
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "stream-subject", userID: UInt32(geteuid()), codeIdentity: identity,
        declaredBySubjectID: "stream-subject", declaredAt: "2026-08-03T00:00:00Z",
        updatedAt: "2026-08-03T00:00:00Z"
      )
    )
    let adapter = try SQLiteControlIdentitySecurityAdapter(store: store, sessionLifetime: 600)
    let sessionStore = StreamITSessionStore(base: adapter)
    let credentials = RawControlPeerCredentials(
      peerUID: UInt32(geteuid()), peerGID: UInt32(getegid()), peerPID: getpid(),
      auditEffectiveUID: UInt32(geteuid()), auditEffectiveGID: UInt32(getegid()),
      auditPID: getpid(), auditPIDVersion: 1, auditSessionID: 1,
      auditTokenData: Data(repeating: 11, count: MemoryLayout<audit_token_t>.size)
    )
    let authenticator = ControlPeerAuthenticator(
      policy: try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()), pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
      ),
      credentialReader: StreamITCredentialReader(credentials: credentials),
      codeValidator: StreamITCodeValidator(identity: identity),
      subjectResolver: adapter,
      sessionStore: sessionStore
    )
    let server = try PersistentControlConnectionServer(
      authenticator: authenticator,
      requestRepository: ControlRequestRepository(store: store),
      daemonGeneration: 1,
      socketIdentity: ControlSocketIdentity(device: 101, inode: 103),
      mutatingOperations: [],
      auditRecorder: StreamITAuditRecorder(),
      authorizer: { _, _, _ in
        RBACDecision(effect: .allow, ruleIdentifiers: ["allow"], reasonCode: "authorization.allowed")
      },
      admissionEvaluator: { _, _, _ in throw PersistentControlServerError.persistenceFailed },
      streamAuthorizer: streamAuthorizer,
      streamCursorValidator: streamCursorValidator,
      streamReauthorizer: streamReauthorizer,
      streamOpener: streamOpener ?? { peer, request, cursor, emit in
        try producerHarness.open(peer: peer, request: request, cursor: cursor, emit: emit)
      },
      handler: handler
    )
    return try StreamITFixture(root: root, server: server, sessionStore: sessionStore)
  }
}

private final class StreamITFixture: @unchecked Sendable {
  let sessionStore: StreamITSessionStore
  private let root: URL
  private let client: Int32
  private let result = StreamITServerResult()
  private let finished: DispatchSemaphore
  private let exitState = StreamITExitState()
  private var closed = false

  init(root: URL, server: PersistentControlConnectionServer, sessionStore: StreamITSessionStore) throws {
    self.root = root
    self.sessionStore = sessionStore
    self.finished = DispatchSemaphore(value: 0)
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.ENFILE) }
    client = descriptors[0]
    let serverDescriptor = descriptors[1]
    try ControlFrameCodec.configureNoSigPipe(descriptor: client)
    try ControlFrameCodec.configureNoSigPipe(descriptor: serverDescriptor)
    DispatchQueue.global().async { [result, finished, exitState] in
      defer {
        _ = Darwin.close(serverDescriptor)
        exitState.markExited()
        finished.signal()
      }
      do {
        try server.serve(descriptor: serverDescriptor)
      } catch {
        result.error = error
      }
    }
  }

  func authenticate() throws -> PersistentControlClientSession {
    let deadline = try ControlTransportDeadline(timeoutMilliseconds: 1_000)
    let challengeData = try ControlFrameCodec.read(kind: .frame, descriptor: client, deadline: deadline)
    let challenge = try ControlAuthenticationWireContract.decodeChallenge(challengeData)
    XCTAssertFalse(challenge.credentialProofRequired)
    try ControlFrameCodec.write(
      try ControlPlaneCanonicalJSON.encode(ControlAuthenticationResponse()),
      kind: .request,
      descriptor: client,
      deadline: deadline
    )
    let session = PersistentControlClientSession(descriptor: client)
    session.start()
    return session
  }

  var serverError: Error? { result.error }

  func waitForExit(timeout: TimeInterval = 2) -> Bool {
    if exitState.hasExited { return true }
    guard finished.wait(timeout: .now() + timeout) == .success else { return false }
    return true
  }

  func close() {
    guard !closed else { return }
    closed = true
    _ = shutdown(client, SHUT_RDWR)
    _ = waitForExit()
    try? FileManager.default.removeItem(at: root)
  }
}

private final class StreamITRawClientFixture: @unchecked Sendable {
  let session: PersistentControlClientSession
  private let finished = DispatchSemaphore(value: 0)
  private let result = StreamITServerResult()
  private let exitState = StreamITExitState()
  private var closed = false

  init(
    frameWriter: @escaping ControlFrameWriteOperation = defaultControlFrameWrite,
    server: @escaping @Sendable (Int32) throws -> Void
  ) throws {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.ENFILE) }
    try ControlFrameCodec.configureNoSigPipe(descriptor: descriptors[0])
    try ControlFrameCodec.configureNoSigPipe(descriptor: descriptors[1])
    session = PersistentControlClientSession(
      descriptor: descriptors[0], frameWriter: frameWriter)
    let serverDescriptor = descriptors[1]
    DispatchQueue.global().async { [result, finished, exitState] in
      defer {
        _ = Darwin.close(serverDescriptor)
        exitState.markExited()
        finished.signal()
      }
      do {
        try server(serverDescriptor)
      } catch {
        result.error = error
      }
    }
    session.start()
  }

  var serverError: Error? { result.error }

  func waitForExit(timeout: TimeInterval = 2) -> Bool {
    if exitState.hasExited { return true }
    return finished.wait(timeout: .now() + timeout) == .success
  }

  func close() {
    guard !closed else { return }
    closed = true
    session.close()
    _ = waitForExit()
  }
}

private final class StreamITProducerHarness: @unchecked Sendable {
  typealias InputHandler = @Sendable (
    String, ControlPlaneJSONValue, @escaping @Sendable () -> Void
  ) -> Bool

  private let condition = NSCondition()
  private let automaticEmissions: [String: [ControlStreamEmission]]
  private let expectedStreamIDs: [String]
  private let inputHandler: InputHandler
  private var nextExpectedStreamIndex = 0
  private var emitters: [String: @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition] = [:]
  private var credits: [String: [Int]] = [:]
  private var cancelled = Set<String>()

  init(
    automaticEmissions: [String: [ControlStreamEmission]] = [:],
    expectedStreamIDs: [String] = [],
    inputHandler: @escaping InputHandler = { _, _, _ in false }
  ) {
    self.automaticEmissions = automaticEmissions
    self.expectedStreamIDs = expectedStreamIDs
    self.inputHandler = inputHandler
  }

  func open(
    peer _: AuthenticatedControlPeer,
    request _: ControlStreamOpenRequest,
    cursor _: String?,
    emit: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws -> ControlStreamProducerHandle {
    let streamID = try nextStreamID()
    condition.lock()
    emitters[streamID] = emit
    condition.broadcast()
    let automatic = automaticEmissions[streamID] ?? []
    condition.unlock()
    for emission in automatic {
      _ = emit(emission)
    }
    return ControlStreamProducerHandle(
      onCredit: { [weak self] credit in self?.recordCredit(streamID: streamID, credit: credit) },
      onInput: { [inputHandler] payload, onConsumed in
        inputHandler(streamID, payload, onConsumed)
      },
      cancel: { [weak self] in self?.recordCancellation(streamID: streamID) }
    )
  }

  func waitForOpen(_ streamID: String, timeout: TimeInterval = 1) -> Bool {
    wait(timeout: timeout) { emitters[streamID] != nil }
  }

  func emit(streamID: String, emission: ControlStreamEmission) -> ControlStreamEmissionDisposition {
    condition.lock()
    let emitter = emitters[streamID]
    condition.unlock()
    return emitter?(emission) ?? .terminated
  }

  func waitForCredit(streamID: String, timeout: TimeInterval = 1) -> Int? {
    guard wait(timeout: timeout, { !(credits[streamID] ?? []).isEmpty }) else { return nil }
    condition.lock()
    defer { condition.unlock() }
    return credits[streamID]?.first
  }

  func waitForCancellation(_ streamID: String, timeout: TimeInterval = 1) -> Bool {
    wait(timeout: timeout) { cancelled.contains(streamID) }
  }

  private func nextStreamID() throws -> String {
    condition.lock()
    defer { condition.unlock() }
    guard nextExpectedStreamIndex < expectedStreamIDs.count else {
      throw NSError(domain: "PersistentControlStreamIntegrationTests", code: 1)
    }
    let streamID = expectedStreamIDs[nextExpectedStreamIndex]
    nextExpectedStreamIndex += 1
    guard emitters[streamID] == nil else {
      throw NSError(domain: "PersistentControlStreamIntegrationTests", code: 1)
    }
    return streamID
  }

  private func recordCredit(streamID: String, credit: Int) {
    condition.lock()
    credits[streamID, default: []].append(credit)
    condition.broadcast()
    condition.unlock()
  }

  private func recordCancellation(streamID: String) {
    condition.lock()
    cancelled.insert(streamID)
    condition.broadcast()
    condition.unlock()
  }

  private func wait(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    defer { condition.unlock() }
    while !predicate() {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }
}

private final class StreamITInputConsumptionHarness: @unchecked Sendable {
  private let condition = NSCondition()
  private var consumptions: [@Sendable () -> Void] = []
  private var receivedCount = 0

  func accept(
    streamID _: String,
    payload _: ControlPlaneJSONValue,
    onConsumed: @escaping @Sendable () -> Void
  ) -> Bool {
    condition.lock()
    consumptions.append(onConsumed)
    receivedCount += 1
    condition.broadcast()
    condition.unlock()
    return true
  }

  func waitForInput(count: Int = 1, timeout: TimeInterval = 1) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    defer { condition.unlock() }
    while receivedCount < count {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }

  func consumeNext() {
    condition.lock()
    let callback = consumptions.isEmpty ? nil : consumptions.removeFirst()
    condition.unlock()
    callback?()
  }
}

private final class StreamITSessionStore: ControlSessionBindingStoring, @unchecked Sendable {
  private let base: SQLiteControlIdentitySecurityAdapter
  private let lock = NSLock()
  private var active = true

  init(base: SQLiteControlIdentitySecurityAdapter) { self.base = base }

  func persist(_ binding: ControlSessionBinding) throws { try base.persist(binding) }

  func isActive(sessionID: String, daemonGeneration: UInt64) throws -> Bool {
    lock.lock()
    let enabled = active
    lock.unlock()
    guard enabled else { return false }
    return try base.isActive(sessionID: sessionID, daemonGeneration: daemonGeneration)
  }

  func deactivate() {
    lock.lock()
    active = false
    lock.unlock()
  }
}

private final class StreamITReauthorizationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var permitted = true

  func revoke() {
    lock.lock()
    permitted = false
    lock.unlock()
  }

  func decision() -> RBACDecision {
    lock.lock()
    let allowed = permitted
    lock.unlock()
    return RBACDecision(
      effect: allowed ? .allow : .deny,
      ruleIdentifiers: [allowed ? "allow-stream" : "revoked-stream"],
      reasonCode: allowed ? "authorization.allowed" : "authorization.revoked"
    )
  }
}

private final class StreamITCursorOrderingTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  private var authorizations = 0
  private var openers = 0

  func validate(cursor: String?) throws {
    lock.withLock { events.append("validate:\(cursor ?? "nil")") }
    if cursor == "forged-cursor" {
      throw PersistentControlServerError.invalidRequest
    }
  }

  func recordAuthorization() {
    lock.withLock {
      authorizations += 1
      events.append("authorize")
    }
  }

  func recordOpener() {
    lock.withLock {
      openers += 1
      events.append("open")
    }
  }

  var authorizationCount: Int { lock.withLock { authorizations } }
  var openerCount: Int { lock.withLock { openers } }
  var order: [String] { lock.withLock { events } }
}

private struct StreamITCredentialReader: ControlPeerCredentialReading {
  let credentials: RawControlPeerCredentials
  func read(descriptor _: Int32) throws -> RawControlPeerCredentials { credentials }
}

private struct StreamITCodeValidator: ControlPeerCodeValidating {
  let identity: CodeIdentity
  func identity(for _: Data, peerPID _: pid_t) throws -> CodeIdentity { identity }
}

private final class StreamITAuditRecorder: ControlSecurityAuditRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var sequence: UInt64 = 0

  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    lock.lock()
    sequence += 1
    let current = sequence
    lock.unlock()
    return AuditRecord(
      identifier: "stream-audit-\(current)", segmentID: "stream-segment", sequence: current,
      timestamp: Date(), previousDigest: current == 1 ? nil : "sha256:" + String(repeating: "1", count: 64),
      subjectID: event.subjectID, requestID: event.requestID, target: event.target,
      action: event.action, outcome: event.outcome, reasonCode: event.reasonCode,
      operationRef: event.operationRef, payloadDigest: event.payloadDigest,
      recordDigest: "sha256:" + String(repeating: "2", count: 64), signingKeyID: "test-key"
    )
  }
}

private final class StreamITResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<ControlResponseEnvelope, Error>?

  var result: Result<ControlResponseEnvelope, Error>? {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }

  func value() throws -> ControlResponseEnvelope {
    guard let result else { throw NSError(domain: "PersistentControlStreamIntegrationTests", code: 2) }
    return try result.get()
  }
}

private final class StreamITErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Error?

  var error: Error? {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
}

private final class StreamITVoidResultsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Result<Void, Error>] = []

  func append(_ result: Result<Void, Error>) {
    lock.lock()
    stored.append(result)
    lock.unlock()
  }

  var errors: [Error] {
    lock.lock()
    defer { lock.unlock() }
    return stored.compactMap {
      guard case .failure(let error) = $0 else { return nil }
      return error
    }
  }
}

private final class StreamITServerResult: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Error?

  var error: Error? {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
}

private final class StreamITExitState: @unchecked Sendable {
  private let lock = NSLock()
  private var exited = false

  var hasExited: Bool {
    lock.lock()
    defer { lock.unlock() }
    return exited
  }

  func markExited() {
    lock.lock()
    exited = true
    lock.unlock()
  }
}

private final class StreamITFailingFirstWriter: @unchecked Sendable {
  let firstWriteStarted = DispatchSemaphore(value: 0)
  let releaseFirstWrite = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var writes = 0

  func write(
    _ data: Data,
    _ kind: ControlPayloadKind,
    _ descriptor: Int32,
    _ deadline: ControlTransportDeadline
  ) throws {
    let first = lock.withLock { () -> Bool in
      writes += 1
      return writes == 1
    }
    guard first else { throw ControlTransportError.ioFailure }
    firstWriteStarted.signal()
    _ = releaseFirstWrite.wait(timeout: .now() + 1)
    throw ControlTransportError.ioFailure
  }
}

private final class StreamITHOLWriter: @unchecked Sendable {
  let firstWriteStarted = DispatchSemaphore(value: 0)
  let releaseFirstWrite = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var writes = 0

  func write(
    _ data: Data,
    _ kind: ControlPayloadKind,
    _ descriptor: Int32,
    _ deadline: ControlTransportDeadline
  ) throws {
    let first = lock.withLock { () -> Bool in
      writes += 1
      return writes == 1
    }
    guard first else { return }
    firstWriteStarted.signal()
    _ = releaseFirstWrite.wait(timeout: .now() + 1)
  }
}

private final class StreamITHalfCloseWriter: @unchecked Sendable {
  let inFlightFrameStarted = DispatchSemaphore(value: 0)
  let releaseInFlightFrame = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var writes = 0

  func write(
    _ data: Data,
    _ kind: ControlPayloadKind,
    _ descriptor: Int32,
    _ deadline: ControlTransportDeadline
  ) throws {
    let current = lock.withLock { () -> Int in
      writes += 1
      return writes
    }
    if current == 2 {
      inFlightFrameStarted.signal()
      guard releaseInFlightFrame.wait(timeout: .now() + 1) == .success else {
        throw ControlTransportError.deadlineExceeded
      }
    }
    try defaultControlFrameWrite(data, kind, descriptor, deadline)
  }
}

private final class StreamITDeadlineBlockingWriter: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)

  func write(
    _ data: Data,
    _ kind: ControlPayloadKind,
    _ descriptor: Int32,
    _ deadline: ControlTransportDeadline
  ) throws {
    entered.signal()
    while true {
      try deadline.assertActive()
      Darwin.usleep(1_000)
    }
  }
}

private final class StreamITCountingWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var writeCount: Int { lock.withLock { count } }

  func write(
    _ data: Data,
    _ kind: ControlPayloadKind,
    _ descriptor: Int32,
    _ deadline: ControlTransportDeadline
  ) throws {
    lock.withLock { count += 1 }
  }
}

private func streamITAllowDecision() -> RBACDecision {
  RBACDecision(
    effect: .allow,
    ruleIdentifiers: ["stream-it-allow"],
    reasonCode: "authorization.allowed"
  )
}

private func streamITPeer() -> AuthenticatedControlPeer {
  let identity = CodeIdentity(
    signingIdentifier: "hostwright-stream-integration",
    codeDirectoryHash: String(repeating: "a", count: 40),
    validationMode: .pinnedAdHoc
  )
  let userID = UInt32(geteuid())
  let peer = UnixPeerIdentity(
    effectiveUID: userID, effectiveGID: UInt32(getegid()), pid: getpid(), pidVersion: 1,
    auditSessionID: 1, codeIdentity: identity
  )
  return AuthenticatedControlPeer(binding: ControlSessionBinding(
    sessionID: "stream-it-session", daemonGeneration: 1, serverNonce: "stream-it-nonce",
    socketDevice: 1, socketInode: 1, peer: peer,
    subject: LocalSubject(
      identifier: "stream-it-subject", userID: userID,
      codeIdentityHash: identity.codeDirectoryHash)
  ))
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
