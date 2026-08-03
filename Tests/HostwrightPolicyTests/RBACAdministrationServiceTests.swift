import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightPolicy
@testable import HostwrightState

final class RBACAdministrationServiceTests: XCTestCase {
  private let createdAt = "2026-08-02T20:00:00Z"
  private let decisionDate = ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!
  private let future = "2026-08-02T21:00:00Z"

  func testOwnerCanCreateRoleAndBindingsThenDeleteOnlyNonLastOwner() throws {
    try withService(subjects: ["member", "second-owner"]) { repository, service in
      let role = try service.createRole(
        role("project-reader", rules: [allow("project-read", resources: [.project], verbs: [.get])]),
        actorSubjectID: "owner", timestamp: createdAt)
      XCTAssertEqual(role.createdBySubjectID, "owner")
      XCTAssertEqual(
        try service.createBinding(
          binding("member-reader", subject: "member", role: "project-reader", actor: "owner"),
          actorSubjectID: "owner", at: decisionDate).roleID,
        "project-reader")

      _ = try service.createBinding(
        binding("second-owner", subject: "second-owner", role: "owner", actor: "owner"),
        actorSubjectID: "owner", at: decisionDate)
      try service.deleteBinding(
        id: "bootstrap-owner", expectedGeneration: 1, actorSubjectID: "owner", at: decisionDate)
      XCTAssertNil(try repository.binding(id: "bootstrap-owner"))
      XCTAssertThrowsError(
        try service.deleteBinding(
          id: "second-owner", expectedGeneration: 1, actorSubjectID: "second-owner",
          at: decisionDate))
      XCTAssertNotNil(try repository.binding(id: "second-owner"))
    }
  }

  func testSecurityAdminCanGrantOnlyExactSubsetOfEffectiveRules() throws {
    try withService(subjects: ["security", "member"]) { repository, service in
      try seedBinding("security-admin", subject: "security", role: "security-admin", repository: repository)

      let auditReader = try service.createRole(
        role("audit-reader", rules: [allow("audit-read", resources: [.audit], verbs: [.get])]),
        actorSubjectID: "security", timestamp: createdAt)
      XCTAssertEqual(auditReader.rules.map(\.identifier), ["audit-read"])
      XCTAssertEqual(
        try service.createBinding(
          binding("member-audit", subject: "member", role: "audit-reader", actor: "security"),
          actorSubjectID: "security", at: decisionDate).subjectID,
        "member")

      XCTAssertThrowsError(
        try service.createRole(
          role("service-operator", rules: [allow("service-start", resources: [.service], verbs: [.start])]),
          actorSubjectID: "security", timestamp: createdAt))
      XCTAssertThrowsError(
        try service.createBinding(
          binding("member-operator", subject: "member", role: "operator", actor: "security"),
          actorSubjectID: "security", at: decisionDate))
      XCTAssertThrowsError(
        try service.createBinding(
          binding("member-owner", subject: "member", role: "owner", actor: "security"),
          actorSubjectID: "security", at: decisionDate))
    }
  }

  func testNonOwnerConditionalAndUnprivilegedGrantsAreRejected() throws {
    try withService(subjects: ["security", "viewer"]) { repository, service in
      try seedBinding("security-admin", subject: "security", role: "security-admin", repository: repository)
      try seedBinding("viewer", subject: "viewer", role: "viewer", repository: repository)

      XCTAssertThrowsError(
        try service.createRole(
          role(
            "conditional-audit", rules: [
              allow(
                "conditional-audit-read", resources: [.audit], verbs: [.get],
                conditions: [RBACCondition(kind: .operation, value: "audit.verify")])
            ]), actorSubjectID: "security", timestamp: createdAt))
      XCTAssertThrowsError(
        try service.createRole(
          role("viewer-escalation", rules: [allow("project-read", resources: [.project], verbs: [.get])]),
          actorSubjectID: "viewer", timestamp: createdAt))
    }
  }

  func testDelegationRequiresDelegatorSubsetFutureExpiryAndNeverOwner() throws {
    try withService(subjects: ["security", "delegate"]) { repository, service in
      try seedBinding("security-admin", subject: "security", role: "security-admin", repository: repository)
      _ = try service.createRole(
        role("audit-reader", rules: [allow("audit-read", resources: [.audit], verbs: [.get])]),
        actorSubjectID: "security", timestamp: createdAt)

      let allowed = delegation(
        "security-audit", delegator: "security", delegate: "delegate", roles: ["audit-reader"],
        expiresAt: future)
      XCTAssertEqual(
        try service.createDelegation(allowed, actorSubjectID: "security", at: decisionDate).delegationID,
        "security-audit")
      XCTAssertThrowsError(
        try service.createDelegation(allowed, actorSubjectID: "owner", at: decisionDate))
      XCTAssertThrowsError(
        try service.createDelegation(
          delegation("security-operator", delegator: "security", delegate: "delegate", roles: ["operator"], expiresAt: future),
          actorSubjectID: "security", at: decisionDate))
      XCTAssertThrowsError(
        try service.createDelegation(
          delegation("security-owner", delegator: "security", delegate: "delegate", roles: ["owner"], expiresAt: future),
          actorSubjectID: "security", at: decisionDate))
      XCTAssertThrowsError(
        try service.createDelegation(
          delegation(
            "expired-audit", delegator: "security", delegate: "delegate", roles: ["audit-reader"],
            expiresAt: "2026-08-02T20:15:00Z"), actorSubjectID: "security", at: decisionDate))
    }
  }

  func testOnlyDelegatorOrGlobalOwnerCanRevokeDelegation() throws {
    try withService(subjects: ["security", "delegate"]) { repository, service in
      try seedBinding("security-admin", subject: "security", role: "security-admin", repository: repository)
      _ = try service.createRole(
        role("audit-reader", rules: [allow("audit-read", resources: [.audit], verbs: [.get])]),
        actorSubjectID: "security", timestamp: createdAt)
      _ = try service.createDelegation(
        delegation(
          "security-audit", delegator: "security", delegate: "delegate", roles: ["audit-reader"],
          expiresAt: future), actorSubjectID: "security", at: decisionDate)

      XCTAssertThrowsError(
        try service.revokeDelegation(
          id: "security-audit", expectedGeneration: 1, actorSubjectID: "delegate", revokedAt: "2026-08-02T20:31:00Z"))
      let revoked = try service.revokeDelegation(
        id: "security-audit", expectedGeneration: 1, actorSubjectID: "owner", revokedAt: "2026-08-02T20:31:00Z")
      XCTAssertEqual(revoked.revokedAt, "2026-08-02T20:31:00Z")
      XCTAssertEqual(revoked.generation, 2)
    }
  }

  func testDirectNonOwnerManagementCallsRequireExactPolicyVerbs() throws {
    try withService(subjects: ["creator", "updater", "deleter", "member"]) { repository, service in
      try installManagementRole(
        "creator-rights", subject: "creator", rules: [
          allow("creator-management", resources: [.policy], verbs: [.create, .delegate]),
          allow("creator-audit-read", resources: [.audit], verbs: [.get]),
        ], repository: repository, service: service)
      try installManagementRole(
        "updater-rights", subject: "updater", rules: [
          allow("updater-management", resources: [.policy], verbs: [.update, .delegate]),
          allow("updater-audit-read", resources: [.audit], verbs: [.get]),
        ], repository: repository, service: service)
      try installManagementRole(
        "deleter-rights", subject: "deleter", rules: [
          allow("deleter-management", resources: [.policy], verbs: [.delete])
        ], repository: repository, service: service)

      let created = try service.createRole(
        role("managed-audit", rules: [allow("managed-audit-read", resources: [.audit], verbs: [.get])]),
        actorSubjectID: "creator", timestamp: createdAt)
      XCTAssertEqual(created.generation, 1)
      XCTAssertThrowsError(
        try service.updateRole(
          role("managed-audit", rules: [allow("managed-audit-read-v2", resources: [.audit], verbs: [.get])]),
          expectedGeneration: 1, actorSubjectID: "creator", timestamp: "2026-08-02T20:31:00Z"))
      XCTAssertThrowsError(
        try service.deleteRole(
          id: "managed-audit", expectedGeneration: 1, actorSubjectID: "creator", at: decisionDate))

      let updated = try service.updateRole(
        role("managed-audit", rules: [allow("managed-audit-read-v2", resources: [.audit], verbs: [.get])]),
        expectedGeneration: 1, actorSubjectID: "updater", timestamp: "2026-08-02T20:31:00Z")
      XCTAssertEqual(updated.generation, 2)
      XCTAssertThrowsError(
        try service.deleteRole(
          id: "managed-audit", expectedGeneration: 2, actorSubjectID: "updater", at: decisionDate))

      let createdBinding = try service.createBinding(
        binding("member-managed-audit", subject: "member", role: "managed-audit", actor: "creator"),
        actorSubjectID: "creator", at: decisionDate)
      XCTAssertEqual(createdBinding.subjectID, "member")
      XCTAssertThrowsError(
        try service.createBinding(
          binding("member-managed-audit-update", subject: "member", role: "managed-audit", actor: "updater"),
          actorSubjectID: "updater", at: decisionDate))
      try service.deleteBinding(
        id: "member-managed-audit", expectedGeneration: 1, actorSubjectID: "deleter", at: decisionDate)
      try service.deleteRole(
        id: "managed-audit", expectedGeneration: 2, actorSubjectID: "deleter", at: decisionDate)
      XCTAssertNil(try repository.role(id: "managed-audit"))
    }
  }

  func testSecurityAdminLegitimateCreateUpdateDeleteRoleAndBindingFlowsPass() throws {
    try withService(subjects: ["security", "member"]) { repository, service in
      try seedBinding("security-admin", subject: "security", role: "security-admin", repository: repository)
      let created = try service.createRole(
        role("security-audit", rules: [allow("security-audit-read", resources: [.audit], verbs: [.get])]),
        actorSubjectID: "security", timestamp: createdAt)
      let updated = try service.updateRole(
        role("security-audit", rules: [allow("security-audit-read-v2", resources: [.audit], verbs: [.get])]),
        expectedGeneration: created.generation, actorSubjectID: "security", timestamp: "2026-08-02T20:31:00Z")
      let binding = try service.createBinding(
        self.binding("member-security-audit", subject: "member", role: "security-audit", actor: "security"),
        actorSubjectID: "security", at: decisionDate)

      try service.deleteBinding(
        id: binding.bindingID, expectedGeneration: binding.generation, actorSubjectID: "security", at: decisionDate)
      try service.deleteRole(
        id: updated.roleID, expectedGeneration: updated.generation, actorSubjectID: "security", at: decisionDate)
      XCTAssertNil(try repository.role(id: "security-audit"))
    }
  }

  private func withService(
    subjects: [String], _ body: (RBACRepository, RBACAdministrationService) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner"))
    let repository = store.rbac
    try repository.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: createdAt)
    for (index, subject) in subjects.enumerated() {
      let hex = String(index + 11, radix: 16).first ?? "b"
      try store.controlIdentities.declare(identity(subject, hash: hex, declaredBy: "owner"))
    }
    try body(
      repository,
      RBACAdministrationService(
        repository: repository, authorizer: RBACAuthorizationEngine(repository: repository)))
  }

  private func seedBinding(
    _ id: String, subject: String, role: String, repository: RBACRepository
  ) throws {
    _ = try repository.createBinding(binding(id, subject: subject, role: role, actor: "owner"))
  }

  private func installManagementRole(
    _ identifier: String, subject: String, rules: [RBACRule], repository: RBACRepository,
    service: RBACAdministrationService
  ) throws {
    _ = try service.createRole(
      role(identifier, rules: rules), actorSubjectID: "owner", timestamp: createdAt)
    _ = try service.createBinding(
      binding("\(identifier)-binding", subject: subject, role: identifier, actor: "owner"),
      actorSubjectID: "owner", at: decisionDate)
  }

  private func role(_ id: String, rules: [RBACRule]) -> RBACRoleRecord {
    RBACRoleRecord(
      roleID: id, builtIn: false, rules: rules, createdBySubjectID: "owner",
      createdAt: createdAt, updatedAt: createdAt)
  }

  private func binding(
    _ id: String, subject: String, role: String, actor: String,
    scope: RBACScope = .init(kind: .global)
  ) -> RBACBindingRecord {
    RBACBindingRecord(
      bindingID: id, subjectID: subject, roleID: role, scope: scope, createdBySubjectID: actor,
      createdAt: createdAt, updatedAt: createdAt)
  }

  private func delegation(
    _ id: String, delegator: String, delegate: String, roles: [String], expiresAt: String
  ) -> RBACDelegationRecord {
    RBACDelegationRecord(
      delegationID: id, delegatorSubjectID: delegator, delegateSubjectID: delegate,
      roleIDs: roles, delegatedRules: [], scope: .init(kind: .global), expiresAt: expiresAt,
      createdAt: createdAt, updatedAt: createdAt)
  }

  private func allow(
    _ id: String, resources: [RBACResource], verbs: [RBACVerb],
    conditions: [RBACCondition] = []
  ) -> RBACRule {
    RBACRule(
      identifier: id, effect: .allow, resources: resources, verbs: verbs,
      scope: .init(kind: .global), conditions: conditions)
  }

  private func identity(_ subject: String, hash: Character, declaredBy: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subject, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
        codeDirectoryHash: String(repeating: String(hash), count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: createdAt, updatedAt: createdAt)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-rbac-administration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
