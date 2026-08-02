import CryptoKit
import Darwin
import HostwrightControlPlane
import XCTest

@testable import HostwrightControlSecurity

final class ControlPeerAuthenticatorTests: XCTestCase {
  private let codeHash = String(repeating: "a", count: 64)

  func testRejectsTokenUIDMismatchBeforeCodeValidation() throws {
    let fixture = Fixture()
    fixture.credentials = fixture.credentials.with(auditEffectiveUID: UInt32(geteuid()) + 1)

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .peerUIDMismatch)
    }
    XCTAssertEqual(fixture.validator.calls, 0)
  }

  func testRejectsPIDReuseCrossCheckBeforeCodeValidation() throws {
    let fixture = Fixture()
    fixture.credentials = fixture.credentials.with(auditPID: fixture.credentials.peerPID + 1)

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .peerPIDMismatch)
    }
    XCTAssertEqual(fixture.validator.calls, 0)
  }

  func testRejectsSpoofedGroup() throws {
    let fixture = Fixture()
    fixture.credentials = fixture.credentials.with(
      auditEffectiveGID: fixture.credentials.peerGID + 1)

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .peerGIDMismatch)
    }
  }

  func testRejectsOversizedServerNonce() throws {
    let fixture = Fixture()
    XCTAssertThrowsError(try fixture.authenticate(serverNonce: String(repeating: "A", count: 129)))
    { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .invalidServerNonce)
    }
  }

  func testRejectsMalformedAuditTokenBeforeCodeValidation() throws {
    let fixture = Fixture()
    fixture.credentials = RawControlPeerCredentials(
      peerUID: fixture.credentials.peerUID, peerGID: fixture.credentials.peerGID,
      peerPID: fixture.credentials.peerPID,
      auditEffectiveUID: fixture.credentials.auditEffectiveUID,
      auditEffectiveGID: fixture.credentials.auditEffectiveGID,
      auditPID: fixture.credentials.auditPID,
      auditPIDVersion: fixture.credentials.auditPIDVersion,
      auditSessionID: fixture.credentials.auditSessionID,
      auditTokenData: Data(repeating: 1, count: 33)
    )

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .malformedPeerToken)
    }
    XCTAssertEqual(fixture.validator.calls, 0)
  }

  func testRejectsInstalledIdentityWithWrongTeam() throws {
    let fixture = Fixture()
    fixture.validator.identity = CodeIdentity(
      teamIdentifier: "WRONGTEAM", signingIdentifier: "hostwright", codeDirectoryHash: codeHash,
      validationMode: .installedRequirement
    )

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .installedTeamRejected)
    }
  }

  func testTrustPolicyCannotReplaceFrozenTeamOrInstalledIdentifiers() throws {
    XCTAssertThrowsError(
      try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        installedTeamIdentifier: "AAAAAAAAAA"
      )
    )
    XCTAssertThrowsError(
      try ControlPeerTrustPolicy(
        expectedUserID: UInt32(geteuid()),
        installedIdentifiers: ["hostwright", "attacker"]
      )
    )
  }

  func testRejectsInstalledIdentityWithWrongIdentifier() throws {
    let fixture = Fixture()
    fixture.validator.identity = CodeIdentity(
      teamIdentifier: "993YC3JY4Q", signingIdentifier: "com.example.other",
      codeDirectoryHash: codeHash,
      validationMode: .installedRequirement
    )

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .installedIdentifierRejected)
    }
  }

  func testRejectsUnpinnedAdHocIdentity() throws {
    let fixture = Fixture()
    fixture.validator.identity = CodeIdentity(
      signingIdentifier: "hostwright", codeDirectoryHash: codeHash, validationMode: .pinnedAdHoc
    )

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .adHocHashRejected)
    }
  }

  func testRequiresCredentialForCredentialBoundSubject() throws {
    let fixture = Fixture(credential: Fixture.credential)

    XCTAssertThrowsError(try fixture.authenticate()) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .credentialProofRequired)
    }
  }

  func testAcceptsCredentialProofBoundToCompleteChallenge() throws {
    let fixture = Fixture(credential: Fixture.credential)
    let proof = try fixture.proof()

    let context = try fixture.authenticate(credentialProof: proof)

    XCTAssertEqual(context.binding.subject.identifier, "local-owner")
    XCTAssertEqual(fixture.sessions.persisted.count, 1)
  }

  func testRejectsWrongCredentialID() throws {
    let fixture = Fixture(credential: Fixture.credential)
    var proof = try fixture.proof()
    proof = ControlPeerCredentialProof(
      credentialID: "other", signatureDERBase64: proof.signatureDERBase64)

    XCTAssertThrowsError(try fixture.authenticate(credentialProof: proof)) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .credentialIDMismatch)
    }
  }

  func testRejectsCredentialProofForDifferentNonce() throws {
    let fixture = Fixture(credential: Fixture.credential)
    let proof = try fixture.proof(serverNonce: "YWJjZGVmZ2hpamtsbW5vcA==")

    XCTAssertThrowsError(try fixture.authenticate(credentialProof: proof)) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .credentialProofRejected)
    }
  }

  func testRejectsUnexpectedCredentialProofForUnboundSubject() throws {
    let fixture = Fixture()
    let proof = ControlPeerCredentialProof(
      credentialID: "device-key", signatureDERBase64: "MAYCAQECAQE=")

    XCTAssertThrowsError(try fixture.authenticate(credentialProof: proof)) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .credentialProofUnexpected)
    }
  }

  func testRejectsReplayWhenDaemonGenerationChanges() throws {
    let fixture = Fixture(credential: Fixture.credential)
    let proof = try fixture.proof(daemonGeneration: 1)

    XCTAssertThrowsError(try fixture.authenticate(daemonGeneration: 2, credentialProof: proof)) {
      error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .credentialProofRejected)
    }
  }

  func testSessionValidationRechecksImmediateRevocationAndGeneration() throws {
    let fixture = Fixture()
    let context = try fixture.authenticate()
    fixture.resolver.revoked = true
    XCTAssertThrowsError(
      try fixture.authenticator.validateSession(context.binding, daemonGeneration: 1)
    ) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .subjectRevoked)
    }
    fixture.resolver.revoked = false
    XCTAssertThrowsError(
      try fixture.authenticator.validateSession(context.binding, daemonGeneration: 2)
    ) { error in
      XCTAssertEqual(error as? ControlPeerAuthenticationError, .daemonGenerationChanged)
    }
  }

  func testProductionSocketPeerReaderCrossChecksCurrentProcess() throws {
    var descriptors = [Int32](repeating: 0, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    defer {
      _ = close(descriptors[0])
      _ = close(descriptors[1])
    }

    let credentials = try DarwinControlPeerCredentialReader().read(descriptor: descriptors[0])
    XCTAssertEqual(credentials.peerUID, UInt32(geteuid()))
    XCTAssertEqual(credentials.auditEffectiveUID, UInt32(geteuid()))
    XCTAssertEqual(credentials.peerPID, getpid())
    XCTAssertEqual(credentials.auditPID, getpid())
    XCTAssertGreaterThan(credentials.auditPIDVersion, 0)
  }

  func testProductionCodeValidatorBindsLiveCodeToAuditToken() throws {
    var descriptors = [Int32](repeating: 0, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    defer {
      _ = close(descriptors[0])
      _ = close(descriptors[1])
    }

    let credentials = try DarwinControlPeerCredentialReader().read(descriptor: descriptors[0])
    let identity = try DarwinControlPeerCodeValidator().identity(
      for: credentials.auditTokenData, peerPID: credentials.peerPID)

    XCTAssertTrue([40, 64].contains(identity.codeDirectoryHash.count))
    XCTAssertTrue(identity.codeDirectoryHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    XCTAssertFalse(identity.signingIdentifier.isEmpty)
  }
}

private final class Fixture: @unchecked Sendable {
  static let credential = CredentialFixture()

  var credentials: RawControlPeerCredentials
  let validator: TestCodeValidator
  let resolver: TestSubjectResolver
  let sessions: TestSessionStore
  let authenticator: ControlPeerAuthenticator

  init(credential: CredentialFixture? = nil) {
    let uid = UInt32(geteuid())
    let gid = UInt32(getegid())
    let hash = String(repeating: "a", count: 64)
    credentials = RawControlPeerCredentials(
      peerUID: uid, peerGID: gid, peerPID: 8123, auditEffectiveUID: uid, auditEffectiveGID: gid,
      auditPID: 8123, auditPIDVersion: 44, auditSessionID: 7,
      auditTokenData: Data(repeating: 1, count: 32)
    )
    validator = TestCodeValidator(
      identity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright", codeDirectoryHash: hash,
        validationMode: .installedRequirement
      ))
    resolver = TestSubjectResolver(credential: credential?.material)
    sessions = TestSessionStore()
    authenticator = ControlPeerAuthenticator(
      policy: try! ControlPeerTrustPolicy(expectedUserID: uid),
      credentialReader: TestCredentialReader(),
      codeValidator: validator, subjectResolver: resolver, sessionStore: sessions
    )
    (authenticator.credentialReader as! TestCredentialReader).credentials = credentials
  }

  func authenticate(
    daemonGeneration: UInt64 = 1, serverNonce: String = "MDEyMzQ1Njc4OWFiY2RlZg==",
    credentialProof: ControlPeerCredentialProof? = nil
  ) throws -> AuthenticatedControlPeer {
    (authenticator.credentialReader as! TestCredentialReader).credentials = credentials
    return try authenticator.authenticate(
      descriptor: 11, daemonGeneration: daemonGeneration, serverNonce: serverNonce,
      socketDevice: 23, socketInode: 29, credentialProof: credentialProof
    )
  }

  func proof(
    daemonGeneration: UInt64 = 1,
    serverNonce: String = "MDEyMzQ1Njc4OWFiY2RlZg=="
  ) throws -> ControlPeerCredentialProof {
    let peer = try authenticator.peerIdentity(from: credentials, identity: validator.identity)
    let challenge = try ControlPeerCredentialChallenge(
      subjectID: "local-owner", serverNonce: serverNonce,
      daemonGeneration: daemonGeneration,
      socketDevice: 23, socketInode: 29, peer: peer
    ).canonicalData()
    let signature = try Self.credential.privateKey.signature(for: challenge)
    return ControlPeerCredentialProof(
      credentialID: "device-key",
      signatureDERBase64: signature.derRepresentation.base64EncodedString()
    )
  }

  struct CredentialFixture: Sendable {
    let privateKey = P256.Signing.PrivateKey()
    var material: DeclaredControlCredential {
      DeclaredControlCredential(
        identifier: "device-key", p256X963PublicKey: privateKey.publicKey.x963Representation
      )
    }
  }
}

private final class TestCredentialReader: ControlPeerCredentialReading, @unchecked Sendable {
  var credentials = RawControlPeerCredentials(
    peerUID: 0, peerGID: 0, peerPID: 1, auditEffectiveUID: 0, auditEffectiveGID: 0,
    auditPID: 1, auditPIDVersion: 1, auditSessionID: 1,
    auditTokenData: Data(repeating: 1, count: 32)
  )
  func read(descriptor: Int32) throws -> RawControlPeerCredentials { credentials }
}

private final class TestCodeValidator: ControlPeerCodeValidating, @unchecked Sendable {
  var identity: CodeIdentity
  var calls = 0
  init(identity: CodeIdentity) { self.identity = identity }
  func identity(for auditTokenData: Data, peerPID: pid_t) throws -> CodeIdentity {
    calls += 1
    return identity
  }
}

private final class TestSubjectResolver: DeclaredControlSubjectResolving, @unchecked Sendable {
  var credential: DeclaredControlCredential?
  var revoked = false
  init(credential: DeclaredControlCredential?) { self.credential = credential }
  func resolve(userID: UInt32, codeIdentity: CodeIdentity) throws -> DeclaredControlSubject {
    DeclaredControlSubject(
      localSubject: LocalSubject(
        identifier: "local-owner", userID: userID, codeIdentityHash: codeIdentity.codeDirectoryHash,
        credentialID: credential?.identifier
      ), credential: credential, isRevoked: revoked
    )
  }
}

private final class TestSessionStore: ControlSessionBindingStoring, @unchecked Sendable {
  var persisted: [ControlSessionBinding] = []
  func persist(_ binding: ControlSessionBinding) throws { persisted.append(binding) }
  func isActive(sessionID: String, daemonGeneration: UInt64) throws -> Bool { true }
}

extension RawControlPeerCredentials {
  fileprivate func with(
    auditEffectiveUID: UInt32? = nil, auditEffectiveGID: UInt32? = nil, auditPID: pid_t? = nil
  ) -> Self {
    Self(
      peerUID: peerUID, peerGID: peerGID, peerPID: peerPID,
      auditEffectiveUID: auditEffectiveUID ?? self.auditEffectiveUID,
      auditEffectiveGID: auditEffectiveGID ?? self.auditEffectiveGID,
      auditPID: auditPID ?? self.auditPID, auditPIDVersion: auditPIDVersion,
      auditSessionID: auditSessionID,
      auditTokenData: auditTokenData
    )
  }
}
