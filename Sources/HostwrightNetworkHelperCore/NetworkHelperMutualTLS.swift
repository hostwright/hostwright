import CryptoKit
import Foundation
@preconcurrency import Security
import X509

public enum NetworkHelperMutualTLSAuditReason:
  String,
  Codable,
  Equatable,
  Sendable
{
  case allowed
  case handshakeRejected = "handshake-rejected"
  case trustRejected = "trust-rejected"
  case revoked
  case usageRejected = "usage-rejected"
  case identityRejected = "identity-rejected"
  case fingerprintRejected = "fingerprint-rejected"
}

public struct NetworkHelperMutualTLSAuditEntry:
  Codable,
  Equatable,
  Sendable
{
  public let timestamp: Date
  public let listenerName: String
  public let allowed: Bool
  public let reason: NetworkHelperMutualTLSAuditReason
  public let identityURI: String?
  public let certificateSHA256: String?
}

struct NetworkHelperTrustedPeer: Equatable, Sendable {
  let identityURI: String
  let certificateSHA256: String

  init(
    identityURI: String,
    certificateSHA256: String
  ) throws {
    guard
      Self.isCanonicalIdentityURI(identityURI),
      Self.isCanonicalSHA256(certificateSHA256)
    else {
      throw NetworkHelperError.invalidCertificate
    }
    self.identityURI = identityURI
    self.certificateSHA256 = certificateSHA256
  }

  private static func isCanonicalIdentityURI(
    _ value: String
  ) -> Bool {
    guard
      value.utf8.count <= 512,
      let components = URLComponents(string: value),
      components.scheme == "spiffe",
      components.host == "hostwright.internal",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil,
      components.string == value
    else {
      return false
    }
    let fields = components.path.split(
      separator: "/",
      omittingEmptySubsequences: true
    )
    guard
      fields.count == 8,
      fields[0] == "projects",
      fields[2] == "resources",
      fields[4] == "roles",
      fields[6] == "generations",
      canonicalUUID(String(fields[1])),
      canonicalUUID(String(fields[3])),
      ["workload", "ingress", "tunnel", "node"].contains(
        String(fields[5])
      ),
      let generation = Int(fields[7]),
      generation > 0,
      String(generation) == fields[7]
    else {
      return false
    }
    return true
  }

  private static func canonicalUUID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }

  private static func isCanonicalSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
}

struct NetworkHelperMutualTLSPolicy: @unchecked Sendable {
  fileprivate struct Decision {
    let allowed: Bool
    let reason: NetworkHelperMutualTLSAuditReason
    let identityURI: String?
    let certificateSHA256: String?
  }

  let configurationSHA256: String

  private let trustAnchors: [SecCertificate]
  private let allowedFingerprintsByIdentity: [String: Set<String>]
  private let revokedFingerprints: Set<String>

  init(
    trustAnchors: [SecCertificate],
    trustedPeers: [NetworkHelperTrustedPeer],
    revokedFingerprints: Set<String> = []
  ) throws {
    guard !trustAnchors.isEmpty, !trustedPeers.isEmpty else {
      throw NetworkHelperError.invalidCertificate
    }
    var anchorFingerprints = Set<String>()
    for anchor in trustAnchors {
      guard anchorFingerprints.insert(Self.sha256(anchor)).inserted else {
        throw NetworkHelperError.invalidCertificate
      }
    }
    guard revokedFingerprints.allSatisfy(Self.isCanonicalSHA256) else {
      throw NetworkHelperError.invalidCertificate
    }

    var allowed: [String: Set<String>] = [:]
    for peer in trustedPeers {
      guard !revokedFingerprints.contains(peer.certificateSHA256)
      else {
        throw NetworkHelperError.invalidCertificate
      }
      allowed[peer.identityURI, default: []].insert(
        peer.certificateSHA256
      )
    }
    guard
      allowed.values.allSatisfy({
        (1...2).contains($0.count)
      })
    else {
      throw NetworkHelperError.invalidCertificate
    }
    let canonical = [
      anchorFingerprints.sorted().joined(separator: ","),
      allowed.keys.sorted().map { identity in
        "\(identity)="
          + allowed[identity]!.sorted()
          .joined(separator: ",")
      }.joined(separator: "\n"),
      revokedFingerprints.sorted().joined(separator: ","),
    ].joined(separator: "\n--\n")
    configurationSHA256 = SHA256.hash(
      data: Data(canonical.utf8)
    ).map {
      String(format: "%02x", $0)
    }.joined()
    self.trustAnchors = trustAnchors
    allowedFingerprintsByIdentity = allowed
    self.revokedFingerprints = revokedFingerprints
  }

  func evaluate(
    _ trust: SecTrust,
    now: Date = Date()
  ) -> Bool {
    decision(trust, now: now).allowed
  }

  fileprivate func decision(
    _ trust: SecTrust,
    now: Date
  ) -> Decision {
    let policy = SecPolicyCreateSSL(false, nil)
    guard
      SecTrustSetPolicies(trust, policy) == errSecSuccess,
      SecTrustSetAnchorCertificates(
        trust,
        trustAnchors as CFArray
      ) == errSecSuccess,
      SecTrustSetAnchorCertificatesOnly(trust, true)
        == errSecSuccess,
      SecTrustSetNetworkFetchAllowed(trust, false)
        == errSecSuccess,
      SecTrustSetVerifyDate(trust, now as CFDate)
        == errSecSuccess
    else {
      return Decision(
        allowed: false,
        reason: .trustRejected,
        identityURI: nil,
        certificateSHA256: nil
      )
    }

    var trustError: CFError?
    guard
      SecTrustEvaluateWithError(trust, &trustError),
      let chain = SecTrustCopyCertificateChain(trust)
        as? [SecCertificate],
      let leaf = chain.first
    else {
      return Decision(
        allowed: false,
        reason: .trustRejected,
        identityURI: nil,
        certificateSHA256: nil
      )
    }

    let fingerprint = Self.sha256(leaf)
    guard !revokedFingerprints.contains(fingerprint) else {
      return Decision(
        allowed: false,
        reason: .revoked,
        identityURI: nil,
        certificateSHA256: fingerprint
      )
    }
    do {
      let certificate = try Certificate(leaf)
      let usages = try certificate.extensions.extendedKeyUsage
      guard
        usages?.count == 1,
        usages?.contains(.clientAuth) == true
      else {
        return Decision(
          allowed: false,
          reason: .usageRejected,
          identityURI: nil,
          certificateSHA256: fingerprint
        )
      }
      let identities: [String] =
        try certificate.extensions.subjectAlternativeNames?
        .compactMap {
          if case .uniformResourceIdentifier(let value) = $0 {
            return value
          }
          return nil
        } ?? []
      guard
        identities.count == 1,
        let identity = identities.first
      else {
        return Decision(
          allowed: false,
          reason: .identityRejected,
          identityURI: nil,
          certificateSHA256: fingerprint
        )
      }
      guard
        let allowed =
          allowedFingerprintsByIdentity[identity]
      else {
        return Decision(
          allowed: false,
          reason: .identityRejected,
          identityURI: identity,
          certificateSHA256: fingerprint
        )
      }
      guard allowed.contains(fingerprint) else {
        return Decision(
          allowed: false,
          reason: .fingerprintRejected,
          identityURI: identity,
          certificateSHA256: fingerprint
        )
      }
      return Decision(
        allowed: true,
        reason: .allowed,
        identityURI: identity,
        certificateSHA256: fingerprint
      )
    } catch {
      return Decision(
        allowed: false,
        reason: .identityRejected,
        identityURI: nil,
        certificateSHA256: fingerprint
      )
    }
  }

  private static func sha256(_ certificate: SecCertificate) -> String {
    SHA256.hash(
      data: SecCertificateCopyData(certificate) as Data
    ).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private static func isCanonicalSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
}

final class NetworkHelperMutualTLSPolicyProvider:
  @unchecked Sendable
{
  private static let maximumAuditEntries = 1_024

  private let lock = NSLock()
  private let listenerName: String
  private var policy: NetworkHelperMutualTLSPolicy
  private var audit: [NetworkHelperMutualTLSAuditEntry] = []
  private var authenticatedPeers: [ObjectIdentifier: String] = [:]

  init(
    _ policy: NetworkHelperMutualTLSPolicy,
    listenerName: String
  ) {
    self.policy = policy
    self.listenerName = listenerName
  }

  func evaluate(
    _ trust: SecTrust,
    metadata: sec_protocol_metadata_t
  ) -> Bool {
    lock.lock()
    let current = policy
    lock.unlock()
    let timestamp = Date()
    let decision = current.decision(trust, now: timestamp)
    let entry = NetworkHelperMutualTLSAuditEntry(
      timestamp: timestamp,
      listenerName: listenerName,
      allowed: decision.allowed,
      reason: decision.reason,
      identityURI: decision.identityURI,
      certificateSHA256: decision.certificateSHA256
    )
    lock.lock()
    let metadataID = ObjectIdentifier(metadata as AnyObject)
    if decision.allowed, let identityURI = decision.identityURI {
      authenticatedPeers[metadataID] = identityURI
    } else {
      authenticatedPeers.removeValue(forKey: metadataID)
    }
    audit.append(entry)
    if audit.count > Self.maximumAuditEntries {
      audit.removeFirst(
        audit.count - Self.maximumAuditEntries
      )
    }
    lock.unlock()
    return decision.allowed
  }

  func consumeAuthenticatedIdentity(
    metadata: sec_protocol_metadata_t
  ) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return authenticatedPeers.removeValue(
      forKey: ObjectIdentifier(metadata as AnyObject)
    )
  }

  func replace(_ replacement: NetworkHelperMutualTLSPolicy) {
    lock.lock()
    policy = replacement
    lock.unlock()
  }

  func recordHandshakeFailure() {
    append(
      NetworkHelperMutualTLSAuditEntry(
        timestamp: Date(),
        listenerName: listenerName,
        allowed: false,
        reason: .handshakeRejected,
        identityURI: nil,
        certificateSHA256: nil
      )
    )
  }

  func auditEntries() -> [NetworkHelperMutualTLSAuditEntry] {
    lock.lock()
    defer { lock.unlock() }
    return audit
  }

  private func append(
    _ entry: NetworkHelperMutualTLSAuditEntry
  ) {
    lock.lock()
    audit.append(entry)
    if audit.count > Self.maximumAuditEntries {
      audit.removeFirst(
        audit.count - Self.maximumAuditEntries
      )
    }
    lock.unlock()
  }
}
