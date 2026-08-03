import Darwin
import Foundation
import XCTest
@testable import HostwrightControlPlane

final class ControlStreamFrameContractTests: XCTestCase {
  func testFrozenAcceptanceAndInputGoldenFixturesRoundTripStrictly() throws {
    let contracts = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("contracts/v0.0.2", isDirectory: true)
    let decoder = JSONDecoder()
    let acceptanceData = try Data(contentsOf:
      contracts.appendingPathComponent("phase09-stream-acceptance-v2.1.json"))
    let acceptanceValue = try decoder.decode(ControlPlaneJSONValue.self, from: acceptanceData)
    let acceptance = try ControlStreamFrameContract.decodeAcceptance(acceptanceValue)
    XCTAssertEqual(
      try ControlStreamFrameContract.decodeAcceptance(
        try ControlStreamFrameContract.value(acceptance)),
      acceptance
    )
    XCTAssertEqual(acceptance.source, .exec)
    XCTAssertEqual(acceptance.inputCredit, 16)

    let inputData = try Data(contentsOf:
      contracts.appendingPathComponent("phase09-stream-input-v2.1.json"))
    let inputValue = try decoder.decode(ControlPlaneJSONValue.self, from: inputData)
    let input = try ControlStreamFrameContract.decodeClientInput(inputValue)
    XCTAssertEqual(
      try ControlStreamFrameContract.decodeClientInput(
        try ControlStreamFrameContract.value(input)),
      input
    )
    XCTAssertEqual(input.kind, .stdin)
  }

  func testDecodeRequiresOnlyFrozenTopLevelFieldsAndRejectsUnknownOrDuplicateFields() throws {
    let minimal =
      #"{"apiVersion":2,"protocolRevision":"2.1","streamID":"stream-1","sequence":1,"kind":"heartbeat"}"#
    XCTAssertEqual(try ControlStreamFrameContract.decode(Data(minimal.utf8)).kind, .heartbeat)

    let unknown =
      #"{"apiVersion":2,"protocolRevision":"2.1","streamID":"stream-1","sequence":1,"kind":"heartbeat","unknown":true}"#
    XCTAssertThrowsError(try ControlStreamFrameContract.decode(Data(unknown.utf8)))

    let missing = #"{"apiVersion":2,"protocolRevision":"2.1","streamID":"stream-1","sequence":1}"#
    XCTAssertThrowsError(try ControlStreamFrameContract.decode(Data(missing.utf8)))

    let duplicate =
      #"{"apiVersion":2,"protocolRevision":"2.1","streamID":"stream-1","sequence":1,"kind":"heartbeat","kind":"heartbeat"}"#
    XCTAssertThrowsError(try ControlStreamFrameContract.decode(Data(duplicate.utf8)))
  }

  func testOpenStrictlyDecodesSourceTargetAndHeartbeat() throws {
    let valid = try openFrame(source: .logs, target: "service-a", heartbeatMilliseconds: 1_000)
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(valid, direction: .clientToServer)
    )

    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        try openFrame(source: .logs, target: nil), direction: .clientToServer
      )
    )
    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        try openFrame(source: .events, target: "bad\nsubject"), direction: .clientToServer
      )
    )
    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        try openFrame(source: .events, target: String(repeating: "a", count: 513)),
        direction: .clientToServer
      )
    )
    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        try openFrame(source: .events, heartbeatMilliseconds: 999), direction: .clientToServer
      )
    )
    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        try openFrame(source: .events, heartbeatMilliseconds: 60_001), direction: .clientToServer
      )
    )

    let unknownOpenField: ControlPlaneJSONValue = .object([
      "source": .string("events"),
      "heartbeatMilliseconds": .integer(1_000),
      "unknown": .bool(true),
    ])
    XCTAssertThrowsError(try ControlStreamFrameContract.decodeOpenRequest(unknownOpenField))

    let missingHeartbeat: ControlPlaneJSONValue = .object(["source": .string("events")])
    XCTAssertThrowsError(try ControlStreamFrameContract.decodeOpenRequest(missingHeartbeat))
  }

  func testDirectionAndKindLegalityIsStrict() throws {
    let clientOpen = try openFrame(source: .events)
    XCTAssertNoThrow(try ControlStreamFrameContract.validate(clientOpen, direction: .clientToServer))
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 2, cursor: "cursor_1", kind: .ack, credit: 1),
        direction: .clientToServer
      )
    )
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 2, kind: .cancel),
        direction: .clientToServer
      )
    )

    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(
          streamID: "stream-1", sequence: 2, kind: .data,
          payload: .object(["kind": .string("stdin"), "payloadBase64": .string("YQ==")])
        ),
        direction: .clientToServer
      )
    )
    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(clientOpen, direction: .serverToClient)
    )

    let acceptance = StreamFrame(
      streamID: "stream-1", sequence: 1, kind: .open,
      payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
        source: .events, resumed: false, heartbeatMilliseconds: 15_000,
        inputCredit: 0, auditHealth: .healthy
      ))
    )
    XCTAssertNoThrow(try ControlStreamFrameContract.validate(acceptance, direction: .serverToClient))
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 2, cursor: "cursor_1", kind: .data, payload: .null),
        direction: .serverToClient
      )
    )
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 3, kind: .heartbeat),
        direction: .serverToClient
      )
    )
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 4, kind: .end), direction: .serverToClient
      )
    )
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(
          streamID: "stream-1", sequence: 5, kind: .error,
          error: SanitizedError(code: "failed", message: "safe")
        ),
        direction: .serverToClient
      )
    )
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 1, kind: .ack, credit: 1),
        direction: .serverToClient
      )
    )
  }

  func testAcceptanceIsStrictlyTypedAndRejectsMalformedRuntimeAndReadVariants() throws {
    let validRead = ControlStreamAcceptance(
      source: .events, resumed: false, heartbeatMilliseconds: 15_000,
      inputCredit: 0, auditHealth: .healthy
    )
    XCTAssertEqual(
      try ControlStreamFrameContract.decodeAcceptance(
        try ControlStreamFrameContract.value(validRead)
      ),
      validRead
    )

    let missingAuditHealth: ControlPlaneJSONValue = .object([
      "source": .string("events"), "resumed": .bool(false),
      "heartbeatMilliseconds": .integer(15_000), "inputCredit": .integer(0),
    ])
    XCTAssertThrowsError(try ControlStreamFrameContract.decodeAcceptance(missingAuditHealth))

    let unknownField: ControlPlaneJSONValue = .object([
      "source": .string("events"), "resumed": .bool(false),
      "heartbeatMilliseconds": .integer(15_000), "inputCredit": .integer(0),
      "auditHealth": .string("healthy"), "unexpected": .bool(true),
    ])
    XCTAssertThrowsError(try ControlStreamFrameContract.decodeAcceptance(unknownField))

    XCTAssertThrowsError(try ControlStreamFrameContract.decodeAcceptance(.object([
      "source": .string("events"), "resumed": .bool(false),
      "heartbeatMilliseconds": .integer(15_000), "inputCredit": .integer(16),
      "auditHealth": .string("healthy"),
    ])))
    XCTAssertThrowsError(try ControlStreamFrameContract.decodeAcceptance(.object([
      "source": .string("exec"), "resumed": .bool(false),
      "heartbeatMilliseconds": .integer(15_000), "inputCredit": .integer(16),
      "auditHealth": .string("healthy"),
    ])))
    XCTAssertThrowsError(try ControlStreamFrameContract.decodeAcceptance(.object([
      "source": .string("attach"), "resumed": .bool(false),
      "heartbeatMilliseconds": .integer(15_000), "inputCredit": .integer(15),
      "operationRef": .string("stream:" + String(repeating: "a", count: 32)),
      "auditHealth": .string("healthy"),
    ])))
  }

  func testCreditSequenceAndCursorBoundsAreEnforced() throws {
    for credit in [1, ControlPlaneContract.maximumStreamCredit] {
      XCTAssertNoThrow(
        try ControlStreamFrameContract.validate(
          try openFrame(source: .events, credit: credit), direction: .clientToServer
        )
      )
    }
    for credit in [0, ControlPlaneContract.maximumStreamCredit + 1] {
      XCTAssertThrowsError(
        try ControlStreamFrameContract.validate(
          try openFrame(source: .events, credit: credit), direction: .clientToServer
        )
      )
    }

    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        try openFrame(source: .events, sequence: 2), direction: .clientToServer
      )
    )
    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 0, kind: .heartbeat),
        direction: .serverToClient
      )
    )

    let maximumCursor = String(repeating: "a", count: ControlPlaneContract.maximumStreamCursorBytes)
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 2, cursor: maximumCursor, kind: .ack, credit: 1),
        direction: .clientToServer
      )
    )
    for cursor in ["", "contains/slash", String(repeating: "a", count: ControlPlaneContract.maximumStreamCursorBytes + 1)] {
      XCTAssertThrowsError(
        try ControlStreamFrameContract.validate(
          StreamFrame(streamID: "stream-1", sequence: 2, cursor: cursor, kind: .ack, credit: 1),
          direction: .clientToServer
        )
      )
    }
  }

  func testTypedClientInputSchemasAndWireBoundaryAreStrict() throws {
    let stdin = ControlStreamClientInput(
      kind: .stdin,
      payloadBase64: Data(repeating: 0x61, count: ControlPlaneContract.maximumStreamInputBytes)
        .base64EncodedString()
    )
    let stdinValue = try ControlStreamFrameContract.value(stdin)
    XCTAssertNoThrow(try ControlStreamFrameContract.decodeClientInput(stdinValue))
    let maxFrame = StreamFrame(
      streamID: String(repeating: "s", count: ControlPlaneContract.maximumStreamIdentifierBytes),
      sequence: UInt64.max - 1,
      kind: .data,
      payload: stdinValue
    )
    XCTAssertLessThanOrEqual(
      try ControlPlaneCanonicalJSON.encode(maxFrame).count,
      ControlPlaneContract.maximumRequestBytes
    )
    XCTAssertThrowsError(try ControlStreamClientInput(
      kind: .stdin,
      payloadBase64: Data(
        repeating: 0x61,
        count: ControlPlaneContract.maximumStreamInputBytes + 1
      ).base64EncodedString()
    ).validate())

    XCTAssertNoThrow(try ControlStreamClientInput(kind: .resize, columns: 80, rows: 24).validate())
    XCTAssertNoThrow(try ControlStreamClientInput(kind: .signal, signal: SIGTERM).validate())
    XCTAssertThrowsError(try ControlStreamFrameContract.decodeClientInput(.object([
      "kind": .string("stdin"), "payloadBase64": .string("YQ=="), "unknown": .bool(true),
    ])))
    XCTAssertThrowsError(try ControlStreamClientInput(
      kind: .resize, payloadBase64: "YQ==", columns: 80, rows: 24
    ).validate())
    XCTAssertThrowsError(try ControlStreamClientInput(kind: .signal, signal: SIGKILL).validate())
  }

  func testGapPayloadIsStrictlyDecodedAndValidated() throws {
    let gap = try ControlStreamFrameContract.value(
      ControlStreamGap(reason: "retention-gap", earliestCursor: "first", latestCursor: "last")
    )
    XCTAssertNoThrow(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 1, kind: .gap, payload: gap),
        direction: .serverToClient
      )
    )

    let invalidGap: ControlPlaneJSONValue = .object([
      "reason": .string("retention-gap"),
      "requiresAcknowledgement": .bool(false),
    ])
    XCTAssertThrowsError(
      try ControlStreamFrameContract.validate(
        StreamFrame(streamID: "stream-1", sequence: 1, kind: .gap, payload: invalidGap),
        direction: .serverToClient
      )
    )
  }

  private func openFrame(
    source: ControlStreamSource,
    target: String? = nil,
    heartbeatMilliseconds: Int = ControlPlaneContract.streamHeartbeatMilliseconds,
    credit: Int = 1,
    sequence: UInt64 = 1
  ) throws -> StreamFrame {
    StreamFrame(
      streamID: "stream-1",
      sequence: sequence,
      kind: .open,
      credit: credit,
      payload: try ControlStreamFrameContract.value(
        ControlStreamOpenRequest(
          source: source,
          target: target,
          heartbeatMilliseconds: heartbeatMilliseconds
        )
      )
    )
  }
}
