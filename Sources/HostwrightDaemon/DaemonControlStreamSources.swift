import Foundation
import CryptoKit
import HostwrightCLI
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightControlTransport
import HostwrightObservability
import HostwrightRuntime
import HostwrightState

enum DaemonControlStreamSourceError: Error {
  case invalidFilter
  case unsupportedSource
}

protocol DaemonInteractiveStreamTask: Sendable {
  func start(
    beforeExternalExecution: @escaping @Sendable () throws -> Void,
    sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void,
    completion: @escaping ControlRuntimeStreamTask.Completion
  ) throws
  func cancel()
  func sendInput(_ data: Data, onConsumed: @escaping @Sendable () -> Void) -> Bool
  func finishInput()
  func resize(columns: UInt16, rows: UInt16) -> Bool
  func forward(signal: Int32) -> Bool
}

extension ControlRuntimeStreamTask: DaemonInteractiveStreamTask {}

final class DaemonControlStreamSourceFactory: @unchecked Sendable {
  private let store: SQLiteStateStore
  private let cursorCodec: ControlStreamCursorCodec
  private let manifestPath: String
  private let stateDatabasePath: String
  private let requestRepository: ControlRequestRepository
  private let auditRecorder: any ControlSecurityAuditRecording

  init(
    store: SQLiteStateStore,
    cursorCodec: ControlStreamCursorCodec,
    manifestPath: String,
    stateDatabasePath: String,
    auditRecorder: any ControlSecurityAuditRecording
  ) {
    self.store = store
    self.cursorCodec = cursorCodec
    self.manifestPath = manifestPath
    self.stateDatabasePath = stateDatabasePath
    self.requestRepository = ControlRequestRepository(store: store)
    self.auditRecorder = auditRecorder
  }

  func open(
    peer: AuthenticatedControlPeer,
    request: ControlStreamOpenRequest,
    cursor: String?,
    preStartAuthorization: @escaping @Sendable () throws -> Void,
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws -> ControlStreamProducerHandle {
    switch request.source {
    case .events, .traces, .state:
      guard request.target == nil else { throw DaemonControlStreamSourceError.invalidFilter }
    case .metrics:
      guard request.target == nil, request.filter == nil else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
    case .operation:
      guard let target = request.target, !target.isEmpty else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
    case .logs, .attach, .exec:
      break
    }
    let binding = try ControlStreamCursorBinding(
      subjectID: peer.binding.subject.identifier,
      source: request.source,
      target: request.target,
      filter: request.filter
    )
    let sourceCursor = try cursor.map { try cursorCodec.verify($0, expectedBinding: binding).sourceCursor }
    switch request.source {
    case .events, .state, .operation, .traces:
      let producer = try EventControlStreamProducer(
        store: store,
        cursorCodec: cursorCodec,
        binding: binding,
        request: request,
        sourceCursor: sourceCursor,
        sink: sink
      )
      producer.start()
      return producer.handle
    case .metrics:
      let producer = MetricsControlStreamProducer(
        store: store,
        cursorCodec: cursorCodec,
        binding: binding,
        sourceCursor: sourceCursor,
        sink: sink,
        heartbeatMilliseconds: request.heartbeatMilliseconds
      )
      producer.start()
      return producer.handle
    case .logs:
      let producer = try FiniteLogsControlStreamProducer(
        store: store,
        cursorCodec: cursorCodec,
        binding: binding,
        request: request,
        sourceCursor: sourceCursor,
        manifestPath: manifestPath,
        stateDatabasePath: stateDatabasePath,
        sink: sink
      )
      producer.start()
      return producer.handle
    case .attach, .exec:
      let producer = try InteractiveControlStreamProducer(
        cursorCodec: cursorCodec,
        binding: binding,
        request: request,
        sourceCursor: sourceCursor,
        manifestPath: manifestPath,
        stateDatabasePath: stateDatabasePath,
        requestRepository: requestRepository,
        auditRecorder: auditRecorder,
        subjectID: peer.binding.subject.identifier,
        preStartAuthorization: preStartAuthorization,
        sink: sink
      )
      producer.start()
      return producer.handle
    }
  }

  func validateCursor(
    peer: AuthenticatedControlPeer,
    request: ControlStreamOpenRequest,
    cursor: String?
  ) throws {
    guard let cursor else { return }
    let binding = try ControlStreamCursorBinding(
      subjectID: peer.binding.subject.identifier,
      source: request.source,
      target: request.target,
      filter: request.filter
    )
    _ = try cursorCodec.verify(cursor, expectedBinding: binding)
  }

  func validateRequest(_ request: ControlStreamOpenRequest) throws {
    try request.validate()
    switch request.source {
    case .events, .traces, .state:
      guard request.target == nil else { throw DaemonControlStreamSourceError.invalidFilter }
      _ = try EventControlStreamProducer.filter(request)
    case .operation:
      guard let target = request.target,
        target.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression)
          != nil
      else { throw DaemonControlStreamSourceError.invalidFilter }
      _ = try EventControlStreamProducer.filter(request)
    case .metrics:
      guard request.target == nil, request.filter == nil else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
    case .logs, .attach, .exec:
      guard let target = request.target else { throw DaemonControlStreamSourceError.invalidFilter }
      guard case .object(let fields)? = request.filter else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      let allowedKeys: Set<String>
      switch request.source {
      case .logs: allowedKeys = ["serviceName", "tail"]
      case .attach: allowedKeys = ["serviceName", "timeoutSeconds", "tty"]
      case .exec: allowedKeys = ["arguments", "serviceName", "timeoutSeconds", "tty"]
      default: throw DaemonControlStreamSourceError.invalidFilter
      }
      guard Set(fields.keys).isSubset(of: allowedKeys),
        case .string(let serviceName)? = fields["serviceName"],
        !serviceName.isEmpty, serviceName.utf8.count <= 128
      else { throw DaemonControlStreamSourceError.invalidFilter }
      if request.source == .exec {
        guard case .array(let arguments)? = fields["arguments"], !arguments.isEmpty,
          arguments.count <= 256,
          arguments.allSatisfy({
            if case .string(let value) = $0 { return !value.isEmpty && value.utf8.count <= 4_096 }
            return false
          })
        else { throw DaemonControlStreamSourceError.invalidFilter }
      } else if fields["arguments"] != nil {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      if let value = fields["timeoutSeconds"] {
        guard case .integer(let raw) = value, (1...86_400).contains(raw) else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
      }
      if let value = fields["tty"] {
        guard request.source != .logs, case .bool = value else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
      }
      if let value = fields["tail"] {
        guard request.source == .logs, case .integer(let raw) = value, (1...1_000).contains(raw)
        else { throw DaemonControlStreamSourceError.invalidFilter }
      }
      let ownership = try store.ownership.loadAll().filter {
        $0.resourceType == "container" && $0.resourceUUID == target
          && $0.serviceName == serviceName
      }
      guard ownership.count == 1 else { throw DaemonControlStreamSourceError.invalidFilter }
    }
  }
}

private final class EventControlStreamProducer: @unchecked Sendable {
  private let store: SQLiteStateStore
  private let cursorCodec: ControlStreamCursorCodec
  private let binding: ControlStreamCursorBinding
  private let request: ControlStreamOpenRequest
  private let sink: @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  private let condition = NSCondition()
  private let queue = DispatchQueue(label: "dev.hostwright.control.stream.events")
  private var rawCursor: String?
  private var cancelled = false

  init(
    store: SQLiteStateStore,
    cursorCodec: ControlStreamCursorCodec,
    binding: ControlStreamCursorBinding,
    request: ControlStreamOpenRequest,
    sourceCursor: String?,
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws {
    self.store = store
    self.cursorCodec = cursorCodec
    self.binding = binding
    self.request = request
    self.rawCursor = sourceCursor
    self.sink = sink
    _ = try Self.filter(request)
  }

  var handle: ControlStreamProducerHandle {
    ControlStreamProducerHandle(
      onCredit: { [self] _ in wake() },
      cancel: { [self] in cancel() }
    )
  }

  func start() { queue.async { [weak self] in self?.run() } }

  private func run() {
    do {
      let filter = try Self.filter(request)
      var lastHeartbeat = Date()
      while !isCancelled {
        let page = try store.events.streamPage(after: rawCursor, filter: filter, pageSize: 100)
        if page.status == .retentionGap {
          let earliest = try page.retentionGap?.earliestAvailableCursor.map {
            try cursorCodec.issue(binding: binding, sourceCursor: $0)
          }
          let latest = try page.retentionGap?.latestAvailableCursor.map {
            try cursorCodec.issue(binding: binding, sourceCursor: $0)
          }
          _ = sink(.gap(
            cursor: earliest,
            payload: ControlStreamGap(
              reason: "retention.compacted",
              earliestCursor: earliest,
              latestCursor: latest
            )
          ))
          return
        }
        for record in page.events where shouldDeliver(record) {
          let cursor = try cursorCodec.issue(binding: binding, sourceCursor: record.cursor)
          let payload = Self.eventPayload(record)
          while !isCancelled {
            switch sink(.data(cursor: cursor, payload: payload)) {
            case .accepted:
              break
            case .creditExhausted:
              waitForWake(milliseconds: request.heartbeatMilliseconds)
              guard sink(.heartbeat) != .terminated else { return }
              continue
            case .terminated:
              return
            }
            break
          }
        }
        rawCursor = page.nextCursor ?? rawCursor
        if page.moreAvailable { continue }
        if Date().timeIntervalSince(lastHeartbeat) * 1_000
          >= Double(request.heartbeatMilliseconds)
        {
          guard sink(.heartbeat) != .terminated else { return }
          lastHeartbeat = Date()
        }
        waitForWake(milliseconds: 250)
      }
    } catch {
      _ = sink(.failure(SanitizedError(
        code: "streamSourceFailed",
        message: "The durable stream source failed safely."
      )))
    }
  }

  private func shouldDeliver(_ record: HostwrightEventStreamRecord) -> Bool {
    switch request.source {
    case .operation:
      guard let target = request.target else { return false }
      guard target.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression)
        != nil,
        record.operationReferences.contains(target)
      else { return false }
      return ![.desiredChange, .policy, .garbageCollection, .operatorDecision]
        .contains(record.eventClass)
    case .traces:
      return record.event.type == HostwrightTraceContract.eventType
    case .state:
      return record.auditReference == nil
        && record.event.type != HostwrightTraceContract.eventType
        && [.state, .providerState, .health, .recovery].contains(record.eventClass)
    case .events:
      return true
    case .logs, .attach, .exec, .metrics:
      return false
    }
  }

  fileprivate static func filter(_ request: ControlStreamOpenRequest) throws
    -> HostwrightEventStreamFilter
  {
    var fields: [String: ControlPlaneJSONValue] = [:]
    if let filter = request.filter {
      guard case .object(let value) = filter,
        Set(value.keys).isSubset(of: ["projectID", "type", "serviceName", "severity"])
      else { throw DaemonControlStreamSourceError.invalidFilter }
      fields = value
    }
    func string(_ key: String) throws -> String? {
      guard let value = fields[key] else { return nil }
      guard case .string(let result) = value else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      return result
    }
    let severity: StateEventSeverity?
    if let raw = try string("severity") {
      guard let parsed = StateEventSeverity(rawValue: raw) else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      severity = parsed
    } else {
      severity = nil
    }
    let forcedType = request.source == .traces ? HostwrightTraceContract.eventType : nil
    let type = try forcedType ?? string("type")
    return HostwrightEventStreamFilter(
      projectID: try string("projectID"),
      type: type,
      serviceName: try string("serviceName"),
      severity: severity
    )
  }

  private static func eventPayload(_ record: HostwrightEventStreamRecord) -> ControlPlaneJSONValue {
    .object([
      "position": .integer(Int64(record.position)),
      "id": .string(record.event.id),
      "timestamp": .string(record.event.timestamp),
      "severity": .string(record.event.severity.rawValue),
      "type": .string(record.event.type),
      "source": .string(record.event.source),
      "projectID": record.event.projectID.map(ControlPlaneJSONValue.string) ?? .null,
      "serviceName": record.event.serviceName.map(ControlPlaneJSONValue.string) ?? .null,
      "message": .string(record.event.message),
      "payloadJSONRedacted": .string(record.event.payloadJSONRedacted),
      "eventReference": .string(record.eventReference),
      "operationReferences": .array(record.operationReferences.map(ControlPlaneJSONValue.string)),
    ])
  }

  private var isCancelled: Bool { condition.withLock { cancelled } }
  private func wake() { condition.withLock { condition.signal() } }
  private func cancel() { condition.withLock { cancelled = true; condition.broadcast() } }
  private func waitForWake(milliseconds: Int) {
    condition.withLock {
      if !cancelled {
        _ = condition.wait(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
      }
    }
  }
}

private final class MetricsControlStreamProducer: @unchecked Sendable {
  private let service: StateMetricsService
  private let cursorCodec: ControlStreamCursorCodec
  private let binding: ControlStreamCursorBinding
  private let sourceCursor: String?
  private let sink: @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  private let heartbeatMilliseconds: Int
  private let condition = NSCondition()
  private let queue = DispatchQueue(label: "dev.hostwright.control.stream.metrics")
  private var cancelled = false

  init(
    store: SQLiteStateStore,
    cursorCodec: ControlStreamCursorCodec,
    binding: ControlStreamCursorBinding,
    sourceCursor: String?,
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition,
    heartbeatMilliseconds: Int
  ) {
    service = StateMetricsService(store: store)
    self.cursorCodec = cursorCodec
    self.binding = binding
    self.sourceCursor = sourceCursor
    self.sink = sink
    self.heartbeatMilliseconds = heartbeatMilliseconds
  }

  var handle: ControlStreamProducerHandle {
    ControlStreamProducerHandle(
      onCredit: { [self] _ in wake() },
      cancel: { [self] in cancel() }
    )
  }

  func start() { queue.async { [weak self] in self?.run() } }

  private func run() {
    do {
      var previous = sourceCursor
      var firstSnapshot = true
      var lastHeartbeat = Date()
      while !isCancelled {
        let snapshot = try service.snapshot()
        if firstSnapshot, let sourceCursor, previous == sourceCursor,
          sourceCursor != snapshot.snapshotSHA256
        {
          let current = try cursorCodec.issue(
            binding: binding,
            sourceCursor: snapshot.snapshotSHA256
          )
          _ = sink(.gap(
            cursor: current,
            payload: ControlStreamGap(
              reason: "snapshot.not-replayable",
              earliestCursor: current,
              latestCursor: current
            )
          ))
          return
        }
        firstSnapshot = false
        if previous != snapshot.snapshotSHA256 {
          let cursor = try cursorCodec.issue(
            binding: binding,
            sourceCursor: snapshot.snapshotSHA256
          )
          let payload = try ControlStreamFrameContract.value(snapshot)
          while !isCancelled {
            let disposition = sink(.data(cursor: cursor, payload: payload))
            if disposition == .accepted { break }
            if disposition == .terminated { return }
            waitForWake(milliseconds: heartbeatMilliseconds)
            guard sink(.heartbeat) != .terminated else { return }
          }
          previous = snapshot.snapshotSHA256
        }
        if Date().timeIntervalSince(lastHeartbeat) * 1_000
          >= Double(heartbeatMilliseconds)
        {
          guard sink(.heartbeat) != .terminated else { return }
          lastHeartbeat = Date()
        }
        waitForWake(milliseconds: 1_000)
      }
    } catch {
      _ = sink(.failure(SanitizedError(
        code: "metricsStreamFailed",
        message: "The metrics stream failed safely."
      )))
    }
  }

  private var isCancelled: Bool { condition.withLock { cancelled } }
  private func wake() { condition.withLock { condition.signal() } }
  private func cancel() { condition.withLock { cancelled = true; condition.broadcast() } }
  private func waitForWake(milliseconds: Int) {
    condition.withLock {
      if !cancelled {
        _ = condition.wait(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
      }
    }
  }
}

private final class FiniteLogsControlStreamProducer: @unchecked Sendable {
  private let cursorCodec: ControlStreamCursorCodec
  private let binding: ControlStreamCursorBinding
  private let request: ControlStreamOpenRequest
  private let sourceCursor: String?
  private let manifestPath: String
  private let stateDatabasePath: String
  private let sink: @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  private let condition = NSCondition()
  private let queue = DispatchQueue(label: "dev.hostwright.control.stream.logs")
  private let tail: Int
  private let serviceName: String
  private var cancelled = false

  init(
    store: SQLiteStateStore,
    cursorCodec: ControlStreamCursorCodec,
    binding: ControlStreamCursorBinding,
    request: ControlStreamOpenRequest,
    sourceCursor: String?,
    manifestPath: String,
    stateDatabasePath: String,
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws {
    guard let target = request.target, !target.isEmpty else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    var tail = 100
    var serviceName: String?
    if let filter = request.filter {
      guard case .object(let fields) = filter,
        Set(fields.keys).isSubset(of: ["serviceName", "tail"])
      else { throw DaemonControlStreamSourceError.invalidFilter }
      if let value = fields["serviceName"] {
        guard case .string(let raw) = value, !raw.isEmpty, raw.utf8.count <= 128 else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        serviceName = raw
      }
      if let value = fields["tail"] {
        guard case .integer(let raw) = value, (1...1_000).contains(raw) else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        tail = Int(raw)
      }
    }
    guard let serviceName else { throw DaemonControlStreamSourceError.invalidFilter }
    let ownership = try store.ownership.loadAll().filter {
      $0.resourceType == "container" && $0.resourceUUID == target
        && $0.serviceName == serviceName
    }
    guard ownership.count == 1 else { throw DaemonControlStreamSourceError.invalidFilter }
    self.cursorCodec = cursorCodec
    self.binding = binding
    self.request = request
    self.sourceCursor = sourceCursor
    self.manifestPath = manifestPath
    self.stateDatabasePath = stateDatabasePath
    self.sink = sink
    self.tail = tail
    self.serviceName = serviceName
  }

  var handle: ControlStreamProducerHandle {
    ControlStreamProducerHandle(
      onCredit: { [self] _ in wake() },
      cancel: { [self] in cancel() }
    )
  }

  func start() { queue.async { [weak self] in self?.run() } }

  private func run() {
    let data: Data
    do {
      data = try ControlRuntimeLogSnapshotReader().read(
        manifestPath: manifestPath,
        stateDatabasePath: stateDatabasePath,
        serviceName: serviceName,
        expectedResourceUUID: request.target!,
        tail: tail
      )
    } catch {
      _ = sink(.failure(SanitizedError(
        code: "runtimeLogsUnavailable",
        message: "The bounded verified runtime log read did not complete."
      )))
      return
    }
    guard !isCancelled else { return }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let resume: (digest: String, offset: Int)?
    if let sourceCursor {
      let parts = sourceCursor.split(separator: ".", omittingEmptySubsequences: false)
      if parts.count == 3, parts[0] == "logs1", parts[1].count == 64,
        let offset = Int(parts[2]), offset >= 0, offset <= ControlRuntimeLogSnapshotReader.maximumBytes
      {
        resume = (String(parts[1]), offset)
      } else {
        resume = nil
      }
    } else { resume = nil }
    if sourceCursor != nil, resume == nil || resume!.digest != digest || resume!.offset > data.count {
      do {
        let raw = "logs1.\(digest).0"
        let current = try cursorCodec.issue(binding: binding, sourceCursor: raw)
        _ = sink(.gap(
          cursor: current,
          payload: ControlStreamGap(
            reason: "logs.not-replayable",
            earliestCursor: current,
            latestCursor: current
          )
        ))
      } catch {
        _ = sink(.failure(SanitizedError(
          code: "runtimeLogsCursorFailed",
          message: "The runtime log cursor could not be issued."
        )))
      }
      return
    }
    let initialOffset = resume?.offset ?? 0
    if initialOffset == data.count {
      let raw = "logs1.\(digest).\(data.count)"
      _ = sink(.end(cursor: try? cursorCodec.issue(binding: binding, sourceCursor: raw)))
      return
    }
    do {
      let chunkBytes = 48 * 1_024
      var offset = initialOffset
      var ordinal = Int64(initialOffset / chunkBytes)
      var finalCursor: String?
      var lastHeartbeat = Date()
      while offset < data.count, !isCancelled {
        let end = min(offset + chunkBytes, data.count)
        let chunk = data.subdata(in: offset..<end)
        let cursor = try cursorCodec.issue(
          binding: binding,
          sourceCursor: "logs1.\(digest).\(end)"
        )
        let payload: ControlPlaneJSONValue = .object([
          "ordinal": .integer(ordinal),
          "encoding": .string("base64"),
          "payload": .string(chunk.base64EncodedString()),
        ])
        while !isCancelled {
          let disposition = sink(.data(cursor: cursor, payload: payload))
          if disposition == .accepted { break }
          if disposition == .terminated { return }
          waitForWake()
          if Date().timeIntervalSince(lastHeartbeat) * 1_000
            >= Double(request.heartbeatMilliseconds)
          {
            guard sink(.heartbeat) != .terminated else { return }
            lastHeartbeat = Date()
          }
        }
        offset = end
        finalCursor = cursor
        ordinal += 1
      }
      if !isCancelled { _ = sink(.end(cursor: finalCursor)) }
    } catch {
      _ = sink(.failure(SanitizedError(
        code: "runtimeLogsStreamFailed",
        message: "The runtime log stream failed safely."
      )))
    }
  }

  private var isCancelled: Bool { condition.withLock { cancelled } }
  private func wake() { condition.withLock { condition.signal() } }
  private func cancel() { condition.withLock { cancelled = true; condition.broadcast() } }
  private func waitForWake() {
    condition.withLock {
      if !cancelled { _ = condition.wait(until: Date().addingTimeInterval(1)) }
    }
  }
}

final class InteractiveControlStreamProducer: @unchecked Sendable {
  private enum DeliveryError: Error { case terminated }
  private enum Lifecycle { case prepared, preparing, running, cancelRequested, terminal }
  private struct PendingInput: @unchecked Sendable {
    let input: ControlStreamClientInput
    let onConsumed: @Sendable () -> Void
  }

  private let cursorCodec: ControlStreamCursorCodec
  private let binding: ControlStreamCursorBinding
  private let sourceCursor: String?
  private let sink: @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  private let prepareTask: @Sendable () throws -> any DaemonInteractiveStreamTask
  private let preparationQueue = DispatchQueue(label: "dev.hostwright.control.runtime-prepare")
  private let requestHeartbeatMilliseconds: Int
  private let requestRepository: ControlRequestRepository
  private let requestID: String
  private let operationReference: String
  private let auditRecorder: any ControlSecurityAuditRecording
  private let subjectID: String
  private let target: String
  private let preStartAuthorization: @Sendable () throws -> Void
  private let condition = NSCondition()
  private var lifecycle: Lifecycle = .prepared
  private var lifecycleEvidenceFailure = false
  private var task: (any DaemonInteractiveStreamTask)?
  private var pendingInputs: [PendingInput] = []
  private var inputFinished = false

  init(
    cursorCodec: ControlStreamCursorCodec,
    binding: ControlStreamCursorBinding,
    request: ControlStreamOpenRequest,
    sourceCursor: String?,
    manifestPath: String,
    stateDatabasePath: String,
    requestRepository: ControlRequestRepository,
    auditRecorder: any ControlSecurityAuditRecording,
    subjectID: String,
    preStartAuthorization: @escaping @Sendable () throws -> Void,
    prepareTaskOverride: (@Sendable () throws -> any DaemonInteractiveStreamTask)? = nil,
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws {
    guard let target = request.target else { throw DaemonControlStreamSourceError.invalidFilter }
    var arguments: [String] = []
    var serviceName: String?
    var timeoutSeconds = 300
    var terminal = false
    if let filter = request.filter {
      guard case .object(let fields) = filter,
        Set(fields.keys).isSubset(of: [
          "arguments", "serviceName", "timeoutSeconds", "tty", "tail",
        ])
      else { throw DaemonControlStreamSourceError.invalidFilter }
      if let value = fields["serviceName"] {
        guard case .string(let raw) = value, !raw.isEmpty, raw.utf8.count <= 128 else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        serviceName = raw
      }
      if let value = fields["arguments"] {
        guard case .array(let values) = value, !values.isEmpty, values.count <= 256 else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        arguments = try values.map {
          guard case .string(let item) = $0, !item.isEmpty, item.utf8.count <= 4_096 else {
            throw DaemonControlStreamSourceError.invalidFilter
          }
          return item
        }
      }
      if let value = fields["timeoutSeconds"] {
        guard case .integer(let raw) = value, (1...86_400).contains(raw) else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        timeoutSeconds = Int(raw)
      }
      if let value = fields["tty"] {
        guard case .bool(let raw) = value else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        terminal = raw
      }
    }
    if request.source == .exec, arguments.isEmpty {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    guard let serviceName else { throw DaemonControlStreamSourceError.invalidFilter }
    self.cursorCodec = cursorCodec
    self.binding = binding
    self.sourceCursor = sourceCursor
    self.sink = sink
    self.requestHeartbeatMilliseconds = request.heartbeatMilliseconds
    guard let requestID = request.requestID else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    self.requestID = requestID
    self.operationReference = "stream:" + SHA256.hash(
      data: Data("\(binding.subjectID):\(requestID)".utf8)
    ).prefix(16).map { String(format: "%02x", $0) }.joined()
    self.requestRepository = requestRepository
    self.auditRecorder = auditRecorder
    self.subjectID = subjectID
    self.target = target
    self.preStartAuthorization = preStartAuthorization
    let preparedArguments = arguments
    let preparedServiceName = serviceName
    let preparedTimeoutSeconds = timeoutSeconds
    let preparedTerminal = terminal
    let defaultPrepareTask: @Sendable () throws -> any DaemonInteractiveStreamTask = {
      try ControlRuntimeStreamDriver().prepare(
        options: InteractiveCLIOptions(
          command: request.source == .exec ? .exec : (request.source == .attach ? .attach : .logsFollow),
          manifestPath: manifestPath,
          serviceName: preparedServiceName,
          arguments: preparedArguments,
          stateDatabasePath: stateDatabasePath,
          timeoutSeconds: preparedTimeoutSeconds,
          output: .text,
          terminal: preparedTerminal,
          forwardsStandardInput: request.source == .exec || request.source == .attach
        ),
        expectedResourceUUID: target
      )
    }
    self.prepareTask = prepareTaskOverride ?? defaultPrepareTask
  }

  var handle: ControlStreamProducerHandle {
    ControlStreamProducerHandle(
      onCredit: { [self] _ in wake() },
      onInput: { [self] payload, onConsumed in acceptInput(payload, onConsumed: onConsumed) },
      finishInput: { [self] in finishInput() },
      cancellationMode: .deferredUntilProducerTerminal,
      cancel: { [self] in cancel() }
    )
  }

  func start() {
    if sourceCursor != nil {
      _ = sink(.gap(
        cursor: nil,
        payload: ControlStreamGap(reason: "execution.not-replayable")
      ))
      return
    }
    let mayPrepare = condition.withLock { () -> Bool in
      guard lifecycle == .prepared else { return false }
      lifecycle = .preparing
      return true
    }
    guard mayPrepare else { return }
    startHeartbeat()
    preparationQueue.async { [self] in prepareAndStart() }
  }

  private func prepareAndStart() {
    do {
      let preparedTask = try prepareTask()
      let mayStart = condition.withLock { () -> Bool in
        guard lifecycle == .preparing else { return false }
        task = preparedTask
        return true
      }
      guard mayStart else {
        preparedTask.cancel()
        return
      }
      try preparedTask.start(
        beforeExternalExecution: { [self] in
          try establishExternalExecutionBoundary(preparedTask)
        },
        sink: { [weak self] envelope in try self?.deliver(envelope) },
        completion: { [self] result in complete(result) }
      )
    } catch {
      complete(.failure(error))
    }
  }

  private func establishExternalExecutionBoundary(
    _ preparedTask: any DaemonInteractiveStreamTask
  ) throws {
    condition.lock()
    guard lifecycle == .preparing else {
      condition.unlock()
      preparedTask.cancel()
      throw DeliveryError.terminated
    }
    var didMarkStarted = false
    let boundary: ([PendingInput], Bool)
    do {
      try preStartAuthorization()
      let timestamp = ISO8601DateFormatter().string(from: Date())
      try requestRepository.markStreamOperationStarted(
        requestID: requestID,
        operationReference: operationReference,
        updatedAt: timestamp
      )
      didMarkStarted = true
      try recordLifecycleAudit(outcome: "started", reasonCode: "stream.operation-started")
      lifecycle = .running
      boundary = (pendingInputs, inputFinished)
      pendingInputs.removeAll(keepingCapacity: false)
      condition.unlock()
    } catch {
      preparedTask.cancel()
      pendingInputs.removeAll(keepingCapacity: false)
      var evidenceFailed = false
      if !didMarkStarted {
        do {
          try requestRepository.cancelPlannedStreamOperation(
            requestID: requestID,
            operationReference: operationReference,
            updatedAt: ISO8601DateFormatter().string(from: Date())
          )
          try recordLifecycleAudit(
            outcome: "denied",
            reasonCode: "stream.operation-prestart-denied"
          )
        } catch {
          evidenceFailed = true
          lifecycleEvidenceFailure = true
        }
      }
      lifecycle = .terminal
      condition.broadcast()
      condition.unlock()
      _ = sink(.failure(SanitizedError(
        code: evidenceFailed
          ? "runtimeExecutionPrestartEvidenceFailed"
          : (didMarkStarted
            ? "runtimeExecutionStartEvidenceFailed" : "runtimeExecutionAuthorizationRevoked"),
        message: evidenceFailed
          ? "The denied runtime operation could not persist coherent pre-start evidence."
          : (didMarkStarted
            ? "The runtime operation crossed its durable start boundary but required audit evidence failed."
            : "The runtime operation was denied at its durable start boundary and was not started.")
      )))
      throw DeliveryError.terminated
    }
    for pending in boundary.0 {
      guard apply(pending.input, to: preparedTask, onConsumed: pending.onConsumed) else {
        throw DeliveryError.terminated
      }
    }
    if boundary.1 { preparedTask.finishInput() }
  }

  private func acceptInput(
    _ payload: ControlPlaneJSONValue,
    onConsumed: @escaping @Sendable () -> Void
  ) -> Bool {
    guard let input = try? ControlStreamFrameContract.decodeClientInput(payload) else { return false }
    return condition.withLock {
      guard lifecycle == .preparing || lifecycle == .running, !inputFinished else { return false }
      if lifecycle == .running, let task {
        return apply(input, to: task, onConsumed: onConsumed)
      }
      guard pendingInputs.count < 16 else { return false }
      pendingInputs.append(PendingInput(input: input, onConsumed: onConsumed))
      return true
    }
  }

  private func apply(
    _ input: ControlStreamClientInput,
    to task: any DaemonInteractiveStreamTask,
    onConsumed: @escaping @Sendable () -> Void
  ) -> Bool {
    switch input.kind {
    case .stdin:
      guard let encoded = input.payloadBase64, let data = Data(base64Encoded: encoded) else {
        return false
      }
      return task.sendInput(data, onConsumed: onConsumed)
    case .resize:
      guard let columns = input.columns, let rows = input.rows else { return false }
      let accepted = task.resize(columns: UInt16(columns), rows: UInt16(rows))
      if accepted { onConsumed() }
      return accepted
    case .signal:
      guard let signal = input.signal else { return false }
      let accepted = task.forward(signal: signal)
      if accepted { onConsumed() }
      return accepted
    }
  }

  private func finishInput() {
    let currentTask = condition.withLock { () -> (any DaemonInteractiveStreamTask)? in
      guard lifecycle == .preparing || lifecycle == .running, !inputFinished else { return nil }
      inputFinished = true
      return lifecycle == .running ? task : nil
    }
    currentTask?.finishInput()
  }

  private func startHeartbeat() {
    let interval = requestHeartbeatMilliseconds
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      while !self.isCancelled {
        self.condition.withLock {
          if self.lifecycle == .prepared || self.lifecycle == .preparing
            || self.lifecycle == .running
          {
            _ = self.condition.wait(until: Date().addingTimeInterval(Double(interval) / 1_000))
          }
        }
        guard !self.isCancelled else { return }
        if self.sink(.heartbeat) == .terminated { self.cancel(); return }
      }
    }
  }

  private func deliver(_ envelope: RuntimeStreamEnvelope) throws {
    let cursor = try cursorCodec.issue(
      binding: binding,
      sourceCursor: "runtime:\(envelope.sequence)"
    )
    let payload = try ControlStreamFrameContract.value(envelope)
    while !isCancelled {
      switch sink(.data(cursor: cursor, payload: payload)) {
      case .accepted: return
      case .creditExhausted: waitForWake()
      case .terminated: throw DeliveryError.terminated
      }
    }
    throw DeliveryError.terminated
  }

  private func complete(_ result: Result<RuntimeInteractiveExecutionResult, Error>) {
    let completionState = condition.withLock { () -> (Bool, Bool, Bool)? in
      guard lifecycle != .terminal else { return nil }
      let crossedStartBoundary = lifecycle == .running || lifecycle == .cancelRequested
      let requested = lifecycle == .cancelRequested
      let evidenceFailed = lifecycleEvidenceFailure
      lifecycle = .terminal
      condition.broadcast()
      return (crossedStartBoundary, requested, evidenceFailed)
    }
    guard let (crossedStartBoundary, cancelWasRequested, evidenceFailed) = completionState else {
      return
    }
    guard crossedStartBoundary else {
      do {
        try recordLifecycleAudit(
          outcome: "not-started",
          reasonCode: "stream.operation-not-started"
        )
        _ = sink(.failure(SanitizedError(
          code: "runtimeExecutionNotStarted",
          message: "The runtime operation failed freshness checks before external execution and may be retried."
        )))
      } catch {
        _ = sink(.failure(SanitizedError(
          code: "runtimeExecutionPrestartEvidenceFailed",
          message: "The runtime operation did not start, but required pre-start audit evidence failed."
        )))
      }
      return
    }
    if evidenceFailed {
      _ = sink(.failure(SanitizedError(
        code: "runtimeCancellationPersistenceFailed",
        message: "Runtime cancellation completed without coherent durable request evidence."
      )))
      return
    }
    switch result {
    case .success:
      do {
        try recordLifecycleAudit(
          outcome: cancelWasRequested ? "completed-after-cancel-request" : "completed",
          reasonCode: cancelWasRequested
            ? "stream.operation-completed-after-cancel-request"
            : "stream.operation-completed"
        )
        try requestRepository.finishStreamOperation(
          requestID: requestID, operationReference: operationReference, succeeded: true,
          updatedAt: ISO8601DateFormatter().string(from: Date()))
        _ = sink(.end(cursor: nil))
      } catch {
        _ = sink(.failure(SanitizedError(
          code: "runtimeExecutionPersistenceFailed",
          message: "The runtime operation completed but durable terminal evidence failed."
        )))
      }
    case .failure:
      do {
        try recordLifecycleAudit(
          outcome: cancelWasRequested ? "cancelled" : "failed",
          reasonCode: cancelWasRequested
            ? "stream.operation-cancelled"
            : "stream.operation-failed"
        )
        try requestRepository.finishStreamOperation(
          requestID: requestID, operationReference: operationReference, succeeded: false,
          abandoned: cancelWasRequested,
          updatedAt: ISO8601DateFormatter().string(from: Date()))
      } catch {
        _ = sink(.failure(SanitizedError(
          code: "runtimeExecutionPersistenceFailed",
          message: "The runtime operation failure could not be persisted safely."
        )))
        return
      }
      _ = sink(.failure(SanitizedError(
        code: "runtimeExecutionFailed",
        message: "The verified runtime execution stream failed safely."
      )))
    }
  }

  private var isCancelled: Bool {
    condition.withLock { lifecycle == .cancelRequested || lifecycle == .terminal }
  }
  private func wake() { condition.withLock { condition.signal() } }
  private func cancel() {
    condition.lock()
    switch lifecycle {
    case .prepared, .preparing:
      let currentTask = task
      do {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try requestRepository.cancelPlannedStreamOperation(
          requestID: requestID,
          operationReference: operationReference,
          updatedAt: timestamp
        )
        try recordLifecycleAudit(
          outcome: "cancel-requested",
          reasonCode: "stream.operation-cancel-requested"
        )
        try recordLifecycleAudit(
          outcome: "cancelled",
          reasonCode: "stream.operation-cancelled"
        )
        lifecycle = .terminal
        pendingInputs.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()
        currentTask?.cancel()
        _ = sink(.failure(SanitizedError(
          code: "runtimeExecutionCancelledBeforeStart",
          message: "The runtime operation was cancelled before external execution started."
        )))
      } catch {
        lifecycle = .terminal
        lifecycleEvidenceFailure = true
        condition.broadcast()
        condition.unlock()
        currentTask?.cancel()
        _ = sink(.failure(SanitizedError(
          code: "runtimeCancellationPersistenceFailed",
          message: "Runtime cancellation could not persist coherent durable evidence."
        )))
      }
    case .running:
      lifecycle = .cancelRequested
      let currentTask = task
      do {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try requestRepository.recordStreamOperationCancelRequested(
          operationReference: operationReference,
          updatedAt: timestamp
        )
        try recordLifecycleAudit(
          outcome: "cancel-requested",
          reasonCode: "stream.operation-cancel-requested"
        )
        condition.broadcast()
        condition.unlock()
        currentTask?.cancel()
      } catch {
        lifecycleEvidenceFailure = true
        condition.broadcast()
        condition.unlock()
        currentTask?.cancel()
      }
    case .cancelRequested, .terminal:
      condition.unlock()
    }
  }

  private func recordLifecycleAudit(outcome: String, reasonCode: String) throws {
    let digest = SHA256.hash(data: Data("\(requestID):\(operationReference):\(outcome)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    _ = try auditRecorder.record(ControlSecurityAuditEvent(
      subjectID: subjectID,
      requestID: requestID,
      target: target,
      action: .operation,
      outcome: outcome,
      reasonCode: reasonCode,
      operationRef: operationReference,
      payloadDigest: "sha256:\(digest)",
      deduplicationKey: "\(requestID):\(reasonCode)"
    ))
  }
  private func waitForWake() {
    condition.withLock {
      if lifecycle == .prepared || lifecycle == .running {
        _ = condition.wait(until: Date().addingTimeInterval(1))
      }
    }
  }
}

private extension NSCondition {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
