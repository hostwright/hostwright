import CryptoKit
import Foundation
import LocalAuthentication
import Security
import X509

public enum CertificateIdentityStoreError: Error, Equatable, Sendable {
  case invalidScope
  case invalidFingerprint
  case invalidDNSName
  case invalidValidity
  case notFound
  case duplicate
  case keychainLocked
  case accessDenied
  case cancelled
  case tampered
  case validationFailed
  case keychainFailure(Int32)
}

public struct CertificateIdentityScope: Hashable, Sendable {
  public let projectUUID: String
  public let certificateUUID: String
  public let generation: Int

  public init(
    projectUUID: String,
    certificateUUID: String,
    generation: Int
  ) throws {
    guard
      Self.isCanonicalUUID(projectUUID),
      Self.isCanonicalUUID(certificateUUID),
      generation > 0
    else {
      throw CertificateIdentityStoreError.invalidScope
    }
    self.projectUUID = projectUUID
    self.certificateUUID = certificateUUID
    self.generation = generation
  }

  public init(
    projectUUID: UUID,
    certificateUUID: UUID,
    generation: Int
  ) throws {
    try self.init(
      projectUUID: projectUUID.uuidString.lowercased(),
      certificateUUID: certificateUUID.uuidString.lowercased(),
      generation: generation
    )
  }

  public var keychainLocator: String {
    "\(projectUUID).\(certificateUUID).g\(generation)"
  }

  private static func isCanonicalUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }
}

public enum CertificateRevocationStatus: String, Equatable, Sendable {
  case unavailable
  case suppliedGood
  case suppliedRevoked
}

public struct CertificateIdentityMetadata: Equatable, Sendable {
  public let certificateSHA256: String
  public let issuerCertificateSHA256: String?
  public let dnsNames: [String]
  public let uriNames: [String]
  public let supportsServerAuthentication: Bool
  public let supportsClientAuthentication: Bool
  public let notValidBefore: Date
  public let notValidAfter: Date
  public let revocationStatus: CertificateRevocationStatus

  public init(
    certificateSHA256: String,
    dnsNames: [String],
    uriNames: [String] = [],
    supportsServerAuthentication: Bool = false,
    supportsClientAuthentication: Bool = false,
    notValidBefore: Date,
    notValidAfter: Date,
    revocationStatus: CertificateRevocationStatus = .unavailable,
    issuerCertificateSHA256: String? = nil
  ) {
    self.certificateSHA256 = certificateSHA256
    self.issuerCertificateSHA256 = issuerCertificateSHA256
    self.dnsNames = dnsNames
    self.uriNames = uriNames
    self.supportsServerAuthentication = supportsServerAuthentication
    self.supportsClientAuthentication = supportsClientAuthentication
    self.notValidBefore = notValidBefore
    self.notValidAfter = notValidAfter
    self.revocationStatus = revocationStatus
  }
}

/// The intended peer class is part of the client identity issuance contract.
/// It does not grant any network behaviour by itself.
public enum ManagedClientIdentityRole: String, CaseIterable, Sendable {
  case workload
  case ingress
  case tunnel
  case node
}

public struct CertificateIdentityHandle: @unchecked Sendable {
  public let identity: SecIdentity
  public let metadata: CertificateIdentityMetadata
  public let managedScope: CertificateIdentityScope?
  /// Issuer certificates for serving, ordered nearest issuer first.
  /// The leaf is represented by `identity` and is not duplicated here.
  public let certificateChain: [SecCertificate]

  fileprivate init(
    identity: SecIdentity,
    metadata: CertificateIdentityMetadata,
    managedScope: CertificateIdentityScope?,
    certificateChain: [SecCertificate]
  ) {
    self.identity = identity
    self.metadata = metadata
    self.managedScope = managedScope
    self.certificateChain = certificateChain
  }
}

public struct ManagedCertificateIdentityEvidence: @unchecked Sendable {
  public let handle: CertificateIdentityHandle
  public let issuerCertificateSHA256: String

  fileprivate init(
    handle: CertificateIdentityHandle,
    issuerCertificateSHA256: String
  ) {
    self.handle = handle
    self.issuerCertificateSHA256 = issuerCertificateSHA256
  }
}

public struct CertificateIdentityRotation: @unchecked Sendable {
  public let current: CertificateIdentityHandle
  public let prior: CertificateIdentityHandle?
}

/// Stores Hostwright-generated TLS identities without exporting private keys.
///
/// Managed identities are located exclusively by immutable UUID-backed scope.
/// Imported identities are fingerprint-resolved and are never cleanup targets.
public final class CertificateIdentityStore: @unchecked Sendable {
  public static let applicationTagPrefix =
    "dev.hostwright.network-helper.certificate-identity.v1"
  public static let maximumLeafValidity: TimeInterval =
    60 * 60 * 24 * 365

  private enum Role: String, CaseIterable {
    case issuer
    case leaf
    case clientLeaf
  }

  public init() {}

  public func resolveImportedIdentity(
    certificateSHA256: String
  ) throws -> CertificateIdentityHandle {
    let expected = try Self.canonicalFingerprint(certificateSHA256)
    let context = Self.nonInteractiveContext()
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecReturnRef: true,
      kSecMatchLimit: kSecMatchLimitAll,
      kSecUseAuthenticationContext: context,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw Self.mapKeychainStatus(status)
    }
    guard let identities = result as? [SecIdentity] else {
      throw CertificateIdentityStoreError.tampered
    }

    for identity in identities {
      guard let certificate = try? certificate(for: identity) else {
        continue
      }
      if fingerprint(certificate) == expected {
        return CertificateIdentityHandle(
          identity: identity,
          metadata: try metadata(for: certificate),
          managedScope: nil,
          certificateChain:
            validatedSystemTrustChain(for: certificate)
        )
      }
    }
    throw CertificateIdentityStoreError.notFound
  }

  public func generateLocalIdentity(
    scope: CertificateIdentityScope,
    dnsNames: [String],
    uriSAN: String? = nil,
    validity: TimeInterval = 60 * 60 * 24 * 30,
    now: Date = Date()
  ) throws -> CertificateIdentityHandle {
    let names = try Self.canonicalDNSNames(dnsNames)
    let uriName = try uriSAN.map { try Self.canonicalURI($0) }
    let subjectAlternativeNames: [GeneralName] =
      names.map { .dnsName($0) }
      + (uriName.map { [.uniformResourceIdentifier($0)] } ?? [])
    try Self.validateValidity(validity)
    try refuseManagedCollision(scope: scope)

    var createdKeys: [(Role, SecKey)] = []
    var createdCertificates: [(Role, SecCertificate)] = []

    do {
      let issuerKey = try generateKey(scope: scope, role: .issuer)
      createdKeys.append((.issuer, issuerKey))
      let leafKey = try generateKey(scope: scope, role: .leaf)
      createdKeys.append((.leaf, leafKey))

      let notValidBefore = now.addingTimeInterval(-60)
      let notValidAfter = now.addingTimeInterval(validity)
      let issuerName = try DistinguishedName {
        OrganizationName("Hostwright")
        CommonName("Hostwright Local CA \(scope.certificateUUID)")
      }
      let issuerPrivateKey = try Certificate.PrivateKey(issuerKey)
      let issuerCertificate = try Certificate(
        version: .v3,
        serialNumber: .init(),
        publicKey: issuerPrivateKey.publicKey,
        notValidBefore: notValidBefore,
        notValidAfter: notValidAfter,
        issuer: issuerName,
        subject: issuerName,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: Certificate.Extensions {
          Critical(
            BasicConstraints.isCertificateAuthority(
              maxPathLength: 0
            )
          )
          Critical(KeyUsage(keyCertSign: true, cRLSign: true))
          SubjectKeyIdentifier(hash: issuerPrivateKey.publicKey)
        },
        issuerPrivateKey: issuerPrivateKey
      )

      let leafPrivateKey = try Certificate.PrivateKey(leafKey)
      let leafName = try DistinguishedName {
        OrganizationName("Hostwright")
        CommonName(names[0])
      }
      let authorityKeyIdentifier = try issuerCertificate.extensions
        .subjectKeyIdentifier!.keyIdentifier
      let serverAuth = try ExtendedKeyUsage([.serverAuth])
      let leafCertificate = try Certificate(
        version: .v3,
        serialNumber: .init(),
        publicKey: leafPrivateKey.publicKey,
        notValidBefore: notValidBefore,
        notValidAfter: notValidAfter,
        issuer: issuerName,
        subject: leafName,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: Certificate.Extensions {
          Critical(BasicConstraints.notCertificateAuthority)
          Critical(KeyUsage(digitalSignature: true))
          serverAuth
          SubjectAlternativeNames(subjectAlternativeNames)
          SubjectKeyIdentifier(hash: leafPrivateKey.publicKey)
          AuthorityKeyIdentifier(
            keyIdentifier: authorityKeyIdentifier
          )
        },
        issuerPrivateKey: issuerPrivateKey
      )
      guard leafCertificate.notValidAfter <= issuerCertificate.notValidAfter
      else {
        throw CertificateIdentityStoreError.invalidValidity
      }

      let issuerSecCertificate =
        try SecCertificate.makeWithCertificate(issuerCertificate)
      let leafSecCertificate =
        try SecCertificate.makeWithCertificate(leafCertificate)
      try addCertificate(
        issuerSecCertificate,
        scope: scope,
        role: .issuer
      )
      createdCertificates.append((.issuer, issuerSecCertificate))
      try addCertificate(
        leafSecCertificate,
        scope: scope,
        role: .leaf
      )
      createdCertificates.append((.leaf, leafSecCertificate))

      let recoveredIssuerCertificate = try copyCertificate(
        scope: scope,
        role: .issuer
      )
      let recoveredLeafCertificate = try copyCertificate(
        scope: scope,
        role: .leaf
      )
      let recoveredIssuerKey = try copyKey(
        scope: scope,
        role: .issuer
      )
      let recoveredLeafKey = try copyKey(
        scope: scope,
        role: .leaf
      )
      guard
        fingerprint(recoveredIssuerCertificate)
          == fingerprint(issuerSecCertificate),
        fingerprint(recoveredLeafCertificate)
          == fingerprint(leafSecCertificate)
      else {
        throw CertificateIdentityStoreError.tampered
      }
      let evidence = try makeManagedEvidence(
        scope: scope,
        leafCertificate: recoveredLeafCertificate,
        issuerCertificate: recoveredIssuerCertificate,
        leafKey: recoveredLeafKey,
        issuerKey: recoveredIssuerKey,
        expectedDNSNames: names,
        now: now
      )
      return evidence.handle
    } catch {
      compensate(
        certificates: createdCertificates,
        keys: createdKeys,
        scope: scope
      )
      throw error
    }
  }

  public func resolveManagedIdentity(
    scope: CertificateIdentityScope,
    expectedLeafSHA256: String,
    expectedIssuerSHA256: String,
    now: Date = Date()
  ) throws -> CertificateIdentityHandle {
    let expectedLeaf = try Self.canonicalFingerprint(
      expectedLeafSHA256
    )
    let expectedIssuer = try Self.canonicalFingerprint(
      expectedIssuerSHA256
    )
    let evidence = try managedIdentityEvidence(
      scope: scope,
      now: now
    )
    guard
      evidence.handle.metadata.certificateSHA256 == expectedLeaf,
      evidence.issuerCertificateSHA256 == expectedIssuer
    else {
      throw CertificateIdentityStoreError.tampered
    }
    return evidence.handle
  }

  /// Issues a client-authentication-only leaf from the CA already owned by
  /// `issuerScope`.  The peer scope contains only this leaf and its key.
  public func issueManagedClientIdentity(
    issuerScope: CertificateIdentityScope,
    peerScope: CertificateIdentityScope,
    role: ManagedClientIdentityRole,
    uriSAN: String,
    validity: TimeInterval = 60 * 60,
    now: Date = Date()
  ) throws -> CertificateIdentityHandle {
    guard issuerScope != peerScope else {
      throw CertificateIdentityStoreError.invalidScope
    }
    let uri = try Self.canonicalURI(uriSAN)
    guard Self.matches(uri: uri, scope: peerScope, role: role) else {
      throw CertificateIdentityStoreError.validationFailed
    }
    try Self.validateValidity(validity)
    try refuseManagedCollision(scope: peerScope)

    let issuerCertificate = try copyCertificate(scope: issuerScope, role: .issuer)
    let issuerKey = try copyKey(scope: issuerScope, role: .issuer)
    try requireManagedOwnership(
      certificate: issuerCertificate,
      key: issuerKey,
      scope: issuerScope,
      role: .issuer
    )
    let issuer = try Certificate(issuerCertificate)
    try validateIssuer(issuer, key: issuerKey)

    var createdKeys: [(Role, SecKey)] = []
    var createdCertificates: [(Role, SecCertificate)] = []
    do {
      let leafKey = try generateKey(scope: peerScope, role: .clientLeaf)
      createdKeys.append((.clientLeaf, leafKey))
      let leafPrivateKey = try Certificate.PrivateKey(leafKey)
      let authorityKeyIdentifier = try issuer.extensions
        .subjectKeyIdentifier!.keyIdentifier
      let clientAuth = try ExtendedKeyUsage([.clientAuth])
      let leaf = try Certificate(
        version: .v3,
        serialNumber: .init(),
        publicKey: leafPrivateKey.publicKey,
        notValidBefore: now.addingTimeInterval(-60),
        notValidAfter: now.addingTimeInterval(validity),
        issuer: issuer.subject,
        subject: try DistinguishedName {
          OrganizationName("Hostwright")
          CommonName("Hostwright \(role.rawValue) peer")
        },
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: Certificate.Extensions {
          Critical(BasicConstraints.notCertificateAuthority)
          Critical(KeyUsage(digitalSignature: true))
          clientAuth
          SubjectAlternativeNames([.uniformResourceIdentifier(uri)])
          SubjectKeyIdentifier(hash: leafPrivateKey.publicKey)
          AuthorityKeyIdentifier(keyIdentifier: authorityKeyIdentifier)
        },
        issuerPrivateKey: try Certificate.PrivateKey(issuerKey)
      )
      guard leaf.notValidAfter <= issuer.notValidAfter else {
        throw CertificateIdentityStoreError.invalidValidity
      }
      let secLeaf = try SecCertificate.makeWithCertificate(leaf)
      try addCertificate(secLeaf, scope: peerScope, role: .clientLeaf)
      createdCertificates.append((.clientLeaf, secLeaf))
      return try makeManagedClientIdentity(
        peerScope: peerScope,
        leafCertificate: secLeaf,
        leafKey: leafKey,
        issuerCertificate: issuerCertificate,
        expectedURI: uri,
        now: now
      )
    } catch {
      compensate(certificates: createdCertificates, keys: createdKeys, scope: peerScope)
      throw error
    }
  }

  public func resolveManagedClientIdentity(
    issuerScope: CertificateIdentityScope,
    peerScope: CertificateIdentityScope,
    expectedLeafSHA256: String,
    expectedIssuerSHA256: String,
    expectedURI: String,
    now: Date = Date(),
    clockSkew: TimeInterval = 300
  ) throws -> CertificateIdentityHandle {
    let leaf = try copyCertificate(scope: peerScope, role: .clientLeaf)
    let key = try copyKey(scope: peerScope, role: .clientLeaf)
    let issuer = try copyCertificate(scope: issuerScope, role: .issuer)
    let issuerKey = try copyKey(scope: issuerScope, role: .issuer)
    try requireManagedOwnership(
      certificate: issuer,
      key: issuerKey,
      scope: issuerScope,
      role: .issuer
    )
    let expectedLeaf = try Self.canonicalFingerprint(expectedLeafSHA256)
    let expectedIssuer = try Self.canonicalFingerprint(expectedIssuerSHA256)
    guard fingerprint(leaf) == expectedLeaf,
      fingerprint(issuer) == expectedIssuer
    else {
      throw CertificateIdentityStoreError.tampered
    }
    return try makeManagedClientIdentity(
      peerScope: peerScope, leafCertificate: leaf, leafKey: key, issuerCertificate: issuer,
      expectedURI: try Self.canonicalURI(expectedURI), now: now, clockSkew: clockSkew)
  }

  /// Recovers a completed client identity after a crash that happened before
  /// its leaf fingerprint was persisted.
  public func managedClientIdentityEvidence(
    issuerScope: CertificateIdentityScope,
    peerScope: CertificateIdentityScope,
    expectedURI: String,
    now: Date = Date(),
    clockSkew: TimeInterval = 300
  ) throws -> CertificateIdentityHandle {
    let leaf = try copyCertificate(
      scope: peerScope,
      role: .clientLeaf
    )
    let key = try copyKey(scope: peerScope, role: .clientLeaf)
    let issuer = try copyCertificate(
      scope: issuerScope,
      role: .issuer
    )
    let issuerKey = try copyKey(
      scope: issuerScope,
      role: .issuer
    )
    try requireManagedOwnership(
      certificate: issuer,
      key: issuerKey,
      scope: issuerScope,
      role: .issuer
    )
    return try makeManagedClientIdentity(
      peerScope: peerScope,
      leafCertificate: leaf,
      leafKey: key,
      issuerCertificate: issuer,
      expectedURI: try Self.canonicalURI(expectedURI),
      now: now,
      clockSkew: clockSkew
    )
  }

  public func validateManagedClientIdentity(
    _ handle: CertificateIdentityHandle,
    expectedURI: String,
    expectedCA: SecCertificate,
    now: Date = Date(),
    clockSkew: TimeInterval = 300
  ) throws {
    guard clockSkew >= 0, clockSkew <= 300 else {
      throw CertificateIdentityStoreError.validationFailed
    }
    let certificate = try certificate(for: handle.identity)
    let parsed = try Certificate(certificate)
    guard parsed.notValidBefore <= now.addingTimeInterval(clockSkew),
      parsed.notValidAfter >= now.addingTimeInterval(-clockSkew),
      try parsed.extensions.extendedKeyUsage?.contains(.clientAuth) == true,
      try parsed.extensions.extendedKeyUsage?.contains(.serverAuth) == false,
      try Self.dnsNames(from: parsed).isEmpty,
      try Self.uriNames(from: parsed) == [try Self.canonicalURI(expectedURI)],
      parsed.issuer == (try Certificate(expectedCA)).subject
    else {
      throw CertificateIdentityStoreError.validationFailed
    }
    var trust: SecTrust?
    guard
      SecTrustCreateWithCertificates(
        [certificate, expectedCA] as CFTypeRef, SecPolicyCreateBasicX509(), &trust)
        == errSecSuccess,
      let trust
    else { throw CertificateIdentityStoreError.validationFailed }
    SecTrustSetAnchorCertificates(trust, [expectedCA] as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    SecTrustSetVerifyDate(trust, now as CFDate)
    var error: CFError?
    guard SecTrustEvaluateWithError(trust, &error) else {
      throw CertificateIdentityStoreError.validationFailed
    }
  }

  public func cleanupManagedClientIdentity(
    peerScope: CertificateIdentityScope,
    expectedLeafSHA256: String
  ) throws {
    let expected = try Self.canonicalFingerprint(expectedLeafSHA256)
    let certificate = try copyCertificateIfPresent(scope: peerScope, role: .clientLeaf)
    let key = try copyKeyIfPresent(scope: peerScope, role: .clientLeaf)
    if let certificate, fingerprint(certificate) != expected {
      throw CertificateIdentityStoreError.tampered
    }
    if let certificate, let key {
      try requireManagedOwnership(
        certificate: certificate, key: key, scope: peerScope, role: .clientLeaf)
    } else if let key {
      try requireKeyAttributes(key)
    }
    if let certificate { try deleteCertificate(certificate, scope: peerScope, role: .clientLeaf) }
    if let key { try deleteKey(key, scope: peerScope, role: .clientLeaf) }
  }

  /// Recovers a completed managed Keychain identity after a crash that
  /// occurred before its public fingerprints were persisted.
  public func managedIdentityEvidence(
    scope: CertificateIdentityScope,
    now: Date = Date()
  ) throws -> ManagedCertificateIdentityEvidence {
    let leafCertificate = try copyCertificate(
      scope: scope,
      role: .leaf
    )
    let issuerCertificate = try copyCertificate(
      scope: scope,
      role: .issuer
    )
    let leafKey = try copyKey(scope: scope, role: .leaf)
    let issuerKey = try copyKey(scope: scope, role: .issuer)
    let leaf = try Certificate(leafCertificate)
    return try makeManagedEvidence(
      scope: scope,
      leafCertificate: leafCertificate,
      issuerCertificate: issuerCertificate,
      leafKey: leafKey,
      issuerKey: issuerKey,
      expectedDNSNames: try Self.dnsNames(from: leaf),
      now: now
    )
  }

  public func validatedRotation(
    current: CertificateIdentityHandle,
    prior: CertificateIdentityHandle?,
    expectedDNSNames: [String],
    expectedCA: SecCertificate? = nil,
    now: Date = Date()
  ) throws -> CertificateIdentityRotation {
    try validate(
      current,
      expectedDNSNames: expectedDNSNames,
      expectedCA: expectedCA,
      now: now
    )
    if let prior {
      try validate(
        prior,
        expectedDNSNames: expectedDNSNames,
        expectedCA: expectedCA,
        now: now
      )
    }
    return CertificateIdentityRotation(current: current, prior: prior)
  }

  public func validate(
    _ handle: CertificateIdentityHandle,
    expectedDNSNames: [String],
    expectedCA: SecCertificate? = nil,
    now: Date = Date(),
    clockSkew: TimeInterval = 300
  ) throws {
    guard clockSkew >= 0, clockSkew <= 300 else {
      throw CertificateIdentityStoreError.validationFailed
    }
    let expectedNames = try Self.canonicalDNSNames(expectedDNSNames)
    let certificate = try certificate(for: handle.identity)
    let parsed = try Certificate(certificate)
    let extendedKeyUsage = try parsed.extensions.extendedKeyUsage
    let actualNames = try Self.dnsNames(from: parsed)

    guard
      parsed.notValidBefore <= now.addingTimeInterval(clockSkew),
      parsed.notValidAfter >= now.addingTimeInterval(-clockSkew),
      extendedKeyUsage?.contains(.serverAuth) == true,
      actualNames == expectedNames
    else {
      throw CertificateIdentityStoreError.validationFailed
    }

    var trust: SecTrust?
    let policy = SecPolicyCreateSSL(true, expectedNames[0] as CFString)
    let chain: [SecCertificate] =
      expectedCA.map {
        [certificate, $0]
      } ?? [certificate]
    guard
      SecTrustCreateWithCertificates(
        chain as CFTypeRef,
        policy,
        &trust
      ) == errSecSuccess,
      let trust
    else {
      throw CertificateIdentityStoreError.validationFailed
    }
    if let expectedCA {
      SecTrustSetAnchorCertificates(trust, [expectedCA] as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, true)
    }
    SecTrustSetVerifyDate(trust, now as CFDate)
    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError) else {
      throw CertificateIdentityStoreError.validationFailed
    }
  }

  public func cleanupManagedIdentity(
    scope: CertificateIdentityScope,
    expectedLeafSHA256: String,
    expectedIssuerSHA256: String
  ) throws {
    let expectedLeaf = try Self.canonicalFingerprint(
      expectedLeafSHA256
    )
    let expectedIssuer = try Self.canonicalFingerprint(
      expectedIssuerSHA256
    )
    let leafCertificate = try copyCertificateIfPresent(
      scope: scope,
      role: .leaf
    )
    let issuerCertificate = try copyCertificateIfPresent(
      scope: scope,
      role: .issuer
    )
    let leafKey = try copyKeyIfPresent(scope: scope, role: .leaf)
    let issuerKey = try copyKeyIfPresent(
      scope: scope,
      role: .issuer
    )

    if let leafCertificate,
      fingerprint(leafCertificate) != expectedLeaf
    {
      throw CertificateIdentityStoreError.tampered
    }
    if let issuerCertificate,
      fingerprint(issuerCertificate) != expectedIssuer
    {
      throw CertificateIdentityStoreError.tampered
    }
    if let leafKey {
      try requireKeyAttributes(leafKey)
    }
    if let issuerKey {
      try requireKeyAttributes(issuerKey)
    }
    if let leafCertificate, let leafKey {
      try requireManagedOwnership(
        certificate: leafCertificate,
        key: leafKey,
        scope: scope,
        role: .leaf
      )
    }
    if let issuerCertificate, let issuerKey {
      try requireManagedOwnership(
        certificate: issuerCertificate,
        key: issuerKey,
        scope: scope,
        role: .issuer
      )
    }

    if let leafCertificate {
      try deleteCertificate(
        leafCertificate,
        scope: scope,
        role: .leaf
      )
    }
    if let issuerCertificate {
      try deleteCertificate(
        issuerCertificate,
        scope: scope,
        role: .issuer
      )
    }
    if let leafKey {
      try deleteKey(leafKey, scope: scope, role: .leaf)
    }
    if let issuerKey {
      try deleteKey(issuerKey, scope: scope, role: .issuer)
    }
  }

  static func canonicalFingerprint(_ value: String) throws -> String {
    guard
      value.utf8.count == 64,
      value.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else {
      throw CertificateIdentityStoreError.invalidFingerprint
    }
    return value
  }

  static func canonicalDNSNames(_ values: [String]) throws -> [String] {
    let names = values.map { $0.lowercased() }.sorted()
    guard
      !names.isEmpty,
      names.allSatisfy({
        $0.range(
          of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
            + "(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}"
            + "[a-z0-9])?)*$",
          options: .regularExpression
        ) != nil
      }),
      Set(names).count == names.count
    else {
      throw CertificateIdentityStoreError.invalidDNSName
    }
    return names
  }

  static func canonicalURI(_ value: String) throws -> String {
    guard let components = URLComponents(string: value),
      components.scheme == "spiffe",
      components.host == "hostwright.internal",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil,
      components.string == value,
      value.utf8.count <= 512,
      !value.contains(where: { $0.isWhitespace })
    else {
      throw CertificateIdentityStoreError.validationFailed
    }
    let fields = components.path.split(separator: "/", omittingEmptySubsequences: true)
    guard fields.count == 8,
      fields[0] == "projects",
      Self.isCanonicalURIUUID(String(fields[1])),
      fields[2] == "resources",
      Self.isCanonicalURIUUID(String(fields[3])),
      fields[4] == "roles",
      ManagedClientIdentityRole(rawValue: String(fields[5])) != nil,
      fields[6] == "generations",
      let generation = Int(fields[7]), generation > 0,
      String(generation) == fields[7]
    else {
      throw CertificateIdentityStoreError.validationFailed
    }
    return value
  }

  private static func matches(
    uri: String,
    scope: CertificateIdentityScope,
    role: ManagedClientIdentityRole
  ) -> Bool {
    guard let components = URLComponents(string: uri) else { return false }
    let fields = components.path.split(separator: "/", omittingEmptySubsequences: true)
    return fields.count == 8
      && fields[1] == scope.projectUUID
      && fields[5] == role.rawValue
      && fields[7] == String(scope.generation)
  }

  private static func isCanonicalURIUUID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }

  static func validateValidity(_ validity: TimeInterval) throws {
    guard validity > 0, validity <= maximumLeafValidity else {
      throw CertificateIdentityStoreError.invalidValidity
    }
  }

  static func mapKeychainStatus(
    _ status: OSStatus
  ) -> CertificateIdentityStoreError {
    switch status {
    case errSecItemNotFound:
      .notFound
    case errSecDuplicateItem:
      .duplicate
    case errSecInteractionNotAllowed:
      .keychainLocked
    case errSecAuthFailed, errSecNotAvailable:
      .accessDenied
    case errSecUserCanceled:
      .cancelled
    default:
      .keychainFailure(status)
    }
  }

  private static func nonInteractiveContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }

  private func refuseManagedCollision(
    scope: CertificateIdentityScope
  ) throws {
    for role in Role.allCases {
      if try itemExists(keyQuery(scope: scope, role: role)) {
        throw CertificateIdentityStoreError.duplicate
      }
      if try itemExists(certificateQuery(scope: scope, role: role)) {
        throw CertificateIdentityStoreError.duplicate
      }
    }
  }

  private func itemExists(_ query: [CFString: Any]) throws -> Bool {
    var query = query
    query[kSecReturnRef] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
    query[kSecUseAuthenticationContext] =
      Self.nonInteractiveContext()
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      return true
    case errSecItemNotFound:
      return false
    default:
      throw Self.mapKeychainStatus(status)
    }
  }

  private func generateKey(
    scope: CertificateIdentityScope,
    role: Role
  ) throws -> SecKey {
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecAttrIsSensitive: true,
      kSecAttrIsExtractable: false,
      kSecPrivateKeyAttrs: [
        kSecAttrIsPermanent: true,
        kSecAttrIsSensitive: true,
        kSecAttrIsExtractable: false,
        kSecAttrApplicationTag: applicationTag(
          scope: scope,
          role: role
        ),
        kSecAttrLabel: label(scope: scope, role: role),
        kSecAttrAccessible:
          kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecAttrSynchronizable: false,
      ],
    ]
    var error: Unmanaged<CFError>?
    guard
      let key = SecKeyCreateRandomKey(
        attributes as CFDictionary,
        &error
      )
    else {
      if let error = error?.takeRetainedValue() {
        let status = OSStatus((error as Error as NSError).code)
        throw Self.mapKeychainStatus(status)
      }
      throw CertificateIdentityStoreError.keychainFailure(errSecParam)
    }
    return key
  }

  private func addCertificate(
    _ certificate: SecCertificate,
    scope: CertificateIdentityScope,
    role: Role
  ) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecValueRef: certificate,
      kSecAttrLabel: label(scope: scope, role: role),
      kSecAttrAccessible:
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable: false,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw Self.mapKeychainStatus(status)
    }
    let exactReference: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecValueRef: certificate,
    ]
    let updateStatus = SecItemUpdate(
      exactReference as CFDictionary,
      [kSecAttrLabel: label(scope: scope, role: role)]
        as CFDictionary
    )
    guard updateStatus == errSecSuccess else {
      _ = SecItemDelete(exactReference as CFDictionary)
      throw Self.mapKeychainStatus(updateStatus)
    }
  }

  private func copyKey(
    scope: CertificateIdentityScope,
    role: Role
  ) throws -> SecKey {
    guard let key = try copyKeyIfPresent(scope: scope, role: role)
    else {
      throw CertificateIdentityStoreError.notFound
    }
    return key
  }

  private func copyKeyIfPresent(
    scope: CertificateIdentityScope,
    role: Role
  ) throws -> SecKey? {
    var query = keyQuery(scope: scope, role: role)
    query[kSecReturnRef] = true
    query[kSecMatchLimit] = kSecMatchLimitAll
    query[kSecAttrSynchronizable] = false
    query[kSecUseAuthenticationContext] =
      Self.nonInteractiveContext()
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw Self.mapKeychainStatus(status)
    }
    guard let keys = result as? [SecKey], keys.count == 1 else {
      throw CertificateIdentityStoreError.tampered
    }
    try requireKeyAttributes(keys[0])
    return keys[0]
  }

  private func copyCertificate(
    scope: CertificateIdentityScope,
    role: Role
  ) throws -> SecCertificate {
    guard
      let certificate = try copyCertificateIfPresent(
        scope: scope,
        role: role
      )
    else {
      throw CertificateIdentityStoreError.notFound
    }
    return certificate
  }

  private func copyCertificateIfPresent(
    scope: CertificateIdentityScope,
    role: Role
  ) throws -> SecCertificate? {
    var query = certificateQuery(scope: scope, role: role)
    query[kSecReturnRef] = true
    query[kSecMatchLimit] = kSecMatchLimitAll
    query[kSecUseAuthenticationContext] =
      Self.nonInteractiveContext()
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw Self.mapKeychainStatus(status)
    }
    guard
      let certificates = result as? [SecCertificate],
      certificates.count == 1
    else {
      throw CertificateIdentityStoreError.tampered
    }
    return certificates[0]
  }

  private func makeManagedEvidence(
    scope: CertificateIdentityScope,
    leafCertificate: SecCertificate,
    issuerCertificate: SecCertificate,
    leafKey: SecKey,
    issuerKey: SecKey,
    expectedDNSNames: [String],
    now: Date
  ) throws -> ManagedCertificateIdentityEvidence {
    try requireManagedOwnership(
      certificate: leafCertificate,
      key: leafKey,
      scope: scope,
      role: .leaf
    )
    let identity = try self.identity(
      certificate: leafCertificate,
      expectedKey: leafKey
    )
    let issuerSHA256 = fingerprint(issuerCertificate)
    let handle = CertificateIdentityHandle(
      identity: identity,
      metadata: try metadata(
        for: leafCertificate,
        issuerCertificateSHA256: issuerSHA256
      ),
      managedScope: scope,
      certificateChain: [issuerCertificate]
    )
    try validateManagedPair(
      handle: handle,
      issuerCertificate: issuerCertificate,
      issuerKey: issuerKey,
      expectedDNSNames: expectedDNSNames,
      now: now
    )
    return ManagedCertificateIdentityEvidence(
      handle: handle,
      issuerCertificateSHA256: issuerSHA256
    )
  }

  private func makeManagedClientIdentity(
    peerScope: CertificateIdentityScope,
    leafCertificate: SecCertificate,
    leafKey: SecKey,
    issuerCertificate: SecCertificate,
    expectedURI: String,
    now: Date,
    clockSkew: TimeInterval = 300
  ) throws -> CertificateIdentityHandle {
    try requireManagedOwnership(
      certificate: leafCertificate, key: leafKey, scope: peerScope, role: .clientLeaf)
    let identity = try identity(certificate: leafCertificate, expectedKey: leafKey)
    let handle = CertificateIdentityHandle(
      identity: identity,
      metadata: try metadata(
        for: leafCertificate, issuerCertificateSHA256: fingerprint(issuerCertificate)),
      managedScope: peerScope,
      certificateChain: [issuerCertificate]
    )
    try validateManagedClientIdentity(
      handle, expectedURI: expectedURI, expectedCA: issuerCertificate, now: now,
      clockSkew: clockSkew)
    return handle
  }

  private func validateIssuer(_ issuer: Certificate, key: SecKey) throws {
    let constraints = try issuer.extensions.basicConstraints
    let usage = try issuer.extensions.keyUsage
    guard constraints == .isCertificateAuthority(maxPathLength: 0),
      usage?.keyCertSign == true,
      issuer.subject == issuer.issuer,
      try issuer.extensions.subjectKeyIdentifier != nil
    else {
      throw CertificateIdentityStoreError.validationFailed
    }
    try requireKeyAttributes(key)
  }

  private func validateManagedPair(
    handle: CertificateIdentityHandle,
    issuerCertificate: SecCertificate,
    issuerKey: SecKey,
    expectedDNSNames: [String],
    now: Date
  ) throws {
    guard let scope = handle.managedScope else {
      throw CertificateIdentityStoreError.tampered
    }
    try requireManagedOwnership(
      certificate: issuerCertificate,
      key: issuerKey,
      scope: scope,
      role: .issuer
    )
    _ = try identity(
      certificate: issuerCertificate,
      expectedKey: issuerKey
    )

    let issuer = try Certificate(issuerCertificate)
    let leafCertificate = try certificate(for: handle.identity)
    let leaf = try Certificate(leafCertificate)
    let basicConstraints = try issuer.extensions.basicConstraints
    let keyUsage = try issuer.extensions.keyUsage
    guard
      basicConstraints
        == .isCertificateAuthority(maxPathLength: 0),
      keyUsage?.keyCertSign == true,
      issuer.subject == issuer.issuer,
      leaf.issuer == issuer.subject,
      leaf.notValidAfter <= issuer.notValidAfter
    else {
      throw CertificateIdentityStoreError.validationFailed
    }
    try validate(
      handle,
      expectedDNSNames: expectedDNSNames,
      expectedCA: issuerCertificate,
      now: now
    )
  }

  private func requireManagedOwnership(
    certificate: SecCertificate,
    key: SecKey,
    scope: CertificateIdentityScope,
    role: Role
  ) throws {
    try requireKeyAttributes(key)
    guard try publicKeyData(key) == publicKeyData(certificate) else {
      throw CertificateIdentityStoreError.tampered
    }
    _ = try identity(certificate: certificate, expectedKey: key)
  }

  private func requireKeyAttributes(_ key: SecKey) throws {
    guard let attributes = SecKeyCopyAttributes(key) as NSDictionary?
    else {
      throw CertificateIdentityStoreError.tampered
    }
    let expectedKeyType = Int(
      kSecAttrKeyTypeECSECPrimeRandom as String
    )
    let keyType =
      (attributes[kSecAttrKeyType] as? NSNumber)?.intValue
      ?? Int(attributes[kSecAttrKeyType] as? String ?? "")
    let keySize =
      (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue
      ?? Int(attributes[kSecAttrKeySizeInBits] as? String ?? "")
    let isPermanent =
      (attributes[kSecAttrIsPermanent] as? NSNumber)?.boolValue
      ?? (attributes[kSecAttrIsPermanent] as? Bool)
    let isExtractable =
      (attributes[kSecAttrIsExtractable] as? NSNumber)?.boolValue
      ?? (attributes[kSecAttrIsExtractable] as? Bool)
    guard
      keyType == expectedKeyType,
      keySize == 256,
      isPermanent == true,
      isExtractable == false
    else {
      throw CertificateIdentityStoreError.tampered
    }
  }

  private func identity(
    certificate: SecCertificate,
    expectedKey: SecKey
  ) throws -> SecIdentity {
    var identity: SecIdentity?
    let status = SecIdentityCreateWithCertificate(
      nil,
      certificate,
      &identity
    )
    guard status == errSecSuccess, let identity else {
      throw Self.mapKeychainStatus(status)
    }
    var identityKey: SecKey?
    guard
      SecIdentityCopyPrivateKey(identity, &identityKey) == errSecSuccess,
      let identityKey,
      try publicKeyData(identityKey) == publicKeyData(expectedKey)
    else {
      throw CertificateIdentityStoreError.tampered
    }
    return identity
  }

  private func certificate(
    for identity: SecIdentity
  ) throws -> SecCertificate {
    var certificate: SecCertificate?
    guard
      SecIdentityCopyCertificate(identity, &certificate)
        == errSecSuccess,
      let certificate
    else {
      throw CertificateIdentityStoreError.tampered
    }
    return certificate
  }

  private func publicKeyData(_ key: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(key) else {
      throw CertificateIdentityStoreError.tampered
    }
    var error: Unmanaged<CFError>?
    guard
      let data = SecKeyCopyExternalRepresentation(
        publicKey,
        &error
      ) as Data?
    else {
      throw CertificateIdentityStoreError.tampered
    }
    return data
  }

  private func publicKeyData(
    _ certificate: SecCertificate
  ) throws -> Data {
    guard let key = SecCertificateCopyKey(certificate) else {
      throw CertificateIdentityStoreError.tampered
    }
    var error: Unmanaged<CFError>?
    guard
      let data = SecKeyCopyExternalRepresentation(
        key,
        &error
      ) as Data?
    else {
      throw CertificateIdentityStoreError.tampered
    }
    return data
  }

  private func metadata(
    for certificate: SecCertificate,
    issuerCertificateSHA256: String? = nil
  ) throws -> CertificateIdentityMetadata {
    let parsed = try Certificate(certificate)
    let extendedKeyUsage = try parsed.extensions.extendedKeyUsage
    return CertificateIdentityMetadata(
      certificateSHA256: fingerprint(certificate),
      dnsNames: try Self.dnsNames(from: parsed),
      uriNames: try Self.uriNames(from: parsed),
      supportsServerAuthentication: extendedKeyUsage?.contains(.serverAuth) == true,
      supportsClientAuthentication: extendedKeyUsage?.contains(.clientAuth) == true,
      notValidBefore: parsed.notValidBefore,
      notValidAfter: parsed.notValidAfter,
      issuerCertificateSHA256: issuerCertificateSHA256
    )
  }

  private func validatedSystemTrustChain(
    for leafCertificate: SecCertificate
  ) -> [SecCertificate] {
    var trust: SecTrust?
    guard
      SecTrustCreateWithCertificates(
        leafCertificate,
        SecPolicyCreateBasicX509(),
        &trust
      ) == errSecSuccess,
      let trust
    else {
      return []
    }
    SecTrustSetNetworkFetchAllowed(trust, false)
    var error: CFError?
    guard
      SecTrustEvaluateWithError(trust, &error),
      let chain = SecTrustCopyCertificateChain(trust)
        as? [SecCertificate],
      let evaluatedLeaf = chain.first,
      fingerprint(evaluatedLeaf) == fingerprint(leafCertificate)
    else {
      return []
    }
    return Array(chain.dropFirst())
  }

  private static func dnsNames(
    from certificate: Certificate
  ) throws -> [String] {
    let subjectAlternativeNames =
      try certificate.extensions.subjectAlternativeNames
    let names: [String] =
      subjectAlternativeNames?.compactMap {
        if case .dnsName(let name) = $0 {
          return name.lowercased()
        }
        return nil
      } ?? []
    return names.sorted()
  }

  private static func uriNames(
    from certificate: Certificate
  ) throws -> [String] {
    let names: [String] =
      try certificate.extensions.subjectAlternativeNames?
      .compactMap {
        if case .uniformResourceIdentifier(let uri) = $0 { return uri }
        return nil
      } ?? []
    return names.sorted()
  }

  private func fingerprint(_ certificate: SecCertificate) -> String {
    let data = SecCertificateCopyData(certificate) as Data
    return SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func keyQuery(
    scope: CertificateIdentityScope,
    role: Role
  ) -> [CFString: Any] {
    [
      kSecClass: kSecClassKey,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrApplicationTag: applicationTag(
        scope: scope,
        role: role
      ),
      kSecAttrLabel: label(scope: scope, role: role),
    ]
  }

  private func certificateQuery(
    scope: CertificateIdentityScope,
    role: Role
  ) -> [CFString: Any] {
    [
      kSecClass: kSecClassCertificate,
      kSecAttrLabel: label(scope: scope, role: role),
    ]
  }

  private func applicationTag(
    scope: CertificateIdentityScope,
    role: Role
  ) -> Data {
    Data(
      "\(Self.applicationTagPrefix).\(scope.keychainLocator)."
        .appending(role.rawValue)
        .utf8
    )
  }

  private func label(
    scope: CertificateIdentityScope,
    role: Role
  ) -> String {
    "Hostwright Certificate Identity v1 "
      + "\(scope.keychainLocator) \(role.rawValue)"
  }

  private func compensate(
    certificates: [(Role, SecCertificate)],
    keys: [(Role, SecKey)],
    scope: CertificateIdentityScope
  ) {
    for (role, certificate) in certificates.reversed() {
      try? deleteCertificate(
        certificate,
        scope: scope,
        role: role
      )
    }
    for (role, key) in keys.reversed() {
      try? deleteKey(key, scope: scope, role: role)
    }
  }

  private func deleteCertificate(
    _ certificate: SecCertificate,
    scope: CertificateIdentityScope,
    role: Role
  ) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecAttrLabel: label(scope: scope, role: role),
      kSecValueRef: certificate,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.mapKeychainStatus(status)
    }
  }

  private func deleteKey(
    _ key: SecKey,
    scope: CertificateIdentityScope,
    role: Role
  ) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrApplicationTag: applicationTag(
        scope: scope,
        role: role
      ),
      kSecAttrLabel: label(scope: scope, role: role),
      kSecAttrSynchronizable: false,
      kSecValueRef: key,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.mapKeychainStatus(status)
    }
  }
}
