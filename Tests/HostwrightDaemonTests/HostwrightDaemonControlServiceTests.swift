import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightControlTransport
@testable import HostwrightCommandTransport
@testable import HostwrightCore
@testable import HostwrightDaemon
@testable import HostwrightDaemonCore
@testable import HostwrightState

final class HostwrightDaemonControlServiceTests: XCTestCase {
  func testStartCreatesPrivateSocketAndStopRemovesIt() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      let service = fixture.service
      try service.start()
      defer { service.stop() }

      var socket = stat()
      XCTAssertEqual(lstat(fixture.socketPath, &socket), 0)
      XCTAssertEqual(socket.st_mode & S_IFMT, S_IFSOCK)
      XCTAssertEqual(socket.st_mode & 0o7777, 0o600)
      XCTAssertEqual(socket.st_uid, geteuid())

      service.stop()
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
    }
  }

  func testExplicitStateAuthoritiesUseDistinctPrivateLedgersWithoutDefaultMetadata() throws {
    try withPrivateHome { home in
      let first = try makeService(home: home, explicitStateName: "authority-a.sqlite")
      let second = try makeService(home: home, explicitStateName: "authority-b.sqlite")
      XCTAssertEqual(
        URL(fileURLWithPath: first.statePath).deletingLastPathComponent(),
        URL(fileURLWithPath: second.statePath).deletingLastPathComponent()
      )
      let metadataPath = home
        .appendingPathComponent("Library/Application Support/Hostwright/metadata")
        .path
      XCTAssertFalse(FileManager.default.fileExists(atPath: metadataPath))

      try first.service.start()
      first.service.stop()
      try second.service.start()
      defer { second.service.stop() }

      let stateDirectory = URL(fileURLWithPath: first.statePath).deletingLastPathComponent()
      let ledgers = try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)
        .filter { $0.hasSuffix("-plugin-provider-workers-v1.jsonl") }
        .sorted()
      XCTAssertEqual(ledgers.count, 2)
      XCTAssertNotEqual(ledgers[0], ledgers[1])
      for ledgerName in ledgers {
        var ledger = stat()
        XCTAssertEqual(lstat(stateDirectory.appendingPathComponent(ledgerName).path, &ledger), 0)
        XCTAssertEqual(ledger.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(ledger.st_mode & 0o7777, 0o600)
        XCTAssertEqual(ledger.st_uid, geteuid())
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: metadataPath))
    }
  }

  func testStopIsSafeWhenRepeated() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      let service = fixture.service
      try service.start()

      service.stop()
      service.stop()

      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
    }
  }

  func testServiceCanRestartAfterOwnedSocketCleanup() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      let service = fixture.service
      try service.start()
      service.stop()
      try service.start()
      defer { service.stop() }

      var socket = stat()
      XCTAssertEqual(lstat(fixture.socketPath, &socket), 0)
      XCTAssertEqual(socket.st_mode & S_IFMT, S_IFSOCK)
      XCTAssertEqual(socket.st_mode & 0o7777, 0o600)
    }
  }

  func testAuthenticatedClientCanReconnectAfterServiceRestart() throws {
    try withPrivateHome { home in
      var stage = "fixture"
      do {
        let fixture = try makeService(home: home)
        let service = fixture.service
        let serverIdentity = try DarwinCurrentControlCodeIdentity.inspect()
        let client = PersistentControlClient(
          socketPath: fixture.socketPath,
          serverTrustPolicy: PersistentControlServerTrustPolicy(
            pinnedAdHocCodeDirectoryHashes: [serverIdentity.codeDirectoryHash]
          )
        )
        stage = "first-start"
        try service.start()
        stage = "first-connect"
        let first = try client.connectSession()
        first.close()

        stage = "first-stop"
        service.stop()
        stage = "second-start"
        try service.start()
        defer { service.stop() }
        stage = "second-connect"
        let second = try client.connectSession()
        second.close()
      } catch {
        XCTFail("authenticated reconnect stage \(stage) failed: \(error)")
      }
    }
  }

  func testAuthenticatedPersistentCapabilitiesWaitsForStateAccessFenceDuringSessionAndUnaryProcessing() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      try fixture.service.start()
      defer { fixture.service.stop() }

      let identity = try DarwinCurrentControlCodeIdentity.inspect()
      let client = PersistentControlClient(
        socketPath: fixture.socketPath,
        serverTrustPolicy: PersistentControlServerTrustPolicy(
          pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
        )
      )

      func holdAccessFenceForFourHundredMilliseconds() throws -> DispatchSemaphore {
        let descriptor = open(
          fixture.accessLockPath,
          O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
          S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
          let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          close(descriptor)
          throw error
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
          let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          close(descriptor)
          throw error
        }
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
          Thread.sleep(forTimeInterval: 0.400)
          _ = flock(descriptor, LOCK_UN)
          close(descriptor)
          released.signal()
        }
        return released
      }

      let authenticationRelease = try holdAccessFenceForFourHundredMilliseconds()
      defer { XCTAssertEqual(authenticationRelease.wait(timeout: .now() + 2), .success) }
      let authenticationStartedAt = Date()
      let session = try client.connectSession()
      defer { session.close() }
      XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(authenticationStartedAt), 0.350)

      let route = try CLIControlRoute.classify(arguments: ["capabilities", "--output", "json"])
      XCTAssertFalse(route.mutating)
      let request = ControlRequestEnvelope(
        requestID: "capabilities-state-access-fence",
        operation: route.operation,
        timeoutMilliseconds: 1_000,
        body: route.requestBody()
      )
      let unaryRelease = try holdAccessFenceForFourHundredMilliseconds()
      defer { XCTAssertEqual(unaryRelease.wait(timeout: .now() + 2), .success) }
      let unaryStartedAt = Date()
      let response = try session.send(request)
      XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(unaryStartedAt), 0.350)
      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(response.reasonCode, .completed)
      XCTAssertNotNil(response.result)
    }
  }

  func testStreamPreparationDispatchesBeforeUnaryCLIParsing() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      let service = fixture.service
      try service.start()
      defer { service.stop() }

      let identity = try DarwinCurrentControlCodeIdentity.inspect()
      let client = PersistentControlClient(
        socketPath: fixture.socketPath,
        serverTrustPolicy: PersistentControlServerTrustPolicy(
          pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
        )
      )
      let scope = CLIControlAuthorizationScope(
        projectIdentifier: HostwrightResourceUUID.legacy(
          kind: "project",
          identifier: "project-daemon-control-tests"
        ),
        resourceIdentifier: nil
      )
      let route = try CLIControlRoute.classify(arguments: [
        "events", "--state-db", fixture.statePath, "--project", "daemon-control-tests",
        "--watch", "--limit", "1", "--output", "json",
      ])
        .withWorkingDirectory(home.path)
        .withAuthorizationScope(scope)
      let request = ControlRequestEnvelope(
        requestID: "daemon-stream-prepare",
        operation: CLIControlStreamPreparationContract.operation,
        timeoutMilliseconds: 1_000,
        body: route.requestBody()
      )

      let response = try client.send(request)
      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(response.reasonCode, .completed)
      XCTAssertNotNil(response.result)
    }
  }

  func testPersistentPluginReadTraversesAuthenticationRBACAndAuditPipeline() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      try fixture.service.start()
      defer { fixture.service.stop() }
      let identity = try DarwinCurrentControlCodeIdentity.inspect()
      let client = PersistentControlClient(
        socketPath: fixture.socketPath,
        serverTrustPolicy: PersistentControlServerTrustPolicy(
          pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]))
      let request = ControlRequestEnvelope(
        requestID: "plugin-persistent-list", operation: "plugin.list",
        timeoutMilliseconds: 1_000, body: .object([:]))
      let response = try client.send(request)
      XCTAssertEqual(response.status, .completed)
      XCTAssertEqual(response.reasonCode, .completed)
      XCTAssertEqual(response.result, .array([]))

      let replay = try client.send(request)
      XCTAssertEqual(replay, response)
      let store = SQLiteStateStore(path: fixture.statePath)
      let auditCount = try store.withConnection(createIfNeeded: false, readOnly: true) {
        try $0.query(
          "SELECT COUNT(*) FROM audit_records WHERE request_id = ?",
          bindings: [.text(request.requestID)]).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
      }
      XCTAssertGreaterThanOrEqual(auditCount, 1)
      XCTAssertNil(try ControlRequestRepository(store: store).load(request.requestID))
    }
  }

  func testPersistentPluginUninstallPersistsTerminalStateAndReplaysIdempotently() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      let resolution = try HostwrightLocalPathResolver.resolve(
        homeDirectory: home.path,
        environment: [:]
      )
      let store = SQLiteStateStore(path: fixture.statePath)
      let seeded = try seedStagedPluginPackage(
        home: home,
        applicationSupportDirectory: resolution.layout.applicationSupportDirectory,
        repository: store.plugins
      )

      try fixture.service.start()
      defer { fixture.service.stop() }

      let identity = try DarwinCurrentControlCodeIdentity.inspect()
      let client = PersistentControlClient(
        socketPath: fixture.socketPath,
        serverTrustPolicy: PersistentControlServerTrustPolicy(
          pinnedAdHocCodeDirectoryHashes: [identity.codeDirectoryHash]
        )
      )
      let session = try client.connectSession()
      defer { session.close() }
      let request = ControlRequestEnvelope(
        requestID: "plugin-persistent-uninstall",
        operation: "plugin.uninstall",
        timeoutMilliseconds: 1_000,
        idempotencyKey: "plugin-persistent-uninstall-key",
        body: .object([
          "packageDigest": .string(seeded.packageDigest),
          "expectedGeneration": .integer(Int64(seeded.generation)),
        ])
      )

      let first = try session.send(request)
      XCTAssertEqual(first.status, .completed)
      XCTAssertEqual(first.reasonCode, .completed)
      XCTAssertNotNil(first.operationRef)

      let replay = try session.send(request)
      XCTAssertEqual(replay, first)

      let terminal = try XCTUnwrap(store.plugins.package(digest: seeded.packageDigest))
      XCTAssertEqual(terminal.lifecycleState, .uninstalled)
      XCTAssertEqual(terminal.generation, seeded.generation + 1)
      XCTAssertEqual(terminal.ownershipLedger, seeded.ownershipLedger)
      XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.storagePath))
      XCTAssertNil(try store.plugins.activation(identifier: terminal.manifest.identifier))
      XCTAssertEqual(
        try store.plugins.rollback(operationID: request.requestID)?.status,
        "succeeded"
      )
      XCTAssertEqual(
        try store.plugins.rollback(operationID: request.requestID)?.stage,
        "complete"
      )

      let requests = ControlRequestRepository(store: store)
      let persisted = try XCTUnwrap(try requests.load(request.requestID))
      XCTAssertEqual(persisted.status, .completed)
      XCTAssertEqual(persisted.operationReference, first.operationRef)
      XCTAssertEqual(
        try requests.load(
          subjectID: "daemon-control-test-owner",
          idempotencyKey: "plugin-persistent-uninstall-key"
        ),
        persisted
      )

      let auditEvents = try store.withConnection(createIfNeeded: false, readOnly: true) {
        try $0.query(
          "SELECT action, outcome, reason_code FROM audit_records WHERE request_id = ? ORDER BY sequence",
          bindings: [.text(request.requestID)]
        )
      }
      XCTAssertTrue(auditEvents.contains(["authorization", "allow", "authorization.allowed"]))
      XCTAssertTrue(auditEvents.contains(["admission", "allowed", "admission.allowed"]))
      XCTAssertTrue(auditEvents.contains(["request", "accepted", "accepted"]))
      XCTAssertTrue(auditEvents.contains(["operation", "completed", "completed"]))
    }
  }

  func testInterruptedUnaryRecoveryRetriesAuditBeforeTerminalState() throws {
    try withPrivateHome { home in
      let store = SQLiteStateStore(path: home.appendingPathComponent("state.sqlite").path)
      try store.migrate()
      try store.controlIdentities.bootstrap(ControlPeerIdentityRecord(
        subjectID: "recovery-owner",
        userID: UInt32(geteuid()),
        codeIdentity: CodeIdentity(
          signingIdentifier: "recovery-owner",
          codeDirectoryHash: String(repeating: "a", count: 40),
          validationMode: .pinnedAdHoc
        ),
        declaredBySubjectID: "recovery-owner",
        declaredAt: "2026-08-02T00:00:00Z",
        updatedAt: "2026-08-02T00:00:00Z"
      ))
      let repository = ControlRequestRepository(store: store)
      _ = try repository.record(ControlRequestSubmission(
        request: ControlRequestRecord(
          requestID: "restart-recovery-request",
          subjectID: "recovery-owner",
          idempotencyKey: "restart-recovery-key",
          requestDigestSHA256: String(repeating: "b", count: 64),
          status: .accepted,
          operationReference: "unary:" + String(repeating: "c", count: 64),
          createdAt: "2026-08-02T00:00:00Z",
          updatedAt: "2026-08-02T00:00:00Z"
        ),
        idempotencyExpiresAt: "2026-08-03T00:00:00Z"
      ))
      let recorder = FailOnceAuditRecorder()
      let now = { Date(timeIntervalSince1970: 1_785_715_200) }

      XCTAssertThrowsError(try HostwrightDaemonControlService.recoverInterruptedUnaryRequests(
        repository: repository,
        auditRecorder: recorder,
        now: now
      ))
      XCTAssertEqual(try repository.load("restart-recovery-request")?.status, .accepted)

      XCTAssertEqual(try HostwrightDaemonControlService.recoverInterruptedUnaryRequests(
        repository: repository,
        auditRecorder: recorder,
        now: now
      ), 1)
      XCTAssertEqual(try repository.load("restart-recovery-request")?.status, .error)
      XCTAssertEqual(recorder.recordedEvents.count, 1)
      XCTAssertEqual(recorder.recordedEvents.first?.reasonCode, "operation.interrupted-by-daemon-restart")
    }
  }

  func testStopPreservesSocketThatReplacedTheOwnedInode() throws {
    try withPrivateHome { home in
      let fixture = try makeService(home: home)
      let service = fixture.service
      try service.start()
      defer { service.stop() }

      var owned = stat()
      XCTAssertEqual(lstat(fixture.socketPath, &owned), 0)
      XCTAssertEqual(unlink(fixture.socketPath), 0)
      let replacement = try bindSocket(at: fixture.socketPath)
      defer {
        _ = Darwin.close(replacement)
        _ = unlink(fixture.socketPath)
      }

      service.stop()

      var retained = stat()
      XCTAssertEqual(lstat(fixture.socketPath, &retained), 0)
      XCTAssertEqual(retained.st_mode & S_IFMT, S_IFSOCK)
      XCTAssertNotEqual(UInt64(retained.st_ino), UInt64(owned.st_ino))
    }
  }

  private func makeService(home: URL, explicitStateName: String? = nil) throws -> (
    service: any DaemonControlServing,
    socketPath: String,
    statePath: String,
    accessLockPath: String
  ) {
    let defaultResolution = try HostwrightLocalPathResolver.resolve(
      homeDirectory: home.path,
      environment: [:]
    )
    let resolution: HostwrightLocalPathResolution
    if let explicitStateName {
      resolution = try HostwrightLocalPathResolver.resolve(
        explicitStateDatabasePath: URL(
          fileURLWithPath: defaultResolution.layout.stateDirectory,
          isDirectory: true
        ).appendingPathComponent(explicitStateName).path,
        homeDirectory: home.path,
        environment: [:]
      )
    } else {
      resolution = defaultResolution
    }
    if explicitStateName != nil {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: resolution.layout.stateDirectory, isDirectory: true),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      XCTAssertEqual(chmod(resolution.layout.applicationSupportDirectory, 0o700), 0)
      XCTAssertEqual(chmod(resolution.layout.stateDirectory, 0o700), 0)
    }
    let stateConfiguration = StateStoreConfiguration(localPathResolution: resolution)
    try stateConfiguration.prepareRuntimeSupport()
    let store = SQLiteStateStore(configuration: stateConfiguration)
    try store.migrate()
    let identity = try DarwinCurrentControlCodeIdentity.inspect()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "daemon-control-test-owner",
        userID: UInt32(geteuid()),
        codeIdentity: identity,
        declaredBySubjectID: "daemon-control-test-owner",
        declaredAt: "2026-08-02T00:00:00Z",
        updatedAt: "2026-08-02T00:00:00Z"
      )
    )
    try store.rbac.bootstrapDefaultRolesAndOwner(
      subjectID: "daemon-control-test-owner",
      timestamp: "2026-08-02T00:00:00Z"
    )
    let configPath = home.appendingPathComponent("hostwright.yaml")
    try Data("version: 2\nproject: daemon-control-tests\nservices: {}\n".utf8).write(to: configPath)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
    let configuration = DaemonConfiguration(
      configPath: configPath.path,
      stateStoreConfiguration: stateConfiguration,
      lockFilePath: resolution.layout.daemonLock,
      maxIterations: 1
    )
    return (
      try HostwrightDaemonControlService.make(configuration: configuration),
      resolution.layout.controlSocket,
      resolution.stateDatabasePath,
      try stateConfiguration.maintenancePaths().accessLockPath
    )
  }

  private func bindSocket(at path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw POSIXError(.ENFILE)
    }
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      _ = Darwin.close(descriptor)
      throw POSIXError(.ENAMETOOLONG)
    }
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.initializeMemory(as: UInt8.self, repeating: 0)
      destination.copyBytes(from: bytes)
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        )
      }
    }
    guard result == 0, chmod(path, 0o600) == 0 else {
      _ = Darwin.close(descriptor)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
  }

  private func seedStagedPluginPackage(
    home: URL,
    applicationSupportDirectory: String,
    repository: PluginLifecycleRepository
  ) throws -> PluginPackageRecord {
    let content = Data("persistent plugin fixture".utf8)
    let contentDigests = [PluginContentDigest(path: "plugin.wasm", digest: pluginDigest(content))]
    let packageDigest = pluginDigest(try ControlPlaneCanonicalJSON.encode(
      PluginContentIndexFixture(schemaVersion: 1, contentDigests: contentDigests)
    ))
    let manifest = PluginPackageManifest(
      identifier: "dev.hostwright.persistent-plugin",
      packageVersion: "1.0.0",
      hostwrightCompatibility: ">=0.0.2,<0.0.3",
      providerKind: .wasi,
      entrypoint: "plugin.wasm",
      grants: [PluginGrant(capability: .diagnostics, scope: "read")],
      artifactDigest: contentDigests[0].digest,
      contentDigests: contentDigests,
      provenance: PluginProvenance(
        checksum: packageDigest,
        signature: "persistent-fixture-signature",
        signerIdentifier: "dev.hostwright.persistent-plugin-signer",
        source: PluginSource(kind: .localDirectory, locator: home.appendingPathComponent("source").path)
      ),
      cmsSignature: "persistent-fixture-signature",
      signerIdentifier: "dev.hostwright.persistent-plugin-signer"
    )
    let manifestData = try ControlPlaneCanonicalJSON.encode(manifest)
    let pluginRootURL = URL(
      fileURLWithPath: applicationSupportDirectory,
      isDirectory: true
    )
      .appendingPathComponent("plugins-v1", isDirectory: true)
    if mkdir(pluginRootURL.path, 0o700) != 0, errno != EEXIST {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let packagesURL = pluginRootURL.appendingPathComponent("packages", isDirectory: true)
    if mkdir(packagesURL.path, 0o700) != 0, errno != EEXIST {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let packageURL = packagesURL
      .appendingPathComponent(String(packageDigest.dropFirst("sha256:".count)), isDirectory: true)
    try FileManager.default.createDirectory(
      at: packageURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let contentURL = packageURL.appendingPathComponent("plugin.wasm")
    try manifestData.write(to: manifestURL)
    try content.write(to: contentURL)
    XCTAssertEqual(chmod(manifestURL.path, 0o400), 0)
    XCTAssertEqual(chmod(contentURL.path, 0o400), 0)

    let ledger = try [
      pluginOwnedArtifact(at: packageURL, kind: .directory),
      pluginOwnedArtifact(at: manifestURL, kind: .file, digest: pluginDigest(manifestData)),
      pluginOwnedArtifact(at: contentURL, kind: .file, digest: pluginDigest(content)),
    ]
    let record = try PluginPackageRecord(
      packageDigest: packageDigest,
      manifest: manifest,
      storagePath: packageURL.path,
      ownershipLedger: ledger,
      lifecycleState: .staged,
      createdBySubjectID: "daemon-control-test-owner",
      createdAt: "2026-08-04T00:00:00Z",
      updatedAt: "2026-08-04T00:00:00Z"
    )
    return try repository.persistVerifiedPackage(record)
  }

  private func pluginOwnedArtifact(
    at url: URL,
    kind: PluginOwnedArtifactKind,
    digest: String? = nil
  ) throws -> PluginOwnedArtifact {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return try PluginOwnedArtifact(
      path: url.path,
      kind: kind,
      deviceID: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      sha256Digest: digest
    )
  }

  private func withPrivateHome(_ body: (URL) throws -> Void) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "hwds-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: home) }
    try body(home)
  }
}

private struct PluginContentIndexFixture: Encodable {
  let schemaVersion: Int
  let contentDigests: [PluginContentDigest]
}

private func pluginDigest(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private final class FailOnceAuditRecorder: ControlSecurityAuditRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  private var events: [ControlSecurityAuditEvent] = []

  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    lock.lock()
    defer { lock.unlock() }
    attempts += 1
    if attempts == 1 { throw POSIXError(.EIO) }
    events.append(event)
    return AuditRecord(
      identifier: "restart-recovery-audit",
      segmentID: "segment",
      sequence: UInt64(events.count),
      timestamp: Date(timeIntervalSince1970: 1_785_715_200),
      previousDigest: nil,
      subjectID: event.subjectID,
      requestID: event.requestID,
      target: event.target,
      action: event.action,
      outcome: event.outcome,
      reasonCode: event.reasonCode,
      operationRef: event.operationRef,
      payloadDigest: event.payloadDigest,
      recordDigest: "sha256:" + String(repeating: "d", count: 64),
      signingKeyID: "test-key"
    )
  }

  var recordedEvents: [ControlSecurityAuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}
