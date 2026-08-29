import CryptoKit
import Foundation
import HostwrightControlPlane

public enum ControlStreamCursorError: Error, Equatable, Sendable {
  case invalidCursor
  case expired
  case bindingMismatch
  case keyUnavailable
}

public struct ControlStreamCursorBinding: Codable, Equatable, Sendable {
  public let subjectID: String
  public let source: ControlStreamSource
  public let targetDigestSHA256: String
  public let filterDigestSHA256: String

  public init(
    subjectID: String,
    source: ControlStreamSource,
    target: String?,
    filter: ControlPlaneJSONValue?
  ) throws {
    guard subjectID.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else {
      throw ControlStreamCursorError.bindingMismatch
    }
    self.subjectID = subjectID
    self.source = source
    targetDigestSHA256 = Self.digest(try ControlPlaneCanonicalJSON.encode(target))
    filterDigestSHA256 = Self.digest(try ControlPlaneCanonicalJSON.encode(filter))
  }

  public func validate() throws {
    guard subjectID.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
      Self.isDigest(targetDigestSHA256), Self.isDigest(filterDigestSHA256)
    else { throw ControlStreamCursorError.bindingMismatch }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isDigest(_ value: String) -> Bool {
    value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
  }
}

public struct ControlStreamCursorClaims: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let keyID: String
  public let binding: ControlStreamCursorBinding
  public let sourceCursor: String
  public let issuedAtEpochSeconds: Int64
  public let expiresAtEpochSeconds: Int64

  public init(
    schemaVersion: Int = 1,
    keyID: String,
    binding: ControlStreamCursorBinding,
    sourceCursor: String,
    issuedAtEpochSeconds: Int64,
    expiresAtEpochSeconds: Int64
  ) {
    self.schemaVersion = schemaVersion
    self.keyID = keyID
    self.binding = binding
    self.sourceCursor = sourceCursor
    self.issuedAtEpochSeconds = issuedAtEpochSeconds
    self.expiresAtEpochSeconds = expiresAtEpochSeconds
  }

  public func validate() throws {
    try binding.validate()
    guard schemaVersion == 1,
      keyID.range(of: "^p256:[a-f0-9]{64}$", options: .regularExpression) != nil,
      !sourceCursor.isEmpty,
      sourceCursor.utf8.count <= 2_048,
      issuedAtEpochSeconds > 0,
      expiresAtEpochSeconds > issuedAtEpochSeconds,
      expiresAtEpochSeconds - issuedAtEpochSeconds <= 86_400
    else { throw ControlStreamCursorError.invalidCursor }
  }
}

public final class ControlStreamCursorCodec: @unchecked Sendable {
  private let keyStore: any AuditSigningKeyStoring
  private let now: @Sendable () -> Date
  private let lifetimeSeconds: Int64

  public init(
    keyStore: any AuditSigningKeyStoring,
    lifetimeSeconds: Int64 = 3_600,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    guard (60...86_400).contains(lifetimeSeconds) else {
      throw ControlStreamCursorError.invalidCursor
    }
    self.keyStore = keyStore
    self.lifetimeSeconds = lifetimeSeconds
    self.now = now
  }

  public static func keychainServiceName(stateDatabasePath: String) -> String {
    let namespace = SHA256.hash(data: Data(stateDatabasePath.utf8))
      .prefix(16)
      .map { String(format: "%02x", $0) }
      .joined()
    return "dev.hostwright.stream-cursor.v1.\(namespace)"
  }

  public func issue(
    binding: ControlStreamCursorBinding,
    sourceCursor: String
  ) throws -> String {
    let descriptor = try keyStore.activeKey()
    let issuedAt = Int64(now().timeIntervalSince1970.rounded(.down))
    let claims = ControlStreamCursorClaims(
      keyID: descriptor.keyID,
      binding: binding,
      sourceCursor: sourceCursor,
      issuedAtEpochSeconds: issuedAt,
      expiresAtEpochSeconds: issuedAt + lifetimeSeconds
    )
    try claims.validate()
    let canonical = try ControlPlaneCanonicalJSON.encode(claims)
    let digest = Data(SHA256.hash(data: canonical))
    let signature = try keyStore.sign(digest, keyID: descriptor.keyID)
    let cursor = "hwsc1.\(Self.base64URL(canonical)).\(Self.base64URL(signature))"
    guard cursor.utf8.count <= ControlPlaneContract.maximumStreamCursorBytes else {
      throw ControlStreamCursorError.invalidCursor
    }
    return cursor
  }

  public func verify(
    _ cursor: String,
    expectedBinding: ControlStreamCursorBinding
  ) throws -> ControlStreamCursorClaims {
    guard cursor.utf8.count <= ControlPlaneContract.maximumStreamCursorBytes else {
      throw ControlStreamCursorError.invalidCursor
    }
    let components = cursor.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3, components[0] == "hwsc1",
      let canonical = Self.decodeBase64URL(String(components[1])),
      let signatureData = Self.decodeBase64URL(String(components[2])),
      Self.base64URL(canonical) == components[1],
      Self.base64URL(signatureData) == components[2]
    else { throw ControlStreamCursorError.invalidCursor }
    let claims: ControlStreamCursorClaims
    do {
      claims = try JSONDecoder().decode(ControlStreamCursorClaims.self, from: canonical)
      try claims.validate()
    } catch {
      throw ControlStreamCursorError.invalidCursor
    }
    guard claims.binding == expectedBinding else {
      throw ControlStreamCursorError.bindingMismatch
    }
    let descriptor: AuditSigningKeyDescriptor
    do {
      descriptor = try keyStore.activeKey()
    } catch {
      throw ControlStreamCursorError.keyUnavailable
    }
    guard descriptor.keyID == claims.keyID,
      let publicData = Data(base64Encoded: descriptor.publicKeyX963Base64),
      let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData),
      let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
      publicKey.isValidSignature(signature, for: Data(SHA256.hash(data: canonical)))
    else { throw ControlStreamCursorError.invalidCursor }
    let current = Int64(now().timeIntervalSince1970.rounded(.down))
    guard current >= claims.issuedAtEpochSeconds - 300,
      current <= claims.expiresAtEpochSeconds
    else { throw ControlStreamCursorError.expired }
    return claims
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeBase64URL(_ value: String) -> Data? {
    guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
      return nil
    }
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
  }
}
