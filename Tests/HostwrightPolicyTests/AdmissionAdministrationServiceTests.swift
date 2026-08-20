import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightPolicy
@testable import HostwrightState

final class AdmissionAdministrationServiceTests: XCTestCase {
  private let createdAt = "2026-08-02T20:00:00Z"
  private let decisionDate = ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!
  private let future = "2026-08-02T21:00:00Z"
  private let expired = "2026-08-02T20:15:00Z"

  func testOwnerAndSecurityAdminCanPerformPolicyLifecycleWithPolicyVerbs() throws {
    try withService(subjects: ["security"]) { repository, rbacRepository, service in
      try bind("security-admin", subject: "security", role: "security-admin", repository: rbacRepository)

      let created = try service.createPolicy(
        policy("extension-policy", creator: "owner"), actorSubjectID: "owner", at: decisionDate)
      XCTAssertEqual(created.createdBySubjectID, "owner")

      let disabled = try service.setPolicyEnabled(
        id: created.policyID, enabled: false, expectedGeneration: created.generation,
        actorSubjectID: "security", updatedAt: "2026-08-02T20:31:00Z", at: decisionDate)
      XCTAssertFalse(disabled.enabled)
      XCTAssertEqual(disabled.generation, 2)

      try service.deletePolicy(
        id: disabled.policyID, expectedGeneration: disabled.generation,
        actorSubjectID: "owner", at: decisionDate)
      XCTAssertNil(try repository.policy(id: disabled.policyID))
    }
  }

  func testUnboundSubjectCannotCreateUpdateOrDeletePolicies() throws {
    try withService(subjects: ["unbound"]) { repository, _, service in
      let created = try service.createPolicy(
        policy("managed-policy", creator: "owner"), actorSubjectID: "owner", at: decisionDate)

      XCTAssertThrowsError(
        try service.createPolicy(
          policy("unbound-policy", creator: "unbound"), actorSubjectID: "unbound", at: decisionDate))
      XCTAssertThrowsError(
        try service.setPolicyEnabled(
          id: created.policyID, enabled: false, expectedGeneration: created.generation,
          actorSubjectID: "unbound", updatedAt: "2026-08-02T20:31:00Z", at: decisionDate))
      XCTAssertThrowsError(
        try service.deletePolicy(
          id: created.policyID, expectedGeneration: created.generation,
          actorSubjectID: "unbound", at: decisionDate))
      XCTAssertEqual(try repository.policy(id: created.policyID)?.generation, 1)
      XCTAssertTrue(try repository.policy(id: created.policyID)?.enabled == true)
    }
  }

  func testPolicyCreationRefusesCreatorAndBuiltInSourceSpoofing() throws {
    try withService(subjects: ["security"]) { repository, rbacRepository, service in
      try bind("security-admin", subject: "security", role: "security-admin", repository: rbacRepository)

      XCTAssertThrowsError(
        try service.createPolicy(
          policy("spoofed-creator", creator: "owner"), actorSubjectID: "security", at: decisionDate))
      XCTAssertThrowsError(
        try service.createPolicy(
          policy(
            "spoofed-builtin", source: .builtIn, stage: .builtInValidation,
            creator: "security"), actorSubjectID: "security", at: decisionDate))
      XCTAssertNil(try repository.policy(id: "spoofed-creator"))
      XCTAssertNil(try repository.policy(id: "spoofed-builtin"))
    }
  }

  func testExceptionCreationRequiresApproveAndBindsExactActorAndFutureExpiry() throws {
    try withService(subjects: ["security", "approver", "member", "unbound"]) { repository, rbacRepository, service in
      try bind("security-admin", subject: "security", role: "security-admin", repository: rbacRepository)
      try installPolicyVerbRole(
        "approve-only", subject: "approver", verbs: [.approve], repository: rbacRepository)
      _ = try service.createPolicy(
        policy("exception-policy", creator: "owner"), actorSubjectID: "owner", at: decisionDate)

      XCTAssertThrowsError(
        try service.createException(
          exception("unbound-exception", policyID: "exception-policy", subject: "member", actor: "unbound"),
          actorSubjectID: "unbound", at: decisionDate))
      XCTAssertThrowsError(
        try service.createException(
          exception(
            "spoofed-approval", policyID: "exception-policy", subject: "member",
            actor: "security", approval: "owner"), actorSubjectID: "security", at: decisionDate))
      XCTAssertThrowsError(
        try service.createException(
          exception(
            "spoofed-creator", policyID: "exception-policy", subject: "member",
            actor: "owner", approval: "security"), actorSubjectID: "security", at: decisionDate))
      XCTAssertThrowsError(
        try service.createException(
          exception(
            "expired-exception", policyID: "exception-policy", subject: "member",
            actor: "security", expiresAt: expired), actorSubjectID: "security", at: decisionDate))

      let accepted = try service.createException(
        exception("approved-exception", policyID: "exception-policy", subject: "member", actor: "approver"),
        actorSubjectID: "approver", at: decisionDate)
      XCTAssertEqual(accepted.createdBySubjectID, "approver")
      XCTAssertEqual(accepted.approvalIdentity, "approver")
      XCTAssertEqual(accepted.subjectID, "member")
    }
  }

  func testExceptionCreationRequiresActiveSubjectAndEnabledPolicy() throws {
    try withService(subjects: ["security", "member"]) { repository, rbacRepository, service in
      try bind("security-admin", subject: "security", role: "security-admin", repository: rbacRepository)
      let enabled = try service.createPolicy(
        policy("enabled-policy", creator: "security"), actorSubjectID: "security", at: decisionDate)
      let disabled = try service.createPolicy(
        policy("disabled-policy", creator: "security"), actorSubjectID: "security", at: decisionDate)
      _ = try service.setPolicyEnabled(
        id: disabled.policyID, enabled: false, expectedGeneration: disabled.generation,
        actorSubjectID: "security", updatedAt: "2026-08-02T20:31:00Z", at: decisionDate)

      XCTAssertThrowsError(
        try service.createException(
          exception("inactive-target", policyID: enabled.policyID, subject: "missing", actor: "security"),
          actorSubjectID: "security", at: decisionDate))
      XCTAssertThrowsError(
        try service.createException(
          exception("disabled-policy", policyID: disabled.policyID, subject: "member", actor: "security"),
          actorSubjectID: "security", at: decisionDate))
      XCTAssertNil(try repository.exception(id: "inactive-target"))
      XCTAssertNil(try repository.exception(id: "disabled-policy"))
    }
  }

  func testExceptionDeletionRequiresDeleteVerb() throws {
    try withService(subjects: ["approver", "deleter", "member"]) { repository, rbacRepository, service in
      try installPolicyVerbRole(
        "approve-only", subject: "approver", verbs: [.approve], repository: rbacRepository)
      try installPolicyVerbRole(
        "delete-only", subject: "deleter", verbs: [.delete], repository: rbacRepository)
      _ = try service.createPolicy(
        policy("delete-exception-policy", creator: "owner"), actorSubjectID: "owner", at: decisionDate)
      let stored = try service.createException(
        exception(
          "deletable-exception", policyID: "delete-exception-policy", subject: "member",
          actor: "approver"), actorSubjectID: "approver", at: decisionDate)

      XCTAssertThrowsError(
        try service.deleteException(
          id: stored.exceptionID, expectedGeneration: stored.generation,
          actorSubjectID: "approver", at: decisionDate))
      try service.deleteException(
        id: stored.exceptionID, expectedGeneration: stored.generation,
        actorSubjectID: "deleter", at: decisionDate)
      XCTAssertNil(try repository.exception(id: stored.exceptionID))
    }
  }

  private func withService(
    subjects: [String],
    _ body: (AdmissionRepository, RBACRepository, AdmissionAdministrationService) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner"))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: createdAt)
    for (index, subject) in subjects.enumerated() {
      let hash = String(index + 11, radix: 16).first ?? "b"
      try store.controlIdentities.declare(identity(subject, hash: hash, declaredBy: "owner"))
    }
    try body(
      store.admission, store.rbac,
      AdmissionAdministrationService(
        repository: store.admission, authorizer: RBACAuthorizationEngine(repository: store.rbac)))
  }

  private func installPolicyVerbRole(
    _ id: String, subject: String, verbs: [RBACVerb], repository: RBACRepository
  ) throws {
    _ = try repository.createCustomRole(
      RBACRoleRecord(
        roleID: id, builtIn: false,
        rules: [
          RBACRule(
            identifier: "\(id)-rule", effect: .allow, resources: [.policy], verbs: verbs,
            scope: .init(kind: .global))
        ], createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt),
      actorSubjectID: "owner", timestamp: createdAt)
    try bind("\(id)-binding", subject: subject, role: id, repository: repository)
  }

  private func bind(_ id: String, subject: String, role: String, repository: RBACRepository) throws {
    _ = try repository.createBinding(
      RBACBindingRecord(
        bindingID: id, subjectID: subject, roleID: role, scope: .init(kind: .global),
        createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt))
  }

  private func policy(
    _ id: String, source: AdmissionPolicySourceKind = .extension,
    stage: AdmissionStage = .extensionValidation, creator: String
  ) throws -> AdmissionPolicyRecord {
    let document: ControlPlaneJSONValue = .object([
      "schemaVersion": .integer(1),
      "operations": .array([.string("service.update")]),
      "conditions": .array([]),
      "mutations": .array([]),
      "validations": .array([]),
    ])
    return try AdmissionPolicyRecord(
      policyID: id, version: 1, sourceKind: source, stage: stage, failurePolicy: .deny,
      advisory: false, mutating: stage == .builtInMutation || stage == .extensionMutation,
      document: document, documentSHA256: AdmissionPolicyRecord.digest(document),
      createdBySubjectID: creator, createdAt: createdAt, updatedAt: createdAt).canonicalized()
  }

  private func exception(
    _ id: String, policyID: String, subject: String, actor: String,
    approval: String? = nil, expiresAt: String? = nil
  ) -> AdmissionExceptionRecord {
    AdmissionExceptionRecord(
      exceptionID: id, policyID: policyID, subjectID: subject,
      target: "operation:service.update|project:-|resource:-",
      planHash: String(repeating: "a", count: 64), approvalIdentity: approval ?? actor,
      expiresAt: expiresAt ?? future, createdBySubjectID: actor,
      createdAt: createdAt, updatedAt: createdAt)
  }

  private func identity(_ subject: String, hash: Character, declaredBy: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subject, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-\(subject)",
        codeDirectoryHash: String(repeating: String(hash), count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: createdAt, updatedAt: createdAt)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-admission-administration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
