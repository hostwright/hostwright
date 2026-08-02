import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import XCTest

@testable import HostwrightState

final class ControlIdentitySecurityAdapterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_785_706_200)

  func testResolvesExactNativeCDHashAndPersistsBoundSession() throws {
    try withAdapter { store, adapter, identity in
      let subject = try adapter.resolve(
        userID: identity.userID,
        codeIdentity: identity.codeIdentity
      )
      XCTAssertEqual(subject.localSubject.identifier, identity.subjectID)
      XCTAssertFalse(subject.isRevoked)

      let binding = self.binding(identity: identity)
      try adapter.persist(binding)
      XCTAssertTrue(
        try adapter.isActive(
          sessionID: binding.sessionID,
          daemonGeneration: binding.daemonGeneration
        )
      )
      let stored = try XCTUnwrap(
        store.controlIdentities.loadSession(binding.sessionID)
      )
      XCTAssertEqual(stored.codeDirectoryHash.count, 40)
      XCTAssertNotEqual(stored.serverNonceSHA256, binding.serverNonce)
      XCTAssertEqual(stored.serverNonceSHA256.count, 64)
    }
  }

  func testRejectsUndeclaredOrDuplicateActiveIdentity() throws {
    try withAdapter { store, adapter, identity in
      XCTAssertThrowsError(
        try adapter.resolve(
          userID: identity.userID,
          codeIdentity: CodeIdentity(
            teamIdentifier: identity.codeIdentity.teamIdentifier,
            signingIdentifier: identity.codeIdentity.signingIdentifier,
            codeDirectoryHash: String(repeating: "b", count: 40),
            validationMode: identity.codeIdentity.validationMode
          )
        )
      ) { error in
        XCTAssertEqual(
          error as? ControlPeerAuthenticationError,
          .subjectNotDeclared
        )
      }
      XCTAssertThrowsError(
        try store.controlIdentities.declare(
          ControlPeerIdentityRecord(
            subjectID: "duplicate",
            userID: identity.userID,
            codeIdentity: identity.codeIdentity,
            declaredBySubjectID: identity.subjectID,
            declaredAt: "2026-08-02T20:00:00Z",
            updatedAt: "2026-08-02T20:01:00Z"
          )
        )
      )
    }
  }

  func testRevocationAndGenerationChangeInvalidateSessionImmediately() throws {
    try withAdapter { store, adapter, identity in
      let binding = self.binding(identity: identity)
      try adapter.persist(binding)
      XCTAssertFalse(
        try adapter.isActive(
          sessionID: binding.sessionID,
          daemonGeneration: binding.daemonGeneration + 1
        )
      )
      try store.controlIdentities.revoke(
        ControlIdentityRevocationRecord(
          revocationID: "revoke-owner",
          targetKind: .subject,
          targetIdentifier: identity.subjectID,
          reason: "integration security proof",
          actorSubjectID: identity.subjectID,
          revokedAt: "2026-08-02T20:31:00Z"
        )
      )
      XCTAssertFalse(
        try adapter.isActive(
          sessionID: binding.sessionID,
          daemonGeneration: binding.daemonGeneration
        )
      )
      XCTAssertTrue(
        try adapter.resolve(
          userID: identity.userID,
          codeIdentity: identity.codeIdentity
        ).isRevoked
      )
    }
  }

  func testRefusesUnboundedSessionLifetimeAndUnsignedIntegerOverflow() throws {
    let store = try temporaryStore()
    XCTAssertThrowsError(
      try SQLiteControlIdentitySecurityAdapter(
        store: store,
        sessionLifetime: .infinity
      )
    )
    let invalid = ControlSessionRecord(
      sessionID: "overflow",
      subjectID: "owner",
      daemonGeneration: UInt64.max,
      serverNonceSHA256: String(repeating: "f", count: 64),
      socketDevice: 1,
      socketInode: 2,
      effectiveUID: UInt32(geteuid()),
      effectiveGID: UInt32(getegid()),
      pid: getpid(),
      pidVersion: 1,
      auditSessionID: 1,
      codeDirectoryHash: String(repeating: "a", count: 40),
      createdAt: "2026-08-02T20:00:00Z",
      expiresAt: "2026-08-02T21:00:00Z",
      updatedAt: "2026-08-02T20:00:00Z"
    )
    XCTAssertThrowsError(try invalid.validate())
  }

  private func withAdapter(
    _ body: (
      SQLiteStateStore,
      SQLiteControlIdentitySecurityAdapter,
      ControlPeerIdentityRecord
    ) throws -> Void
  ) throws {
    let store = try temporaryStore()
    let identity = ControlPeerIdentityRecord(
      subjectID: "owner",
      userID: UInt32(geteuid()),
      codeIdentity: CodeIdentity(
        teamIdentifier: ControlPeerTrustPolicy.installedTeamIdentifier,
        signingIdentifier: "hostwright",
        codeDirectoryHash: String(repeating: "a", count: 40),
        validationMode: .installedRequirement
      ),
      declaredBySubjectID: "owner",
      declaredAt: "2026-08-02T20:00:00Z",
      updatedAt: "2026-08-02T20:01:00Z"
    )
    try store.controlIdentities.bootstrap(identity)
    let fixedNow = now
    let adapter = try SQLiteControlIdentitySecurityAdapter(
      store: store,
      sessionLifetime: 3_600,
      now: { fixedNow }
    )
    try body(store, adapter, identity)
  }

  private func binding(identity: ControlPeerIdentityRecord) -> ControlSessionBinding {
    ControlSessionBinding(
      sessionID: "session-one",
      daemonGeneration: 1,
      serverNonce: "MDEyMzQ1Njc4OWFiY2RlZg==",
      socketDevice: 23,
      socketInode: 29,
      peer: UnixPeerIdentity(
        effectiveUID: identity.userID,
        effectiveGID: UInt32(getegid()),
        pid: getpid(),
        pidVersion: 1,
        auditSessionID: 1,
        codeIdentity: identity.codeIdentity
      ),
      subject: LocalSubject(
        identifier: identity.subjectID,
        userID: identity.userID,
        codeIdentityHash: identity.codeIdentity.codeDirectoryHash
      )
    )
  }

  private func temporaryStore() throws -> SQLiteStateStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-control-security-adapter-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    return store
  }
}
