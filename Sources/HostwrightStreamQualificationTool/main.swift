import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightControlTransport
import HostwrightCore
import HostwrightState

private struct LiveQualificationResult: Codable {
  let kind: String
  let stateSchemaVersion: Int
  let integrityHealth: String
  let resourceIdentifier: String
  let resourceUUID: String
  let cursor: String
  let eventBackpressureRecovered: Bool
  let heartbeatWhileCreditExhausted: Bool
  let metricsWatchCompleted: Bool
  let logsStreamCompleted: Bool
  let execStreamCompleted: Bool
  let fullDuplexInputAcknowledged: Bool
  let fullDuplexEchoVerified: Bool
  let cancellationTerminalObserved: Bool
  let cancellationDurabilityVerified: Bool
}

private struct ResumeQualificationResult: Codable {
  let kind: String
  let resumedWithoutDuplicate: Bool
  let daemonRestartCursorAccepted: Bool
  let integrityHealth: String
}

@main
private enum HostwrightStreamQualificationMain {
  static func main() {
    do {
      try run()
    } catch {
      let nativeError = error as NSError
      let code = nativeError.domain == "HostwrightStreamQualification"
        && (64...80).contains(nativeError.code)
        ? Int32(nativeError.code) : 70
      let detail = "type=\(String(reflecting: type(of: error))),"
        + " value=\(String(describing: error))"
      FileHandle.standardError.write(
        Data("stream qualification failed safely (code \(code); \(detail)).\n".utf8)
      )
      Foundation.exit(code)
    }
  }

  private static func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 7,
      ["--bootstrap", "--live", "--resume", "--cleanup"].contains(arguments[0]),
      arguments[1] == "--root", arguments[3] == "--state", arguments[5] == "--socket"
    else { throw NSError(domain: "HostwrightStreamQualification", code: 64) }
    let root = try validatedRoot(arguments[2])
    let statePath = try validatedChild(arguments[4], of: root, mustExist: arguments[0] != "--bootstrap")
    let socketPath = try validatedChild(
      arguments[6], of: root,
      mustExist: arguments[0] == "--live" || arguments[0] == "--resume")
    switch arguments[0] {
    case "--bootstrap": try bootstrap(root: root, statePath: statePath)
    case "--live": try live(root: root, statePath: statePath, socketPath: socketPath)
    case "--resume": try resume(root: root, statePath: statePath, socketPath: socketPath)
    case "--cleanup": try removeOwnedKeychainItems(statePath: statePath)
    default: throw NSError(domain: "HostwrightStreamQualification", code: 64)
    }
  }

  private static func bootstrap(root: URL, statePath: String) throws {
    let stateParent = URL(fileURLWithPath: statePath).deletingLastPathComponent()
    guard stateParent.path.hasPrefix(root.path + "/") else { throw failure(75) }
    try FileManager.default.createDirectory(
      at: stateParent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let store = SQLiteStateStore(path: statePath)
    try store.migrate()
    guard try store.schemaVersion() == 20 else { throw failure(65) }
    let identity = try DarwinCurrentControlCodeIdentity.inspect()
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let subjectID = "gate08-owner-\(identity.codeDirectoryHash.prefix(16))"
    if try store.controlIdentities.listIdentities().isEmpty {
      try store.controlIdentities.bootstrap(ControlPeerIdentityRecord(
        subjectID: subjectID,
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: subjectID,
        declaredAt: timestamp,
        updatedAt: timestamp
      ))
    }
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: subjectID, timestamp: timestamp)
    try Data(subjectID.utf8).write(to: root.appendingPathComponent("subject-id.txt"))
  }

  private static func live(root: URL, statePath: String, socketPath: String) throws {
    let store = SQLiteStateStore(path: statePath)
    var stage = "ownership"
    do {
      let ownership = try waitForOwnership(store: store)
      guard let projectID = ownership.projectID,
        projectID.range(
          of: "^project-[a-z0-9-]{1,96}$", options: .regularExpression
        ) != nil
      else { throw failure(70) }
      try Data(projectID.utf8).write(
        to: root.appendingPathComponent("resume-project.txt")
      )
      stage = "reconciliation-quiescence"
      try waitForReconciliationQuiescence(store: store, projectID: projectID)
      stage = "connect"
      let session = try PersistentControlClient(socketPath: socketPath).connectSession()
      defer { session.close() }

    stage = "events-open"
    let eventStream = "gate08-events"
    try session.openStream(
      streamID: eventStream,
      request: ControlStreamOpenRequest(
        source: .events,
        filter: .object(["projectID": .string(projectID)]),
        heartbeatMilliseconds: 1_000
      ),
      initialCredit: 1
    )
    stage = "events-accept"
    try requireOpen(session, streamID: eventStream)
    stage = "events-first"
    try store.events.append([
      event("gate08-live-event-1", projectID: projectID),
      event("gate08-live-event-2", projectID: projectID),
    ])
    let markerDeadline = Date().addingTimeInterval(20)
    var deliveredEventIDs = Set<String>()
    var firstCursor: String?
    while firstCursor == nil, deliveredEventIDs.count < 256, Date() < markerDeadline {
      let remaining = max(1, Int(markerDeadline.timeIntervalSinceNow * 1_000))
      let first = try nextData(
        session,
        streamID: eventStream,
        timeoutMilliseconds: remaining
      )
      let (identifier, cursor) = try eventIdentity(first)
      guard deliveredEventIDs.insert(identifier).inserted,
        identifier != "gate08-live-event-2"
      else { throw failure(66) }
      if identifier == "gate08-live-event-1" {
        firstCursor = cursor
      } else {
        try session.acknowledge(streamID: eventStream, credit: 1, cursor: cursor)
      }
    }
    guard let firstCursor else { throw failure(66) }
    stage = "events-heartbeat"
    var heartbeatObserved = false
    do {
      let frame = try session.nextFrame(streamID: eventStream, timeoutMilliseconds: 1_500)
      heartbeatObserved = frame.kind == .heartbeat
      guard frame.kind != .data else { throw failure(67) }
    } catch PersistentControlClientError.deadlineExceeded {
      heartbeatObserved = false
    }
    stage = "events-second"
    try session.acknowledge(streamID: eventStream, credit: 1, cursor: firstCursor)
    let secondMarkerDeadline = Date().addingTimeInterval(20)
    var cursor: String?
    while cursor == nil, deliveredEventIDs.count < 256, Date() < secondMarkerDeadline {
      let remaining = max(1, Int(secondMarkerDeadline.timeIntervalSinceNow * 1_000))
      let second = try nextData(
        session,
        streamID: eventStream,
        timeoutMilliseconds: remaining
      )
      let (identifier, candidate) = try eventIdentity(second)
      guard deliveredEventIDs.insert(identifier).inserted,
        identifier != "gate08-live-event-1",
        candidate != firstCursor
      else { throw failure(68) }
      if identifier == "gate08-live-event-2" {
        cursor = candidate
      } else {
        try session.acknowledge(streamID: eventStream, credit: 1, cursor: candidate)
      }
    }
    guard let cursor else { throw failure(68) }
    try Data(cursor.utf8).write(to: root.appendingPathComponent("resume-cursor.txt"))
    stage = "events-terminal"
    try session.cancel(streamID: eventStream)
    try requireTerminal(session, streamID: eventStream)

    stage = "metrics"
    let metrics = "gate08-metrics"
    try session.openStream(streamID: metrics, request: ControlStreamOpenRequest(source: .metrics))
    try requireOpen(session, streamID: metrics)
    _ = try nextData(session, streamID: metrics, timeoutMilliseconds: 10_000)
    try session.cancel(streamID: metrics)
    try requireTerminal(session, streamID: metrics)

    stage = "logs"
    let logs = "gate08-logs"
    try session.openStream(
      streamID: logs,
      request: ControlStreamOpenRequest(
        source: .logs,
        target: ownership.resourceUUID,
        filter: .object([
          "serviceName": .string("probe"),
          "tail": .integer(100),
        ])
      ),
      initialCredit: 32
    )
    try requireOpen(session, streamID: logs)
    let logsCompleted = try drainFinite(session, streamID: logs, requireData: true)

    stage = "exec-open"
    let exec = "gate08-exec"
    try session.openStream(
      streamID: exec,
      request: ControlStreamOpenRequest(
        source: .exec,
        target: ownership.resourceUUID,
        filter: .object([
          "serviceName": .string("probe"),
          "arguments": .array([
            .string("python3"), .string("-c"),
            .string("import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data); sys.stdout.buffer.flush()"),
          ]),
          "timeoutSeconds": .integer(30),
          "tty": .bool(false),
        ]),
        requestID: "gate08-exec-request",
        idempotencyKey: "gate08-exec-idempotency"
      ),
      initialCredit: 32
    )
    try requireOpen(session, streamID: exec)
    stage = "exec-start"
    try waitForStreamOperationStarted(
      store: store,
      requestID: "gate08-exec-request",
      timeoutMilliseconds: 120_000
    )
    stage = "exec-input-send"
    let echoInput = Data("hostwright-gate08-full-duplex\n".utf8)
    try session.sendStreamInput(
      streamID: exec,
      payload: try ControlStreamFrameContract.value(ControlStreamClientInput(
        kind: .stdin,
        payloadBase64: echoInput.base64EncodedString()
      ))
    )
    stage = "exec-input-ack"
    var inputAcknowledged = false
    var prefetchedExecFrames: [StreamFrame] = []
    let acknowledgementDeadline = Date().addingTimeInterval(30)
    while !inputAcknowledged, Date() < acknowledgementDeadline {
      let remaining = max(1, Int(acknowledgementDeadline.timeIntervalSinceNow * 1_000))
      let frame = try session.nextFrame(streamID: exec, timeoutMilliseconds: remaining)
      if frame.kind == .ack {
        guard frame.credit == 1 else { throw failure(77) }
        inputAcknowledged = true
      } else if frame.kind == .data || frame.kind == .heartbeat {
        prefetchedExecFrames.append(frame)
      } else {
        throw failure(77)
      }
    }
    guard inputAcknowledged else { throw failure(77) }
    stage = "exec-input-finish"
    try session.finishStreamInput(streamID: exec)
    stage = "exec-drain"
    let execEvidence = try drainInteractiveEcho(
      session,
      streamID: exec,
      prefetched: prefetchedExecFrames,
      expected: echoInput
    )

    stage = "cancel-open"
    let cancel = "gate08-cancel"
    try session.openStream(
      streamID: cancel,
      request: ControlStreamOpenRequest(
        source: .exec,
        target: ownership.resourceUUID,
        filter: .object([
          "serviceName": .string("probe"),
          "arguments": .array([
            .string("python3"), .string("-c"),
            .string("import time; print('hostwright-gate08-cancel-ready', flush=True); time.sleep(30)"),
          ]),
          "timeoutSeconds": .integer(60),
          "tty": .bool(false),
        ]),
        requestID: "gate08-cancel-request",
        idempotencyKey: "gate08-cancel-idempotency"
      )
    )
    try requireOpen(session, streamID: cancel)
    stage = "cancel-start"
    try waitForStreamOperationStarted(
      store: store,
      requestID: "gate08-cancel-request",
      timeoutMilliseconds: 120_000
    )
    stage = "cancel-marker"
    try waitForRuntimeMarker(
      session,
      streamID: cancel,
      marker: Data("hostwright-gate08-cancel-ready".utf8),
      timeoutMilliseconds: 20_000
    )
    stage = "cancel-terminal"
    try session.cancel(streamID: cancel)
    try requireTerminal(session, streamID: cancel, timeoutMilliseconds: 20_000)
    stage = "cancel-evidence"
    let cancellationDurable = try verifyCancellationEvidence(
      store: store,
      session: session,
      requestID: "gate08-cancel-request"
    )

    stage = "result"
    let integrity = StateIntegrityService(store: store).inspect()
    try emit(LiveQualificationResult(
      kind: "hostwright.phase09.stream.live-qualification.v1",
      stateSchemaVersion: try store.schemaVersion(),
      integrityHealth: integrity.health.rawValue,
      resourceIdentifier: ownership.resourceIdentifier,
      resourceUUID: ownership.resourceUUID,
      cursor: cursor,
      eventBackpressureRecovered: true,
      heartbeatWhileCreditExhausted: heartbeatObserved,
      metricsWatchCompleted: true,
      logsStreamCompleted: logsCompleted,
      execStreamCompleted: execEvidence.completed,
      fullDuplexInputAcknowledged: inputAcknowledged,
      fullDuplexEchoVerified: execEvidence.echoVerified,
      cancellationTerminalObserved: true,
      cancellationDurabilityVerified: cancellationDurable
    ))
    } catch {
      let request = try? ControlRequestRepository(store: store).load("gate08-exec-request")
      let operationStatus = request?.operationReference.flatMap { reference in
        try? store.operations.loadAll().first(where: { $0.id == reference })?.status.rawValue
      } ?? nil
      let diagnostic = "stream qualification live stage '\(stage)' failed"
        + " (execRequest=\(request?.status.rawValue ?? "absent"),"
        + " execOperation=\(operationStatus ?? "absent"),"
        + " errorType=\(String(reflecting: type(of: error))),"
        + " error=\(String(describing: error))).\n"
      FileHandle.standardError.write(
        Data(diagnostic.utf8)
      )
      throw error
    }
  }

  private static func resume(root: URL, statePath: String, socketPath: String) throws {
    let store = SQLiteStateStore(path: statePath)
    var stage = "cursor-load"
    do {
      let cursor = String(
        decoding: try Data(contentsOf: root.appendingPathComponent("resume-cursor.txt")),
        as: UTF8.self
      )
      stage = "connect"
      let session = try PersistentControlClient(socketPath: socketPath).connectSession()
      defer { session.close() }
      let streamID = "gate08-resume"
      let projectID = String(
        decoding: try Data(contentsOf: root.appendingPathComponent("resume-project.txt")),
        as: UTF8.self
      )
      guard projectID.range(
        of: "^project-[a-z0-9-]{1,96}$", options: .regularExpression
      ) != nil else { throw failure(69) }
      stage = "stream-open"
      try session.openStream(
        streamID: streamID,
        request: ControlStreamOpenRequest(
          source: .events,
          filter: .object(["projectID": .string(projectID)]),
          heartbeatMilliseconds: 1_000
        ),
        cursor: cursor,
        initialCredit: 4
      )
      stage = "stream-accept"
      try requireOpen(session, streamID: streamID)
      stage = "event-append"
      try store.events.append([event("gate08-live-event-after-restart", projectID: projectID)])
      stage = "event-resume"
      let deadline = Date().addingTimeInterval(20)
      var resumedIDs = Set<String>()
      var markerObserved = false
      while !markerObserved, resumedIDs.count < 256, Date() < deadline {
        let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
        let resumed = try nextData(
          session,
          streamID: streamID,
          timeoutMilliseconds: remaining
        )
        let (identifier, resumedCursor) = try eventIdentity(resumed)
        guard
          identifier != "gate08-live-event-1",
          identifier != "gate08-live-event-2",
          resumedIDs.insert(identifier).inserted
        else { throw failure(69) }
        markerObserved = identifier == "gate08-live-event-after-restart"
        if !markerObserved {
          try session.acknowledge(streamID: streamID, credit: 1, cursor: resumedCursor)
        }
      }
      guard markerObserved else { throw failure(69) }
      stage = "stream-terminal"
      try session.cancel(streamID: streamID)
      try requireTerminal(session, streamID: streamID)
      stage = "integrity"
      let integrity = StateIntegrityService(store: store).inspect()
      let result = ResumeQualificationResult(
        kind: "hostwright.phase09.stream.resume-qualification.v1",
        resumedWithoutDuplicate: true,
        daemonRestartCursorAccepted: true,
        integrityHealth: integrity.health.rawValue
      )
      stage = "result"
      try emit(result)
    } catch {
      let diagnostic = "stream qualification resume stage '\(stage)' failed"
        + " (errorType=\(String(reflecting: type(of: error))),"
        + " error=\(String(describing: error))).\n"
      FileHandle.standardError.write(Data(diagnostic.utf8))
      throw error
    }
  }

  private static func waitForOwnership(store: SQLiteStateStore) throws -> OwnershipRecord {
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline {
      let matches = try store.ownership.loadAll().filter {
        $0.resourceType == "container"
          && ($0.projectID?.hasPrefix("project-phase09-gate") == true)
          && $0.serviceName == "probe"
      }
      if matches.count == 1, let match = matches.first { return match }
      usleep(250_000)
    }
    throw failure(70)
  }

  private static func waitForReconciliationQuiescence(
    store: SQLiteStateStore,
    projectID: String
  ) throws {
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      let groups = try store.operationGroups.loadProject(projectID: projectID)
      if groups.contains(where: { $0.status == .failed || $0.status == .interrupted }) {
        throw failure(70)
      }
      if !groups.isEmpty, groups.allSatisfy({ $0.status == .succeeded }) {
        return
      }
      usleep(250_000)
    }
    throw failure(70)
  }

  private static func requireOpen(_ session: PersistentControlClientSession, streamID: String) throws {
    guard try session.nextFrame(streamID: streamID, timeoutMilliseconds: 10_000).kind == .open else {
      throw failure(71)
    }
  }

  private static func nextData(
    _ session: PersistentControlClientSession,
    streamID: String,
    timeoutMilliseconds: Int
  ) throws -> StreamFrame {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    while Date() < deadline {
      let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
      let frame = try session.nextFrame(streamID: streamID, timeoutMilliseconds: remaining)
      if frame.kind == .data { return frame }
      if frame.kind == .gap || frame.kind == .end || frame.kind == .error { throw failure(72) }
    }
    throw failure(72)
  }

  private static func eventIdentity(_ frame: StreamFrame) throws -> (String, String) {
    guard frame.kind == .data,
      case .object(let fields)? = frame.payload,
      case .string(let identifier)? = fields["id"],
      !identifier.isEmpty,
      let cursor = frame.cursor,
      !cursor.isEmpty
    else { throw failure(69) }
    return (identifier, cursor)
  }

  private static func drainFinite(
    _ session: PersistentControlClientSession,
    streamID: String,
    requireData: Bool
  ) throws -> Bool {
    var sawData = false
    while true {
      let frame = try session.nextFrame(streamID: streamID, timeoutMilliseconds: 30_000)
      if frame.kind == .data { sawData = true; continue }
      if frame.kind == .end { return !requireData || sawData }
      if frame.kind == .error || frame.kind == .gap { throw failure(73) }
    }
  }

  private static func drainInteractiveEcho(
    _ session: PersistentControlClientSession,
    streamID: String,
    prefetched: [StreamFrame],
    expected: Data
  ) throws -> (completed: Bool, echoVerified: Bool) {
    var standardOutput = Data()
    var pending = prefetched
    while true {
      let frame = pending.isEmpty
        ? try session.nextFrame(streamID: streamID, timeoutMilliseconds: 30_000)
        : pending.removeFirst()
      if frame.kind == .heartbeat || frame.kind == .ack { continue }
      if frame.kind == .data {
        guard case .object(let fields)? = frame.payload,
          case .string(let stream)? = fields["stream"],
          case .string(let payloadBase64)? = fields["payloadBase64"],
          let payload = Data(base64Encoded: payloadBase64)
        else { throw failure(78) }
        if stream == "stdout" { standardOutput.append(payload) }
        continue
      }
      if frame.kind == .end {
        return (true, standardOutput == expected)
      }
      throw failure(78)
    }
  }

  private static func verifyCancellationEvidence(
    store: SQLiteStateStore,
    session: PersistentControlClientSession,
    requestID: String
  ) throws -> Bool {
    let requests = ControlRequestRepository(store: store)
    guard let request = try requests.load(requestID),
      request.status == .error,
      let operationReference = request.operationReference,
      try store.operations.loadAll().contains(where: {
        $0.id == operationReference && $0.status == .abandoned
      })
    else { return false }
    let stages = try Set(store.events.loadAll().compactMap { event -> String? in
      guard event.source == "hostwrightd-control",
        let data = event.payloadJSONRedacted.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
        object["operationID"] == operationReference
      else { return nil }
      return object["stage"]
    })
    guard stages.isSuperset(of: ["planned", "started", "cancel-requested", "cancelled"])
    else { return false }
    let response = try session.send(ControlRequestEnvelope(
      requestID: "gate08-audit-export",
      operation: "audit.export",
      timeoutMilliseconds: 30_000
    ))
    guard response.status == .completed,
      case .object(let fields)? = response.result,
      case .string("base64")? = fields["encoding"],
      case .string(let payload)? = fields["payload"],
      let exported = Data(base64Encoded: payload)
    else { return false }
    let report = try TamperEvidentAuditTrail.verifyExport(exported)
    let bundle = try JSONDecoder().decode(AuditExportBundle.self, from: exported)
    let reasons = Set(bundle.records.compactMap { exported -> String? in
      let record = exported.record
      guard record.requestID == requestID, record.operationRef == operationReference else { return nil }
      return record.reasonCode
    })
    return report.health == .healthy
      && reasons.isSuperset(of: [
        "stream.accepted", "stream.operation-started",
        "stream.operation-cancel-requested", "stream.operation-cancelled",
      ])
  }

  private static func waitForStreamOperationStarted(
    store: SQLiteStateStore,
    requestID: String,
    timeoutMilliseconds: Int
  ) throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    let requests = ControlRequestRepository(store: store)
    while Date() < deadline {
      if let operationReference = try requests.load(requestID)?.operationReference,
        try store.operations.loadAll().contains(where: {
          $0.id == operationReference && $0.status == .recorded
        })
      { return }
      usleep(100_000)
    }
    throw failure(79)
  }

  private static func runtimePayload(_ frame: StreamFrame) throws -> Data {
    guard case .object(let fields)? = frame.payload,
      case .string(let payloadBase64)? = fields["payloadBase64"],
      let payload = Data(base64Encoded: payloadBase64)
    else { throw failure(80) }
    return payload
  }

  private static func waitForRuntimeMarker(
    _ session: PersistentControlClientSession,
    streamID: String,
    marker: Data,
    timeoutMilliseconds: Int
  ) throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    var standardOutput = Data()
    while Date() < deadline {
      let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
      let frame = try session.nextFrame(streamID: streamID, timeoutMilliseconds: remaining)
      switch frame.kind {
      case .data:
        guard case .object(let fields)? = frame.payload,
          case .string(let stream)? = fields["stream"]
        else { throw failure(80) }
        let payload = try runtimePayload(frame)
        if stream == "stdout" {
          guard standardOutput.count <= 65_536 - payload.count else { throw failure(80) }
          standardOutput.append(payload)
        }
        try session.acknowledge(streamID: streamID, credit: 1, cursor: frame.cursor)
        if standardOutput.range(of: marker) != nil { return }
      case .heartbeat, .ack:
        continue
      case .gap, .end, .error, .open, .cancel:
        throw failure(80)
      }
    }
    throw failure(80)
  }

  private static func requireTerminal(
    _ session: PersistentControlClientSession,
    streamID: String,
    timeoutMilliseconds: Int = 10_000
  ) throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    while Date() < deadline {
      let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
      let frame = try session.nextFrame(streamID: streamID, timeoutMilliseconds: remaining)
      switch frame.kind {
      case .end, .error, .gap:
        return
      case .data:
        continue
      case .heartbeat, .ack:
        continue
      case .open, .cancel:
        throw failure(74)
      }
    }
    throw failure(74)
  }

  private static func event(_ id: String, projectID: String) -> EventRecord {
    EventRecord(
      id: id,
      timestamp: ISO8601DateFormatter().string(from: Date()),
      severity: .info,
      type: "state.changed",
      source: "hostwright-stream-qualification",
      projectID: projectID,
      serviceName: "probe",
      runtimeAdapter: "apple-container-cli",
      message: "Bounded Gate 8 qualification event.",
      payloadJSONRedacted: "{}"
    )
  }

  private static func removeOwnedKeychainItems(statePath: String) throws {
    try MacOSAuditSigningKeyStore(
      service: MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: statePath)
    ).removeOwnedItems()
    try MacOSAuditSigningKeyStore(
      service: ControlStreamCursorCodec.keychainServiceName(stateDatabasePath: statePath)
    ).removeOwnedItems()
  }

  private static func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
  }

  private static func validatedRoot(_ path: String) throws -> URL {
    guard path.hasPrefix("/"), !path.contains("\n"),
      let resolved = path.withCString({ realpath($0, nil) })
    else { throw failure(75) }
    defer { free(resolved) }
    let canonical = String(cString: resolved)
    var status = stat()
    guard canonical == path, lstat(path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR, (status.st_mode & 0o7777) == 0o700,
      status.st_uid == geteuid()
    else { throw failure(75) }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private static func validatedChild(_ path: String, of root: URL, mustExist: Bool) throws -> String {
    let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
    guard path == normalized, path.hasPrefix(root.path + "/"), !path.contains("\n") else {
      throw failure(76)
    }
    if mustExist, !FileManager.default.fileExists(atPath: path) { throw failure(76) }
    return path
  }

  private static func failure(_ code: Int) -> NSError {
    NSError(domain: "HostwrightStreamQualification", code: code)
  }
}
