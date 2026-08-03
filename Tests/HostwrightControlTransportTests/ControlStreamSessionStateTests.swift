import XCTest
@testable import HostwrightControlPlane
@testable import HostwrightControlTransport

final class ControlStreamSessionStateTests: XCTestCase {
  func testEnforcesThirtyTwoActiveStreamsAndRejectsDuplicateIDs() throws {
    let state = ControlStreamSessionState()
    for index in 1...ControlPlaneContract.maximumStreams {
      _ = try state.open(openFrame(streamID: "stream-\(index)"))
    }
    XCTAssertEqual(state.activeStreamCount, ControlPlaneContract.maximumStreams)
    XCTAssertThrowsError(try state.open(openFrame(streamID: "stream-33"))) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .streamLimit)
    }
    XCTAssertThrowsError(try state.open(openFrame(streamID: "stream-1"))) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .duplicateStream)
    }
  }

  func testCreditExhaustionAcknowledgementReplenishmentAndOverflow() throws {
    let state = ControlStreamSessionState()
    _ = try state.open(openFrame(streamID: "credit", credit: 1))
    _ = try state.makeServerFrame(
      streamID: "credit", kind: .open,
      payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
        source: .events, resumed: false, heartbeatMilliseconds: 15_000,
        inputCredit: 0, auditHealth: .healthy
      ))
    )
    _ = try state.makeServerFrame(
      streamID: "credit", kind: .data, cursor: "cursor-1", payload: .null
    )
    XCTAssertThrowsError(
      try state.makeServerFrame(streamID: "credit", kind: .data, cursor: "cursor-2", payload: .null)
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .creditExhausted)
    }

    let replenished = try state.receiveClientControl(
      StreamFrame(streamID: "credit", sequence: 2, cursor: "cursor-1", kind: .ack, credit: 2)
    )
    XCTAssertEqual(replenished.availableCredit, 2)
    XCTAssertEqual(replenished.lastAcknowledgedCursor, "cursor-1")
    _ = try state.makeServerFrame(
      streamID: "credit", kind: .data, cursor: "cursor-2", payload: .null
    )
    _ = try state.makeServerFrame(
      streamID: "credit", kind: .data, cursor: "cursor-3", payload: .null
    )

    let overflow = ControlStreamSessionState()
    _ = try overflow.open(openFrame(streamID: "overflow", credit: ControlPlaneContract.maximumStreamCredit))
    XCTAssertThrowsError(
      try overflow.receiveClientControl(
        StreamFrame(streamID: "overflow", sequence: 2, kind: .ack, credit: 1)
      )
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .creditOverflow)
    }
  }

  func testRejectsInvalidControlSequenceAndCursorAcknowledgementMismatch() throws {
    let state = ControlStreamSessionState()
    _ = try state.open(openFrame(streamID: "sequence"))
    _ = try state.makeServerFrame(
      streamID: "sequence", kind: .data, cursor: "cursor-1", payload: .null
    )

    XCTAssertThrowsError(
      try state.receiveClientControl(
        StreamFrame(streamID: "sequence", sequence: 3, cursor: "cursor-1", kind: .ack, credit: 1)
      )
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .invalidSequence)
    }
    XCTAssertThrowsError(
      try state.receiveClientControl(
        StreamFrame(streamID: "sequence", sequence: 2, cursor: "wrong-cursor", kind: .ack, credit: 1)
      )
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .cursorMismatch)
    }

    let acknowledged = try state.receiveClientControl(
      StreamFrame(streamID: "sequence", sequence: 2, cursor: "cursor-1", kind: .ack, credit: 1)
    )
    XCTAssertEqual(acknowledged.lastClientSequence, 2)
    XCTAssertEqual(acknowledged.lastAcknowledgedCursor, "cursor-1")
  }

  func testInteractiveInputAcknowledgementsNeverExceedFrozenSixteenCreditWindow() throws {
    let state = ControlStreamSessionState()
    _ = try state.open(interactiveOpenFrame(streamID: "exec"))

    // The runtime consumes one input, so its first acknowledgement may restore
    // exactly one credit. A duplicate callback must not mint another credit.
    _ = try state.receiveClientControl(inputFrame(streamID: "exec", sequence: 2))
    let restored = try state.makeServerFrame(streamID: "exec", kind: .ack, credit: 1)
    XCTAssertEqual(restored.sequence, 1)
    XCTAssertThrowsError(
      try state.makeServerFrame(streamID: "exec", kind: .ack, credit: 1)
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .creditOverflow)
    }

    // An over-credit callback after a single consumed frame is likewise denied.
    _ = try state.receiveClientControl(inputFrame(streamID: "exec", sequence: 3))
    XCTAssertThrowsError(
      try state.makeServerFrame(streamID: "exec", kind: .ack, credit: 2)
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .creditOverflow)
    }
    _ = try state.makeServerFrame(streamID: "exec", kind: .ack, credit: 1)

    // The failed callbacks leave the effective ceiling at 16, not 17 or 18.
    for sequence in 4...19 {
      _ = try state.receiveClientControl(inputFrame(streamID: "exec", sequence: UInt64(sequence)))
    }
    XCTAssertThrowsError(
      try state.receiveClientControl(inputFrame(streamID: "exec", sequence: 20))
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .creditExhausted)
    }
  }

  func testCancellationWaitsForServerTerminalAcknowledgement() throws {
    let state = ControlStreamSessionState()
    _ = try state.open(openFrame(streamID: "cancel"))
    let incarnation = try state.incarnation(streamID: "cancel")
    XCTAssertEqual(
      try state.receiveCancellation(
        StreamFrame(streamID: "cancel", sequence: 2, kind: .cancel),
        expectedIncarnation: incarnation,
        terminalImmediately: true
      )?.kind,
      .end
    )
    XCTAssertEqual(state.activeStreamCount, 0)
    XCTAssertThrowsError(
      try state.makeServerFrame(streamID: "cancel", kind: .data, payload: .null)
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .unknownStream)
    }
  }

  func testEndAndGapAreTerminalAndRejectFurtherData() throws {
    let state = ControlStreamSessionState()
    _ = try state.open(openFrame(streamID: "end"))
    _ = try state.makeServerFrame(streamID: "end", kind: .end)
    XCTAssertThrowsError(try state.snapshot(streamID: "end"))
    XCTAssertThrowsError(
      try state.makeServerFrame(streamID: "end", kind: .data, payload: .null)
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .unknownStream)
    }

    _ = try state.open(openFrame(streamID: "gap"))
    let gap = try ControlStreamFrameContract.value(
      ControlStreamGap(reason: "retention-gap", earliestCursor: "first", latestCursor: "last")
    )
    _ = try state.makeServerFrame(streamID: "gap", kind: .gap, payload: gap)
    XCTAssertThrowsError(try state.snapshot(streamID: "gap"))
    XCTAssertEqual(state.activeStreamCount, 0)
    XCTAssertThrowsError(
      try state.receiveClientControl(
        StreamFrame(streamID: "gap", sequence: 2, kind: .ack, credit: 1)
      )
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .unknownStream)
    }
  }

  func testCancelAllCancelsOnlyNonterminalStreamsInSortedOrder() throws {
    let state = ControlStreamSessionState()
    _ = try state.open(openFrame(streamID: "b"))
    _ = try state.open(openFrame(streamID: "a"))
    _ = try state.open(openFrame(streamID: "terminal"))
    _ = try state.makeServerFrame(streamID: "terminal", kind: .end)

    let cancelled = state.cancelAll()
    XCTAssertEqual(cancelled.map(\.streamID), ["a", "b"])
    XCTAssertTrue(cancelled.allSatisfy(\.isCancelled))
    XCTAssertTrue(cancelled.allSatisfy(\.isTerminal))
    XCTAssertEqual(state.activeStreamCount, 0)
    XCTAssertTrue(state.cancelAll().isEmpty)
  }

  func testReusedStreamIdentifierReceivesNewIncarnationAndRejectsStaleEmitter() throws {
    let state = ControlStreamSessionState()
    _ = try state.open(openFrame(streamID: "reused"))
    let firstIncarnation = try state.incarnation(streamID: "reused")
    _ = try state.receiveCancellation(
      StreamFrame(streamID: "reused", sequence: 2, kind: .cancel),
      expectedIncarnation: firstIncarnation,
      terminalImmediately: true
    )

    _ = try state.open(openFrame(streamID: "reused"))
    let secondIncarnation = try state.incarnation(streamID: "reused")
    XCTAssertGreaterThan(secondIncarnation, firstIncarnation)
    XCTAssertThrowsError(
      try state.makeServerFrame(
        streamID: "reused", expectedIncarnation: firstIncarnation, kind: .data, payload: .null)
    ) { error in
      XCTAssertEqual(error as? ControlStreamSessionError, .unknownStream)
    }
    XCTAssertNoThrow(
      try state.makeServerFrame(
        streamID: "reused", expectedIncarnation: secondIncarnation, kind: .data, payload: .null)
    )
  }

  private func openFrame(
    streamID: String,
    credit: Int = 1
  ) throws -> StreamFrame {
    StreamFrame(
      streamID: streamID,
      sequence: 1,
      kind: .open,
      credit: credit,
      payload: try ControlStreamFrameContract.value(
        ControlStreamOpenRequest(source: .events)
      )
    )
  }

  private func interactiveOpenFrame(streamID: String) throws -> StreamFrame {
    StreamFrame(
      streamID: streamID,
      sequence: 1,
      kind: .open,
      credit: 1,
      payload: try ControlStreamFrameContract.value(
        ControlStreamOpenRequest(
          source: .exec,
          target: "project:interactive",
          requestID: "interactive-request",
          idempotencyKey: "interactive-idempotency"
        )
      )
    )
  }

  private func inputFrame(streamID: String, sequence: UInt64) throws -> StreamFrame {
    StreamFrame(
      streamID: streamID,
      sequence: sequence,
      kind: .data,
      payload: try ControlStreamFrameContract.value(
        ControlStreamClientInput(kind: .stdin, payloadBase64: "aGVsbG8=")
      )
    )
  }
}
