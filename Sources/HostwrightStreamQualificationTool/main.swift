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
  static func main() throws {
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
    let ownership = try waitForOwnership(store: store)
    let session = try PersistentControlClient(socketPath: socketPath).connectSession()
    defer { session.close() }
    let projectID = "project-phase09-gate08-live"

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
    try requireOpen(session, streamID: eventStream)
    try store.events.append([
      event("gate08-live-event-1", projectID: projectID),
      event("gate08-live-event-2", projectID: projectID),
    ])
    let first = try nextData(session, streamID: eventStream, timeoutMilliseconds: 10_000)
    guard let firstCursor = first.cursor else { throw failure(66) }
    var heartbeatObserved = false
    do {
      let frame = try session.nextFrame(streamID: eventStream, timeoutMilliseconds: 1_500)
      heartbeatObserved = frame.kind == .heartbeat
      guard frame.kind != .data else { throw failure(67) }
    } catch PersistentControlClientError.deadlineExceeded {
      heartbeatObserved = false
    }
    try session.acknowledge(streamID: eventStream, credit: 1, cursor: firstCursor)
    let second = try nextData(session, streamID: eventStream, timeoutMilliseconds: 10_000)
    guard second.cursor != nil, second.cursor != firstCursor else { throw failure(68) }
    let cursor = second.cursor!
    try Data(cursor.utf8).write(to: root.appendingPathComponent("resume-cursor.txt"))
    try session.cancel(streamID: eventStream)
    try requireTerminal(session, streamID: eventStream)

    let metrics = "gate08-metrics"
    try session.openStream(streamID: metrics, request: ControlStreamOpenRequest(source: .metrics))
    try requireOpen(session, streamID: metrics)
    _ = try nextData(session, streamID: metrics, timeoutMilliseconds: 10_000)
    try session.cancel(streamID: metrics)
    try requireTerminal(session, streamID: metrics)

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
    let echoInput = Data("hostwright-gate08-full-duplex\n".utf8)
    try session.sendStreamInput(
      streamID: exec,
      payload: try ControlStreamFrameContract.value(ControlStreamClientInput(
        kind: .stdin,
        payloadBase64: echoInput.base64EncodedString()
      ))
    )
    var inputAcknowledged = false
    var prefetchedExecFrames: [StreamFrame] = []
    let acknowledgementDeadline = Date().addingTimeInterval(10)
    while !inputAcknowledged, Date() < acknowledgementDeadline {
      let frame = try session.nextFrame(streamID: exec, timeoutMilliseconds: 10_000)
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
    try session.finishStreamInput(streamID: exec)
    let execEvidence = try drainInteractiveEcho(
      session,
      streamID: exec,
      prefetched: prefetchedExecFrames,
      expected: echoInput
    )

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
    try waitForStreamOperationStarted(
      store: store,
      requestID: "gate08-cancel-request"
    )
    try waitForRuntimeMarker(
      session,
      streamID: cancel,
      marker: Data("hostwright-gate08-cancel-ready".utf8),
      timeoutMilliseconds: 20_000
    )
    try session.cancel(streamID: cancel)
    try requireTerminal(session, streamID: cancel, timeoutMilliseconds: 20_000)
    let cancellationDurable = try verifyCancellationEvidence(
      store: store,
      statePath: statePath,
      requestID: "gate08-cancel-request"
    )

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
  }

  private static func resume(root: URL, statePath: String, socketPath: String) throws {
    let cursor = String(decoding: try Data(contentsOf: root.appendingPathComponent("resume-cursor.txt")), as: UTF8.self)
    let store = SQLiteStateStore(path: statePath)
    let session = try PersistentControlClient(socketPath: socketPath).connectSession()
    defer { session.close() }
    let streamID = "gate08-resume"
    let projectID = "project-phase09-gate08-live"
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
    try requireOpen(session, streamID: streamID)
    try store.events.append([event("gate08-live-event-after-restart", projectID: projectID)])
    let resumed = try nextData(session, streamID: streamID, timeoutMilliseconds: 10_000)
    guard case .object(let fields)? = resumed.payload,
      case .string(let identifier)? = fields["id"],
      identifier == "gate08-live-event-after-restart"
    else { throw failure(69) }
    try session.cancel(streamID: streamID)
    try requireTerminal(session, streamID: streamID)
    let integrity = StateIntegrityService(store: store).inspect()
    let result = ResumeQualificationResult(
      kind: "hostwright.phase09.stream.resume-qualification.v1",
      resumedWithoutDuplicate: true,
      daemonRestartCursorAccepted: true,
      integrityHealth: integrity.health.rawValue
    )
    try removeOwnedKeychainItems(statePath: statePath)
    try emit(result)
  }

  private static func waitForOwnership(store: SQLiteStateStore) throws -> OwnershipRecord {
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline {
      let matches = try store.ownership.loadAll().filter {
        $0.resourceType == "container" && $0.projectID == "project-phase09-gate08-live"
          && $0.serviceName == "probe"
      }
      if matches.count == 1, let match = matches.first { return match }
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
    statePath: String,
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
    let keyStore = try MacOSAuditSigningKeyStore(
      service: MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: statePath))
    let audit = TamperEvidentAuditTrail(store: store, keyStore: keyStore)
    let exported = try audit.exportVerified()
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
    requestID: String
  ) throws {
    let deadline = Date().addingTimeInterval(20)
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
