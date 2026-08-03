import CryptoKit
import Foundation

public enum ControlPlaneContract {
  public static let apiVersion = 2
  public static let maximumRequestBytes = 65_536
  public static let maximumResponseOrFrameBytes = 1_048_576
  public static let maximumStreams = 32
  public static let maximumOutstandingUnary = 64
  public static let maximumUnaryDeadlineMilliseconds = 300_000
  public static let maximumAuthenticationHandshakeMilliseconds = 5_000
  public static func validateRequestByteCount(_ value: Int) throws {
    guard (1...maximumRequestBytes).contains(value) else {
      throw ContractValidationError.outOfBounds("request bytes")
    }
  }
  public static func validateResponseOrFrameByteCount(_ value: Int) throws {
    guard (1...maximumResponseOrFrameBytes).contains(value) else {
      throw ContractValidationError.outOfBounds("response/frame bytes")
    }
  }
}

public enum ControlFramingContract {
  public static let transport = "SOCK_STREAM"
  public static let lengthPrefixBytes = 4
  public static let lengthByteOrder = "unsigned-big-endian"

  public static let maximumDictionaryBytes = 1_048_576
  public static func validateDeclaredLength(_ length: UInt32, kind: ControlPayloadKind) throws {
    let maximum =
      kind == .request
      ? ControlPlaneContract.maximumRequestBytes : ControlPlaneContract.maximumResponseOrFrameBytes
    guard length > 0, length <= UInt32(maximum) else {
      throw ContractValidationError.outOfBounds("declared frame length")
    }
  }
}

public enum ControlPayloadKind: String, Codable, CaseIterable, Sendable {
  case request, response, frame
}

public enum ContractValidationError: Error, Equatable, Sendable {
  case required(String)
  case unsupportedVersion(String)
  case outOfBounds(String)
  case invalid(String)
  case unknownField(String)
}

public enum ControlProtocolRevision: String, Codable, CaseIterable, Sendable {
  case legacy = "2.0"
  case current = "2.1"
}

public enum ControlResponseStatus: String, Codable, CaseIterable, Sendable {
  case accepted, completed, rejected, error
}

public enum ControlReasonCode: String, Codable, CaseIterable, Sendable {
  case accepted, completed, invalidFrame, invalidRequest, unsupportedAPIVersion
  case unsupportedProtocolRevision, unsupportedOperation, deadlineExceeded, cancelled
  case unauthenticated, identityMismatch, unauthorized, admissionDenied, conflict
  case idempotencyConflict, concurrencyLimit, streamLimit, slowClient, cursorGap
  case auditUnavailable, serviceUnavailable, internalError
}

public struct SanitizedError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  public func validate() throws {
    guard !code.isEmpty, !message.isEmpty else {
      throw ContractValidationError.required("sanitized error")
    }
  }
}

public indirect enum ControlPlaneJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([ControlPlaneJSONValue])
  case object([String: ControlPlaneJSONValue])

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let item = try? value.decode(Bool.self) {
      self = .bool(item)
    } else if let item = try? value.decode(Int64.self) {
      self = .integer(item)
    } else if let item = try? value.decode(Double.self) {
      self = .number(item)
    } else if let item = try? value.decode(String.self) {
      self = .string(item)
    } else if let item = try? value.decode([ControlPlaneJSONValue].self) {
      self = .array(item)
    } else {
      self = .object(try value.decode([String: ControlPlaneJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .bool(let item): try value.encode(item)
    case .integer(let item): try value.encode(item)
    case .number(let item): try value.encode(item)
    case .string(let item): try value.encode(item)
    case .array(let item): try value.encode(item)
    case .object(let item): try value.encode(item)
    }
  }
}

public enum ControlPlaneCanonicalJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

public enum ControlAuthenticationWireKind: String, Codable, CaseIterable, Sendable {
  case challenge = "authentication-challenge"
  case response = "authentication-response"
}

public struct ControlPeerCredentialProof: Codable, Equatable, Sendable {
  public let credentialID: String
  public let signatureDERBase64: String

  public init(credentialID: String, signatureDERBase64: String) {
    self.credentialID = credentialID
    self.signatureDERBase64 = signatureDERBase64
  }

  public func validate() throws {
    guard Self.safeIdentifier(credentialID, maximumLength: 128),
      signatureDERBase64.utf8.count <= 256,
      let signature = Data(base64Encoded: signatureDERBase64),
      (8...128).contains(signature.count),
      signature.base64EncodedString() == signatureDERBase64,
      (try? P256.Signing.ECDSASignature(derRepresentation: signature)) != nil
    else {
      throw ContractValidationError.invalid("credential proof")
    }
  }

  private static func safeIdentifier(_ value: String, maximumLength: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
    return value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
  }
}

public struct ControlPeerCredentialChallenge: Codable, Equatable, Sendable {
  public let apiVersion: Int
  public let protocolRevision: ControlProtocolRevision
  public let kind: ControlAuthenticationWireKind
  public let credentialProofRequired: Bool
  public let protocolLabel: String
  public let subjectID: String
  public let serverNonce: String
  public let daemonGeneration: UInt64
  public let socketDevice: UInt64
  public let socketInode: UInt64
  public let peerUID: UInt32
  public let peerGID: UInt32
  public let peerPID: Int32
  public let peerPIDVersion: UInt32
  public let peerAuditSessionID: UInt32
  public let codeDirectoryHash: String

  public init(
    subjectID: String,
    serverNonce: String,
    daemonGeneration: UInt64,
    socketDevice: UInt64,
    socketInode: UInt64,
    peer: UnixPeerIdentity,
    credentialProofRequired: Bool
  ) {
    apiVersion = ControlPlaneContract.apiVersion
    protocolRevision = .current
    kind = .challenge
    self.credentialProofRequired = credentialProofRequired
    protocolLabel = "hostwright-control-credential-proof-v2.1"
    self.subjectID = subjectID
    self.serverNonce = serverNonce
    self.daemonGeneration = daemonGeneration
    self.socketDevice = socketDevice
    self.socketInode = socketInode
    peerUID = peer.effectiveUID
    peerGID = peer.effectiveGID
    peerPID = peer.pid
    peerPIDVersion = peer.pidVersion
    peerAuditSessionID = peer.auditSessionID
    codeDirectoryHash = peer.codeIdentity.codeDirectoryHash
  }

  public func validate() throws {
    guard apiVersion == ControlPlaneContract.apiVersion, protocolRevision == .current,
      kind == .challenge,
      protocolLabel == "hostwright-control-credential-proof-v2.1",
      Self.safeIdentifier(subjectID, maximumLength: 128),
      (16...128).contains(serverNonce.utf8.count),
      let nonce = Data(base64Encoded: serverNonce),
      (16...96).contains(nonce.count),
      nonce.base64EncodedString() == serverNonce,
      daemonGeneration > 0, socketDevice > 0, socketInode > 0,
      peerPID > 0, peerPIDVersion > 0, peerAuditSessionID > 0,
      codeDirectoryHash.range(
        of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil
    else {
      throw ContractValidationError.invalid("authentication challenge")
    }
  }

  public func canonicalData() throws -> Data {
    try validate()
    return try ControlPlaneCanonicalJSON.encode(self)
  }

  private static func safeIdentifier(_ value: String, maximumLength: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
    return value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
  }
}

public struct ControlAuthenticationResponse: Codable, Equatable, Sendable {
  public let apiVersion: Int
  public let protocolRevision: ControlProtocolRevision
  public let kind: ControlAuthenticationWireKind
  public let credentialID: String?
  public let signatureDERBase64: String?

  public init(credentialProof: ControlPeerCredentialProof? = nil) {
    apiVersion = ControlPlaneContract.apiVersion
    protocolRevision = .current
    kind = .response
    credentialID = credentialProof?.credentialID
    signatureDERBase64 = credentialProof?.signatureDERBase64
  }

  public var credentialProof: ControlPeerCredentialProof? {
    guard let credentialID, let signatureDERBase64 else { return nil }
    return ControlPeerCredentialProof(
      credentialID: credentialID,
      signatureDERBase64: signatureDERBase64
    )
  }

  public func validate(for challenge: ControlPeerCredentialChallenge) throws {
    try challenge.validate()
    guard apiVersion == ControlPlaneContract.apiVersion, protocolRevision == .current,
      kind == .response,
      (credentialID == nil) == (signatureDERBase64 == nil),
      challenge.credentialProofRequired == (credentialID != nil)
    else {
      throw ContractValidationError.invalid("authentication response")
    }
    try credentialProof?.validate()
  }
}

public enum ControlAuthenticationWireContract {
  public static let challengeAllowedKeys: Set<String> = [
    "apiVersion", "protocolRevision", "kind", "credentialProofRequired", "protocolLabel",
    "subjectID", "serverNonce", "daemonGeneration", "socketDevice", "socketInode", "peerUID",
    "peerGID", "peerPID", "peerPIDVersion", "peerAuditSessionID", "codeDirectoryHash",
  ]
  public static let responseAllowedKeys: Set<String> = [
    "apiVersion", "protocolRevision", "kind", "credentialID", "signatureDERBase64",
  ]

  public static func decodeChallenge(_ data: Data) throws -> ControlPeerCredentialChallenge {
    let value = try Phase09StrictDecoder.decode(
      ControlPeerCredentialChallenge.self,
      from: data,
      allowedKeys: challengeAllowedKeys,
      requiredKeys: challengeAllowedKeys
    )
    try value.validate()
    return value
  }

  public static func decodeResponse(
    _ data: Data,
    for challenge: ControlPeerCredentialChallenge
  ) throws -> ControlAuthenticationResponse {
    let required: Set<String> = ["apiVersion", "protocolRevision", "kind"]
    let value = try Phase09StrictDecoder.decode(
      ControlAuthenticationResponse.self,
      from: data,
      allowedKeys: responseAllowedKeys,
      requiredKeys: required
    )
    try value.validate(for: challenge)
    return value
  }
}

public struct ControlRequestEnvelope: Codable, Equatable, Sendable {
  public let apiVersion: Int
  public let protocolRevision: ControlProtocolRevision?
  public let requestID: String
  public let operation: String
  public let timeoutMilliseconds: Int?
  public let idempotencyKey: String?
  public let body: ControlPlaneJSONValue?

  public init(
    apiVersion: Int = ControlPlaneContract.apiVersion,
    protocolRevision: ControlProtocolRevision? = .current, requestID: String, operation: String,
    timeoutMilliseconds: Int? = nil, idempotencyKey: String? = nil,
    body: ControlPlaneJSONValue? = nil
  ) {
    self.apiVersion = apiVersion
    self.protocolRevision = protocolRevision
    self.requestID = requestID
    self.operation = operation
    self.timeoutMilliseconds = timeoutMilliseconds
    self.idempotencyKey = idempotencyKey
    self.body = body
  }

  public func validate() throws {
    guard apiVersion == ControlPlaneContract.apiVersion else {
      throw ContractValidationError.unsupportedVersion("control API")
    }
    guard !requestID.isEmpty, !operation.isEmpty else {
      throw ContractValidationError.required("request identifier or operation")
    }
    if protocolRevision == nil {
      guard timeoutMilliseconds == nil, idempotencyKey == nil, body == nil else {
        throw ContractValidationError.invalid("legacy v2.1 field")
      }
      return
    }
    guard let timeoutMilliseconds,
      (1...ControlPlaneContract.maximumUnaryDeadlineMilliseconds).contains(timeoutMilliseconds)
    else { throw ContractValidationError.required("timeoutMilliseconds") }
    if let idempotencyKey, idempotencyKey.isEmpty {
      throw ContractValidationError.required("idempotencyKey")
    }
  }
}

public struct LegacyControlResponse: Codable, Equatable, Sendable {
  public let apiVersion: Int
  public let requestID: String
  public let operation: String
  public let success: Bool
  public let exitCode: Int
  public let result: ControlPlaneJSONValue?
}

public struct ControlResponseEnvelope: Codable, Equatable, Sendable {
  public let apiVersion: Int
  public let protocolRevision: ControlProtocolRevision
  public let requestID: String
  public let status: ControlResponseStatus
  public let reasonCode: ControlReasonCode
  public let operationRef: String?
  public let result: ControlPlaneJSONValue?
  public let error: SanitizedError?
  public init(
    apiVersion: Int = 2, protocolRevision: ControlProtocolRevision = .current, requestID: String,
    status: ControlResponseStatus, reasonCode: ControlReasonCode, operationRef: String? = nil,
    result: ControlPlaneJSONValue? = nil, error: SanitizedError? = nil
  ) {
    self.apiVersion = apiVersion
    self.protocolRevision = protocolRevision
    self.requestID = requestID
    self.status = status
    self.reasonCode = reasonCode
    self.operationRef = operationRef
    self.result = result
    self.error = error
  }
  public func validate() throws {
    guard apiVersion == 2, protocolRevision == .current, !requestID.isEmpty else {
      throw ContractValidationError.unsupportedVersion("control response")
    }
    switch status {
    case .accepted:
      guard let operationRef, !operationRef.isEmpty, result == nil, error == nil else {
        throw ContractValidationError.required("accepted operation reference")
      }
    case .completed:
      guard error == nil else { throw ContractValidationError.invalid("success error") }
    case .rejected, .error:
      guard let error else { throw ContractValidationError.required("response error") }
      try error.validate()
    }
  }
}

public enum StreamFrameKind: String, Codable, CaseIterable, Sendable {
  case open, data, heartbeat, gap, ack, cancel, end, error
}
public struct StreamFrame: Codable, Equatable, Sendable {
  public let apiVersion: Int
  public let protocolRevision: ControlProtocolRevision
  public let streamID: String
  public let sequence: UInt64
  public let cursor: String?
  public let kind: StreamFrameKind
  public let credit: Int?
  public let payload: ControlPlaneJSONValue?
  public let error: SanitizedError?
  public init(
    apiVersion: Int = 2, protocolRevision: ControlProtocolRevision = .current, streamID: String,
    sequence: UInt64, cursor: String? = nil, kind: StreamFrameKind, credit: Int? = nil,
    payload: ControlPlaneJSONValue? = nil, error: SanitizedError? = nil
  ) {
    self.apiVersion = apiVersion
    self.protocolRevision = protocolRevision
    self.streamID = streamID
    self.sequence = sequence
    self.cursor = cursor
    self.kind = kind
    self.credit = credit
    self.payload = payload
    self.error = error
  }
  public func validate() throws {
    guard apiVersion == 2, protocolRevision == .current, !streamID.isEmpty, sequence > 0 else {
      throw ContractValidationError.invalid("stream frame")
    }
    if let credit, credit < 0 { throw ContractValidationError.outOfBounds("credit") }
    if kind == .error {
      guard let error else { throw ContractValidationError.required("stream error") }
      try error.validate()
    } else if error != nil {
      throw ContractValidationError.invalid("non-error stream error")
    }
  }
}

public struct ControlSessionLimits: Codable, Equatable, Sendable {
  public let streams: Int
  public let outstandingUnary: Int
  public func validate() throws {
    guard (0...32).contains(streams), (0...64).contains(outstandingUnary) else {
      throw ContractValidationError.outOfBounds("session limits")
    }
  }
}

public enum Phase09StrictDecoder {
  public static func decode<T: Decodable>(
    _ type: T.Type, from data: Data, allowedKeys: Set<String>, requiredKeys: Set<String>,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T {
    let keys = try topLevelKeys(data)
    var seen = Set<String>()
    guard keys.allSatisfy({ seen.insert($0).inserted }) else {
      throw ContractValidationError.invalid("duplicate top-level key")
    }
    let actual = Set(keys)
    guard actual.isSubset(of: allowedKeys) else {
      throw ContractValidationError.unknownField("top-level")
    }
    guard requiredKeys.isSubset(of: actual) else {
      throw ContractValidationError.required("top-level key")
    }
    return try decoder.decode(T.self, from: data)
  }

  private static func topLevelKeys(_ data: Data) throws -> [String] {
    let bytes = Array(data)
    var i = 0
    func ws() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
    func string() throws -> String {
      guard i < bytes.count, bytes[i] == 34 else {
        throw ContractValidationError.invalid("JSON key")
      }
      let start = i
      i += 1
      var escaped = false
      while i < bytes.count {
        let byte = bytes[i]
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          let value = Data(bytes[start...i])
          i += 1
          guard let key = try? JSONDecoder().decode(String.self, from: value) else {
            throw ContractValidationError.invalid("JSON key")
          }
          return key
        }
        i += 1
      }
      throw ContractValidationError.invalid("JSON key")
    }
    func value() throws {
      ws()
      var depth = 0
      var quoted = false
      var escaped = false
      while i < bytes.count {
        let byte = bytes[i]
        if quoted {
          if escaped {
            escaped = false
          } else if byte == 92 {
            escaped = true
          } else if byte == 34 {
            quoted = false
          }
          i += 1
          continue
        }
        if byte == 34 {
          quoted = true
        } else if byte == 123 || byte == 91 {
          depth += 1
        } else if byte == 125 || byte == 93 {
          if depth == 0 { return }
          depth -= 1
        } else if byte == 44 && depth == 0 {
          return
        }
        i += 1
      }
      throw ContractValidationError.invalid("JSON value")
    }
    ws()
    guard i < bytes.count, bytes[i] == 123 else {
      throw ContractValidationError.invalid("top-level object")
    }
    i += 1
    var result: [String] = []
    while true {
      ws()
      if i < bytes.count, bytes[i] == 125 {
        i += 1
        break
      }
      let key = try string()
      result.append(key)
      ws()
      guard i < bytes.count, bytes[i] == 58 else {
        throw ContractValidationError.invalid("JSON object")
      }
      i += 1
      try value()
      ws()
      guard i < bytes.count else { throw ContractValidationError.invalid("JSON object") }
      if bytes[i] == 44 {
        i += 1
      } else if bytes[i] == 125 {
        i += 1
        break
      } else {
        throw ContractValidationError.invalid("JSON object")
      }
    }
    ws()
    guard i == bytes.count else { throw ContractValidationError.invalid("trailing JSON") }
    return result
  }
}
