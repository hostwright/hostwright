import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import WASI
import WasmKit
import WasmKitWASI

public enum WASIProviderRuntimeError: Error, Equatable, Sendable {
  case invalidModule
  case invalidInvocation
  case missingGrant
  case workerUnavailable
  case executionFailed
  case timedOut
  case cancelled
  case outputLimitExceeded
  case invalidResult
}

public struct WASIProviderExecution: Sendable {
  public let moduleURL: URL
  public let expectedModuleDigest: String
  public let invocation: PluginInvocation
  public let grants: [PluginGrant]

  public init(
    moduleURL: URL, expectedModuleDigest: String, invocation: PluginInvocation,
    grants: [PluginGrant]
  ) {
    self.moduleURL = moduleURL
    self.expectedModuleDigest = expectedModuleDigest
    self.invocation = invocation
    self.grants = grants
  }
}

public struct WASIProviderHostExecutor: Sendable {
  public static let workerExecutableName = "hostwright-wasi-provider-worker"
  private let workerExecutableURL: URL
  private let ownershipRecorder: WorkerOwnershipRecorder?

  public init(workerExecutableURL: URL? = nil, ownershipLedgerURL: URL? = nil) throws {
    ownershipRecorder = try ownershipLedgerURL.map(WorkerOwnershipRecorder.init)
    if let workerExecutableURL {
      self.workerExecutableURL = workerExecutableURL
      return
    }
    let candidate = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .deletingLastPathComponent().appendingPathComponent(Self.workerExecutableName)
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
      throw WASIProviderRuntimeError.workerUnavailable
    }
    self.workerExecutableURL = candidate
  }

  public func execute(_ request: WASIProviderExecution) async throws -> PluginResult {
    do { try request.invocation.validate() } catch { throw WASIProviderRuntimeError.invalidInvocation }
    try request.grants.forEach { try $0.validate() }
    let invocationScope = try Self.scope(from: request.invocation.input)
    guard request.grants.contains(where: {
      $0.capability == request.invocation.capability && $0.scope == invocationScope
    }) else {
      throw WASIProviderRuntimeError.missingGrant
    }
    let seconds = request.invocation.timestamp.timeIntervalSince1970
    guard seconds.isFinite, seconds >= 0, seconds == seconds.rounded(.down) else {
      throw WASIProviderRuntimeError.invalidInvocation
    }
    let wholeSeconds = UInt64(seconds)
    let nanoseconds: UInt32 = 0
    let moduleDigest = try Self.validateModule(
      request.moduleURL, maximumBytes: request.invocation.limits.moduleBytes)
    guard moduleDigest == request.expectedModuleDigest else {
      throw WASIProviderRuntimeError.invalidModule
    }

    let invocationData = try Self.encode(request.invocation)
    guard invocationData.count <= request.invocation.limits.inputBytes else {
      throw WASIProviderRuntimeError.invalidInvocation
    }
    let workerIdentity: SecureExecutableIdentity
    do {
      workerIdentity = try SecureExecutableResolver.verify(path: workerExecutableURL.path)
    } catch {
      throw WASIProviderRuntimeError.workerUnavailable
    }
    let subprocess = SecureSubprocessRequest(
      executablePath: workerIdentity.path,
      arguments: [
        "--module", request.moduleURL.path,
        "--digest", request.expectedModuleDigest,
        "--wall-seconds", String(wholeSeconds),
        "--wall-nanoseconds", String(nanoseconds),
        "--seed", String(request.invocation.seed),
        "--memory-pages", String(request.invocation.limits.memoryBytes / 65_536),
      ],
      environment: SecureSubprocessEnvironment.minimal,
      workingDirectory: "/",
      standardInput: invocationData,
      timeoutMilliseconds: request.invocation.limits.normalExecutionMilliseconds,
      terminationGraceMilliseconds: 100,
      maximumStandardOutputBytes: request.invocation.limits.outputBytes,
      maximumStandardErrorBytes: WASISandboxContract.stderrMaximumBytes,
      maximumStandardInputBytes: request.invocation.limits.inputBytes)
    let execution: SecureSubprocessResult
    do {
      execution = try await SecureSubprocessRunner().runAsync(
        subprocess, expectedExecutable: workerIdentity,
        suspendedProcessValidator: { processID in
          try ownershipRecorder?.record(processID: processID, executable: workerIdentity)
        })
    } catch let error as SecureSubprocessError {
      switch error {
      case .timedOut: throw WASIProviderRuntimeError.timedOut
      case .cancelled: throw WASIProviderRuntimeError.cancelled
      case .outputLimitExceeded: throw WASIProviderRuntimeError.outputLimitExceeded
      default: throw WASIProviderRuntimeError.executionFailed
      }
    } catch {
      throw WASIProviderRuntimeError.executionFailed
    }
    guard execution.exitStatus == 0, execution.terminationSignal == nil,
      !execution.standardOutputTruncated, !execution.standardErrorTruncated,
      execution.standardError.count <= WASISandboxContract.stderrMaximumBytes
    else { throw WASIProviderRuntimeError.executionFailed }
    return try Self.decodeResult(
      execution.standardOutput, invocation: request.invocation, grants: request.grants)
  }

  private static func encode(_ invocation: PluginInvocation) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(invocation)
  }

  private static func validateModule(_ url: URL, maximumBytes: Int) throws -> String {
    let path = url.standardizedFileURL.path
    guard url.isFileURL, path == url.path, path.hasPrefix("/"), !path.contains("\0") else {
      throw WASIProviderRuntimeError.invalidModule
    }
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), (info.st_mode & 0o022) == 0,
      info.st_size > 0, info.st_size <= maximumBytes
    else { throw WASIProviderRuntimeError.invalidModule }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count == Int(info.st_size), data.count <= maximumBytes else {
      throw WASIProviderRuntimeError.invalidModule
    }
    return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  package static func decodeResult(
    _ data: Data, invocation: PluginInvocation, grants: [PluginGrant]
  ) throws -> PluginResult {
    guard !data.isEmpty, data.count <= invocation.limits.outputBytes,
      let result = try? JSONDecoder().decode(PluginResult.self, from: data),
      result.invocationID == invocation.invocationID,
      result.actions.count <= 128, result.diagnostics.count <= 128
    else { throw WASIProviderRuntimeError.invalidResult }
    let canonical = try ControlPlaneCanonicalJSON.encode(result)
    guard canonical == data else { throw WASIProviderRuntimeError.invalidResult }
    for diagnostic in result.diagnostics { try diagnostic.validate() }
    guard let invocationScope = try? Self.scope(from: invocation.input) else {
      throw WASIProviderRuntimeError.invalidResult
    }
    for action in result.actions {
      guard let actionScope = try? Self.scope(from: action.payload) else {
        throw WASIProviderRuntimeError.invalidResult
      }
      guard action.capability == invocation.capability,
        grants.contains(where: { $0.capability == action.capability && $0.scope == actionScope }),
        actionScope == invocationScope,
        Self.safeIdentifier(action.kind, maximumBytes: 128)
      else { throw WASIProviderRuntimeError.invalidResult }
      try Self.validateJSON(action.payload)
    }
    return result
  }

  private static func validateJSON(
    _ value: ControlPlaneJSONValue, depth: Int = 0, nodes: inout Int
  ) throws {
    guard depth <= 32 else { throw WASIProviderRuntimeError.invalidResult }
    nodes += 1
    guard nodes <= 16_384 else { throw WASIProviderRuntimeError.invalidResult }
    switch value {
    case .null, .bool, .integer: return
    case .number(let number): guard number.isFinite else { throw WASIProviderRuntimeError.invalidResult }
    case .string(let string): guard string.utf8.count <= 65_536 else { throw WASIProviderRuntimeError.invalidResult }
    case .array(let values):
      guard values.count <= 4_096 else { throw WASIProviderRuntimeError.invalidResult }
      for item in values { try validateJSON(item, depth: depth + 1, nodes: &nodes) }
    case .object(let values):
      guard values.count <= 4_096,
        values.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
      else { throw WASIProviderRuntimeError.invalidResult }
      for item in values.values { try validateJSON(item, depth: depth + 1, nodes: &nodes) }
    }
  }

  private static func validateJSON(_ value: ControlPlaneJSONValue) throws {
    var nodes = 0
    try validateJSON(value, nodes: &nodes)
  }

  private static func safeIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes && value.unicodeScalars.allSatisfy {
      (48...57).contains($0.value) || (65...90).contains($0.value)
        || (97...122).contains($0.value) || "-_.:".unicodeScalars.contains($0)
    }
  }

  private static func scope(from value: ControlPlaneJSONValue) throws -> String {
    guard case .object(let object) = value, case .string(let scope)? = object["scope"],
      !scope.isEmpty, scope.utf8.count <= 512,
      scope.unicodeScalars.allSatisfy({ (32...126).contains($0.value) })
    else { throw WASIProviderRuntimeError.invalidInvocation }
    return scope
  }
}

public enum WASIProviderModuleRuntime {
  public static func run(
    moduleBytes: Data, wallSeconds: UInt64, wallNanoseconds: UInt32, seed: UInt64,
    maximumMemoryPages: UInt64
  ) throws -> UInt32 {
    guard !moduleBytes.isEmpty, moduleBytes.count <= WASILimits.default.moduleBytes,
      wallNanoseconds < 1_000_000_000,
      (1...UInt64(WASILimits.default.memoryBytes / 65_536)).contains(maximumMemoryPages)
    else { throw WASIProviderRuntimeError.invalidModule }
    try validateResourceDeclarations(moduleBytes, maximumPages: maximumMemoryPages)
    let module = try parseWasm(bytes: Array(moduleBytes))
    for item in module.imports {
      guard item.module == "wasi_snapshot_preview1" else {
        throw WASIProviderRuntimeError.invalidModule
      }
      guard case .function = item.descriptor else {
        throw WASIProviderRuntimeError.invalidModule
      }
    }
    let engine = Engine(configuration: EngineConfiguration(
      threadingModel: .direct, compilationMode: .lazy, stackSize: 512 * 1_024,
      memoryBoundsChecking: .software))
    let store = Store(engine: engine)
    let wasi = try WASIBridgeToHost(
      args: ["hostwright-wasi-provider"], environment: [:], preopens: [],
      wallClock: FixedWallClock(seconds: wallSeconds, nanoseconds: wallNanoseconds),
      monotonicClock: FixedMonotonicClock(),
      randomGenerator: SeededRandomGenerator(seed: seed))
    var imports = Imports()
    wasi.link(to: &imports, store: store)
    let instance = try module.instantiate(store: store, imports: imports)
    guard let memory = instance.exports[memory: "memory"],
      memory.type.max.map({ $0 <= maximumMemoryPages }) == true,
      memory.byteCount <= Int(maximumMemoryPages * 65_536)
    else { throw WASIProviderRuntimeError.invalidModule }
    return try wasi.runAndClose { bridge in try bridge.start(instance) }
  }

  private static func validateResourceDeclarations(_ data: Data, maximumPages: UInt64) throws {
    var reader = BinaryReader(Array(data))
    guard try reader.bytes(8) == [0, 97, 115, 109, 1, 0, 0, 0] else {
      throw WASIProviderRuntimeError.invalidModule
    }
    var foundMemory = false
    var foundTableSection = false
    while !reader.atEnd {
      let id = try reader.byte()
      let size = try reader.uleb()
      guard size <= UInt64(Int.max) else { throw WASIProviderRuntimeError.invalidModule }
      let payload = try reader.bytes(Int(size))
      let vectorBounds: [UInt8: UInt64] = [
        1: 65_536, 2: 1_024, 3: 100_000, 6: 4_096, 7: 4_096,
        9: 65_536, 11: 65_536, 12: 65_536,
      ]
      if let bound = vectorBounds[id] {
        var vector = BinaryReader(payload)
        guard try vector.uleb() <= bound else { throw WASIProviderRuntimeError.invalidModule }
      }
      if id == 4 {
        guard !foundTableSection else { throw WASIProviderRuntimeError.invalidModule }
        foundTableSection = true
        var tables = BinaryReader(payload)
        let count = try tables.uleb()
        guard count <= 4 else { throw WASIProviderRuntimeError.invalidModule }
        for _ in 0..<count {
          let element = try tables.byte()
          guard element == 0x70 || element == 0x6f, try tables.uleb() == 1 else {
            throw WASIProviderRuntimeError.invalidModule
          }
          let minimum = try tables.uleb(), maximum = try tables.uleb()
          guard minimum <= maximum, maximum <= 65_536 else {
            throw WASIProviderRuntimeError.invalidModule
          }
        }
        guard tables.atEnd else { throw WASIProviderRuntimeError.invalidModule }
      } else if id == 5 {
        guard !foundMemory else { throw WASIProviderRuntimeError.invalidModule }
        var memory = BinaryReader(payload)
        guard try memory.uleb() == 1, try memory.uleb() == 1 else {
          throw WASIProviderRuntimeError.invalidModule
        }
        let minimum = try memory.uleb(), maximum = try memory.uleb()
        guard memory.atEnd, minimum <= maximum, maximum <= maximumPages else {
          throw WASIProviderRuntimeError.invalidModule
        }
        foundMemory = true
      }
    }
    guard foundMemory else { throw WASIProviderRuntimeError.invalidModule }
  }
}

private struct FixedWallClock: WallClock {
  let seconds: UInt64
  let nanoseconds: UInt32
  func now() throws -> WallClock.Duration { (seconds: seconds, nanoseconds: nanoseconds) }
  func resolution() throws -> WallClock.Duration { (seconds: 0, nanoseconds: 1) }
}

private struct FixedMonotonicClock: MonotonicClock {
  func now() throws -> MonotonicClock.Instant { 0 }
  func resolution() throws -> MonotonicClock.Duration { 1 }
}

private struct SeededRandomGenerator: RandomBufferGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func fill(buffer: UnsafeMutableBufferPointer<UInt8>) {
    for index in buffer.indices {
      if index % 8 == 0 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        state = value ^ (value >> 31)
      }
      buffer[index] = UInt8(truncatingIfNeeded: state >> UInt64((index % 8) * 8))
    }
  }
}

private struct BinaryReader {
  let data: [UInt8]
  var offset = 0
  init(_ data: [UInt8]) { self.data = data }
  var atEnd: Bool { offset == data.count }
  mutating func byte() throws -> UInt8 {
    guard offset < data.count else { throw WASIProviderRuntimeError.invalidModule }
    defer { offset += 1 }
    return data[offset]
  }
  mutating func bytes(_ count: Int) throws -> [UInt8] {
    guard count >= 0, count <= data.count - offset else {
      throw WASIProviderRuntimeError.invalidModule
    }
    defer { offset += count }
    return Array(data[offset..<(offset + count)])
  }
  mutating func uleb() throws -> UInt64 {
    var value: UInt64 = 0, shift: UInt64 = 0
    for _ in 0..<10 {
      let next = try byte(), payload = UInt64(next & 0x7f)
      guard shift < 64, payload <= (UInt64.max >> shift) else {
        throw WASIProviderRuntimeError.invalidModule
      }
      value |= payload << shift
      if next & 0x80 == 0 { return value }
      shift += 7
    }
    throw WASIProviderRuntimeError.invalidModule
  }
}

private final class WorkerOwnershipRecorder: @unchecked Sendable {
  private let url: URL
  private let device: dev_t
  private let inode: ino_t
  private let lock = NSLock()

  init(url: URL) throws {
    var info = stat()
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
      lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o600
    else { throw WASIProviderRuntimeError.executionFailed }
    self.url = url
    device = info.st_dev
    inode = info.st_ino
  }

  func record(processID: pid_t, executable: SecureExecutableIdentity) throws {
    try lock.withLock {
      let processIdentity: HostwrightDarwinProcessIdentity
      do {
        processIdentity = try HostwrightDarwinProcessIdentity.lookup(
          processID: processID,
          expectedExecutable: executable
        )
      } catch {
        throw WASIProviderRuntimeError.executionFailed
      }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      let line = "\(formatter.string(from: Date()))\tprocess\tprovider-worker\t\(executable.path)\t\(executable.device)\t\(executable.inode)\t\(processIdentity.ownershipToken)\n"
      let descriptor = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
      guard descriptor >= 0 else { throw WASIProviderRuntimeError.executionFailed }
      defer { close(descriptor) }
      var current = stat()
      guard fstat(descriptor, &current) == 0, current.st_dev == device, current.st_ino == inode,
        current.st_uid == getuid(), current.st_mode & 0o777 == 0o600
      else { throw WASIProviderRuntimeError.executionFailed }
      try Data(line.utf8).withUnsafeBytes { storage in
        var offset = 0
        while offset < storage.count {
          let count = Darwin.write(
            descriptor, storage.baseAddress?.advanced(by: offset), storage.count - offset)
          guard count > 0 else { throw WASIProviderRuntimeError.executionFailed }
          offset += count
        }
      }
    }
  }

}

private extension SHA256.Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
