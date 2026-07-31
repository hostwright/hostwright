import CryptoKit
import Foundation
import HostwrightNetworking
import Security
import XCTest

@testable import HostwrightNetworkHelperCore

final class NetworkHelperMutualTLSTests: XCTestCase {
  func testPolicyAcceptsExactValidClientIdentity() throws {
    let fixture = try makeClientFixture()
    defer { fixture.cleanup() }

    let policy = try NetworkHelperMutualTLSPolicy(
      trustAnchors: [fixture.issuerCertificate],
      trustedPeers: [
        try NetworkHelperTrustedPeer(
          identityURI: fixture.identityURI,
          certificateSHA256:
            fixture.client.metadata.certificateSHA256
        )
      ]
    )

    XCTAssertTrue(policy.evaluate(try makeTrust(for: fixture.client)))
  }

  func testPolicyRejectsWrongIdentityOrFingerprint() throws {
    let fixture = try makeClientFixture()
    defer { fixture.cleanup() }

    let wrongIdentity = makeIdentityURI(
      projectUUID: fixture.issuerScope.projectUUID,
      certificateUUID: UUID().uuidString.lowercased(),
      generation: 1
    )
    let wrongIdentityPolicy = try NetworkHelperMutualTLSPolicy(
      trustAnchors: [fixture.issuerCertificate],
      trustedPeers: [
        try NetworkHelperTrustedPeer(
          identityURI: wrongIdentity,
          certificateSHA256:
            fixture.client.metadata.certificateSHA256
        )
      ]
    )
    XCTAssertFalse(
      wrongIdentityPolicy.evaluate(try makeTrust(for: fixture.client))
    )

    let wrongFingerprintPolicy = try NetworkHelperMutualTLSPolicy(
      trustAnchors: [fixture.issuerCertificate],
      trustedPeers: [
        try NetworkHelperTrustedPeer(
          identityURI: fixture.identityURI,
          certificateSHA256: String(repeating: "0", count: 64)
        )
      ]
    )
    XCTAssertFalse(
      wrongFingerprintPolicy.evaluate(
        try makeTrust(for: fixture.client)
      )
    )
  }

  func testPolicyRejectsRevokedServerOnlyWrongCAAndExpiredClients()
    throws
  {
    let valid = try makeClientFixture()
    let otherCA = try makeClientFixture()
    let expired = try makeClientFixture(
      issuerNow: Date().addingTimeInterval(-7_200),
      issuerValidity: 10_800,
      clientValidity: 3_600
    )
    defer {
      valid.cleanup()
      otherCA.cleanup()
      expired.cleanup()
    }

    XCTAssertThrowsError(
      try NetworkHelperMutualTLSPolicy(
        trustAnchors: [valid.issuerCertificate],
        trustedPeers: [
          try NetworkHelperTrustedPeer(
            identityURI: valid.identityURI,
            certificateSHA256:
              valid.client.metadata.certificateSHA256
          )
        ],
        revokedFingerprints: [
          valid.client.metadata.certificateSHA256
        ]
      )
    ) { error in
      XCTAssertEqual(error as? NetworkHelperError, .invalidCertificate)
    }

    let serverOnly = try NetworkHelperMutualTLSPolicy(
      trustAnchors: [valid.issuerCertificate],
      trustedPeers: [
        try NetworkHelperTrustedPeer(
          identityURI: valid.identityURI,
          certificateSHA256:
            valid.server.metadata.certificateSHA256
        )
      ]
    )
    XCTAssertFalse(serverOnly.evaluate(try makeTrust(for: valid.server)))

    let wrongCA = try NetworkHelperMutualTLSPolicy(
      trustAnchors: [valid.issuerCertificate],
      trustedPeers: [
        try NetworkHelperTrustedPeer(
          identityURI: otherCA.identityURI,
          certificateSHA256:
            otherCA.client.metadata.certificateSHA256
        )
      ]
    )
    XCTAssertFalse(wrongCA.evaluate(try makeTrust(for: otherCA.client)))

    let expiredPolicy = try NetworkHelperMutualTLSPolicy(
      trustAnchors: [expired.issuerCertificate],
      trustedPeers: [
        try NetworkHelperTrustedPeer(
          identityURI: expired.identityURI,
          certificateSHA256:
            expired.client.metadata.certificateSHA256
        )
      ]
    )
    XCTAssertFalse(expiredPolicy.evaluate(try makeTrust(for: expired.client)))
  }

  func testPolicyLimitsIdentityRotationToTwoFingerprints() throws {
    let identity = makeIdentityURI(
      projectUUID: UUID().uuidString.lowercased(),
      certificateUUID: UUID().uuidString.lowercased(),
      generation: 1
    )
    let anchor = try makeClientFixture()
    defer { anchor.cleanup() }

    let fingerprints = ["1", "2", "3"].map {
      String(repeating: $0, count: 64)
    }
    let rotatingPeers = try fingerprints.map {
      try NetworkHelperTrustedPeer(
        identityURI: identity,
        certificateSHA256: $0
      )
    }
    XCTAssertNoThrow(
      try NetworkHelperMutualTLSPolicy(
        trustAnchors: [anchor.issuerCertificate],
        trustedPeers: Array(rotatingPeers.prefix(2))
      )
    )
    XCTAssertThrowsError(
      try NetworkHelperMutualTLSPolicy(
        trustAnchors: [anchor.issuerCertificate],
        trustedPeers: rotatingPeers
      )
    ) { error in
      XCTAssertEqual(error as? NetworkHelperError, .invalidCertificate)
    }
  }

  func testCoordinatorIssuesRecoversAndCleansExactPeerIdentity()
    throws
  {
    let identity = NetworkHelperDNSIdentity(
      projectUUID:
        "11111111-1111-4111-8111-111111111111",
      dnsUUID: "22222222-2222-4222-8222-222222222222",
      generation: 1,
      fencingToken:
        "33333333-3333-4333-8333-333333333333"
    )
    let peer = try HostwrightMutualTLSIdentity(
      projectUUID: identity.projectUUID,
      resourceUUID:
        "44444444-4444-4444-8444-444444444444",
      role: .workload,
      generation: 1
    )
    let binding = ProjectCertificateRequestBinding(
      name: "local",
      certificateUUID:
        "55555555-5555-4555-8555-555555555555",
      source: .localCA,
      renewBeforeSeconds: 3_600,
      validitySeconds: 86_400,
      statusPolicy: .ifAvailable,
      dnsNames: ["api.internal"],
      peerIdentities: [peer]
    )
    let coordinator = NetworkHelperCertificateCoordinator()
    let first = try coordinator.apply(
      identity: identity,
      bindings: [binding]
    )
    var cleanupEvidence: NetworkHelperPersistedCertificateEvidence?
    defer {
      try? coordinator.cleanup(
        identity: identity,
        evidence: cleanupEvidence
      )
    }

    XCTAssertEqual(first.identities.count, 1)
    XCTAssertEqual(first.peerIdentities.count, 1)
    XCTAssertEqual(first.mutualTLSPolicies.count, 1)
    XCTAssertEqual(
      first.evidence.first?.peers.map(\.identity),
      [peer]
    )
    let persisted = NetworkHelperPersistedCertificateEvidence(
      identity: identity,
      requestSHA256: try requestSHA256([binding]),
      certificates: first.evidence
    )
    cleanupEvidence = persisted
    coordinator.deactivate(identity: identity)
    let recovered = try coordinator.apply(
      identity: identity,
      bindings: [binding],
      persistedEvidence: persisted
    )
    XCTAssertEqual(recovered.evidence, first.evidence)

    let certificate = try XCTUnwrap(
      persisted.certificates.first
    )
    let peerEvidence = try XCTUnwrap(
      certificate.peers.first
    )
    let revokedPeer = NetworkHelperPeerCertificateEvidence(
      identity: peerEvidence.identity,
      certificateSHA256:
        peerEvidence.certificateSHA256,
      issuerCertificateSHA256:
        peerEvidence.issuerCertificateSHA256,
      notValidBefore: peerEvidence.notValidBefore,
      notValidAfter: peerEvidence.notValidAfter,
      revocationStatus:
        CertificateRevocationStatus
        .suppliedRevoked.rawValue
    )
    let revokedCertificate =
      NetworkHelperCertificateEvidence(
        name: certificate.name,
        certificateUUID:
          certificate.certificateUUID,
        source: certificate.source,
        certificateSHA256:
          certificate.certificateSHA256,
        issuerCertificateSHA256:
          certificate.issuerCertificateSHA256,
        dnsNames: certificate.dnsNames,
        uriNames: certificate.uriNames,
        supportsServerAuthentication:
          certificate.supportsServerAuthentication,
        peers: [revokedPeer],
        notValidBefore:
          certificate.notValidBefore,
        notValidAfter: certificate.notValidAfter,
        revocationStatus:
          certificate.revocationStatus
      )
    coordinator.deactivate(identity: identity)
    XCTAssertThrowsError(
      try coordinator.apply(
        identity: identity,
        bindings: [binding],
        persistedEvidence:
          NetworkHelperPersistedCertificateEvidence(
            identity: identity,
            requestSHA256:
              persisted.requestSHA256,
            certificates: [revokedCertificate]
          )
      )
    ) {
      XCTAssertEqual(
        $0 as? NetworkHelperError,
        .invalidCertificate
      )
    }

    try coordinator.cleanup(
      identity: identity,
      evidence: persisted
    )
    cleanupEvidence = nil
    XCTAssertThrowsError(
      try coordinator.apply(
        identity: identity,
        bindings: [binding],
        persistedEvidence: persisted
      )
    ) {
      XCTAssertEqual(
        $0 as? NetworkHelperError,
        .certificateUnavailable
      )
    }
  }

  func testCoordinatorOverlapsThenRetiresPriorGeneration()
    throws
  {
    let projectUUID =
      "11111111-1111-4111-8111-111111111111"
    let certificateUUID =
      "55555555-5555-4555-8555-555555555555"
    let resourceUUID =
      "44444444-4444-4444-8444-444444444444"
    let firstIdentity = NetworkHelperDNSIdentity(
      projectUUID: projectUUID,
      dnsUUID: "22222222-2222-4222-8222-222222222222",
      generation: 1,
      fencingToken:
        "33333333-3333-4333-8333-333333333333"
    )
    let secondIdentity = NetworkHelperDNSIdentity(
      projectUUID: projectUUID,
      dnsUUID: firstIdentity.dnsUUID,
      generation: 2,
      fencingToken:
        "66666666-6666-4666-8666-666666666666"
    )
    let firstPeer = try HostwrightMutualTLSIdentity(
      projectUUID: projectUUID,
      resourceUUID: resourceUUID,
      role: .workload,
      generation: 1
    )
    let secondPeer = try HostwrightMutualTLSIdentity(
      projectUUID: projectUUID,
      resourceUUID: resourceUUID,
      role: .workload,
      generation: 2
    )
    func binding(
      _ peer: HostwrightMutualTLSIdentity
    ) -> ProjectCertificateRequestBinding {
      ProjectCertificateRequestBinding(
        name: "local",
        certificateUUID: certificateUUID,
        source: .localCA,
        renewBeforeSeconds: 3_600,
        validitySeconds: 86_400,
        statusPolicy: .ifAvailable,
        dnsNames: ["api.internal"],
        peerIdentities: [peer]
      )
    }

    let coordinator = NetworkHelperCertificateCoordinator()
    let firstBinding = binding(firstPeer)
    let first = try coordinator.apply(
      identity: firstIdentity,
      bindings: [firstBinding]
    )
    let firstEvidence =
      NetworkHelperPersistedCertificateEvidence(
        identity: firstIdentity,
        requestSHA256:
          try requestSHA256([firstBinding]),
        certificates: first.evidence
      )
    let secondBinding = binding(secondPeer)
    let second = try coordinator.apply(
      identity: secondIdentity,
      bindings: [secondBinding],
      overlapEvidence: firstEvidence
    )
    let secondEvidence =
      NetworkHelperPersistedCertificateEvidence(
        identity: secondIdentity,
        requestSHA256:
          try requestSHA256([secondBinding]),
        certificates: second.evidence
      )
    defer {
      try? coordinator.cleanup(
        identity: secondIdentity,
        evidence: secondEvidence
      )
      try? coordinator.cleanup(
        identity: firstIdentity,
        evidence: firstEvidence
      )
    }

    let firstClient = try XCTUnwrap(
      first.peerIdentities.values.first
    )
    let secondClient = try XCTUnwrap(
      second.peerIdentities.values.first
    )
    let overlapPolicy = try XCTUnwrap(
      second.mutualTLSPolicies["local"]
    )
    XCTAssertTrue(
      overlapPolicy.evaluate(try makeTrust(for: firstClient))
    )
    XCTAssertTrue(
      overlapPolicy.evaluate(try makeTrust(for: secondClient))
    )

    let currentPolicy = try XCTUnwrap(
      second.currentMutualTLSPolicies["local"]
    )
    XCTAssertFalse(
      currentPolicy.evaluate(try makeTrust(for: firstClient))
    )
    XCTAssertTrue(
      currentPolicy.evaluate(try makeTrust(for: secondClient))
    )
  }

  private func makeClientFixture(
    issuerNow: Date = Date(),
    issuerValidity: TimeInterval = 86_400,
    clientValidity: TimeInterval = 3_600
  ) throws -> ClientFixture {
    let store = CertificateIdentityStore()
    let issuerScope = try CertificateIdentityScope(
      projectUUID: UUID(), certificateUUID: UUID(), generation: 1
    )
    let peerScope = try CertificateIdentityScope(
      projectUUID: UUID(), certificateUUID: UUID(), generation: 1
    )
    let identityURI = makeIdentityURI(
      projectUUID: peerScope.projectUUID,
      certificateUUID: peerScope.certificateUUID,
      generation: peerScope.generation
    )
    let server = try store.generateLocalIdentity(
      scope: issuerScope,
      dnsNames: ["mtls.test"],
      uriSAN: identityURI,
      validity: issuerValidity,
      now: issuerNow
    )
    let client = try store.issueManagedClientIdentity(
      issuerScope: issuerScope,
      peerScope: peerScope,
      role: .workload,
      uriSAN: identityURI,
      validity: clientValidity,
      now: issuerNow
    )
    return try ClientFixture(
      store: store,
      issuerScope: issuerScope,
      peerScope: peerScope,
      identityURI: identityURI,
      server: server,
      client: client
    )
  }

  private func makeIdentityURI(
    projectUUID: String,
    certificateUUID: String,
    generation: Int
  ) -> String {
    "spiffe://hostwright.internal/projects/\(projectUUID)"
      + "/resources/\(certificateUUID)/roles/workload"
      + "/generations/\(generation)"
  }

  private func makeTrust(
    for handle: CertificateIdentityHandle
  ) throws -> SecTrust {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(handle.identity, &certificate) == errSecSuccess,
      let certificate
    else {
      throw NetworkHelperError.invalidCertificate
    }
    var trust: SecTrust?
    guard
      SecTrustCreateWithCertificates(
        ([certificate] + handle.certificateChain) as CFTypeRef,
        SecPolicyCreateBasicX509(),
        &trust
      ) == errSecSuccess,
      let trust
    else {
      throw NetworkHelperError.invalidCertificate
    }
    return trust
  }

  private func requestSHA256(
    _ bindings: [ProjectCertificateRequestBinding]
  ) throws -> String {
    SHA256.hash(
      data: try NetworkHelperCanonicalJSON.encode(bindings)
    ).map {
      String(format: "%02x", $0)
    }.joined()
  }
}

private struct ClientFixture {
  let store: CertificateIdentityStore
  let issuerScope: CertificateIdentityScope
  let peerScope: CertificateIdentityScope
  let identityURI: String
  let server: CertificateIdentityHandle
  let client: CertificateIdentityHandle
  let issuerCertificate: SecCertificate
  let issuerFingerprint: String

  init(
    store: CertificateIdentityStore,
    issuerScope: CertificateIdentityScope,
    peerScope: CertificateIdentityScope,
    identityURI: String,
    server: CertificateIdentityHandle,
    client: CertificateIdentityHandle
  ) throws {
    self.store = store
    self.issuerScope = issuerScope
    self.peerScope = peerScope
    self.identityURI = identityURI
    self.server = server
    self.client = client
    issuerCertificate = try XCTUnwrap(server.certificateChain.first)
    issuerFingerprint = try XCTUnwrap(
      server.metadata.issuerCertificateSHA256
    )
  }

  func cleanup() {
    try? store.cleanupManagedClientIdentity(
      peerScope: peerScope,
      expectedLeafSHA256: client.metadata.certificateSHA256
    )
    try? store.cleanupManagedIdentity(
      scope: issuerScope,
      expectedLeafSHA256: server.metadata.certificateSHA256,
      expectedIssuerSHA256: issuerFingerprint
    )
  }
}
