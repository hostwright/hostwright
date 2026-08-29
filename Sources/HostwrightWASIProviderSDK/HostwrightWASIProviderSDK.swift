#if os(WASI)
  import FoundationEssentials
  import WASILibc
#else
  import Darwin
  import Foundation
#endif

public enum HostwrightWASIProviderSDKError: Error, Equatable, Sendable {
  case malformedInvocation
  case inputTooLarge
  case resultTooLarge
  case invalidResult
  case handlerFailed
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      guard value.isFinite else { throw HostwrightWASIProviderSDKError.malformedInvocation }
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value):
      guard value.isFinite else { throw HostwrightWASIProviderSDKError.malformedInvocation }
      try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public func validate(maximumDepth: Int = 32, maximumNodes: Int = 16_384) throws {
    var nodes = 0
    try validate(depth: 0, maximumDepth: maximumDepth, maximumNodes: maximumNodes, nodes: &nodes)
  }

  private func validate(depth: Int, maximumDepth: Int, maximumNodes: Int, nodes: inout Int) throws {
    guard depth <= maximumDepth else { throw HostwrightWASIProviderSDKError.malformedInvocation }
    nodes += 1
    guard nodes <= maximumNodes else { throw HostwrightWASIProviderSDKError.malformedInvocation }
    switch self {
    case .null, .bool, .integer, .number:
      return
    case .string(let value):
      guard value.utf8.count <= 65_536 else { throw HostwrightWASIProviderSDKError.malformedInvocation }
    case .array(let values):
      guard values.count <= 4_096 else { throw HostwrightWASIProviderSDKError.malformedInvocation }
      for value in values {
        try value.validate(depth: depth + 1, maximumDepth: maximumDepth, maximumNodes: maximumNodes, nodes: &nodes)
      }
    case .object(let values):
      guard values.count <= 4_096, values.keys.allSatisfy({ validJSONKey($0) }) else {
        throw HostwrightWASIProviderSDKError.malformedInvocation
      }
      for value in values.values {
        try value.validate(depth: depth + 1, maximumDepth: maximumDepth, maximumNodes: maximumNodes, nodes: &nodes)
      }
    }
  }
}

public enum Capability: String, Codable, CaseIterable, Sendable {
  case policy
  case observation
  case storage
  case network
  case diagnostics
  case scheduler
  case secretMetadata = "secret-metadata"
}

public struct Limits: Codable, Equatable, Sendable {
  public let moduleBytes: Int
  public let inputBytes: Int
  public let outputBytes: Int
  public let memoryBytes: Int
  public let normalExecutionMilliseconds: Int
  public let absoluteExecutionMilliseconds: Int

  public static let frozen = Limits(
    moduleBytes: 16 * 1_024 * 1_024,
    inputBytes: 1 * 1_024 * 1_024,
    outputBytes: 1 * 1_024 * 1_024,
    memoryBytes: 64 * 1_024 * 1_024,
    normalExecutionMilliseconds: 5_000,
    absoluteExecutionMilliseconds: 30_000)

  public init(
    moduleBytes: Int, inputBytes: Int, outputBytes: Int, memoryBytes: Int,
    normalExecutionMilliseconds: Int, absoluteExecutionMilliseconds: Int
  ) {
    self.moduleBytes = moduleBytes
    self.inputBytes = inputBytes
    self.outputBytes = outputBytes
    self.memoryBytes = memoryBytes
    self.normalExecutionMilliseconds = normalExecutionMilliseconds
    self.absoluteExecutionMilliseconds = absoluteExecutionMilliseconds
  }

  public init(from decoder: Decoder) throws {
    try requireExactKeys(decoder, CodingKeys.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      moduleBytes: try container.decode(Int.self, forKey: .moduleBytes),
      inputBytes: try container.decode(Int.self, forKey: .inputBytes),
      outputBytes: try container.decode(Int.self, forKey: .outputBytes),
      memoryBytes: try container.decode(Int.self, forKey: .memoryBytes),
      normalExecutionMilliseconds: try container.decode(Int.self, forKey: .normalExecutionMilliseconds),
      absoluteExecutionMilliseconds: try container.decode(Int.self, forKey: .absoluteExecutionMilliseconds))
  }

  public func validate() throws {
    let maximum = Self.frozen
    guard moduleBytes > 0, moduleBytes <= maximum.moduleBytes,
      inputBytes > 0, inputBytes <= maximum.inputBytes,
      outputBytes > 0, outputBytes <= maximum.outputBytes,
      memoryBytes > 0, memoryBytes <= maximum.memoryBytes,
      normalExecutionMilliseconds > 0,
      normalExecutionMilliseconds <= maximum.normalExecutionMilliseconds,
      absoluteExecutionMilliseconds >= normalExecutionMilliseconds,
      absoluteExecutionMilliseconds <= maximum.absoluteExecutionMilliseconds
    else { throw HostwrightWASIProviderSDKError.malformedInvocation }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case moduleBytes, inputBytes, outputBytes, memoryBytes
    case normalExecutionMilliseconds, absoluteExecutionMilliseconds
  }
}

public struct Invocation: Codable, Equatable, Sendable {
  public let invocationID: String
  public let pluginIdentifier: String
  public let capability: Capability
  public let timestamp: String
  public let seed: UInt64
  public let input: JSONValue
  public let limits: Limits

  public init(
    invocationID: String, pluginIdentifier: String, capability: Capability, timestamp: String,
    seed: UInt64, input: JSONValue, limits: Limits = .frozen
  ) {
    self.invocationID = invocationID
    self.pluginIdentifier = pluginIdentifier
    self.capability = capability
    self.timestamp = timestamp
    self.seed = seed
    self.input = input
    self.limits = limits
  }

  public init(from decoder: Decoder) throws {
    try requireExactKeys(decoder, CodingKeys.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      invocationID: try container.decode(String.self, forKey: .invocationID),
      pluginIdentifier: try container.decode(String.self, forKey: .pluginIdentifier),
      capability: try container.decode(Capability.self, forKey: .capability),
      timestamp: try container.decode(String.self, forKey: .timestamp),
      seed: try container.decode(UInt64.self, forKey: .seed),
      input: try container.decode(JSONValue.self, forKey: .input),
      limits: try container.decode(Limits.self, forKey: .limits))
  }

  public func validate() throws {
    guard validIdentifier(invocationID, maximumBytes: 128),
      validPluginIdentifier(pluginIdentifier),
      validTimestamp(timestamp)
    else { throw HostwrightWASIProviderSDKError.malformedInvocation }
    try input.validate()
    try limits.validate()
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case invocationID, pluginIdentifier, capability, timestamp, seed, input, limits
  }
}

public struct ProposedAction: Codable, Equatable, Sendable {
  public let capability: Capability
  public let kind: String
  public let payload: JSONValue

  public init(capability: Capability, kind: String, payload: JSONValue) {
    self.capability = capability
    self.kind = kind
    self.payload = payload
  }

  public func validate(for invocation: Invocation) throws {
    guard capability == invocation.capability, validIdentifier(kind, maximumBytes: 128) else {
      throw HostwrightWASIProviderSDKError.invalidResult
    }
    try payload.validate()
  }
}

public struct SanitizedDiagnostic: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  public func validate() throws {
    guard validIdentifier(code, maximumBytes: 128),
      validDiagnosticMessage(message)
    else { throw HostwrightWASIProviderSDKError.invalidResult }
  }
}

public struct Result: Codable, Equatable, Sendable {
  public let invocationID: String
  public let actions: [ProposedAction]
  public let diagnostics: [SanitizedDiagnostic]

  public init(
    invocationID: String, actions: [ProposedAction] = [], diagnostics: [SanitizedDiagnostic] = []
  ) {
    self.invocationID = invocationID
    self.actions = actions
    self.diagnostics = diagnostics
  }

  public func validate(for invocation: Invocation) throws {
    guard invocationID == invocation.invocationID, actions.count <= 128, diagnostics.count <= 128 else {
      throw HostwrightWASIProviderSDKError.invalidResult
    }
    try actions.forEach { try $0.validate(for: invocation) }
    try diagnostics.forEach { try $0.validate() }
  }
}

public struct DeterministicContext: Sendable {
  public let timestamp: String
  public let seed: UInt64
  private var state: UInt64

  public init(invocation: Invocation) {
    timestamp = invocation.timestamp
    seed = invocation.seed
    state = invocation.seed
  }

  public mutating func nextRandomUInt64() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

public enum CanonicalJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

public struct CommandOutput: Equatable, Sendable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data
}

public enum CommandRunner {
  public typealias Handler = @Sendable (Invocation, inout DeterministicContext) throws -> Result

  public static func process(input: Data, handler: Handler) -> CommandOutput {
    do {
      guard input.count <= Limits.frozen.inputBytes else { throw HostwrightWASIProviderSDKError.inputTooLarge }
      let invocation: Invocation
      do {
        invocation = try JSONDecoder().decode(Invocation.self, from: input)
      } catch {
        throw HostwrightWASIProviderSDKError.malformedInvocation
      }
      try invocation.validate()
      guard input.count <= invocation.limits.inputBytes else {
        throw HostwrightWASIProviderSDKError.inputTooLarge
      }
      var context = DeterministicContext(invocation: invocation)
      let result = try handler(invocation, &context)
      try result.validate(for: invocation)
      let output = try CanonicalJSON.encode(result)
      guard output.count <= invocation.limits.outputBytes else {
        throw HostwrightWASIProviderSDKError.resultTooLarge
      }
      return CommandOutput(status: 0, stdout: output, stderr: Data())
    } catch let error as HostwrightWASIProviderSDKError {
      return failure(error)
    } catch {
      return failure(.handlerFailed)
    }
  }

  @discardableResult
  public static func run(handler: Handler) -> Int32 {
    let output: CommandOutput
    do {
      let input = try readBoundedStandardInput()
      output = process(input: input, handler: handler)
    } catch {
      output = failure(.malformedInvocation)
    }
    writeStandardOutput(output.stdout)
    writeStandardError(output.stderr)
    return output.status
  }

  private static func failure(_ error: HostwrightWASIProviderSDKError) -> CommandOutput {
    let token: String
    switch error {
    case .inputTooLarge: token = "input-too-large"
    case .resultTooLarge: token = "result-too-large"
    case .invalidResult: token = "invalid-result"
    case .handlerFailed: token = "handler-failed"
    case .malformedInvocation: token = "malformed-invocation"
    }
    let stderr = Data("hostwright-wasi-provider-sdk: \(token)\n".utf8)
    return CommandOutput(status: 64, stdout: Data(), stderr: stderr)
  }

  private static func readBoundedStandardInput() throws -> Data {
    #if os(WASI)
      var input = Data()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        let remaining = Limits.frozen.inputBytes + 1 - input.count
        guard remaining > 0 else { throw HostwrightWASIProviderSDKError.inputTooLarge }
        let count = buffer.withUnsafeMutableBytes { storage in
          WASILibc.read(STDIN_FILENO, storage.baseAddress, min(storage.count, remaining))
        }
        guard count >= 0 else { throw HostwrightWASIProviderSDKError.malformedInvocation }
        if count == 0 { return input }
        input.append(contentsOf: buffer[0..<count])
      }
    #else
    var input = Data()
    while true {
      let remaining = Limits.frozen.inputBytes + 1 - input.count
      guard remaining > 0 else { throw HostwrightWASIProviderSDKError.inputTooLarge }
      guard let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1_024, remaining)),
        !chunk.isEmpty
      else { return input }
      input.append(chunk)
    }
    #endif
  }

  private static func writeStandardOutput(_ data: Data) {
    write(data, descriptor: STDOUT_FILENO)
  }

  private static func writeStandardError(_ data: Data) {
    write(data, descriptor: STDERR_FILENO)
  }

  private static func write(_ data: Data, descriptor: Int32) {
    #if os(WASI)
      data.withUnsafeBytes { storage in
        var offset = 0
        while offset < storage.count {
          let count = WASILibc.write(
            descriptor, storage.baseAddress?.advanced(by: offset), storage.count - offset)
          guard count > 0 else { return }
          offset += count
        }
      }
    #else
      let handle = descriptor == STDOUT_FILENO ? FileHandle.standardOutput : FileHandle.standardError
      handle.write(data)
    #endif
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

private func requireExactKeys<Key: CodingKey & CaseIterable>(
  _ decoder: Decoder, _ type: Key.Type
) throws {
  let container = try decoder.container(keyedBy: AnyCodingKey.self)
  guard Set(container.allKeys.map(\.stringValue)) == Set(type.allCases.map(\.stringValue)) else {
    throw HostwrightWASIProviderSDKError.malformedInvocation
  }
}

private func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
  guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
  return value.unicodeScalars.allSatisfy { scalar in
    (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
      || (48...57).contains(scalar.value) || scalar == "-" || scalar == "_" || scalar == "."
      || scalar == ":"
  }
}

private func validPluginIdentifier(_ value: String) -> Bool {
  guard validIdentifier(value, maximumBytes: 255), value.contains(".") else { return false }
  return !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..")
}

private func validTimestamp(_ value: String) -> Bool {
  #if os(WASI)
    let bytes = Array(value.utf8)
    guard bytes.count == 20, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
      bytes[13] == 58, bytes[16] == 58, bytes[19] == 90
    else { return false }
    let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
    guard digitIndices.allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
    func decimal(_ first: Int) -> Int { Int(bytes[first] - 48) * 10 + Int(bytes[first + 1] - 48) }
    let year = digitIndices[0...3].reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
    let month = decimal(5), day = decimal(8)
    let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...12).contains(month) && (1...days[month - 1]).contains(day)
      && (0...23).contains(decimal(11)) && (0...59).contains(decimal(14))
      && (0...59).contains(decimal(17))
  #else
  guard value.utf8.count <= 64, value.hasSuffix("Z") else { return false }
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  guard let date = formatter.date(from: value) else { return false }
  return formatter.string(from: date) == value
  #endif
}

private func validJSONKey(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { (32...126).contains($0.value) }
}

private func validDiagnosticMessage(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 1_024 && value.unicodeScalars.allSatisfy { (32...126).contains($0.value) }
}
