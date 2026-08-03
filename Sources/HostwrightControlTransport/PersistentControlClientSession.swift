import Darwin
import Foundation
import HostwrightControlPlane

public final class PersistentControlClientSession: @unchecked Sendable {
  private struct PendingStreamOpen {
    let source: ControlStreamSource
    let heartbeatMilliseconds: Int
    let resumed: Bool
  }
  private let descriptor: Int32
  private let condition = NSCondition()
  private let writerLock = NSLock()
  private let readerQueue = DispatchQueue(label: "dev.hostwright.control.client-reader")
  private let frameWriter: ControlFrameWriteOperation
  private var responses: [String: ControlResponseEnvelope] = [:]
  private var waitingRequestIDs: Set<String> = []
  private var abandonedRequestDeadlines: [String: Date] = [:]
  private var streamFrames: [String: [StreamFrame]] = [:]
  private var clientSequences: [String: UInt64] = [:]
  private var serverSequences: [String: UInt64] = [:]
  private var inputCredits: [String: Int] = [:]
  private var outputCredits: [String: Int] = [:]
  private var inputClosedStreams: Set<String> = []
  private var cancelledStreams: Set<String> = []
  private var terminalReceivedStreams: Set<String> = []
  private var acceptedStreamSources: [String: ControlStreamSource] = [:]
  private var pendingStreamOpens: [String: PendingStreamOpen] = [:]
  private var bufferedStreamFrameCount = 0
  private var closed = false
  private var writeHalfClosed = false

  init(
    descriptor: Int32,
    frameWriter: @escaping ControlFrameWriteOperation = defaultControlFrameWrite
  ) {
    self.descriptor = descriptor
    self.frameWriter = frameWriter
  }

  deinit { close() }

  func start() {
    readerQueue.async { [weak self] in self?.readLoop() }
  }

  public func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope {
    try request.validate()
    guard request.protocolRevision == .current, let timeout = request.timeoutMilliseconds else {
      throw PersistentControlClientError.invalidResponse
    }
    try condition.withLock {
      guard !closed, !writeHalfClosed else { throw PersistentControlClientError.connectionClosed }
      discardExpiredAbandonedRequests(at: Date())
      guard waitingRequestIDs.count + abandonedRequestDeadlines.count
        < ControlPlaneContract.maximumOutstandingUnary
      else {
        throw PersistentControlClientError.concurrencyLimit
      }
      guard abandonedRequestDeadlines[request.requestID] == nil,
        waitingRequestIDs.insert(request.requestID).inserted
      else {
        throw PersistentControlClientError.invalidResponse
      }
    }
    do {
      let deadline = try ControlTransportDeadline(timeoutMilliseconds: timeout)
      do {
        try write(
          try ControlPlaneCanonicalJSON.encode(request),
          kind: .request,
          deadline: deadline
        )
      } catch {
        close()
        throw error
      }
      return try waitForResponse(requestID: request.requestID, deadline: deadline)
    } catch {
      condition.withLock {
        waitingRequestIDs.remove(request.requestID)
        responses.removeValue(forKey: request.requestID)
        if error as? PersistentControlClientError == .deadlineExceeded {
          rememberAbandonedRequest(request.requestID)
        }
      }
      throw error
    }
  }

  public func openStream(
    streamID: String,
    request: ControlStreamOpenRequest,
    cursor: String? = nil,
    initialCredit: Int = 16
  ) throws {
    try request.validate()
    let payload = try ControlStreamFrameContract.value(request)
    let frame = StreamFrame(
      streamID: streamID,
      sequence: 1,
      cursor: cursor,
      kind: .open,
      credit: initialCredit,
      payload: payload
    )
    try ControlStreamFrameContract.validate(frame, direction: .clientToServer)
    let deadline = try ControlTransportDeadline(
      timeoutMilliseconds: ControlPlaneContract.streamWriteDeadlineMilliseconds)
    try withWriterDeadline(deadline) {
      var writeStarted = false
      var didRegister = false
      do {
        try condition.withLock {
          guard !closed, !writeHalfClosed else {
            throw PersistentControlClientError.connectionClosed
          }
          guard clientSequences.count < ControlPlaneContract.maximumStreams else {
            throw PersistentControlClientError.streamLimit
          }
          guard clientSequences[streamID] == nil else {
            throw PersistentControlClientError.invalidResponse
          }
          clientSequences[streamID] = 1
          serverSequences[streamID] = 0
          streamFrames[streamID] = []
          inputCredits[streamID] = 0
          outputCredits[streamID] = initialCredit
          pendingStreamOpens[streamID] = PendingStreamOpen(
            source: request.source,
            heartbeatMilliseconds: request.heartbeatMilliseconds,
            resumed: cursor != nil
          )
          didRegister = true
        }
        writeStarted = true
        try frameWriter(
          try ControlPlaneCanonicalJSON.encode(frame),
          .request,
          descriptor,
          deadline
        )
      } catch {
        let shouldClose = condition.withLock { () -> Bool in
          if didRegister { removeStreamState(streamID: streamID) }
          if writeStarted, !closed {
            closed = true
            condition.broadcast()
            return true
          }
          return false
        }
        if shouldClose { _ = shutdown(descriptor, SHUT_RDWR) }
        throw error
      }
    }
  }

  public func acknowledge(streamID: String, credit: Int, cursor: String? = nil) throws {
    try sendControl(streamID: streamID, kind: .ack, credit: credit, cursor: cursor)
  }

  public func cancel(streamID: String) throws {
    try sendControl(streamID: streamID, kind: .cancel, credit: nil, cursor: nil)
  }

  public func sendStreamInput(streamID: String, payload: ControlPlaneJSONValue) throws {
    try sendControl(
      streamID: streamID,
      kind: .data,
      credit: nil,
      cursor: nil,
      payload: payload,
      consumesInputCredit: true
    )
  }

  public func finishStreamInput(streamID: String) throws {
    try sendControl(
      streamID: streamID,
      kind: .end,
      credit: nil,
      cursor: nil,
      payload: nil,
      consumesInputCredit: false
    )
  }

  public func nextFrame(
    streamID: String,
    timeoutMilliseconds: Int = ControlPlaneContract.maximumUnaryDeadlineMilliseconds
  ) throws -> StreamFrame {
    guard timeoutMilliseconds > 0,
      timeoutMilliseconds <= ControlPlaneContract.maximumUnaryDeadlineMilliseconds
    else { throw PersistentControlClientError.deadlineExceeded }
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    return try condition.withLock {
      while true {
        if var queue = streamFrames[streamID], !queue.isEmpty {
          let frame = queue.removeFirst()
          bufferedStreamFrameCount -= 1
          streamFrames[streamID] = queue
          if frame.kind == .gap || frame.kind == .end || frame.kind == .error {
            removeStreamState(streamID: streamID)
          }
          return frame
        }
        guard !closed else { throw PersistentControlClientError.connectionClosed }
        guard clientSequences[streamID] != nil else {
          throw PersistentControlClientError.invalidResponse
        }
        guard condition.wait(until: deadline) else {
          throw PersistentControlClientError.deadlineExceeded
        }
      }
    }
  }

  public func halfCloseWrites() throws {
    let deadline = try ControlTransportDeadline(
      timeoutMilliseconds: ControlPlaneContract.streamWriteDeadlineMilliseconds)
    try withWriterDeadline(deadline) {
      try condition.withLock {
        guard !closed, !writeHalfClosed else {
          throw PersistentControlClientError.connectionClosed
        }
        guard shutdown(descriptor, SHUT_WR) == 0 else {
          throw PersistentControlClientError.connectionClosed
        }
        writeHalfClosed = true
      }
    }
  }

  public func close() {
    let shouldClose = condition.withLock { () -> Bool in
      if closed { return false }
      closed = true
      condition.broadcast()
      return true
    }
    if shouldClose { _ = shutdown(descriptor, SHUT_RDWR) }
  }

  private func sendControl(
    streamID: String,
    kind: StreamFrameKind,
    credit: Int?,
    cursor: String?,
    payload: ControlPlaneJSONValue? = nil,
    consumesInputCredit: Bool = false
  ) throws {
    var writeStarted = false
    let deadline = try ControlTransportDeadline(
      timeoutMilliseconds: ControlPlaneContract.streamWriteDeadlineMilliseconds)
    do {
      // A control frame's sequence reservation and write are one ordered operation.
      // Otherwise two callers can reserve 2 and 3 but have 3 reach the socket first.
      try withWriterDeadline(deadline) {
        let frame = try condition.withLock { () throws -> StreamFrame in
          guard !closed, !writeHalfClosed else {
            throw PersistentControlClientError.connectionClosed
          }
          guard let current = clientSequences[streamID], current < UInt64.max else {
            throw PersistentControlClientError.invalidResponse
          }
          if kind == .cancel {
            guard cancelledStreams.insert(streamID).inserted else {
              throw PersistentControlClientError.invalidResponse
            }
          } else {
            guard !cancelledStreams.contains(streamID) else {
              throw PersistentControlClientError.invalidResponse
            }
          }
          if consumesInputCredit {
            guard Self.isInteractive(acceptedStreamSources[streamID]),
              inputClosedStreams.contains(streamID) == false,
              let available = inputCredits[streamID], available > 0
            else { throw PersistentControlClientError.invalidResponse }
          } else if kind == .end {
            guard Self.isInteractive(acceptedStreamSources[streamID]),
              inputClosedStreams.contains(streamID) == false
            else {
              throw PersistentControlClientError.invalidResponse
            }
          }
          let reserved = current + 1
          let frame = StreamFrame(
            streamID: streamID,
            sequence: reserved,
            cursor: cursor,
            kind: kind,
            credit: credit,
            payload: payload
          )
          try ControlStreamFrameContract.validate(frame, direction: .clientToServer)
          if kind == .ack, let credit {
            let currentOutputCredit = outputCredits[streamID] ?? 0
            guard currentOutputCredit <= ControlPlaneContract.maximumStreamCredit - credit else {
              throw PersistentControlClientError.invalidResponse
            }
            outputCredits[streamID] = currentOutputCredit + credit
          }
          clientSequences[streamID] = reserved
          if consumesInputCredit {
            inputCredits[streamID]! -= 1
          } else if kind == .end {
            inputClosedStreams.insert(streamID)
          }
          return frame
        }
        let data = try ControlPlaneCanonicalJSON.encode(frame)
        writeStarted = true
        try frameWriter(
          data,
          .request,
          descriptor,
          deadline
        )
      }
    } catch {
      if writeStarted { close() }
      throw error
    }
  }

  private func write(
    _ data: Data,
    kind: ControlPayloadKind,
    deadline: ControlTransportDeadline
  ) throws {
    try withWriterDeadline(deadline) {
      try frameWriter(data, kind, descriptor, deadline)
    }
  }

  private func withWriterDeadline<T>(
    _ deadline: ControlTransportDeadline,
    _ body: () throws -> T
  ) throws -> T {
    while !writerLock.try() {
      try deadline.assertActive()
      Darwin.usleep(1_000)
    }
    defer { writerLock.unlock() }
    try deadline.assertActive()
    return try body()
  }

  private func waitForResponse(
    requestID: String,
    deadline: ControlTransportDeadline
  ) throws -> ControlResponseEnvelope {
    return try condition.withLock {
      while true {
        if let response = responses.removeValue(forKey: requestID) {
          waitingRequestIDs.remove(requestID)
          return response
        }
        guard !closed else { throw PersistentControlClientError.connectionClosed }
        let remaining: TimeInterval
        do { remaining = try deadline.remainingTimeInterval() }
        catch ControlTransportError.deadlineExceeded {
          throw PersistentControlClientError.deadlineExceeded
        }
        guard condition.wait(until: Date().addingTimeInterval(remaining)) else {
          throw PersistentControlClientError.deadlineExceeded
        }
      }
    }
  }

  private func readLoop() {
    defer { _ = Darwin.close(descriptor) }
    do {
      while true {
        try ControlFrameCodec.waitForFrame(descriptor: descriptor)
        let data = try ControlFrameCodec.read(
          kind: .frame,
          descriptor: descriptor,
          deadline: try ControlTransportDeadline(
            timeoutMilliseconds: ControlPlaneContract.maximumAuthenticationHandshakeMilliseconds)
        )
        if let response = try? Self.decodeResponse(data) {
          try condition.withLock {
            discardExpiredAbandonedRequests(at: Date())
            if abandonedRequestDeadlines.removeValue(forKey: response.requestID) != nil {
              return
            }
            guard waitingRequestIDs.contains(response.requestID),
              responses[response.requestID] == nil
            else { throw PersistentControlClientError.invalidResponse }
            responses[response.requestID] = response
            condition.broadcast()
          }
          continue
        }
        let frame = try ControlStreamFrameContract.decode(data)
        try ControlStreamFrameContract.validate(frame, direction: .serverToClient)
        try condition.withLock {
          guard let previous = serverSequences[frame.streamID],
            frame.sequence == previous + 1,
            var queue = streamFrames[frame.streamID],
            !terminalReceivedStreams.contains(frame.streamID),
            bufferedStreamFrameCount < ControlPlaneContract.maximumBufferedStreamFrames
          else { throw PersistentControlClientError.invalidResponse }
          if pendingStreamOpens[frame.streamID] != nil,
            frame.kind != .open && frame.kind != .error
          {
            throw PersistentControlClientError.invalidResponse
          }
          serverSequences[frame.streamID] = frame.sequence
          if frame.kind == .open {
            guard let expected = pendingStreamOpens.removeValue(forKey: frame.streamID),
              let payload = frame.payload
            else { throw PersistentControlClientError.invalidResponse }
            let acceptance = try ControlStreamFrameContract.decodeAcceptance(payload)
            guard acceptance.source == expected.source,
              acceptance.heartbeatMilliseconds == expected.heartbeatMilliseconds,
              acceptance.resumed == expected.resumed
            else { throw PersistentControlClientError.invalidResponse }
            acceptedStreamSources[frame.streamID] = acceptance.source
            inputCredits[frame.streamID] = acceptance.inputCredit
          } else if frame.kind == .data {
            guard let credit = outputCredits[frame.streamID], credit > 0 else {
              throw PersistentControlClientError.invalidResponse
            }
            outputCredits[frame.streamID] = credit - 1
          } else if frame.kind == .ack, let replenished = frame.credit {
            guard Self.isInteractive(acceptedStreamSources[frame.streamID]) else {
              throw PersistentControlClientError.invalidResponse
            }
            let current = inputCredits[frame.streamID] ?? 0
            guard current <= Self.maximumInputCredit - replenished else {
              throw PersistentControlClientError.invalidResponse
            }
            inputCredits[frame.streamID] = current + replenished
          }
          if frame.kind == .gap || frame.kind == .end || frame.kind == .error {
            terminalReceivedStreams.insert(frame.streamID)
          }
          queue.append(frame)
          bufferedStreamFrameCount += 1
          streamFrames[frame.streamID] = queue
          condition.broadcast()
        }
      }
    } catch {
      condition.withLock {
        closed = true
        condition.broadcast()
      }
      _ = shutdown(descriptor, SHUT_RDWR)
    }
  }

  private static func decodeResponse(_ data: Data) throws -> ControlResponseEnvelope {
    let response = try Phase09StrictDecoder.decode(
      ControlResponseEnvelope.self,
      from: data,
      allowedKeys: [
        "apiVersion", "protocolRevision", "requestID", "status", "reasonCode",
        "operationRef", "result", "error",
      ],
      requiredKeys: [
        "apiVersion", "protocolRevision", "requestID", "status", "reasonCode",
      ]
    )
    try response.validate()
    return response
  }

  private func rememberAbandonedRequest(_ requestID: String) {
    let now = Date()
    discardExpiredAbandonedRequests(at: now)
    abandonedRequestDeadlines[requestID] = now.addingTimeInterval(
      Double(ControlPlaneContract.maximumUnaryDeadlineMilliseconds) / 1_000)
  }

  private func discardExpiredAbandonedRequests(at date: Date) {
    abandonedRequestDeadlines = abandonedRequestDeadlines.filter { $0.value >= date }
  }

  private func removeStreamState(streamID: String) {
    clientSequences.removeValue(forKey: streamID)
    serverSequences.removeValue(forKey: streamID)
    inputCredits.removeValue(forKey: streamID)
    outputCredits.removeValue(forKey: streamID)
    inputClosedStreams.remove(streamID)
    cancelledStreams.remove(streamID)
    terminalReceivedStreams.remove(streamID)
    acceptedStreamSources.removeValue(forKey: streamID)
    pendingStreamOpens.removeValue(forKey: streamID)
    if let queued = streamFrames.removeValue(forKey: streamID) {
      bufferedStreamFrameCount -= queued.count
    }
  }

  private static func isInteractive(_ source: ControlStreamSource?) -> Bool {
    source == .exec || source == .attach
  }

  private static let maximumInputCredit = ControlPlaneContract.maximumInteractiveStreamInputCredit
}

private extension NSCondition {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
