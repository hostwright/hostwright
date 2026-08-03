import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity

final class ControlStreamConnectionContext: @unchecked Sendable {
  private struct StreamKey: Hashable {
    let streamID: String
    let incarnation: UInt64
  }

  private let descriptor: Int32
  private let state = ControlStreamSessionState()
  private let writerLock = NSLock()
  private let producerLock = NSLock()
  private let terminalSignal = DispatchSemaphore(value: 0)
  private let frameWriter: ControlFrameWriteOperation
  private let validateSession: @Sendable () throws -> Void
  private let globalBudget: ControlStreamGlobalBudget
  private let contextID = UUID().uuidString.lowercased()
  private var producers: [StreamKey: ControlStreamProducerHandle] = [:]
  private var budgetKeys: [StreamKey: String] = [:]
  private var authorizationChecks: [StreamKey: @Sendable () throws -> Void] = [:]
  private var connectionTerminated = false

  init(
    descriptor: Int32,
    globalBudget: ControlStreamGlobalBudget,
    frameWriter: @escaping ControlFrameWriteOperation = defaultControlFrameWrite,
    validateSession: @escaping @Sendable () throws -> Void
  ) {
    self.descriptor = descriptor
    self.globalBudget = globalBudget
    self.frameWriter = frameWriter
    self.validateSession = validateSession
  }

  func open(
    frame: StreamFrame,
    peer: AuthenticatedControlPeer,
    authorizer: ControlStreamAuthorizer,
    cursorValidator: ControlStreamCursorValidator,
    reauthorizer: @escaping ControlStreamReauthorizer,
    opener: ControlStreamOpener,
    now: Date
  ) throws {
    try validateSession()
    guard producerLock.withLock({ !connectionTerminated }) else {
      throw PersistentControlServerError.invalidRequest
    }
    let request: ControlStreamOpenRequest
    do {
      request = try state.open(frame)
    } catch ControlStreamSessionError.streamLimit {
      try write(StreamFrame(
        streamID: frame.streamID,
        sequence: 1,
        kind: .error,
        error: SanitizedError(
          code: "streamLimit",
          message: "The connection has reached its active stream limit."
        )
      ))
      return
    }
    let incarnation = try state.incarnation(streamID: frame.streamID)
    let streamKey = StreamKey(streamID: frame.streamID, incarnation: incarnation)
    let budgetKey = "\(contextID):\(frame.streamID):\(incarnation)"
    do {
      try globalBudget.acquire(key: budgetKey, subjectID: peer.binding.subject.identifier)
      producerLock.withLock { budgetKeys[streamKey] = budgetKey }
    } catch {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "streamGlobalLimit",
          message: "The daemon stream budget is exhausted."
        )
      )
      return
    }
    do {
      try cursorValidator(peer, request, frame.cursor)
    } catch {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "invalidStreamCursor",
          message: "The stream cursor is invalid for the authenticated subject and request."
        )
      )
      return
    }
    let authorization: ControlStreamAuthorization
    do {
      authorization = try authorizer(peer, frame.streamID, request, now)
    } catch ControlStreamAuthorizationError.admissionDenied {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "streamAdmissionDenied",
          message: "Admission policy denied the requested stream operation."
        )
      )
      return
    } catch ControlStreamAuthorizationError.idempotencyConflict {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "idempotencyConflict",
          message: "The stream mutation identity conflicts with durable prior evidence."
        )
      )
      return
    } catch ControlStreamAuthorizationError.auditUnavailable {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "auditUnavailable",
          message: "Required tamper-evident audit persistence is unavailable."
        )
      )
      return
    } catch ControlStreamAuthorizationError.invalidRequest {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "invalidStreamRequest",
          message: "The source-specific stream request is invalid."
        )
      )
      return
    } catch {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "streamAuthorizationFailed",
          message: "The stream authorization pipeline failed safely."
        )
      )
      return
    }
    try authorization.decision.validate()
    guard authorization.decision.effect == .allow else {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "streamAuthorizationDenied",
          message: "The authenticated subject is not authorized for this stream."
        )
      )
      return
    }
    let effectiveRequest = authorization.effectiveRequest ?? request
    _ = try allocateAndWrite {
      try state.makeServerFrame(
        streamID: frame.streamID,
        kind: .open,
        payload: try ControlStreamFrameContract.value(ControlStreamAcceptance(
          source: effectiveRequest.source,
          resumed: frame.cursor != nil,
          heartbeatMilliseconds: effectiveRequest.heartbeatMilliseconds,
          inputCredit: effectiveRequest.source == .exec || effectiveRequest.source == .attach
            ? ControlPlaneContract.maximumInteractiveStreamInputCredit : 0,
          operationRef: authorization.operationReference,
          auditHealth: authorization.auditHealthDegraded ? .degraded : .healthy
        ))
      )
    }
    producerLock.withLock {
      authorizationChecks[streamKey] = {
        let decision = try reauthorizer(peer, effectiveRequest, Date())
        try decision.validate()
        guard decision.effect == .allow else { throw ControlStreamAuthorizationError.admissionDenied }
      }
    }

    if !authorization.shouldStartProducer {
      _ = emit(
        .gap(cursor: nil, payload: ControlStreamGap(reason: "execution.not-replayable")),
        streamID: frame.streamID,
        incarnation: incarnation
      )
      return
    }

    do {
      let streamID = frame.streamID
      let handle = try opener(peer, effectiveRequest, frame.cursor) { [weak self] emission in
        self?.emit(emission, streamID: streamID, incarnation: incarnation) ?? .terminated
      }
      producerLock.withLock {
        if connectionTerminated {
          handle.cancel()
        } else if (try? state.snapshot(streamID: streamID).isTerminal) == false {
          if budgetKeys[streamKey] != nil { producers[streamKey] = handle }
          else { handle.cancel() }
        } else {
          handle.cancel()
        }
      }
    } catch {
      try writeTerminalFailure(
        streamID: frame.streamID,
        expectedIncarnation: incarnation,
        error: SanitizedError(
          code: "streamSourceUnavailable",
          message: "The requested stream source is unavailable."
        )
      )
    }
  }

  func receiveControl(_ frame: StreamFrame) throws {
    try validateSession()
    if frame.kind == .cancel {
      guard let incarnation = try? state.incarnation(streamID: frame.streamID) else { return }
      let streamKey = StreamKey(streamID: frame.streamID, incarnation: incarnation)
      let authorizationCheck = producerLock.withLock { authorizationChecks[streamKey] }
      try authorizationCheck?()
      let handle = producerLock.withLock { producers[streamKey] }
      let terminalImmediately = handle?.cancellationMode != .deferredUntilProducerTerminal
      let terminal = try withWriterDeadline { deadline -> StreamFrame? in
        let terminal = try state.receiveCancellation(
          frame,
          expectedIncarnation: incarnation,
          terminalImmediately: terminalImmediately
        )
        if let terminal { try writeUnlocked(terminal, deadline: deadline) }
        return terminal
      }
      handle?.cancel()
      if terminal != nil {
        removeProducer(streamID: frame.streamID, incarnation: incarnation, cancel: false)
        terminalSignal.signal()
      }
      return
    }
    let incarnation: UInt64
    do {
      incarnation = try state.incarnation(streamID: frame.streamID)
    } catch ControlStreamSessionError.unknownStream where frame.kind == .cancel {
      return
    }
    let streamKey = StreamKey(streamID: frame.streamID, incarnation: incarnation)
    let authorizationCheck = producerLock.withLock { authorizationChecks[streamKey] }
    try authorizationCheck?()
    let snapshot = try state.receiveClientControl(frame)
    let handle = producerLock.withLock { producers[streamKey] }
    if frame.kind == .ack {
      handle?.addCredit(frame.credit!)
    } else if frame.kind == .data {
      guard let payload = frame.payload, handle?.sendInput(payload, onConsumed: { [weak self] in
        self?.acknowledgeConsumedInput(streamID: frame.streamID, incarnation: incarnation)
      }) == true else {
        try writeTerminalFailure(
          streamID: frame.streamID,
          expectedIncarnation: incarnation,
          error: SanitizedError(code: "streamInputRejected", message: "Stream input was rejected safely."))
        return
      }
    } else if frame.kind == .end {
      handle?.finishInput()
    }
    _ = snapshot
  }

  func writeResponse(
    _ response: ControlResponseEnvelope,
    deadline: ControlTransportDeadline
  ) throws {
    try validateSession()
    let data = try ControlPlaneCanonicalJSON.encode(response)
    guard data.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
      throw PersistentControlServerError.responseTooLarge
    }
    try withWriterDeadline(cappedBy: deadline) {
      try frameWriter(
        data,
        .response,
        descriptor,
        $0
      )
    }
  }

  func drainAfterInputHalfClose(timeoutMilliseconds: Int = 5_000) {
    let end = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
    while state.activeStreamCount > 0 {
      if terminalSignal.wait(timeout: end) == .timedOut { break }
    }
    cancelAll()
  }

  func cancelAll() {
    let handles = producerLock.withLock { () -> [ControlStreamProducerHandle] in
      connectionTerminated = true
      let values = Array(producers.values)
      producers.removeAll()
      let keys = Array(budgetKeys.values)
      budgetKeys.removeAll()
      authorizationChecks.removeAll()
      keys.forEach { globalBudget.release(key: $0) }
      return values
    }
    _ = state.cancelAll()
    handles.forEach { $0.cancel() }
    _ = shutdown(descriptor, SHUT_RDWR)
    terminalSignal.signal()
  }

  private func emit(
    _ emission: ControlStreamEmission,
    streamID: String,
    incarnation: UInt64
  ) -> ControlStreamEmissionDisposition {
    do {
      try validateSession()
      let streamKey = StreamKey(streamID: streamID, incarnation: incarnation)
      let authorizationCheck = producerLock.withLock { authorizationChecks[streamKey] }
      try authorizationCheck?()
      let frame: StreamFrame
      do {
        frame = try allocateAndWrite {
          switch emission {
          case .data(let cursor, let payload):
            return try state.makeServerFrame(
              streamID: streamID, expectedIncarnation: incarnation,
              kind: .data, cursor: cursor, payload: payload)
          case .heartbeat:
            return try state.makeServerFrame(
              streamID: streamID, expectedIncarnation: incarnation, kind: .heartbeat)
          case .gap(let cursor, let payload):
            return try state.makeServerFrame(
              streamID: streamID, expectedIncarnation: incarnation, kind: .gap,
              cursor: cursor, payload: try ControlStreamFrameContract.value(payload))
          case .end(let cursor):
            return try state.makeServerFrame(
              streamID: streamID, expectedIncarnation: incarnation, kind: .end, cursor: cursor)
          case .failure(let error):
            return try state.makeServerFrame(
              streamID: streamID, expectedIncarnation: incarnation, kind: .error, error: error)
          }
        }
      } catch ControlStreamSessionError.creditExhausted {
        return .creditExhausted
      }
      if frame.kind == .gap || frame.kind == .end || frame.kind == .error {
        removeProducer(streamID: streamID, incarnation: incarnation, cancel: false)
        terminalSignal.signal()
      }
      return .accepted
    } catch ControlStreamSessionError.unknownStream {
      return .terminated
    } catch ControlStreamAuthorizationError.admissionDenied {
      do {
        try writeTerminalFailure(
          streamID: streamID,
          expectedIncarnation: incarnation,
          error: SanitizedError(
            code: "streamAuthorizationRevoked",
            message: "Stream authorization was revoked."
          )
        )
      } catch { cancelAll() }
      return .terminated
    } catch {
      cancelAll()
      terminalSignal.signal()
      return .terminated
    }
  }

  private func acknowledgeConsumedInput(streamID: String, incarnation: UInt64) {
    do {
      try validateSession()
      let streamKey = StreamKey(streamID: streamID, incarnation: incarnation)
      let authorizationCheck = producerLock.withLock { authorizationChecks[streamKey] }
      try authorizationCheck?()
      _ = try allocateAndWrite {
        try state.makeServerFrame(
          streamID: streamID,
          expectedIncarnation: incarnation,
          kind: .ack,
          credit: 1
        )
      }
    } catch ControlStreamSessionError.unknownStream {
      return
    } catch {
      cancelAll()
    }
  }

  private func writeTerminalFailure(
    streamID: String,
    expectedIncarnation: UInt64? = nil,
    error: SanitizedError
  ) throws {
    _ = try allocateAndWrite {
      try state.makeServerFrame(
        streamID: streamID, expectedIncarnation: expectedIncarnation,
        kind: .error, error: error)
    }
    removeProducer(streamID: streamID, incarnation: expectedIncarnation, cancel: true)
    terminalSignal.signal()
  }

  private func write(_ frame: StreamFrame) throws {
    try withWriterDeadline { deadline in
      try writeUnlocked(frame, deadline: deadline)
    }
  }

  private func allocateAndWrite(
    _ allocation: () throws -> StreamFrame
  ) throws -> StreamFrame {
    try withWriterDeadline { deadline in
      let frame = try allocation()
      try writeUnlocked(frame, deadline: deadline)
      return frame
    }
  }

  private func writeUnlocked(
    _ frame: StreamFrame,
    deadline: ControlTransportDeadline? = nil
  ) throws {
    try validateSession()
    try ControlStreamFrameContract.validate(frame, direction: .serverToClient)
    let data = try ControlPlaneCanonicalJSON.encode(frame)
    guard data.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
      throw PersistentControlServerError.responseTooLarge
    }
    let deadline = try deadline ?? ControlTransportDeadline(
      timeoutMilliseconds: ControlPlaneContract.streamWriteDeadlineMilliseconds)
    try frameWriter(
      data,
      .frame,
      descriptor,
      deadline
    )
  }

  private func withWriterDeadline<T>(
    cappedBy existingDeadline: ControlTransportDeadline? = nil,
    _ body: (ControlTransportDeadline) throws -> T
  ) throws -> T {
    let deadline = try existingDeadline?.capped(
      toMilliseconds: ControlPlaneContract.streamWriteDeadlineMilliseconds
    ) ?? ControlTransportDeadline(
      timeoutMilliseconds: ControlPlaneContract.streamWriteDeadlineMilliseconds)
    while !writerLock.try() {
      try deadline.assertActive()
      Darwin.usleep(1_000)
    }
    defer { writerLock.unlock() }
    try deadline.assertActive()
    return try body(deadline)
  }

  private func removeProducer(streamID: String, incarnation: UInt64?, cancel: Bool) {
    let result: (ControlStreamProducerHandle?, String?) = producerLock.withLock {
      guard let incarnation else {
        return (nil as ControlStreamProducerHandle?, nil as String?)
      }
      let streamKey = StreamKey(streamID: streamID, incarnation: incarnation)
      authorizationChecks.removeValue(forKey: streamKey)
      return (
        producers.removeValue(forKey: streamKey),
        budgetKeys.removeValue(forKey: streamKey)
      )
    }
    let (handle, budgetKey) = result
    if let budgetKey { globalBudget.release(key: budgetKey) }
    if cancel { handle?.cancel() }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
