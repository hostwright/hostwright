import Darwin
import Foundation
import HostwrightNetworking
import Security
import XCTest

@testable import HostwrightNetworkHelperCore

/// Attended Gate 8 evidence against an already-running disposable Tahoe VM.
///
/// The VM is only a LAN client. The listener, certificate, persisted intent,
/// restart recovery, and cleanup all use Hostwright's production helper
/// components.
final class Phase07LANExposureLiveTests: XCTestCase {
  private static let liveFlag =
    "HOSTWRIGHT_PHASE07_GATE08_LAN_LIVE"

  func testExplicitLANPolicyServesTahoeVMAndFailsClosed()
    throws
  {
    let environment = ProcessInfo.processInfo.environment
    guard environment[Self.liveFlag] == "1" else {
      throw XCTSkip(
        "Set \(Self.liveFlag)=1 only for the attended Tahoe LAN evidence lane."
      )
    }
    let tart = try required(
      "HOSTWRIGHT_PHASE07_GATE08_TART",
      environment
    )
    let tartHome = try required(
      "HOSTWRIGHT_PHASE07_GATE08_TART_HOME",
      environment
    )
    let vmName = try required(
      "HOSTWRIGHT_PHASE07_GATE08_VM",
      environment
    )
    let workRoot = URL(
      fileURLWithPath: try required(
        "HOSTWRIGHT_PHASE07_GATE08_WORK_ROOT",
        environment
      ),
      isDirectory: true
    ).standardizedFileURL
    guard
      workRoot.path.hasPrefix(
        "/Volumes/T9/hostwright/qualification/phase07-gate08"
      )
    else {
      throw Gate08LiveError.invalidEnvironment
    }

    let hostEnvironment = try NetworkHostEnvironmentProbe.current(
      localNetworkPermission: .granted
    )
    let selected = try XCTUnwrap(
      hostEnvironment.addresses.first {
        $0.interfaceName == hostEnvironment.primaryInterface && $0.family == .ipv4
          && $0.networkClass == .privateLAN && !$0.isLoopback
      }
    )
    let exposure = HostwrightPortExposurePolicy(
      scope: .lan,
      interfaces: [selected.interfaceName],
      networkClasses: [selected.networkClass],
      allowedCIDRs: [selected.cidr],
      authentication: .tls
    )
    let allowed = NetworkExposureEnvironmentEvaluator.evaluate(
      policy: exposure,
      bindAddress: selected.address,
      environment: hostEnvironment
    )
    XCTAssertTrue(allowed.isAllowed)
    XCTAssertEqual(allowed.selectedAddress, selected)
    XCTAssertEqual(
      NetworkExposureEnvironmentEvaluator.transition(
        previous: nil,
        current: allowed
      ),
      .activate
    )

    let appleInventoryBefore = try appleRuntimeInventory()
    let selectedInterfaceBefore = selected
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: workRoot,
      withIntermediateDirectories: true,
      attributes: [
        .posixPermissions: NSNumber(value: Int16(0o700))
      ]
    )
    try fileManager.setAttributes(
      [
        .posixPermissions:
          NSNumber(value: Int16(0o700))
      ],
      ofItemAtPath: workRoot.path
    )
    let stateRoot = workRoot.appendingPathComponent(
      "helper-state",
      isDirectory: true
    )
    let caURL = workRoot.appendingPathComponent(
      "gate08-ca.pem",
      isDirectory: false
    )
    let projectUUID = UUID().uuidString.lowercased()
    let dnsUUID = UUID().uuidString.lowercased()
    let identity = NetworkHelperDNSIdentity(
      projectUUID: projectUUID,
      dnsUUID: dnsUUID,
      generation: 1,
      fencingToken: UUID().uuidString.lowercased()
    )
    let hostname = "gate08.hostwright.internal"
    let backend = try Gate08Backend(
      responseBody: "hostwright-gate08"
    )
    backend.start(expectedConnections: 2)
    defer { backend.stop() }

    let ingressPort = try availablePort(
      bindAddress: selected.address
    )
    let certificateBinding =
      ProjectCertificateRequestBinding(
        name: "gate08-tls",
        certificateUUID:
          UUID().uuidString.lowercased(),
        source: .localCA,
        renewBeforeSeconds: 3_600,
        validitySeconds: 86_400,
        statusPolicy: .ifAvailable,
        dnsNames: [hostname]
      )
    let ingressBinding =
      ProjectIngressListenerBinding(
        name: "gate08",
        bindAddress: selected.address,
        port: ingressPort,
        exposure: exposure,
        certificate: certificateBinding.name,
        routes: [
          ProjectIngressRouteBinding(
            hostname: hostname,
            pathPrefix: "/v1",
            methods: ["GET"],
            protocolName: .http,
            targetServiceName: "gate08",
            targetServiceUUIDs: [projectUUID],
            targetPort: backend.port,
            backends: [
              ProjectIngressBackend(
                serviceUUID: projectUUID,
                address: "127.0.0.1",
                port: backend.port
              )
            ]
          )
        ]
      )

    let absent = try guestRequest(
      tart: tart,
      tartHome: tartHome,
      vmName: vmName,
      hostname: hostname,
      address: selected.address,
      port: ingressPort,
      caGuestPath: nil
    )
    XCTAssertNotEqual(absent.status, 0)

    let store = try NetworkHelperStateStore(
      rootURL: stateRoot
    )
    let firstIngress = NetworkHelperIngressBroker()
    let firstCertificates =
      NetworkHelperCertificateCoordinator()
    var dispatcher = NetworkHelperDispatcher(
      store: store,
      ingressBroker: firstIngress,
      certificateCoordinator: firstCertificates
    )
    var removed = false
    defer {
      if !removed {
        _ = try? dispatch(
          dispatcher,
          NetworkHelperRequest(
            operation: .remove,
            identity: identity
          )
        )
      }
      try? fileManager.removeItem(at: caURL)
      try? fileManager.removeItem(at: stateRoot)
    }

    let applied = try dispatch(
      dispatcher,
      NetworkHelperRequest(
        operation: .apply,
        identity: identity,
        corefile: corefile(projectUUID: projectUUID),
        ingressBindings: [ingressBinding],
        certificateBindings: [certificateBinding]
      )
    )
    XCTAssertNil(applied.error)
    XCTAssertEqual(applied.status?.disposition, .active)
    XCTAssertEqual(applied.status?.ingressActive, true)
    XCTAssertEqual(applied.status?.certificateActive, true)
    let firstHandle = try XCTUnwrap(
      firstCertificates.activation(
        identity: identity
      )?.identities[certificateBinding.name]
    )
    let trustAnchor = try XCTUnwrap(
      firstHandle.certificateChain.last
    )
    try writePEM(trustAnchor, to: caURL)

    let firstResponse = try guestRequest(
      tart: tart,
      tartHome: tartHome,
      vmName: vmName,
      hostname: hostname,
      address: selected.address,
      port: ingressPort,
      caGuestPath:
        "/Volumes/My Shared Files/gate08/"
        + caURL.lastPathComponent
    )
    XCTAssertEqual(firstResponse.status, 0, firstResponse.stderr)
    XCTAssertEqual(firstResponse.stdout, "hostwright-gate08")
    XCTAssertThrowsError(
      try connect(
        address: "127.0.0.1",
        port: ingressPort
      )
    )

    firstIngress.remove(identity: identity)
    firstCertificates.deactivate(identity: identity)
    let restartedIngress = NetworkHelperIngressBroker()
    let restartedCertificates =
      NetworkHelperCertificateCoordinator()
    dispatcher = NetworkHelperDispatcher(
      store: store,
      ingressBroker: restartedIngress,
      certificateCoordinator: restartedCertificates
    )
    let recovered = try dispatch(
      dispatcher,
      NetworkHelperRequest(
        operation: .status,
        identity: identity
      )
    )
    XCTAssertNil(recovered.error)
    XCTAssertEqual(recovered.status?.ingressActive, true)
    XCTAssertEqual(recovered.status?.certificateActive, true)
    let secondResponse = try guestRequest(
      tart: tart,
      tartHome: tartHome,
      vmName: vmName,
      hostname: hostname,
      address: selected.address,
      port: ingressPort,
      caGuestPath:
        "/Volumes/My Shared Files/gate08/"
        + caURL.lastPathComponent
    )
    XCTAssertEqual(secondResponse.status, 0, secondResponse.stderr)
    XCTAssertEqual(secondResponse.stdout, "hostwright-gate08")

    let denied = NetworkHostEnvironmentSnapshot(
      addresses: hostEnvironment.addresses,
      primaryInterface: hostEnvironment.primaryInterface,
      defaultRouter: hostEnvironment.defaultRouter,
      vpnState: hostEnvironment.vpnState,
      privateRelayState:
        hostEnvironment.privateRelayState,
      localNetworkPermission: .denied
    )
    let deniedEvaluation =
      NetworkExposureEnvironmentEvaluator.evaluate(
        policy: exposure,
        bindAddress: selected.address,
        environment: denied
      )
    XCTAssertFalse(deniedEvaluation.isAllowed)
    XCTAssertTrue(
      deniedEvaluation.issues.contains(
        .localNetworkPermissionNotGranted
      )
    )

    let missingInterface = NetworkHostEnvironmentSnapshot(
      addresses: hostEnvironment.addresses.filter {
        $0 != selected
      },
      primaryInterface: nil,
      defaultRouter: hostEnvironment.defaultRouter,
      vpnState: hostEnvironment.vpnState,
      privateRelayState:
        hostEnvironment.privateRelayState,
      localNetworkPermission: .granted
    )
    let changed = NetworkExposureEnvironmentEvaluator.evaluate(
      policy: exposure,
      bindAddress: selected.address,
      environment: missingInterface
    )
    XCTAssertNotEqual(
      allowed.environmentFingerprint,
      changed.environmentFingerprint
    )
    XCTAssertEqual(
      NetworkExposureEnvironmentEvaluator.transition(
        previous: allowed,
        current: changed
      ),
      .drainAndStop
    )

    let removeResponse = try dispatch(
      dispatcher,
      NetworkHelperRequest(
        operation: .remove,
        identity: identity
      )
    )
    XCTAssertNil(removeResponse.error)
    XCTAssertEqual(
      removeResponse.status?.disposition,
      .absent
    )
    removed = true
    XCTAssertFalse(restartedIngress.hasActiveBindings)
    XCTAssertFalse(
      restartedCertificates.hasActiveCertificates
    )
    XCTAssertTrue(
      try store.activeIngressConfigurations().isEmpty
    )
    XCTAssertTrue(
      try store.activeCertificateConfigurations().isEmpty
    )

    let drained = try guestRequest(
      tart: tart,
      tartHome: tartHome,
      vmName: vmName,
      hostname: hostname,
      address: selected.address,
      port: ingressPort,
      caGuestPath:
        "/Volumes/My Shared Files/gate08/"
        + caURL.lastPathComponent
    )
    XCTAssertNotEqual(drained.status, 0)

    let interfaceAfter = try XCTUnwrap(
      NetworkHostEnvironmentProbe.current(
        localNetworkPermission: .granted
      ).addresses.first {
        $0.interfaceName == selectedInterfaceBefore.interfaceName
          && $0.address == selectedInterfaceBefore.address
      }
    )
    XCTAssertEqual(interfaceAfter, selectedInterfaceBefore)
    XCTAssertEqual(
      try appleRuntimeInventory(),
      appleInventoryBefore
    )
  }

  private func dispatch(
    _ dispatcher: NetworkHelperDispatcher,
    _ request: NetworkHelperRequest
  ) throws -> NetworkHelperResponse {
    try NetworkHelperCanonicalJSON.decodeFrame(
      NetworkHelperResponse.self,
      from: dispatcher.dispatch(
        frame: try NetworkHelperCanonicalJSON.frame(
          request
        )
      )
    )
  }

  private func corefile(projectUUID: String) -> String {
    """
    \(projectUUID).hostwright.internal {
        cache 5
        hosts {
            192.0.2.10 api.\(projectUUID).hostwright.internal
            fallthrough
        }
    }
    """
  }

  private func required(
    _ key: String,
    _ environment: [String: String]
  ) throws -> String {
    guard let value = environment[key], !value.isEmpty else {
      throw XCTSkip(
        "Missing attended Gate 8 input: \(key)"
      )
    }
    return value
  }

  private func guestRequest(
    tart: String,
    tartHome: String,
    vmName: String,
    hostname: String,
    address: String,
    port: Int,
    caGuestPath: String?
  ) throws -> Gate08ProcessResult {
    var arguments = [
      "exec",
      vmName,
      "/usr/bin/curl",
      "--fail",
      "--silent",
      "--show-error",
      "--connect-timeout",
      "2",
      "--max-time",
      "5",
      "--resolve",
      "\(hostname):\(port):\(address)",
    ]
    if let caGuestPath {
      arguments += ["--cacert", caGuestPath]
    } else {
      arguments.append("--insecure")
    }
    arguments.append("https://\(hostname):\(port)/v1")
    return try run(
      executable: tart,
      arguments: arguments,
      environment: ["TART_HOME": tartHome],
      timeoutSeconds: 15
    )
  }

  private func appleRuntimeInventory() throws -> Data {
    let executable = "/usr/local/bin/container"
    let containers = try run(
      executable: executable,
      arguments: ["list", "--format", "json"],
      timeoutSeconds: 10
    )
    let networks = try run(
      executable: executable,
      arguments: ["network", "list", "--format", "json"],
      timeoutSeconds: 10
    )
    guard containers.status == 0, networks.status == 0,
      let containerData = containers.stdout.data(
        using: .utf8
      ),
      let networkData = networks.stdout.data(
        using: .utf8
      )
    else {
      throw Gate08LiveError.runtimeInventoryUnavailable
    }
    let object: [String: Any] = [
      "containers":
        try JSONSerialization.jsonObject(
          with: containerData
        ),
      "networks":
        try JSONSerialization.jsonObject(
          with: networkData
        ),
    ]
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
  }

  private func run(
    executable: String,
    arguments: [String],
    environment additions: [String: String] = [:],
    timeoutSeconds: TimeInterval
  ) throws -> Gate08ProcessResult {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(additions) { _, added in added }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning, Date() < deadline {
      usleep(20_000)
    }
    if process.isRunning {
      process.terminate()
      let terminateDeadline = Date().addingTimeInterval(1)
      while process.isRunning, Date() < terminateDeadline {
        usleep(20_000)
      }
    }
    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
    let stdout = output.fileHandleForReading
      .readDataToEndOfFile()
    let stderr = error.fileHandleForReading
      .readDataToEndOfFile()
    guard stdout.count <= 1 * 1_024 * 1_024,
      stderr.count <= 1 * 1_024 * 1_024
    else {
      throw Gate08LiveError.outputLimit
    }
    return Gate08ProcessResult(
      status: process.terminationStatus,
      stdout: String(decoding: stdout, as: UTF8.self),
      stderr: String(decoding: stderr, as: UTF8.self)
    )
  }

  private func writePEM(
    _ certificate: SecCertificate,
    to url: URL
  ) throws {
    let body = (SecCertificateCopyData(certificate) as Data)
      .base64EncodedString(
        options: [.lineLength64Characters]
      )
    let pem =
      "-----BEGIN CERTIFICATE-----\n"
      + body
      + "\n-----END CERTIFICATE-----\n"
    try Data(pem.utf8).write(
      to: url,
      options: [.atomic]
    )
  }

  private func availablePort(
    bindAddress: String
  ) throws -> Int {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw Gate08LiveError.socketFailure
    }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(
      MemoryLayout<sockaddr_in>.size
    )
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard
      inet_pton(
        AF_INET,
        bindAddress,
        &address.sin_addr
      ) == 1
    else {
      throw Gate08LiveError.socketFailure
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(
        to: sockaddr.self,
        capacity: 1
      ) {
        Darwin.bind(
          descriptor,
          $0,
          socklen_t(
            MemoryLayout<sockaddr_in>.size
          )
        )
      }
    }
    guard bound == 0 else {
      throw Gate08LiveError.socketFailure
    }
    var result = sockaddr_in()
    var length = socklen_t(
      MemoryLayout<sockaddr_in>.size
    )
    let status = withUnsafeMutablePointer(to: &result) {
      $0.withMemoryRebound(
        to: sockaddr.self,
        capacity: 1
      ) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard status == 0 else {
      throw Gate08LiveError.socketFailure
    }
    return Int(UInt16(bigEndian: result.sin_port))
  }

  private func connect(
    address: String,
    port: Int
  ) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw Gate08LiveError.socketFailure
    }
    var endpoint = sockaddr_in()
    endpoint.sin_len = UInt8(
      MemoryLayout<sockaddr_in>.size
    )
    endpoint.sin_family = sa_family_t(AF_INET)
    endpoint.sin_port = in_port_t(port).bigEndian
    guard
      inet_pton(
        AF_INET,
        address,
        &endpoint.sin_addr
      ) == 1
    else {
      Darwin.close(descriptor)
      throw Gate08LiveError.socketFailure
    }
    let result = withUnsafePointer(to: &endpoint) {
      $0.withMemoryRebound(
        to: sockaddr.self,
        capacity: 1
      ) {
        Darwin.connect(
          descriptor,
          $0,
          socklen_t(
            MemoryLayout<sockaddr_in>.size
          )
        )
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw Gate08LiveError.socketFailure
    }
    return descriptor
  }
}

private struct Gate08ProcessResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

private enum Gate08LiveError: Error {
  case invalidEnvironment
  case outputLimit
  case runtimeInventoryUnavailable
  case socketFailure
}

private final class Gate08Backend: @unchecked Sendable {
  let port: Int

  private let descriptor: Int32
  private let response: Data
  private let lock = NSLock()
  private let finished = DispatchGroup()
  private var closed = false

  init(responseBody: String) throws {
    let socketDescriptor = Darwin.socket(
      AF_INET,
      SOCK_STREAM,
      0
    )
    guard socketDescriptor >= 0 else {
      throw Gate08LiveError.socketFailure
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(
      MemoryLayout<sockaddr_in>.size
    )
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr =
      in_addr_t(
        INADDR_LOOPBACK
      ).bigEndian
    let status = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(
        to: sockaddr.self,
        capacity: 1
      ) {
        Darwin.bind(
          socketDescriptor,
          $0,
          socklen_t(
            MemoryLayout<sockaddr_in>.size
          )
        )
      }
    }
    guard status == 0,
      Darwin.listen(socketDescriptor, 4) == 0
    else {
      Darwin.close(socketDescriptor)
      throw Gate08LiveError.socketFailure
    }
    var bound = sockaddr_in()
    var length = socklen_t(
      MemoryLayout<sockaddr_in>.size
    )
    let queried = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(
        to: sockaddr.self,
        capacity: 1
      ) {
        getsockname(
          socketDescriptor,
          $0,
          &length
        )
      }
    }
    guard queried == 0 else {
      Darwin.close(socketDescriptor)
      throw Gate08LiveError.socketFailure
    }
    let selectedPort = Int(
      UInt16(bigEndian: bound.sin_port)
    )
    let wire =
      "HTTP/1.1 200 OK\r\n"
      + "content-length: \(responseBody.utf8.count)\r\n"
      + "connection: close\r\n\r\n"
      + responseBody
    descriptor = socketDescriptor
    port = selectedPort
    response = Data(wire.utf8)
  }

  func start(expectedConnections: Int) {
    finished.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      [self] in
      defer { finished.leave() }
      for _ in 0..<expectedConnections {
        let client = Darwin.accept(
          descriptor,
          nil,
          nil
        )
        guard client >= 0 else { return }
        _ = receiveHeaders(client)
        response.withUnsafeBytes { buffer in
          guard let base = buffer.baseAddress else {
            return
          }
          var offset = 0
          while offset < buffer.count {
            let count = Darwin.send(
              client,
              base.advanced(by: offset),
              buffer.count - offset,
              0
            )
            guard count > 0 else { return }
            offset += count
          }
        }
        Darwin.close(client)
      }
    }
  }

  func stop() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
    lock.unlock()
    _ = finished.wait(timeout: .now() + 2)
  }

  private func receiveHeaders(_ client: Int32) -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while result.count < 64 * 1_024 {
      let count = Darwin.recv(
        client,
        &buffer,
        buffer.count,
        0
      )
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return result }
      result.append(contentsOf: buffer[0..<count])
      if result.range(
        of: Data("\r\n\r\n".utf8)
      ) != nil {
        return result
      }
    }
    return result
  }
}
