import Foundation
import CryptoKit
import HostwrightCLI
import HostwrightCommandTransport
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

enum DaemonRuntimeStreamBindingContract {
  static let filterKey = "authorizedRuntimeBinding"

  static func attach(
    _ binding: ControlRuntimeStreamTarget,
    to request: ControlStreamOpenRequest
  ) throws -> ControlStreamOpenRequest {
    try binding.validate()
    guard case .object(var fields)? = request.filter else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    fields[filterKey] = try ControlStreamFrameContract.value(binding)
    return ControlStreamOpenRequest(
      source: request.source,
      target: request.target,
      filter: .object(fields),
      heartbeatMilliseconds: request.heartbeatMilliseconds,
      requestID: request.requestID,
      idempotencyKey: request.idempotencyKey
    )
  }

  static func decode(_ request: ControlStreamOpenRequest) throws
    -> ControlRuntimeStreamTarget?
  {
    guard case .object(let fields)? = request.filter,
      let value = fields[filterKey] else { return nil }
    let data = try ControlPlaneCanonicalJSON.encode(value)
    let binding = try Phase09StrictDecoder.decode(
      ControlRuntimeStreamTarget.self,
      from: data,
      allowedKeys: [
        "fencingToken", "projectGeneration", "projectID", "projectResourceUUID",
        "providerGeneration", "providerID", "resourceGeneration", "resourceIdentifier",
        "resourceUUID", "serviceName",
      ],
      requiredKeys: [
        "fencingToken", "projectGeneration", "projectID", "projectResourceUUID",
        "providerGeneration", "providerID", "resourceGeneration", "resourceIdentifier",
        "resourceUUID", "serviceName",
      ]
    )
    try binding.validate()
    return binding
  }

  static func make(
    ownership: OwnershipRecord,
    store: SQLiteStateStore
  ) throws -> ControlRuntimeStreamTarget {
    guard let projectID = ownership.projectID,
      let projectResourceUUID = ownership.projectResourceUUID,
      let serviceName = ownership.serviceName,
      let providerID = RuntimeProviderBinding.stableID(for: ownership.runtimeAdapter)
    else { throw DaemonControlStreamSourceError.invalidFilter }
    let project = try store.desiredStates.loadProject(id: projectID)
    guard project.resourceUUID == projectResourceUUID,
      project.providerGeneration == ownership.providerGeneration else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    let binding = ControlRuntimeStreamTarget(
      projectID: projectID,
      projectResourceUUID: projectResourceUUID,
      serviceName: serviceName,
      resourceUUID: ownership.resourceUUID,
      resourceIdentifier: ownership.resourceIdentifier,
      providerID: providerID,
      resourceGeneration: ownership.resourceGeneration,
      projectGeneration: ownership.projectGeneration,
      providerGeneration: ownership.providerGeneration,
      fencingToken: ownership.fencingToken
    )
    try binding.validate()
    return binding
  }

  static func validateCurrent(
    _ binding: ControlRuntimeStreamTarget,
    store: SQLiteStateStore
  ) throws {
    let matches = try store.ownership.loadAll().filter {
      $0.resourceType == "container"
        && $0.projectID == binding.projectID
        && $0.projectResourceUUID == binding.projectResourceUUID
        && $0.serviceName == binding.serviceName
        && $0.resourceUUID == binding.resourceUUID
        && $0.resourceIdentifier == binding.resourceIdentifier
        && RuntimeProviderBinding.stableID(for: $0.runtimeAdapter) == binding.providerID
        && $0.resourceGeneration == binding.resourceGeneration
        && $0.projectGeneration == binding.projectGeneration
        && $0.providerGeneration == binding.providerGeneration
        && $0.fencingToken == binding.fencingToken
    }
    guard matches.count == 1 else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    let project = try store.desiredStates.loadProject(id: binding.projectID)
    guard project.resourceUUID == binding.projectResourceUUID,
      project.providerGeneration == binding.providerGeneration else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
  }
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

private protocol DaemonControlStreamProducer: AnyObject {
  var handle: ControlStreamProducerHandle { get }
  func start()
}

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
    request originalRequest: ControlStreamOpenRequest,
    cursor: String?,
    preStartAuthorization: @escaping @Sendable () throws -> Void,
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws -> ControlStreamProducerHandle {
    let request = try runtimeBoundRequestIfNeeded(originalRequest)
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
    let streamManifestPath = try Self.manifestPath(
      request: request,
      fallback: manifestPath
    )
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
      let producer: any DaemonControlStreamProducer
      if try Self.isFollowingLogsRequest(request) {
        producer = try InteractiveControlStreamProducer(
          cursorCodec: cursorCodec,
          binding: binding,
          request: request,
          sourceCursor: sourceCursor,
          manifestPath: streamManifestPath,
          stateDatabasePath: stateDatabasePath,
          requestRepository: requestRepository,
          auditRecorder: auditRecorder,
          subjectID: peer.binding.subject.identifier,
          preStartAuthorization: preStartAuthorization,
          sink: sink
        )
      } else {
        producer = try FiniteLogsControlStreamProducer(
          store: store,
          cursorCodec: cursorCodec,
          binding: binding,
          request: request,
          sourceCursor: sourceCursor,
          manifestPath: streamManifestPath,
          stateDatabasePath: stateDatabasePath,
          sink: sink
        )
      }
      producer.start()
      return producer.handle
    case .attach, .exec:
      let producer = try InteractiveControlStreamProducer(
        cursorCodec: cursorCodec,
        binding: binding,
        request: request,
        sourceCursor: sourceCursor,
        manifestPath: streamManifestPath,
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

  private func runtimeBoundRequestIfNeeded(
    _ request: ControlStreamOpenRequest
  ) throws -> ControlStreamOpenRequest {
    guard request.source == .logs || request.source == .attach || request.source == .exec,
      try DaemonRuntimeStreamBindingContract.decode(request) == nil,
      let target = request.target,
      case .object(let fields)? = request.filter,
      case .string(let serviceName)? = fields["serviceName"] else { return request }
    let ownership = try store.ownership.loadAll().filter {
      $0.resourceType == "container" && $0.resourceUUID == target
        && $0.serviceName == serviceName
    }
    guard ownership.count == 1 else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    return try DaemonRuntimeStreamBindingContract.attach(
      DaemonRuntimeStreamBindingContract.make(ownership: ownership[0], store: store),
      to: request
    )
  }

  func prepare(
    peer: AuthenticatedControlPeer,
    route: CLIControlRoute,
    environment: CLIEnvironment
  ) throws -> CLIControlStreamPreparation {
    let commandEnvironment = try environment.resolvingRelativePaths(
      against: route.workingDirectory
    )
    let command = try CLICommand.parse(arguments: route.arguments)
    try CLIControlAuthorizationScopeResolver.validate(
      declared: route.authorizationScope,
      command: command,
      arguments: route.arguments,
      environment: commandEnvironment
    )
    switch command {
    case .events(_, let projectName, let filters, let stream, let output):
      var fields: [String: ControlPlaneJSONValue] = [:]
      if let projectName { fields["projectID"] = .string("project-\(projectName)") }
      if let type = filters.type { fields["type"] = .string(type) }
      if let service = filters.serviceName { fields["serviceName"] = .string(service) }
      if let severity = filters.severity { fields["severity"] = .string(severity.rawValue) }
      fields["endAfterSnapshot"] = .bool(true)
      fields["maximumEvents"] = .integer(Int64((filters.limit ?? 100) + 1))
      fields["waitForFirst"] = .bool(stream.watch)
      let filter: ControlPlaneJSONValue? = fields.isEmpty ? nil : .object(fields)
      let rawCursor: String?
      if stream.cursor == HostwrightEventCursor.beginning {
        rawCursor = nil
      } else if let supplied = stream.cursor {
        rawCursor = try HostwrightEventCursor(token: supplied).token
      } else if stream.watch {
        rawCursor = try store.events.latestCursor()
      } else {
        rawCursor = nil
      }
      let binding = try ControlStreamCursorBinding(
        subjectID: peer.binding.subject.identifier,
        source: .events,
        target: nil,
        filter: filter
      )
      return try CLIControlStreamPreparation(
        source: .events,
        target: nil,
        filter: filter,
        cursor: try rawCursor.map { try cursorCodec.issue(binding: binding, sourceCursor: $0) },
        timeoutMilliseconds: stream.timeoutSeconds * 1_000,
        output: output
      )
    case .logs(let serviceName, let path, let tail, let stateDatabasePath):
      let options = InteractiveCLIOptions(
        command: .logsFollow,
        manifestPath: path,
        serviceName: serviceName,
        stateDatabasePath: stateDatabasePath,
        forwardsStandardInput: false,
        tail: tail
      )
      let target = try ControlRuntimeStreamTargetResolver(environment: commandEnvironment)
        .resolve(options: options)
      return try CLIControlStreamPreparation(
        source: .logs,
        target: target.resourceUUID,
        filter: .object([
          "manifestPath": .string(try Self.resolve(
            path,
            against: route.workingDirectory
          )),
          "serviceName": .string(serviceName),
          "tail": .integer(Int64(tail)),
        ]),
        cursor: nil,
        timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
        output: route.output
      )
    case .interactive(let options):
      let source: ControlStreamSource
      switch options.command {
      case .exec: source = .exec
      case .attach: source = .attach
      case .logsFollow: source = .logs
      case .copy, .export, .inspect, .stats:
        throw DaemonControlStreamSourceError.unsupportedSource
      }
      let target = try ControlRuntimeStreamTargetResolver(environment: commandEnvironment)
        .resolve(options: options)
      var filter: [String: ControlPlaneJSONValue] = [
        "manifestPath": .string(try Self.resolve(
          options.manifestPath,
          against: route.workingDirectory
        )),
        "serviceName": .string(target.serviceName),
      ]
      if source == .exec {
        filter["arguments"] = .array(options.arguments.map(ControlPlaneJSONValue.string))
      }
      if source == .attach || source == .exec {
        filter["timeoutSeconds"] = .integer(Int64(options.timeoutSeconds))
        filter["tty"] = .bool(options.terminal)
      } else {
        filter["follow"] = .bool(true)
        filter["tail"] = .integer(Int64(options.tail))
        filter["timeoutSeconds"] = .integer(Int64(options.timeoutSeconds))
      }
      return try CLIControlStreamPreparation(
        source: source,
        target: target.resourceUUID,
        filter: .object(filter),
        cursor: nil,
        timeoutMilliseconds: min(
          options.timeoutSeconds * 1_000,
          CLIControlStreamPreparation.maximumTimeoutMilliseconds
        ),
        output: options.output
      )
    default:
      throw DaemonControlStreamSourceError.unsupportedSource
    }
  }

  private static func isFollowingLogsRequest(_ request: ControlStreamOpenRequest) throws -> Bool {
    guard request.source == .logs else { return false }
    guard case .object(let fields)? = request.filter else { return false }
    guard let value = fields["follow"] else { return false }
    guard case .bool(let follow) = value else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    return follow
  }

  private static func resolve(_ path: String, against workingDirectory: String?) throws -> String {
    let resolved: String
    if path.hasPrefix("/") {
      resolved = URL(fileURLWithPath: path).standardizedFileURL.path
    } else if let workingDirectory {
      resolved = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        .appendingPathComponent(path).standardizedFileURL.path
    } else {
      resolved = path
    }
    guard resolved.hasPrefix("/"), resolved.utf8.count <= 4_096 else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    return resolved
  }

  private static func manifestPath(
    request: ControlStreamOpenRequest,
    fallback: String
  ) throws -> String {
    guard case .object(let fields)? = request.filter,
      let value = fields["manifestPath"] else { return fallback }
    guard case .string(let path) = value, path.hasPrefix("/"), path.utf8.count <= 4_096,
      URL(fileURLWithPath: path).standardizedFileURL.path == path else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    return path
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
      case .logs:
        allowedKeys = [
          "follow", "manifestPath", "serviceName", "tail", "timeoutSeconds",
          DaemonRuntimeStreamBindingContract.filterKey,
        ]
      case .attach:
        allowedKeys = [
          "manifestPath", "serviceName", "timeoutSeconds", "tty",
          DaemonRuntimeStreamBindingContract.filterKey,
        ]
      case .exec:
        allowedKeys = [
          "arguments", "manifestPath", "serviceName", "timeoutSeconds", "tty",
          DaemonRuntimeStreamBindingContract.filterKey,
        ]
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
      if let value = fields["follow"] {
        guard request.source == .logs, case .bool(true) = value,
          fields["timeoutSeconds"] != nil
        else { throw DaemonControlStreamSourceError.invalidFilter }
      } else if request.source == .logs, fields["timeoutSeconds"] != nil {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      if let value = fields["manifestPath"] {
        guard case .string(let path) = value, path.hasPrefix("/"), path.utf8.count <= 4_096,
          URL(fileURLWithPath: path).standardizedFileURL.path == path else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
      }
      let ownership = try store.ownership.loadAll().filter {
        $0.resourceType == "container" && $0.resourceUUID == target
          && $0.serviceName == serviceName
      }
      guard ownership.count == 1 else { throw DaemonControlStreamSourceError.invalidFilter }
      if let binding = try DaemonRuntimeStreamBindingContract.decode(request) {
        guard binding.resourceUUID == target,
          binding.serviceName == serviceName else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        try DaemonRuntimeStreamBindingContract.validateCurrent(binding, store: store)
      }
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
  private let endAfterSnapshot: Bool
  private let maximumEvents: Int?
  private let waitForFirst: Bool

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
    let controls = try Self.controls(request)
    endAfterSnapshot = controls.endAfterSnapshot
    maximumEvents = controls.maximumEvents
    waitForFirst = controls.waitForFirst
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
      var delivered = 0
      while !isCancelled {
        let page = try store.events.streamPage(after: rawCursor, filter: filter, pageSize: 100)
        if page.status == .retentionGap {
          let earliest = page.retentionGap?.earliestAvailableCursor
          let latest = page.retentionGap?.latestAvailableCursor
          let signedEarliest = try earliest.map {
            try cursorCodec.issue(binding: binding, sourceCursor: $0)
          }
          _ = sink(.gap(
            cursor: signedEarliest,
            payload: ControlStreamGap(
              reason: "retention.compacted",
              earliestCursor: earliest,
              latestCursor: latest
            )
          ))
          return
        }
        let matching = page.events.filter(shouldDeliver)
        for record in matching {
          if let maximumEvents, delivered >= maximumEvents {
            _ = sink(.end(cursor: nil))
            return
          }
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
          delivered += 1
        }
        if let maximumEvents, delivered >= maximumEvents {
          _ = sink(.end(cursor: nil))
          return
        }
        rawCursor = page.nextCursor ?? rawCursor
        if page.moreAvailable { continue }
        if endAfterSnapshot, !matching.isEmpty || !waitForFirst {
          _ = sink(.end(cursor: nil))
          return
        }
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
        Set(value.keys).isSubset(of: [
          "projectID", "type", "serviceName", "severity", "endAfterSnapshot",
          "maximumEvents", "waitForFirst",
        ])
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

  private static func controls(
    _ request: ControlStreamOpenRequest
  ) throws -> (endAfterSnapshot: Bool, maximumEvents: Int?, waitForFirst: Bool) {
    guard case .object(let fields)? = request.filter else {
      return (false, nil, false)
    }
    func bool(_ key: String) throws -> Bool {
      guard let value = fields[key] else { return false }
      guard case .bool(let result) = value else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      return result
    }
    let maximum: Int?
    if let value = fields["maximumEvents"] {
      guard case .integer(let raw) = value, (1...1_001).contains(raw) else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      maximum = Int(raw)
    } else {
      maximum = nil
    }
    let end = try bool("endAfterSnapshot")
    let wait = try bool("waitForFirst")
    guard !wait || end else { throw DaemonControlStreamSourceError.invalidFilter }
    return (end, maximum, wait)
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
      "runtimeAdapter": record.event.runtimeAdapter.map(ControlPlaneJSONValue.string) ?? .null,
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

private final class FiniteLogsControlStreamProducer: DaemonControlStreamProducer, @unchecked Sendable {
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
  private let expectedTarget: ControlRuntimeStreamTarget
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
        Set(fields.keys).isSubset(of: [
          "manifestPath", "serviceName", "tail",
          DaemonRuntimeStreamBindingContract.filterKey,
        ])
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
    guard let expectedTarget = try DaemonRuntimeStreamBindingContract.decode(request) else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    try DaemonRuntimeStreamBindingContract.validateCurrent(expectedTarget, store: store)
    self.cursorCodec = cursorCodec
    self.binding = binding
    self.request = request
    self.sourceCursor = sourceCursor
    self.manifestPath = manifestPath
    self.stateDatabasePath = stateDatabasePath
    self.sink = sink
    self.tail = tail
    self.serviceName = serviceName
    self.expectedTarget = expectedTarget
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
        expectedTarget: expectedTarget,
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

final class InteractiveControlStreamProducer: DaemonControlStreamProducer, @unchecked Sendable {
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
  private let requestID: String?
  private let operationReference: String?
  private let mutationOperation: Bool
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
    var tail = 100
    var follow = false
    if let filter = request.filter {
      guard case .object(let fields) = filter,
        Set(fields.keys).isSubset(of: [
          "arguments", "follow", "manifestPath", "serviceName", "timeoutSeconds", "tty", "tail",
          DaemonRuntimeStreamBindingContract.filterKey,
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
      if let value = fields["tail"] {
        guard case .integer(let raw) = value, (1...1_000).contains(raw) else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        tail = Int(raw)
      }
      if let value = fields["follow"] {
        guard case .bool(let raw) = value else {
          throw DaemonControlStreamSourceError.invalidFilter
        }
        follow = raw
      }
    }
    if request.source == .exec, arguments.isEmpty {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    guard request.source != .logs || follow else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    guard let serviceName else { throw DaemonControlStreamSourceError.invalidFilter }
    let expectedTarget = try DaemonRuntimeStreamBindingContract.decode(request)
    guard expectedTarget == nil || (
      expectedTarget!.resourceUUID == target
        && expectedTarget!.serviceName == serviceName
    ), expectedTarget != nil || prepareTaskOverride != nil else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
    self.cursorCodec = cursorCodec
    self.binding = binding
    self.sourceCursor = sourceCursor
    self.sink = sink
    self.requestHeartbeatMilliseconds = request.heartbeatMilliseconds
    mutationOperation = request.source == .exec || request.source == .attach
    if mutationOperation {
      guard let requestID = request.requestID else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      self.requestID = requestID
      self.operationReference = "stream:" + SHA256.hash(
        data: Data("\(binding.subjectID):\(requestID)".utf8)
      ).prefix(16).map { String(format: "%02x", $0) }.joined()
    } else {
      guard request.requestID == nil, request.idempotencyKey == nil else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      self.requestID = nil
      self.operationReference = nil
    }
    self.requestRepository = requestRepository
    self.auditRecorder = auditRecorder
    self.subjectID = subjectID
    self.target = target
    self.preStartAuthorization = preStartAuthorization
    let preparedArguments = arguments
    let preparedServiceName = serviceName
    let preparedTimeoutSeconds = timeoutSeconds
    let preparedTerminal = terminal
    let preparedTail = tail
    let defaultPrepareTask: @Sendable () throws -> any DaemonInteractiveStreamTask = {
      guard let expectedTarget else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
      return try ControlRuntimeStreamDriver().prepare(
        options: InteractiveCLIOptions(
          command: request.source == .exec ? .exec : (request.source == .attach ? .attach : .logsFollow),
          manifestPath: manifestPath,
          serviceName: preparedServiceName,
          arguments: preparedArguments,
          stateDatabasePath: stateDatabasePath,
          timeoutSeconds: preparedTimeoutSeconds,
          output: .text,
          terminal: preparedTerminal,
          forwardsStandardInput: request.source == .exec || request.source == .attach,
          tail: preparedTail
        ),
        expectedTarget: expectedTarget
      )
    }
    self.prepareTask = prepareTaskOverride ?? defaultPrepareTask
  }

  var handle: ControlStreamProducerHandle {
    if mutationOperation {
      return ControlStreamProducerHandle(
        onCredit: { [self] _ in wake() },
        onInput: { [self] payload, onConsumed in acceptInput(payload, onConsumed: onConsumed) },
        finishInput: { [self] in finishInput() },
        cancellationMode: .deferredUntilProducerTerminal,
        cancel: { [self] in cancel() }
      )
    }
    return ControlStreamProducerHandle(
      onCredit: { [self] _ in wake() },
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
      if !mutationOperation {
        lifecycle = .running
        boundary = ([], true)
        pendingInputs.removeAll(keepingCapacity: false)
        condition.unlock()
        preparedTask.finishInput()
        return
      }
      guard let requestID, let operationReference else {
        throw DaemonControlStreamSourceError.invalidFilter
      }
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
      if !mutationOperation {
        lifecycle = .terminal
        condition.broadcast()
        condition.unlock()
        _ = sink(.failure(SanitizedError(
          code: "runtimeLogsAuthorizationRevoked",
          message: "The runtime log stream was denied at its start boundary."
        )))
        throw DeliveryError.terminated
      }
      var evidenceFailed = false
      if !didMarkStarted, let requestID, let operationReference {
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
    if !mutationOperation {
      switch result {
      case .success:
        _ = sink(.end(cursor: nil))
      case .failure:
        _ = sink(.failure(SanitizedError(
          code: cancelWasRequested ? "runtimeLogsCancelled" : "runtimeLogsFollowFailed",
          message: cancelWasRequested
            ? "The runtime log stream was cancelled."
            : "The verified runtime log stream failed safely."
        )))
      }
      return
    }
    guard let requestID, let operationReference else {
      _ = sink(.failure(SanitizedError(
        code: "runtimeExecutionPersistenceFailed",
        message: "The runtime operation lost its durable mutation identity."
      )))
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
    if !mutationOperation {
      guard lifecycle != .terminal else {
        condition.unlock()
        return
      }
      let currentTask = task
      lifecycle = lifecycle == .running ? .cancelRequested : .terminal
      pendingInputs.removeAll(keepingCapacity: false)
      condition.broadcast()
      condition.unlock()
      currentTask?.cancel()
      return
    }
    guard let requestID, let operationReference else {
      lifecycle = .terminal
      condition.broadcast()
      condition.unlock()
      task?.cancel()
      return
    }
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
    guard let requestID, let operationReference else {
      throw DaemonControlStreamSourceError.invalidFilter
    }
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
