import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightState

final class RBACRepositoryTests: XCTestCase {
  private let createdAt = "2026-08-02T20:00:00Z"
  private let updatedAt = "2026-08-02T20:01:00Z"
  private let expiresAt = "2026-08-02T21:00:00Z"

  func testBootstrapPersistsExactDefaultsAndOneOwnerAcrossReopen() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: path)
    try store.migrate()
    try bootstrapIdentity("owner", in: store)
    let repository = RBACRepository(store: store)

    try repository.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: createdAt)
    try repository.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: createdAt)

    assertFrozenDefaultRoles(try repository.listRoles())
    let owners = try repository.listBindings()
    XCTAssertEqual(owners.count, 1)
    XCTAssertEqual(owners[0].bindingID, "bootstrap-owner")
    XCTAssertEqual(owners[0].subjectID, "owner")
    XCTAssertEqual(owners[0].roleID, "owner")
    XCTAssertEqual(owners[0].scope, RBACScope(kind: .global))

    let reopened = RBACRepository(store: SQLiteStateStore(path: path))
    assertFrozenDefaultRoles(try reopened.listRoles())
    XCTAssertEqual(try reopened.listBindings().map(\.bindingID), ["bootstrap-owner"])
  }

  func testBootstrapRefusesToMintOwnerWhenMultipleActiveIdentitiesExistWithoutAnOwner() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try bootstrapIdentity("installing-subject", in: store)
    try declareIdentity("second-subject", declaredBy: "installing-subject", in: store)
    let repository = RBACRepository(store: store)

    XCTAssertThrowsError(
      try repository.bootstrapDefaultRolesAndOwner(
        subjectID: "installing-subject", timestamp: createdAt)) { error in
      guard case .transactionInvariantViolation(let message) = error as? StateStoreError else {
        return XCTFail("Expected bootstrap invariant failure, got \(error)")
      }
      XCTAssertTrue(message.contains("exactly one active self-declared identity"), message)
    }

    XCTAssertEqual(try repository.listBindings(), [])
    assertFrozenDefaultRoles(try repository.listRoles())
  }

  func testCustomRoleCRUDRequiresCurrentGeneration() throws {
    try withRepository { repository, _ in
      let role = customRole("deploy", rules: [rule("deploy-read", verbs: [.get])])
      let created = try repository.createCustomRole(
        role, actorSubjectID: "owner", timestamp: createdAt)
      XCTAssertEqual(created.generation, 1)
      XCTAssertEqual(created.createdBySubjectID, "owner")

      let changed = customRole("deploy", rules: [rule("deploy-write", verbs: [.update])])
      XCTAssertThrowsError(
        try repository.updateCustomRole(
          changed, expectedGeneration: 2, actorSubjectID: "owner", timestamp: updatedAt))
      let updated = try repository.updateCustomRole(
        changed, expectedGeneration: 1, actorSubjectID: "owner", timestamp: updatedAt)
      XCTAssertEqual(updated.generation, 2)
      XCTAssertEqual(updated.rules, try changed.canonicalized().rules)
      XCTAssertThrowsError(try repository.deleteCustomRole(id: "deploy", expectedGeneration: 1))
      try repository.deleteCustomRole(id: "deploy", expectedGeneration: 2)
      XCTAssertNil(try repository.role(id: "deploy"))
    }
  }

  func testBuiltInsAndCanonicalCollectionConstraintsAreRejected() throws {
    try withRepository { repository, _ in
      let owner = try XCTUnwrap(repository.role(id: "owner"))
      XCTAssertThrowsError(
        try repository.updateCustomRole(
          owner, expectedGeneration: 1, actorSubjectID: "owner", timestamp: updatedAt))
      XCTAssertThrowsError(try repository.deleteCustomRole(id: "owner", expectedGeneration: 1))
      XCTAssertThrowsError(
        try repository.createCustomRole(
          customRole("viewer", rules: [rule("r", verbs: [.get])]), actorSubjectID: "owner",
          timestamp: createdAt))
      XCTAssertThrowsError(
        try repository.createCustomRole(
          customRole("duplicate", rules: [rule("same", verbs: [.get, .get])]),
          actorSubjectID: "owner", timestamp: createdAt))
    }
  }

  func testBindingsRejectDuplicatesAndProtectLastActiveOwner() throws {
    try withRepository { repository, store in
      XCTAssertThrowsError(try repository.deleteBinding(id: "bootstrap-owner", expectedGeneration: 1))
      XCTAssertThrowsError(
        try repository.createBinding(
          ownerBinding(subject: "owner", id: "duplicate-owner")))

      try declareIdentity("other", declaredBy: "owner", in: store)
      let secondOwner = ownerBinding(subject: "other", id: "other-owner")
      XCTAssertEqual(try repository.createBinding(secondOwner), secondOwner)
      try repository.deleteBinding(id: "bootstrap-owner", expectedGeneration: 1)
      XCTAssertNil(try repository.binding(id: "bootstrap-owner"))
      XCTAssertEqual(try repository.binding(id: "other-owner"), secondOwner)
      XCTAssertThrowsError(try repository.deleteBinding(id: "other-owner", expectedGeneration: 1))
    }
  }

  func testDelegationRequiresNonOwnerExpiringRightsAndFiltersRevocation() throws {
    try withRepository { repository, store in
      try declareIdentity("delegate", declaredBy: "owner", in: store)
      XCTAssertThrowsError(
        try repository.createDelegation(
          delegation("owner-delegation", roles: ["owner"], expiresAt: expiresAt)))
      XCTAssertThrowsError(
        try repository.createDelegation(
          delegation("expired", roles: ["operator"], expiresAt: createdAt)))

      let created = delegation("delegate-operator", roles: ["operator"], expiresAt: expiresAt)
      XCTAssertEqual(try repository.createDelegation(created), created)
      XCTAssertEqual(
        try repository.listDelegations(delegateSubjectID: "delegate", activeAt: updatedAt), [created])
      XCTAssertEqual(try repository.listDelegations(delegateSubjectID: "delegate", activeAt: expiresAt), [])

      let revoked = try repository.revokeDelegation(
        id: "delegate-operator", expectedGeneration: 1, revokedAt: updatedAt)
      XCTAssertEqual(revoked.generation, 2)
      XCTAssertEqual(revoked.revokedAt, updatedAt)
      XCTAssertEqual(try repository.listDelegations(delegateSubjectID: "delegate", activeAt: updatedAt), [])
      XCTAssertThrowsError(
        try repository.revokeDelegation(id: "delegate-operator", expectedGeneration: 1, revokedAt: expiresAt))
    }
  }

  func testBindingsAndDelegationsPersistAcrossReopen() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: path)
    try store.migrate()
    try bootstrapIdentity("owner", in: store)
    let repository = RBACRepository(store: store)
    try repository.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: createdAt)
    try declareIdentity("delegate", declaredBy: "owner", in: store)
    let binding = RBACBindingRecord(
      bindingID: "delegate-viewer", subjectID: "delegate", roleID: "viewer",
      scope: RBACScope(kind: .project, identifier: "project-1"), createdBySubjectID: "owner",
      createdAt: createdAt, updatedAt: createdAt)
    let delegated = delegation("delegate-rules", roles: [], expiresAt: expiresAt, rules: [rule("read", verbs: [.get])])
    XCTAssertEqual(try repository.createBinding(binding), binding)
    XCTAssertEqual(try repository.createDelegation(delegated), delegated)

    let reopened = RBACRepository(store: SQLiteStateStore(path: path))
    XCTAssertEqual(try reopened.binding(id: binding.bindingID), binding)
    XCTAssertEqual(try reopened.delegation(id: delegated.delegationID), delegated)
  }

  private func withRepository(
    _ body: (RBACRepository, SQLiteStateStore) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try bootstrapIdentity("owner", in: store)
    let repository = RBACRepository(store: store)
    try repository.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: createdAt)
    try body(repository, store)
  }

  private func assertFrozenDefaultRoles(_ roles: [RBACRoleRecord]) {
    XCTAssertEqual(roles.map(\.roleID), DefaultRole.allCases.map(\.rawValue).sorted())
    XCTAssertTrue(roles.allSatisfy { $0.builtIn && $0.generation == 1 && $0.createdBySubjectID == nil })
    XCTAssertEqual(
      roles.map(\.definition),
      (try? RBACRepository.defaultRoles(timestamp: createdAt))?.map(\.definition))
  }

  private func bootstrapIdentity(_ subject: String, in store: SQLiteStateStore) throws {
    try store.controlIdentities.bootstrap(identity(subject, declaredBy: subject, hash: "a"))
  }

  private func declareIdentity(_ subject: String, declaredBy: String, in store: SQLiteStateStore) throws {
    let hash: Character = subject == "delegate" ? "b" : "c"
    try store.controlIdentities.declare(identity(subject, declaredBy: declaredBy, hash: hash))
  }

  private func identity(_ subject: String, declaredBy: String, hash: Character) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subject, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-\(subject)",
        codeDirectoryHash: String(repeating: String(hash), count: 40),
        validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: createdAt, updatedAt: createdAt)
  }

  private func customRole(_ id: String, rules: [RBACRule]) -> RBACRoleRecord {
    RBACRoleRecord(
      roleID: id, builtIn: false, rules: rules, createdBySubjectID: "owner",
      createdAt: createdAt, updatedAt: createdAt)
  }

  private func ownerBinding(subject: String, id: String = "bootstrap-owner") -> RBACBindingRecord {
    RBACBindingRecord(
      bindingID: id, subjectID: subject, roleID: "owner", scope: RBACScope(kind: .global),
      createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt)
  }

  private func delegation(
    _ id: String, roles: [String], expiresAt: String, rules: [RBACRule] = []
  ) -> RBACDelegationRecord {
    RBACDelegationRecord(
      delegationID: id, delegatorSubjectID: "owner", delegateSubjectID: "delegate",
      roleIDs: roles, delegatedRules: rules, scope: RBACScope(kind: .global), expiresAt: expiresAt,
      createdAt: createdAt, updatedAt: createdAt)
  }

  private func rule(_ id: String, verbs: [RBACVerb]) -> RBACRule {
    RBACRule(
      identifier: id, effect: .allow, resources: [.project], verbs: verbs,
      scope: RBACScope(kind: .global))
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-rbac-repository-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
