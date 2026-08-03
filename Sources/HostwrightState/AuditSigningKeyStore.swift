import CryptoKit
import Foundation
import Security

public enum AuditSigningKeyStoreError: Error, Equatable, Sendable {
  case invalidConfiguration
  case keychainFailure(Int32)
  case corruptKeyMaterial
  case missingKey
  case anchorConflict
}

public struct AuditSigningKeyDescriptor: Codable, Equatable, Sendable {
  public let keyID: String
  public let publicKeyX963Base64: String
  public let publicKeySHA256: String

  public init(keyID: String, publicKeyX963Base64: String, publicKeySHA256: String) {
    self.keyID = keyID
    self.publicKeyX963Base64 = publicKeyX963Base64
    self.publicKeySHA256 = publicKeySHA256
  }
}

public struct AuditChainHeadAnchor: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let segmentOrdinal: UInt64
  public let segmentID: String
  public let segmentDigest: String
  public let keyID: String

  public init(
    schemaVersion: Int = 1,
    segmentOrdinal: UInt64,
    segmentID: String,
    segmentDigest: String,
    keyID: String
  ) {
    self.schemaVersion = schemaVersion
    self.segmentOrdinal = segmentOrdinal
    self.segmentID = segmentID
    self.segmentDigest = segmentDigest
    self.keyID = keyID
  }
}

public protocol AuditSigningKeyStoring: Sendable {
  func configuredActiveKey() throws -> AuditSigningKeyDescriptor?
  func activeKey() throws -> AuditSigningKeyDescriptor
  func generateInactiveKey() throws -> AuditSigningKeyDescriptor
  func activate(keyID: String) throws
  func sign(_ digest: Data, keyID: String) throws -> Data
  func loadHead() throws -> AuditChainHeadAnchor?
  func storeHead(_ head: AuditChainHeadAnchor) throws
  func clearHead() throws
}

public final class InMemoryAuditSigningKeyStore: AuditSigningKeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: P256.Signing.PrivateKey] = [:]
  private var activeKeyID: String?
  private var head: AuditChainHeadAnchor?
  public var failSigning = false
  public var failHeadStore = false
  public var failActivation = false

  public init() {}

  public func configuredActiveKey() throws -> AuditSigningKeyDescriptor? {
    lock.lock()
    defer { lock.unlock() }
    guard let activeKeyID, let key = keys[activeKeyID] else { return nil }
    return Self.descriptor(key)
  }

  public func activeKey() throws -> AuditSigningKeyDescriptor {
    lock.lock()
    defer { lock.unlock() }
    if let activeKeyID, let key = keys[activeKeyID] {
      return Self.descriptor(key)
    }
    let key = P256.Signing.PrivateKey()
    let descriptor = Self.descriptor(key)
    keys[descriptor.keyID] = key
    activeKeyID = descriptor.keyID
    return descriptor
  }

  public func generateInactiveKey() throws -> AuditSigningKeyDescriptor {
    lock.lock()
    defer { lock.unlock() }
    let key = P256.Signing.PrivateKey()
    let descriptor = Self.descriptor(key)
    keys[descriptor.keyID] = key
    return descriptor
  }

  public func activate(keyID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !failActivation else { throw AuditSigningKeyStoreError.keychainFailure(-1) }
    guard keys[keyID] != nil else { throw AuditSigningKeyStoreError.missingKey }
    activeKeyID = keyID
  }

  public func sign(_ digest: Data, keyID: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard !failSigning else { throw AuditSigningKeyStoreError.keychainFailure(-1) }
    guard digest.count == SHA256.byteCount, let key = keys[keyID] else {
      throw AuditSigningKeyStoreError.missingKey
    }
    return try key.signature(for: digest).derRepresentation
  }

  public func loadHead() throws -> AuditChainHeadAnchor? {
    lock.lock()
    defer { lock.unlock() }
    return head
  }

  public func storeHead(_ head: AuditChainHeadAnchor) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !failHeadStore else { throw AuditSigningKeyStoreError.keychainFailure(-1) }
    self.head = head
  }

  public func clearHead() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !failHeadStore else { throw AuditSigningKeyStoreError.keychainFailure(-1) }
    head = nil
  }

  private static func descriptor(_ key: P256.Signing.PrivateKey) -> AuditSigningKeyDescriptor {
    let publicKey = key.publicKey.x963Representation
    let digest = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    return AuditSigningKeyDescriptor(
      keyID: "p256:\(digest)",
      publicKeyX963Base64: publicKey.base64EncodedString(),
      publicKeySHA256: digest
    )
  }
}

public final class MacOSAuditSigningKeyStore: AuditSigningKeyStoring, @unchecked Sendable {
  private static let ownershipMarker = Data("hostwright-audit-owned-v1".utf8)
  private static let activeAccount = "active-key-id"
  private static let headAccount = "chain-head-v1"

  private let service: String
  private let lock = NSLock()

  public init(service: String = "dev.hostwright.audit.v1") throws {
    guard service.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else {
      throw AuditSigningKeyStoreError.invalidConfiguration
    }
    self.service = service
  }

  public static func serviceName(stateDatabasePath: String) -> String {
    let namespace = SHA256.hash(data: Data(stateDatabasePath.utf8))
      .prefix(16)
      .map { String(format: "%02x", $0) }
      .joined()
    return "dev.hostwright.audit.v1.\(namespace)"
  }

  public func configuredActiveKey() throws -> AuditSigningKeyDescriptor? {
    lock.lock()
    defer { lock.unlock() }
    guard let identifier = try readString(account: Self.activeAccount) else { return nil }
    return try descriptor(for: identifier)
  }

  public func activeKey() throws -> AuditSigningKeyDescriptor {
    lock.lock()
    defer { lock.unlock() }
    if let identifier = try readString(account: Self.activeAccount) {
      return try descriptor(for: identifier)
    }
    let descriptor = try createKey()
    do {
      try create(value: Data(descriptor.keyID.utf8), account: Self.activeAccount)
      return descriptor
    } catch AuditSigningKeyStoreError.keychainFailure(let status)
      where status == errSecDuplicateItem
    {
      guard let identifier = try readString(account: Self.activeAccount) else {
        throw AuditSigningKeyStoreError.missingKey
      }
      return try self.descriptor(for: identifier)
    }
  }

  public func generateInactiveKey() throws -> AuditSigningKeyDescriptor {
    lock.lock()
    defer { lock.unlock() }
    return try createKey()
  }

  public func activate(keyID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    _ = try descriptor(for: keyID)
    try upsert(value: Data(keyID.utf8), account: Self.activeAccount)
  }

  public func sign(_ digest: Data, keyID: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard digest.count == SHA256.byteCount else {
      throw AuditSigningKeyStoreError.corruptKeyMaterial
    }
    let key = try privateKey(for: keyID)
    return try key.signature(for: digest).derRepresentation
  }

  public func loadHead() throws -> AuditChainHeadAnchor? {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try read(account: Self.headAccount) else { return nil }
    do {
      return try JSONDecoder().decode(AuditChainHeadAnchor.self, from: data)
    } catch {
      throw AuditSigningKeyStoreError.corruptKeyMaterial
    }
  }

  public func storeHead(_ head: AuditChainHeadAnchor) throws {
    lock.lock()
    defer { lock.unlock() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try upsert(value: encoder.encode(head), account: Self.headAccount)
  }

  public func clearHead() throws {
    lock.lock()
    defer { lock.unlock() }
    let status = SecItemDelete(exactQuery(account: Self.headAccount) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AuditSigningKeyStoreError.keychainFailure(status)
    }
  }

  public func removeOwnedItems() throws {
    lock.lock()
    defer { lock.unlock() }
    for account in try ownedAccounts() {
      let status = SecItemDelete(exactQuery(account: account) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw AuditSigningKeyStoreError.keychainFailure(status)
      }
    }
    guard try ownedAccounts().isEmpty else {
      throw AuditSigningKeyStoreError.keychainFailure(errSecInternalError)
    }
  }

  private func ownedAccounts() throws -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrGeneric as String: Self.ownershipMarker,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else {
      throw AuditSigningKeyStoreError.keychainFailure(status)
    }
    let rows: [[String: Any]]
    if let values = result as? [[String: Any]] {
      rows = values
    } else if let value = result as? [String: Any] {
      rows = [value]
    } else {
      throw AuditSigningKeyStoreError.corruptKeyMaterial
    }
    guard rows.count <= 1_024 else {
      throw AuditSigningKeyStoreError.corruptKeyMaterial
    }
    let accounts = rows.compactMap { $0[kSecAttrAccount as String] as? String }
    guard accounts.count == rows.count, Set(accounts).count == accounts.count else {
      throw AuditSigningKeyStoreError.corruptKeyMaterial
    }
    return accounts.sorted()
  }

  private func createKey() throws -> AuditSigningKeyDescriptor {
    for _ in 0..<3 {
      let key = P256.Signing.PrivateKey()
      let descriptor = Self.descriptor(key)
      do {
        try create(value: key.rawRepresentation, account: keyAccount(descriptor.keyID))
        return descriptor
      } catch AuditSigningKeyStoreError.keychainFailure(let status)
        where status == errSecDuplicateItem
      {
        continue
      }
    }
    throw AuditSigningKeyStoreError.keychainFailure(errSecDuplicateItem)
  }

  private func privateKey(for keyID: String) throws -> P256.Signing.PrivateKey {
    guard let material = try read(account: keyAccount(keyID)), material.count == 32 else {
      throw AuditSigningKeyStoreError.missingKey
    }
    do {
      let key = try P256.Signing.PrivateKey(rawRepresentation: material)
      guard Self.descriptor(key).keyID == keyID else {
        throw AuditSigningKeyStoreError.corruptKeyMaterial
      }
      return key
    } catch let error as AuditSigningKeyStoreError {
      throw error
    } catch {
      throw AuditSigningKeyStoreError.corruptKeyMaterial
    }
  }

  private func descriptor(for keyID: String) throws -> AuditSigningKeyDescriptor {
    Self.descriptor(try privateKey(for: keyID))
  }

  private static func descriptor(_ key: P256.Signing.PrivateKey) -> AuditSigningKeyDescriptor {
    let publicKey = key.publicKey.x963Representation
    let digest = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    return AuditSigningKeyDescriptor(
      keyID: "p256:\(digest)",
      publicKeyX963Base64: publicKey.base64EncodedString(),
      publicKeySHA256: digest
    )
  }

  private func keyAccount(_ keyID: String) -> String { "signing-key:\(keyID)" }

  private func readString(account: String) throws -> String? {
    guard let data = try read(account: account) else { return nil }
    guard let value = String(data: data, encoding: .utf8) else {
      throw AuditSigningKeyStoreError.corruptKeyMaterial
    }
    return value
  }

  private func read(account: String) throws -> Data? {
    var query = exactQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw AuditSigningKeyStoreError.keychainFailure(status)
    }
    return data
  }

  private func create(value: Data, account: String) throws {
    var query = exactQuery(account: account)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    query[kSecAttrLabel as String] = "Hostwright tamper-evident audit"
    query[kSecValueData as String] = value
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw AuditSigningKeyStoreError.keychainFailure(status)
    }
  }

  private func upsert(value: Data, account: String) throws {
    let status = SecItemUpdate(
      exactQuery(account: account) as CFDictionary,
      [kSecValueData as String: value] as CFDictionary
    )
    if status == errSecItemNotFound {
      try create(value: value, account: account)
      return
    }
    guard status == errSecSuccess else {
      throw AuditSigningKeyStoreError.keychainFailure(status)
    }
  }

  private func exactQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrGeneric as String: Self.ownershipMarker,
      kSecAttrSynchronizable as String: false,
    ]
  }
}
