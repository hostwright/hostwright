import Foundation

public struct XPCServiceContract: Codable, Equatable, Sendable {
  public static let serviceIdentifier = "dev.hostwright.xpc-provider"
  public static let teamIdentifier = "993YC3JY4Q"
  public static let requiredEntitlements: [String: ControlPlaneJSONValue] = [
    "com.apple.security.app-sandbox": .bool(true)
  ]
  public let serviceIdentifier: String
  public let teamIdentifier: String
  public let entitlements: [String: ControlPlaneJSONValue]
  public init(
    serviceIdentifier: String = XPCServiceContract.serviceIdentifier,
    teamIdentifier: String = XPCServiceContract.teamIdentifier,
    entitlements: [String: ControlPlaneJSONValue] = XPCServiceContract.requiredEntitlements
  ) {
    self.serviceIdentifier = serviceIdentifier
    self.teamIdentifier = teamIdentifier
    self.entitlements = entitlements
  }
  public func validate() throws {
    guard
      serviceIdentifier == Self.serviceIdentifier && teamIdentifier == Self.teamIdentifier
        && entitlements == Self.requiredEntitlements
    else { throw ContractValidationError.invalid("xpc service contract") }
  }
}
public struct CodeIdentityProof: Codable, Equatable, Sendable {
  public let teamIdentifier: String
  public let signingIdentifier: String
  public let codeDirectoryHash: String
  public let entitlementProjection: [String: ControlPlaneJSONValue]
  public init(
    teamIdentifier: String = XPCServiceContract.teamIdentifier, signingIdentifier: String,
    codeDirectoryHash: String,
    entitlementProjection: [String: ControlPlaneJSONValue] = XPCServiceContract.requiredEntitlements
  ) {
    self.teamIdentifier = teamIdentifier
    self.signingIdentifier = signingIdentifier
    self.codeDirectoryHash = codeDirectoryHash
    self.entitlementProjection = entitlementProjection
  }
  public func validate() throws {
    guard
      teamIdentifier == XPCServiceContract.teamIdentifier
        && signingIdentifier == XPCServiceContract.serviceIdentifier
        && codeDirectoryHash.range(
          of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil
        && entitlementProjection == XPCServiceContract.requiredEntitlements
    else { throw ContractValidationError.invalid("code identity proof") }
  }
}
public enum XPCOperation: String, Codable, CaseIterable, Sendable { case codeIdentityProof }
public enum XPCMessageKind: String, Codable, Sendable { case request, cancel }
public enum XPCResponseStatus: String, Codable, Sendable { case completed, cancelled, error }
public struct XPCRequest: Codable, Equatable, Sendable {
  public static let maximumMessageBytes = 1_048_576
  public static let maximumRequestIDBytes = 128
  public let protocolVersion: Int
  public let kind: XPCMessageKind
  public let requestID: String
  public let operation: XPCOperation?
  public let timeoutMilliseconds: Int?
  public init(
    protocolVersion: Int = 1, kind: XPCMessageKind = .request, requestID: String,
    operation: XPCOperation? = .codeIdentityProof, timeoutMilliseconds: Int? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.kind = kind
    self.requestID = requestID
    self.operation = operation
    self.timeoutMilliseconds = timeoutMilliseconds
  }
  public func validate() throws {
    guard protocolVersion == 1 else {
      throw ContractValidationError.unsupportedVersion("xpc")
    }
    guard Self.validRequestID(requestID) else {
      throw ContractValidationError.invalid("xpc request id")
    }
    switch kind {
    case .request:
      guard operation == .codeIdentityProof, let timeoutMilliseconds,
        (1...5_000).contains(timeoutMilliseconds)
      else { throw ContractValidationError.invalid("xpc request") }
    case .cancel:
      guard operation == nil, timeoutMilliseconds == nil else {
        throw ContractValidationError.invalid("xpc cancel")
      }
    }
  }

  public static func validRequestID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumRequestIDBytes
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (65...90).contains($0.value)
          || (97...122).contains($0.value) || "-_.:".unicodeScalars.contains($0)
      }
  }
}
public struct XPCResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let requestID: String
  public let status: XPCResponseStatus
  public let proof: CodeIdentityProof?
  public let error: SanitizedError?
  public init(
    protocolVersion: Int = 1, requestID: String, status: XPCResponseStatus,
    proof: CodeIdentityProof? = nil, error: SanitizedError? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.status = status
    self.proof = proof
    self.error = error
  }
  public func validate() throws {
    guard protocolVersion == 1 else {
      throw ContractValidationError.unsupportedVersion("xpc response")
    }
    guard XPCRequest.validRequestID(requestID) else {
      throw ContractValidationError.invalid("xpc response id")
    }
    switch status {
    case .completed:
      guard let proof, error == nil else { throw ContractValidationError.invalid("xpc completed") }
      try proof.validate()
    case .cancelled:
      guard proof == nil, error == nil else {
        throw ContractValidationError.invalid("xpc cancelled")
      }
    case .error:
      guard proof == nil, let error else { throw ContractValidationError.invalid("xpc error") }
      try error.validate()
    }
  }
}
