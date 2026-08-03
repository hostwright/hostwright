import Foundation

public enum ControlStreamDirection: Sendable {
  case clientToServer
  case serverToClient
}

public enum ControlStreamFrameContract {
  public static let allowedKeys: Set<String> = [
    "apiVersion", "protocolRevision", "streamID", "sequence", "cursor", "kind", "credit",
    "payload", "error",
  ]

  public static let requiredKeys: Set<String> = [
    "apiVersion", "protocolRevision", "streamID", "sequence", "kind",
  ]

  public static func decode(_ data: Data) throws -> StreamFrame {
    let frame = try Phase09StrictDecoder.decode(
      StreamFrame.self,
      from: data,
      allowedKeys: allowedKeys,
      requiredKeys: requiredKeys
    )
    try frame.validate()
    return frame
  }

  public static func validate(_ frame: StreamFrame, direction: ControlStreamDirection) throws {
    try frame.validate()
    guard frame.streamID.range(
      of: "^[A-Za-z0-9._:-]{1,\(ControlPlaneContract.maximumStreamIdentifierBytes)}$",
      options: .regularExpression
    ) != nil else {
      throw ContractValidationError.invalid("stream identifier")
    }
    if let cursor = frame.cursor {
      guard !cursor.isEmpty,
        cursor.utf8.count <= ControlPlaneContract.maximumStreamCursorBytes,
        cursor.range(of: "^[A-Za-z0-9._~-]+$", options: .regularExpression) != nil
      else { throw ContractValidationError.invalid("stream cursor") }
    }

    switch direction {
    case .clientToServer:
      switch frame.kind {
      case .open:
        guard frame.sequence == 1, frame.credit != nil, frame.payload != nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream open")
        }
        try validateCredit(frame.credit)
        try decodeOpenRequest(frame.payload!).validate()
      case .ack:
        guard frame.payload == nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream acknowledgement")
        }
        try validateCredit(frame.credit)
      case .cancel:
        guard frame.cursor == nil, frame.credit == nil, frame.payload == nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream cancellation")
        }
      case .data:
        guard frame.cursor == nil, frame.credit == nil, frame.payload != nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream input")
        }
        try decodeClientInput(frame.payload!).validate()
      case .end:
        guard frame.cursor == nil, frame.credit == nil, frame.payload == nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream input end")
        }
      case .heartbeat, .gap, .error:
        throw ContractValidationError.invalid("server stream frame from client")
      }
    case .serverToClient:
      switch frame.kind {
      case .open:
        guard frame.sequence == 1, frame.cursor == nil, frame.credit == nil,
          frame.payload != nil, frame.error == nil
        else { throw ContractValidationError.invalid("stream acceptance") }
        try decodeAcceptance(frame.payload!).validate()
      case .data:
        guard frame.credit == nil, frame.payload != nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream data")
        }
      case .heartbeat:
        guard frame.cursor == nil, frame.credit == nil, frame.payload == nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream heartbeat")
        }
      case .gap:
        guard frame.credit == nil, frame.payload != nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream gap")
        }
        try decodeGap(frame.payload!).validate()
      case .end:
        guard frame.credit == nil, frame.payload == nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream end")
        }
      case .error:
        guard frame.cursor == nil, frame.credit == nil, frame.payload == nil else {
          throw ContractValidationError.invalid("stream error")
        }
      case .ack:
        guard frame.cursor == nil, frame.payload == nil, frame.error == nil else {
          throw ContractValidationError.invalid("stream input acknowledgement")
        }
        try validateCredit(frame.credit)
      case .cancel:
        throw ContractValidationError.invalid("client stream frame from server")
      }
    }
  }

  public static func decodeOpenRequest(_ payload: ControlPlaneJSONValue) throws
    -> ControlStreamOpenRequest
  {
    let data = try ControlPlaneCanonicalJSON.encode(payload)
    let value = try Phase09StrictDecoder.decode(
      ControlStreamOpenRequest.self,
      from: data,
      allowedKeys: [
        "source", "target", "filter", "heartbeatMilliseconds", "requestID", "idempotencyKey",
      ],
      requiredKeys: ["source", "heartbeatMilliseconds"]
    )
    try value.validate()
    return value
  }

  public static func decodeGap(_ payload: ControlPlaneJSONValue) throws -> ControlStreamGap {
    let data = try ControlPlaneCanonicalJSON.encode(payload)
    let value = try Phase09StrictDecoder.decode(
      ControlStreamGap.self,
      from: data,
      allowedKeys: ["reason", "earliestCursor", "latestCursor", "requiresAcknowledgement"],
      requiredKeys: ["reason", "requiresAcknowledgement"]
    )
    try value.validate()
    return value
  }

  public static func decodeClientInput(
    _ payload: ControlPlaneJSONValue
  ) throws -> ControlStreamClientInput {
    let data = try ControlPlaneCanonicalJSON.encode(payload)
    let value = try Phase09StrictDecoder.decode(
      ControlStreamClientInput.self,
      from: data,
      allowedKeys: ["kind", "payloadBase64", "columns", "rows", "signal"],
      requiredKeys: ["kind"]
    )
    try value.validate()
    return value
  }

  public static func decodeAcceptance(
    _ payload: ControlPlaneJSONValue
  ) throws -> ControlStreamAcceptance {
    let data = try ControlPlaneCanonicalJSON.encode(payload)
    let value = try Phase09StrictDecoder.decode(
      ControlStreamAcceptance.self,
      from: data,
      allowedKeys: [
        "source", "resumed", "heartbeatMilliseconds", "inputCredit", "operationRef",
        "auditHealth",
      ],
      requiredKeys: [
        "source", "resumed", "heartbeatMilliseconds", "inputCredit", "auditHealth",
      ]
    )
    try value.validate()
    return value
  }

  public static func value<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self,
      from: ControlPlaneCanonicalJSON.encode(value)
    )
  }

  private static func validateCredit(_ credit: Int?) throws {
    guard let credit, (1...ControlPlaneContract.maximumStreamCredit).contains(credit) else {
      throw ContractValidationError.outOfBounds("stream credit")
    }
  }
}
