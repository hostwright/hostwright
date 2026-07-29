import CryptoKit
import Foundation
import HostwrightNetworking
@preconcurrency import Security

struct NetworkHelperCertificateActivation: @unchecked Sendable {
  let identities: [String: CertificateIdentityHandle]
  let peerIdentities: [String: CertificateIdentityHandle]
  let mutualTLSPolicies: [String: NetworkHelperMutualTLSPolicy]
  let currentMutualTLSPolicies: [String: NetworkHelperMutualTLSPolicy]
  let evidence: [NetworkHelperCertificateEvidence]
  let evidenceSHA256: String?
}

final class NetworkHelperCertificateCoordinator: @unchecked Sendable {
  private struct PeerActivation {
    let identities: [String: CertificateIdentityHandle]
    let evidence: [NetworkHelperPeerCertificateEvidence]
    let trustAnchors: [SecCertificate]
    let trustedPeers: [NetworkHelperTrustedPeer]
    let policy: NetworkHelperMutualTLSPolicy?
  }

  private let identityStore: CertificateIdentityStore
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  private var active: [String: NetworkHelperCertificateActivation] = [:]

  init(
    identityStore: CertificateIdentityStore =
      CertificateIdentityStore(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.identityStore = identityStore
    self.now = now
  }

  var hasActiveCertificates: Bool {
    lock.withLock { !active.isEmpty }
  }

  func activation(
    identity: NetworkHelperDNSIdentity
  ) -> NetworkHelperCertificateActivation? {
    lock.withLock { active[Self.key(identity)] }
  }

  @discardableResult
  func apply(
    identity: NetworkHelperDNSIdentity,
    bindings: [ProjectCertificateRequestBinding],
    persistedEvidence:
      NetworkHelperPersistedCertificateEvidence? = nil,
    overlapEvidence:
      NetworkHelperPersistedCertificateEvidence? = nil
  ) throws -> NetworkHelperCertificateActivation {
    let identity = try identity.validated()
    let bindings = try NetworkHelperCertificateValidation.validated(
      bindings
    )
    let requestSHA256 =
      bindings.isEmpty
      ? nil
      : Self.sha256(
        try NetworkHelperCanonicalJSON.encode(bindings)
      )
    if let persistedEvidence {
      guard persistedEvidence.identity == identity,
        persistedEvidence.requestSHA256 == requestSHA256
      else {
        throw NetworkHelperError.quarantined
      }
    }
    if let overlapEvidence {
      guard
        overlapEvidence.identity.projectUUID == identity.projectUUID,
        overlapEvidence.identity.dnsUUID == identity.dnsUUID,
        overlapEvidence.identity.generation < identity.generation
      else {
        throw NetworkHelperError.quarantined
      }
    }

    var identities: [String: CertificateIdentityHandle] = [:]
    var peerIdentities: [String: CertificateIdentityHandle] = [:]
    var mutualTLSPolicies: [String: NetworkHelperMutualTLSPolicy] = [:]
    var currentMutualTLSPolicies: [String: NetworkHelperMutualTLSPolicy] = [:]
    var evidence: [NetworkHelperCertificateEvidence] = []
    let persistedByName = Dictionary(
      uniqueKeysWithValues: (persistedEvidence?.certificates ?? []).map {
        ($0.name, $0)
      }
    )
    for binding in bindings {
      let serverIdentity = try HostwrightMutualTLSIdentity(
        projectUUID: identity.projectUUID,
        resourceUUID: binding.certificateUUID,
        role: binding.identityRole,
        generation: identity.generation
      )
      let handle: CertificateIdentityHandle
      switch binding.source {
      case .imported:
        guard let fingerprint = binding.identitySHA256 else {
          throw NetworkHelperError.invalidCertificate
        }
        handle = try mapIdentityStoreError {
          try identityStore.resolveImportedIdentity(
            certificateSHA256: fingerprint
          )
        }
      case .localCA:
        let scope = try mapIdentityStoreError {
          try CertificateIdentityScope(
            projectUUID: identity.projectUUID,
            certificateUUID: binding.certificateUUID,
            generation: identity.generation
          )
        }
        if let persisted = persistedByName[binding.name] {
          guard
            let issuer =
              persisted.issuerCertificateSHA256
          else {
            throw NetworkHelperError.quarantined
          }
          handle = try mapIdentityStoreError {
            try identityStore.resolveManagedIdentity(
              scope: scope,
              expectedLeafSHA256:
                persisted.certificateSHA256,
              expectedIssuerSHA256: issuer,
              now: now()
            )
          }
        } else {
          do {
            handle = try identityStore.managedIdentityEvidence(
              scope: scope,
              now: now()
            ).handle
          } catch CertificateIdentityStoreError.notFound {
            handle = try mapIdentityStoreError {
              try identityStore.generateLocalIdentity(
                scope: scope,
                dnsNames: binding.dnsNames,
                uriSAN: serverIdentity.uriSAN,
                validity:
                  TimeInterval(binding.validitySeconds),
                now: now()
              )
            }
          } catch {
            throw Self.mappedIdentityStoreError(error)
          }
        }
      case .provider:
        throw NetworkHelperError.certificateUnavailable
      }

      try mapIdentityStoreError {
        try identityStore.validate(
          handle,
          expectedDNSNames: binding.dnsNames,
          expectedCA: binding.source == .localCA
            ? handle.certificateChain.first
            : nil,
          now: now()
        )
      }
      if binding.source == .localCA {
        guard
          handle.metadata.uriNames == [serverIdentity.uriSAN],
          handle.metadata.supportsServerAuthentication
        else {
          throw NetworkHelperError.invalidCertificate
        }
      }
      guard
        handle.metadata.notValidAfter.timeIntervalSince(now())
          > TimeInterval(binding.renewBeforeSeconds)
      else {
        throw NetworkHelperError.certificateUnavailable
      }
      switch handle.metadata.revocationStatus {
      case .suppliedRevoked:
        throw NetworkHelperError.invalidCertificate
      case .unavailable where binding.statusPolicy == .required:
        throw NetworkHelperError.certificateUnavailable
      case .unavailable, .suppliedGood:
        break
      }
      let issuerSHA256 =
        handle.metadata.issuerCertificateSHA256
      guard binding.source != .localCA || issuerSHA256 != nil else {
        throw NetworkHelperError.invalidCertificate
      }
      identities[binding.name] = handle
      let peerActivation = try activatePeers(
        identity: identity,
        binding: binding,
        issuerHandle: handle,
        persisted: persistedByName[binding.name]?.peers ?? []
      )
      for (uri, peerHandle) in peerActivation.identities {
        let key = "\(binding.name)/\(uri)"
        guard peerIdentities[key] == nil else {
          throw NetworkHelperError.invalidCertificate
        }
        peerIdentities[key] = peerHandle
      }
      if let policy = peerActivation.policy {
        currentMutualTLSPolicies[binding.name] = policy
        let overlap = try overlapPeerTrust(
          binding: binding,
          overlapEvidence: overlapEvidence
        )
        mutualTLSPolicies[binding.name] =
          try NetworkHelperMutualTLSPolicy(
            trustAnchors:
              peerActivation.trustAnchors + overlap.trustAnchors,
            trustedPeers:
              peerActivation.trustedPeers + overlap.trustedPeers
          )
      }
      evidence.append(
        NetworkHelperCertificateEvidence(
          name: binding.name,
          certificateUUID: binding.certificateUUID,
          source: binding.source,
          certificateSHA256:
            handle.metadata.certificateSHA256,
          issuerCertificateSHA256: issuerSHA256,
          dnsNames: handle.metadata.dnsNames,
          uriNames: handle.metadata.uriNames,
          supportsServerAuthentication:
            handle.metadata.supportsServerAuthentication,
          peers: peerActivation.evidence,
          notValidBefore: handle.metadata.notValidBefore,
          notValidAfter: handle.metadata.notValidAfter,
          revocationStatus:
            handle.metadata.revocationStatus.rawValue
        )
      )
    }
    evidence.sort(
      by: NetworkHelperCertificateEvidence.canonicalPrecedes
    )
    let evidenceSHA256 =
      evidence.isEmpty
      ? nil
      : Self.sha256(
        try NetworkHelperCanonicalJSON.encode(evidence)
      )
    let activation = NetworkHelperCertificateActivation(
      identities: identities,
      peerIdentities: peerIdentities,
      mutualTLSPolicies: mutualTLSPolicies,
      currentMutualTLSPolicies:
        currentMutualTLSPolicies,
      evidence: evidence,
      evidenceSHA256: evidenceSHA256
    )
    lock.withLock {
      active[Self.key(identity)] = activation
    }
    return activation
  }

  func deactivate(identity: NetworkHelperDNSIdentity) {
    _ = lock.withLock {
      active.removeValue(forKey: Self.key(identity))
    }
  }

  func cleanup(
    identity: NetworkHelperDNSIdentity,
    evidence: NetworkHelperPersistedCertificateEvidence?
  ) throws {
    let identity = try identity.validated()
    if let evidence {
      guard evidence.identity == identity else {
        throw NetworkHelperError.quarantined
      }
    }
    for certificate in evidence?.certificates ?? [] {
      guard certificate.source == .localCA else { continue }
      guard let issuer = certificate.issuerCertificateSHA256 else {
        throw NetworkHelperError.quarantined
      }
      for peer in certificate.peers {
        let peerScope = try mapIdentityStoreError {
          try Self.peerScope(
            projectUUID: identity.projectUUID,
            issuerCertificateUUID:
              certificate.certificateUUID,
            peer: peer.identity
          )
        }
        do {
          try identityStore.cleanupManagedClientIdentity(
            peerScope: peerScope,
            expectedLeafSHA256:
              peer.certificateSHA256
          )
        } catch CertificateIdentityStoreError.notFound {
          continue
        } catch {
          throw Self.mappedIdentityStoreError(error)
        }
      }
      let scope = try mapIdentityStoreError {
        try CertificateIdentityScope(
          projectUUID: identity.projectUUID,
          certificateUUID: certificate.certificateUUID,
          generation: identity.generation
        )
      }
      do {
        try identityStore.cleanupManagedIdentity(
          scope: scope,
          expectedLeafSHA256:
            certificate.certificateSHA256,
          expectedIssuerSHA256: issuer
        )
      } catch CertificateIdentityStoreError.notFound {
        continue
      } catch {
        throw Self.mappedIdentityStoreError(error)
      }
    }
    deactivate(identity: identity)
  }

  func cleanupUnrecordedManagedIdentities(
    identity: NetworkHelperDNSIdentity,
    bindings: [ProjectCertificateRequestBinding]
  ) throws {
    let identity = try identity.validated()
    let bindings = try NetworkHelperCertificateValidation.validated(
      bindings
    )
    for binding in bindings where binding.source == .localCA {
      let issuerScope = try mapIdentityStoreError {
        try CertificateIdentityScope(
          projectUUID: identity.projectUUID,
          certificateUUID: binding.certificateUUID,
          generation: identity.generation
        )
      }
      for peer in binding.peerIdentities {
        let peerScope = try mapIdentityStoreError {
          try Self.peerScope(
            projectUUID: identity.projectUUID,
            issuerCertificateUUID:
              binding.certificateUUID,
            peer: peer
          )
        }
        let discovered: CertificateIdentityHandle
        do {
          discovered =
            try identityStore
            .managedClientIdentityEvidence(
              issuerScope: issuerScope,
              peerScope: peerScope,
              expectedURI: peer.uriSAN,
              now: now()
            )
        } catch CertificateIdentityStoreError.notFound {
          continue
        } catch {
          throw Self.mappedIdentityStoreError(error)
        }
        try mapIdentityStoreError {
          try identityStore.cleanupManagedClientIdentity(
            peerScope: peerScope,
            expectedLeafSHA256:
              discovered.metadata.certificateSHA256
          )
        }
      }
      let discovered: ManagedCertificateIdentityEvidence
      do {
        discovered = try identityStore.managedIdentityEvidence(
          scope: issuerScope,
          now: now()
        )
      } catch CertificateIdentityStoreError.notFound {
        continue
      } catch {
        throw Self.mappedIdentityStoreError(error)
      }
      try mapIdentityStoreError {
        try identityStore.cleanupManagedIdentity(
          scope: issuerScope,
          expectedLeafSHA256:
            discovered.handle.metadata.certificateSHA256,
          expectedIssuerSHA256:
            discovered.issuerCertificateSHA256
        )
      }
    }
    deactivate(identity: identity)
  }

  private func activatePeers(
    identity: NetworkHelperDNSIdentity,
    binding: ProjectCertificateRequestBinding,
    issuerHandle: CertificateIdentityHandle,
    persisted: [NetworkHelperPeerCertificateEvidence]
  ) throws -> PeerActivation {
    guard !binding.peerIdentities.isEmpty else {
      guard persisted.isEmpty else {
        throw NetworkHelperError.quarantined
      }
      return PeerActivation(
        identities: [:],
        evidence: [],
        trustAnchors: [],
        trustedPeers: [],
        policy: nil
      )
    }
    guard
      binding.source == .localCA,
      let trustAnchor = issuerHandle.certificateChain.first,
      let issuerSHA256 =
        issuerHandle.metadata.issuerCertificateSHA256
    else {
      throw NetworkHelperError.certificateUnavailable
    }
    let persistedByURI = Dictionary(
      uniqueKeysWithValues: persisted.map {
        ($0.identity.uriSAN, $0)
      }
    )
    if !persisted.isEmpty {
      guard
        persisted.map(\.identity) == binding.peerIdentities
      else {
        throw NetworkHelperError.quarantined
      }
    }
    let issuerScope = try mapIdentityStoreError {
      try CertificateIdentityScope(
        projectUUID: identity.projectUUID,
        certificateUUID: binding.certificateUUID,
        generation: identity.generation
      )
    }
    var handles: [String: CertificateIdentityHandle] = [:]
    var evidence: [NetworkHelperPeerCertificateEvidence] = []
    var trustedPeers: [NetworkHelperTrustedPeer] = []
    for peer in binding.peerIdentities {
      let peerScope = try mapIdentityStoreError {
        try Self.peerScope(
          projectUUID: identity.projectUUID,
          issuerCertificateUUID:
            binding.certificateUUID,
          peer: peer
        )
      }
      let handle: CertificateIdentityHandle
      if let prior = persistedByURI[peer.uriSAN] {
        guard
          prior.identity == peer,
          prior.issuerCertificateSHA256 == issuerSHA256,
          prior.revocationStatus
            != CertificateRevocationStatus
            .suppliedRevoked.rawValue
        else {
          throw NetworkHelperError.invalidCertificate
        }
        handle = try mapIdentityStoreError {
          try identityStore.resolveManagedClientIdentity(
            issuerScope: issuerScope,
            peerScope: peerScope,
            expectedLeafSHA256:
              prior.certificateSHA256,
            expectedIssuerSHA256: issuerSHA256,
            expectedURI: peer.uriSAN,
            now: now()
          )
        }
      } else {
        do {
          handle =
            try identityStore
            .managedClientIdentityEvidence(
              issuerScope: issuerScope,
              peerScope: peerScope,
              expectedURI: peer.uriSAN,
              now: now()
            )
        } catch CertificateIdentityStoreError.notFound {
          let currentTime = now()
          let validity = min(
            86_400,
            issuerHandle.metadata.notValidAfter
              .timeIntervalSince(currentTime) - 60
          )
          guard validity > 0 else {
            throw NetworkHelperError
              .certificateUnavailable
          }
          guard
            let role = ManagedClientIdentityRole(
              rawValue: peer.role.rawValue
            )
          else {
            throw NetworkHelperError.invalidCertificate
          }
          handle = try mapIdentityStoreError {
            try identityStore.issueManagedClientIdentity(
              issuerScope: issuerScope,
              peerScope: peerScope,
              role: role,
              uriSAN: peer.uriSAN,
              validity: validity,
              now: currentTime
            )
          }
        } catch {
          throw Self.mappedIdentityStoreError(error)
        }
      }
      guard
        handle.metadata.uriNames == [peer.uriSAN],
        handle.metadata.supportsClientAuthentication,
        !handle.metadata.supportsServerAuthentication,
        handle.metadata.issuerCertificateSHA256 == issuerSHA256,
        handle.metadata.notValidAfter >= now()
      else {
        throw NetworkHelperError.invalidCertificate
      }
      switch handle.metadata.revocationStatus {
      case .suppliedRevoked:
        throw NetworkHelperError.invalidCertificate
      case .unavailable, .suppliedGood:
        break
      }
      handles[peer.uriSAN] = handle
      evidence.append(
        NetworkHelperPeerCertificateEvidence(
          identity: peer,
          certificateSHA256:
            handle.metadata.certificateSHA256,
          issuerCertificateSHA256: issuerSHA256,
          notValidBefore:
            handle.metadata.notValidBefore,
          notValidAfter: handle.metadata.notValidAfter,
          revocationStatus:
            persistedByURI[peer.uriSAN]?
            .revocationStatus ?? handle.metadata.revocationStatus.rawValue
        )
      )
      trustedPeers.append(
        try NetworkHelperTrustedPeer(
          identityURI: peer.uriSAN,
          certificateSHA256:
            handle.metadata.certificateSHA256
        )
      )
    }
    evidence.sort(
      by: NetworkHelperPeerCertificateEvidence.canonicalPrecedes
    )
    return PeerActivation(
      identities: handles,
      evidence: evidence,
      trustAnchors: [trustAnchor],
      trustedPeers: trustedPeers,
      policy: try NetworkHelperMutualTLSPolicy(
        trustAnchors: [trustAnchor],
        trustedPeers: trustedPeers
      )
    )
  }

  private func overlapPeerTrust(
    binding: ProjectCertificateRequestBinding,
    overlapEvidence:
      NetworkHelperPersistedCertificateEvidence?
  ) throws -> (
    trustAnchors: [SecCertificate],
    trustedPeers: [NetworkHelperTrustedPeer]
  ) {
    guard
      let overlapEvidence,
      let certificate = overlapEvidence.certificates.first(
        where: { $0.name == binding.name }
      ),
      !certificate.peers.isEmpty
    else {
      return ([], [])
    }
    guard
      certificate.source == .localCA,
      certificate.certificateUUID == binding.certificateUUID,
      let issuerSHA256 =
        certificate.issuerCertificateSHA256
    else {
      throw NetworkHelperError.quarantined
    }
    let issuerScope = try mapIdentityStoreError {
      try CertificateIdentityScope(
        projectUUID:
          overlapEvidence.identity.projectUUID,
        certificateUUID:
          certificate.certificateUUID,
        generation:
          overlapEvidence.identity.generation
      )
    }
    let issuerHandle = try mapIdentityStoreError {
      try identityStore.resolveManagedIdentity(
        scope: issuerScope,
        expectedLeafSHA256:
          certificate.certificateSHA256,
        expectedIssuerSHA256: issuerSHA256,
        now: now()
      )
    }
    guard let trustAnchor = issuerHandle.certificateChain.first
    else {
      throw NetworkHelperError.quarantined
    }
    var trustedPeers: [NetworkHelperTrustedPeer] = []
    for peer in certificate.peers {
      guard
        peer.revocationStatus
          != CertificateRevocationStatus
          .suppliedRevoked.rawValue
      else {
        continue
      }
      let peerScope = try mapIdentityStoreError {
        try Self.peerScope(
          projectUUID:
            overlapEvidence.identity.projectUUID,
          issuerCertificateUUID:
            certificate.certificateUUID,
          peer: peer.identity
        )
      }
      _ = try mapIdentityStoreError {
        try identityStore.resolveManagedClientIdentity(
          issuerScope: issuerScope,
          peerScope: peerScope,
          expectedLeafSHA256:
            peer.certificateSHA256,
          expectedIssuerSHA256: issuerSHA256,
          expectedURI: peer.identity.uriSAN,
          now: now()
        )
      }
      trustedPeers.append(
        try NetworkHelperTrustedPeer(
          identityURI: peer.identity.uriSAN,
          certificateSHA256:
            peer.certificateSHA256
        )
      )
    }
    guard !trustedPeers.isEmpty else {
      return ([], [])
    }
    return ([trustAnchor], trustedPeers)
  }

  static func mappedIdentityStoreError(
    _ error: Error
  ) -> NetworkHelperError {
    guard let error = error as? CertificateIdentityStoreError else {
      return .invalidCertificate
    }
    switch error {
    case .keychainLocked,
      .accessDenied,
      .cancelled,
      .notFound:
      return .certificateUnavailable
    case .invalidScope,
      .invalidFingerprint,
      .invalidDNSName,
      .invalidValidity,
      .duplicate,
      .tampered,
      .validationFailed,
      .keychainFailure:
      return .invalidCertificate
    }
  }

  private func mapIdentityStoreError<T>(
    _ body: () throws -> T
  ) throws -> T {
    do {
      return try body()
    } catch {
      throw Self.mappedIdentityStoreError(error)
    }
  }

  private static func key(
    _ identity: NetworkHelperDNSIdentity
  ) -> String {
    [
      identity.projectUUID,
      identity.dnsUUID,
      String(identity.generation),
      identity.fencingToken,
    ].joined(separator: ":")
  }

  private static func peerScope(
    projectUUID: String,
    issuerCertificateUUID: String,
    peer: HostwrightMutualTLSIdentity
  ) throws -> CertificateIdentityScope {
    try CertificateIdentityScope(
      projectUUID: projectUUID,
      certificateUUID: deterministicUUID(
        "mtls-peer:\(issuerCertificateUUID):"
          + peer.uriSAN
      ),
      generation: peer.generation
    )
  }

  private static func deterministicUUID(_ value: String) -> String {
    var bytes = Array(
      SHA256.hash(
        data: Data(
          "hostwright:resource:v1:\(value)".utf8
        )
      ).prefix(16)
    )
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    ).uuidString.lowercased()
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
