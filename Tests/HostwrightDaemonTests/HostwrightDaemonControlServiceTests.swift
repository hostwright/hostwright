import Darwin
import Foundation
import XCTest
@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightControlTransport
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

  private func makeService(home: URL) throws -> (service: any DaemonControlServing, socketPath: String) {
    let resolution = try HostwrightLocalPathResolver.resolve(
      homeDirectory: home.path,
      environment: [:]
    )
    let stateConfiguration = StateStoreConfiguration(localPathResolution: resolution)
    let store = SQLiteStateStore(configuration: stateConfiguration)
    try store.migrate()
    try stateConfiguration.prepareRuntimeSupport()
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
    let configPath = home.appendingPathComponent("hostwright.yaml")
    try Data("version: 2\nproject: daemon-control-tests\nservices: {}\n".utf8).write(to: configPath)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
    let configuration = DaemonConfiguration(
      configPath: configPath.path,
      stateStoreConfiguration: stateConfiguration,
      lockFilePath: resolution.layout.daemonLock,
      maxIterations: 1
    )
    return (try HostwrightDaemonControlService.make(configuration: configuration), resolution.layout.controlSocket)
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
