import Foundation
import HostwrightControlPlane

public enum ControlStreamSessionError: Error, Equatable, Sendable {
  case duplicateStream
  case streamLimit
  case unknownStream
  case invalidSequence
  case invalidTransition
  case creditExhausted
  case creditOverflow
  case cursorMismatch
}

public struct ControlStreamSnapshot: Equatable, Sendable {
  public let streamID: String
  public let source: ControlStreamSource
  public let target: String?
  public let availableCredit: Int
  public let lastClientSequence: UInt64
  public let lastServerSequence: UInt64
  public let lastDeliveredCursor: String?
  public let lastAcknowledgedCursor: String?
  public let isCancelled: Bool
  public let isTerminal: Bool
}

public final class ControlStreamSessionState: @unchecked Sendable {
  private struct State {
    let incarnation: UInt64
    let request: ControlStreamOpenRequest
    let protocolRevision: ControlProtocolRevision
    var availableCredit: Int
    var lastClientSequence: UInt64
    var lastServerSequence: UInt64
    var lastDeliveredCursor: String?
    var lastAcknowledgedCursor: String?
    var availableInputCredit: Int
    var inputClosed = false
    var cancelled = false
    var terminal = false
  }

  private let lock = NSLock()
  private var streams: [String: State] = [:]
  private var nextIncarnation: UInt64 = 1

  public init() {}

  public var activeStreamCount: Int {
    lock.withLock { streams.count }
  }

  public func open(_ frame: StreamFrame) throws -> ControlStreamOpenRequest {
    try ControlStreamFrameContract.validate(frame, direction: .clientToServer)
    guard frame.kind == .open else { throw ControlStreamSessionError.invalidTransition }
    let request = try ControlStreamFrameContract.decodeOpenRequest(frame.payload!)
    return try lock.withLock {
      guard streams[frame.streamID] == nil else {
        throw ControlStreamSessionError.duplicateStream
      }
      guard streams.count < ControlPlaneContract.maximumStreams else {
        throw ControlStreamSessionError.streamLimit
      }
      let incarnation = nextIncarnation
      guard incarnation < UInt64.max else { throw ControlStreamSessionError.invalidTransition }
      nextIncarnation += 1
      streams[frame.streamID] = State(
        incarnation: incarnation,
        request: request,
        protocolRevision: frame.protocolRevision,
        availableCredit: frame.credit!,
        lastClientSequence: frame.sequence,
        lastServerSequence: 0,
        lastDeliveredCursor: nil,
        lastAcknowledgedCursor: frame.cursor,
        availableInputCredit: request.source == .exec || request.source == .attach
          ? ControlPlaneContract.maximumInteractiveStreamInputCredit : 0
      )
      return request
    }
  }

  @discardableResult
  public func receiveClientControl(_ frame: StreamFrame) throws -> ControlStreamSnapshot {
    try ControlStreamFrameContract.validate(frame, direction: .clientToServer)
    guard frame.kind == .ack || frame.kind == .cancel || frame.kind == .data || frame.kind == .end else {
      throw ControlStreamSessionError.invalidTransition
    }
    return try lock.withLock {
      guard var state = streams[frame.streamID], !state.terminal else {
        throw ControlStreamSessionError.unknownStream
      }
      guard frame.protocolRevision == state.protocolRevision else {
        throw ControlStreamSessionError.invalidTransition
      }
      guard !state.cancelled else {
        throw ControlStreamSessionError.invalidTransition
      }
      guard frame.sequence == state.lastClientSequence + 1 else {
        throw ControlStreamSessionError.invalidSequence
      }
      state.lastClientSequence = frame.sequence
      if frame.kind == .cancel {
        state.cancelled = true
      } else if frame.kind == .data {
        guard state.request.source == .exec || state.request.source == .attach,
          !state.inputClosed, state.availableInputCredit > 0
        else {
          throw ControlStreamSessionError.creditExhausted
        }
        state.availableInputCredit -= 1
      } else if frame.kind == .end {
        guard state.request.source == .exec || state.request.source == .attach,
          !state.inputClosed
        else { throw ControlStreamSessionError.invalidTransition }
        state.inputClosed = true
      } else {
        let increment = frame.credit!
        guard state.availableCredit <= ControlPlaneContract.maximumStreamCredit - increment else {
          throw ControlStreamSessionError.creditOverflow
        }
        if let cursor = frame.cursor {
          guard cursor == state.lastDeliveredCursor else {
            throw ControlStreamSessionError.cursorMismatch
          }
          state.lastAcknowledgedCursor = cursor
        }
        state.availableCredit += increment
      }
      let snapshot = Self.snapshot(frame.streamID, state)
      streams[frame.streamID] = state
      return snapshot
    }
  }

  public func receiveCancellation(
    _ frame: StreamFrame,
    expectedIncarnation: UInt64,
    terminalImmediately: Bool
  ) throws -> StreamFrame? {
    try ControlStreamFrameContract.validate(frame, direction: .clientToServer)
    guard frame.kind == .cancel else { throw ControlStreamSessionError.invalidTransition }
    return try lock.withLock {
      guard var state = streams[frame.streamID] else { return nil }
      guard state.incarnation == expectedIncarnation else { return nil }
      guard frame.protocolRevision == state.protocolRevision else {
        throw ControlStreamSessionError.invalidTransition
      }
      guard !state.terminal, !state.cancelled,
        frame.sequence == state.lastClientSequence + 1
      else { throw ControlStreamSessionError.invalidSequence }
      state.lastClientSequence = frame.sequence
      state.cancelled = true
      guard terminalImmediately else {
        streams[frame.streamID] = state
        return nil
      }
      state.terminal = true
      let terminal = StreamFrame(
        protocolRevision: state.protocolRevision,
        streamID: frame.streamID,
        sequence: state.lastServerSequence + 1,
        kind: .end
      )
      try ControlStreamFrameContract.validate(terminal, direction: .serverToClient)
      streams.removeValue(forKey: frame.streamID)
      return terminal
    }
  }

  public func makeServerFrame(
    streamID: String,
    expectedIncarnation: UInt64? = nil,
    kind: StreamFrameKind,
    cursor: String? = nil,
    payload: ControlPlaneJSONValue? = nil,
    error: SanitizedError? = nil,
    credit: Int? = nil
  ) throws -> StreamFrame {
    try lock.withLock {
      guard var state = streams[streamID], !state.terminal else {
        throw ControlStreamSessionError.unknownStream
      }
      if let expectedIncarnation, state.incarnation != expectedIncarnation {
        throw ControlStreamSessionError.unknownStream
      }
      guard kind != .cancel else {
        throw ControlStreamSessionError.invalidTransition
      }
      if kind == .ack {
        guard state.availableInputCredit
          <= ControlPlaneContract.maximumInteractiveStreamInputCredit - (credit ?? 0)
        else { throw ControlStreamSessionError.creditOverflow }
        state.availableInputCredit += credit ?? 0
      }
      if kind == .data {
        guard state.availableCredit > 0 else {
          throw ControlStreamSessionError.creditExhausted
        }
        state.availableCredit -= 1
      }
      let next = state.lastServerSequence + 1
      let frame = StreamFrame(
        protocolRevision: state.protocolRevision,
        streamID: streamID,
        sequence: next,
        cursor: cursor,
        kind: kind,
        credit: credit,
        payload: payload,
        error: error
      )
      try ControlStreamFrameContract.validate(frame, direction: .serverToClient)
      state.lastServerSequence = next
      if kind == .data { state.lastDeliveredCursor = cursor }
      if kind == .end || kind == .error || kind == .gap { state.terminal = true }
      if state.terminal {
        streams.removeValue(forKey: streamID)
      } else {
        streams[streamID] = state
      }
      return frame
    }
  }

  public func snapshot(streamID: String) throws -> ControlStreamSnapshot {
    try lock.withLock {
      guard let state = streams[streamID] else { throw ControlStreamSessionError.unknownStream }
      return Self.snapshot(streamID, state)
    }
  }

  public func incarnation(streamID: String) throws -> UInt64 {
    try lock.withLock {
      guard let state = streams[streamID] else { throw ControlStreamSessionError.unknownStream }
      return state.incarnation
    }
  }

  public func cancelAll() -> [ControlStreamSnapshot] {
    lock.withLock {
      let cancelled: [ControlStreamSnapshot] = streams.keys.sorted().compactMap { streamID in
        guard var state = streams[streamID], !state.terminal else { return nil }
        state.cancelled = true
        state.terminal = true
        return Self.snapshot(streamID, state)
      }
      streams.removeAll(keepingCapacity: false)
      return cancelled
    }
  }

  private static func snapshot(_ streamID: String, _ state: State) -> ControlStreamSnapshot {
    ControlStreamSnapshot(
      streamID: streamID,
      source: state.request.source,
      target: state.request.target,
      availableCredit: state.availableCredit,
      lastClientSequence: state.lastClientSequence,
      lastServerSequence: state.lastServerSequence,
      lastDeliveredCursor: state.lastDeliveredCursor,
      lastAcknowledgedCursor: state.lastAcknowledgedCursor,
      isCancelled: state.cancelled,
      isTerminal: state.terminal
    )
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
