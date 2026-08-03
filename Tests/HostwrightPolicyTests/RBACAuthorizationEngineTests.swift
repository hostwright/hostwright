import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightPolicy
@testable import HostwrightState

final class RBACAuthorizationEngineTests: XCTestCase {
  private let createdAt = "2026-08-02T20:00:00Z"
  private let evaluationDate = ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!
  private let expiryDate = "2026-08-02T21:00:00Z"
  private let profileHash = String(repeating: "a", count: 64)

  func testFrozenDefaultMatrixAndInheritedRolesAuthorizeOnlyTheirExactCapabilities() throws {
    try withSystem(subjects: ["viewer", "operator", "maintainer", "security"]) {
      repository, engine in
      let roles = try repository.listRoles()
      XCTAssertEqual(roles.map(\.roleID), DefaultRole.allCases.map(\.rawValue).sorted())
      XCTAssertTrue(roles.allSatisfy { $0.builtIn && $0.generation == 1 && $0.createdBySubjectID == nil })
      XCTAssertEqual(
        roles.map(\.definition),
        try RBACRepository.defaultRoles(timestamp: createdAt).map(\.definition))

      try bind("viewer", role: "viewer", id: "viewer-role", repository: repository)
      try bind("operator", role: "operator", id: "operator-role", repository: repository)
      try bind("maintainer", role: "maintainer", id: "maintainer-role", repository: repository)
      try bind("security", role: "security-admin", id: "security-role", repository: repository)

      XCTAssertAllowed(engine, subject: "viewer", request: request("status"), rules: ["builtin.viewer.viewer.allow"])
      XCTAssertAllowed(engine, subject: "viewer", request: request("events"), rules: ["builtin.viewer.viewer.allow"])
      XCTAssertDenied(engine, subject: "viewer", request: request("up"), reason: "authorization.no-allow")
      XCTAssertDenied(engine, subject: "viewer", request: request("plan"), reason: "authorization.no-allow")

      XCTAssertAllowed(engine, subject: "operator", request: request("status"), rules: ["builtin.operator.viewer.allow"])
      XCTAssertAllowed(engine, subject: "operator", request: request("up"), rules: ["builtin.operator.operator.allow"])
      XCTAssertDenied(engine, subject: "operator", request: request("update"), reason: "authorization.no-allow")

      XCTAssertAllowed(engine, subject: "maintainer", request: request("status"), rules: ["builtin.maintainer.viewer.allow"])
      XCTAssertAllowed(engine, subject: "maintainer", request: request("up"), rules: ["builtin.maintainer.operator.allow"])
      XCTAssertAllowed(engine, subject: "maintainer", request: request("update"), rules: ["builtin.maintainer.maintainer.allow"])

      XCTAssertAllowed(engine, subject: "security", request: request("audit.verify"), rules: ["builtin.security-admin.security-admin.allow"])
      XCTAssertAllowed(engine, subject: "security", request: request("rbac.role.create"), rules: ["builtin.security-admin.security-admin.allow"])
      XCTAssertDenied(engine, subject: "security", request: request("up"), reason: "authorization.no-allow")
    }
  }

  func testNoBindingDefaultsToDenyAndUnknownOperationsRequireOwnerAdmin() throws {
    try withSystem(subjects: ["unbound", "security"]) { repository, engine in
      try bind("security", role: "security-admin", id: "security-role", repository: repository)

      XCTAssertDenied(engine, subject: "unbound", request: request("status"), reason: "authorization.no-allow")
      XCTAssertDenied(engine, subject: "security", request: request("future.unknown"), reason: "authorization.no-allow")
      XCTAssertAllowed(engine, subject: "owner", request: request("future.unknown"), rules: ["builtin.owner.owner.allow"])
    }
  }

  func testMalformedOrConflictingTargetFieldsFailClosedBeforePolicyEvaluation() throws {
    try withSystem(subjects: []) { _, engine in
      XCTAssertThrowsError(
        try engine.authorize(
          subject: subject("owner"), request: request("status", body: .string("project-a")),
          at: evaluationDate))
      XCTAssertThrowsError(
        try engine.authorize(
          subject: subject("owner"),
          request: request(
            "status",
            body: .object([
              "projectUUID": .string("project-a"),
              "projectID": .string("project-b"),
            ])),
          at: evaluationDate))
      XCTAssertThrowsError(
        try engine.authorize(
          subject: subject("owner"),
          request: request("status", body: .object(["projectUUID": .integer(7)])),
          at: evaluationDate))
    }
  }

  func testExplicitDenyOverridesAllowsWithDeterministicRuleExplanation() throws {
    try withSystem(subjects: ["member"]) { repository, engine in
      try createRole(
        "allow-role", rules: [
          rule("allow-z", effect: .allow, resources: [.service], verbs: [.start]),
          rule("allow-a", effect: .allow, resources: [.service], verbs: [.start]),
        ], repository: repository)
      try createRole(
        "deny-role", rules: [rule("deny-a", effect: .deny, resources: [.service], verbs: [.start])],
        repository: repository)
      try bind("member", role: "allow-role", id: "member-allow", repository: repository)

      XCTAssertAllowed(engine, subject: "member", request: request("start"), rules: ["allow-a", "allow-z"])

      try bind("member", role: "deny-role", id: "member-deny", repository: repository)
      XCTAssertDenied(
        engine, subject: "member", request: request("start"), reason: "authorization.explicit-deny",
        rules: ["deny-a"])
    }
  }

  func testProjectResourceAndANDOnlyConditionsConstrainAuthorization() throws {
    try withSystem(subjects: ["scoped"]) { repository, engine in
      try createRole(
        "conditional", rules: [
          rule(
            "conditional-start", effect: .allow, resources: [.service], verbs: [.start],
            scope: RBACScope(kind: .project, identifier: "project-a"),
            conditions: [
              RBACCondition(kind: .resource, value: "service-a"),
              RBACCondition(kind: .operation, value: "start"),
              RBACCondition(kind: .profileHash, value: profileHash),
              RBACCondition(kind: .expiresAt, value: expiryDate),
            ])
        ], repository: repository)
      try bind("scoped", role: "conditional", id: "conditional-binding", repository: repository)
      try createRole(
        "resource-binding", rules: [
          rule("resource-start", effect: .allow, resources: [.service], verbs: [.start])
        ], repository: repository)
      try bind(
        "scoped", role: "resource-binding", id: "resource-binding", scope: .init(kind: .resource, identifier: "service-b"),
        repository: repository)

      let expiringRequest = request(
        "start", body: body(project: "project-a", resource: "service-a", profile: profileHash))
      XCTAssertAllowed(
        engine, subject: "scoped", request: expiringRequest,
        rules: ["conditional-start"])
      let afterExpiry = try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-08-02T21:00:01Z"))
      XCTAssertEqual(
        try engine.authorize(
          subject: subject("scoped"), request: expiringRequest, at: afterExpiry).effect,
        .deny)
      XCTAssertDenied(
        engine, subject: "scoped",
        request: request("start", body: body(project: "project-b", resource: "service-a", profile: profileHash)),
        reason: "authorization.no-allow")
      XCTAssertDenied(
        engine, subject: "scoped",
        request: request("start", body: body(project: "project-a", resource: "service-a", profile: String(repeating: "b", count: 64))),
        reason: "authorization.no-allow")
      XCTAssertAllowed(
        engine, subject: "scoped", request: request("start", body: body(resource: "service-b")),
        rules: ["resource-start"])
      XCTAssertDenied(
        engine, subject: "scoped", request: request("start", body: body(resource: "service-c")),
        reason: "authorization.no-allow")
    }
  }

  func testActiveDelegationWorksThenRevocationAndExpiryStopItImmediately() throws {
    try withSystem(subjects: ["delegate", "expired-delegate"]) { repository, engine in
      let active = RBACDelegationRecord(
        delegationID: "active-operator", delegatorSubjectID: "owner", delegateSubjectID: "delegate",
        roleIDs: ["operator"], delegatedRules: [], scope: .init(kind: .global), expiresAt: expiryDate,
        createdAt: createdAt, updatedAt: createdAt)
      let expired = RBACDelegationRecord(
        delegationID: "expired-operator", delegatorSubjectID: "owner", delegateSubjectID: "expired-delegate",
        roleIDs: ["operator"], delegatedRules: [], scope: .init(kind: .global), expiresAt: "2026-08-02T20:15:00Z",
        createdAt: createdAt, updatedAt: createdAt)
      _ = try repository.createDelegation(active)
      _ = try repository.createDelegation(expired)

      let delegatedRequest = request("start")
      XCTAssertAllowed(
        engine, subject: "delegate", request: delegatedRequest,
        rules: ["builtin.operator.operator.allow"])
      let afterExpiry = try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-08-02T21:00:01Z"))
      XCTAssertEqual(
        try engine.authorize(
          subject: subject("delegate"), request: delegatedRequest, at: afterExpiry).effect,
        .deny)
      XCTAssertDenied(engine, subject: "expired-delegate", request: request("start"), reason: "authorization.no-allow")

      _ = try repository.revokeDelegation(
        id: "active-operator", expectedGeneration: 1, revokedAt: "2026-08-02T20:31:00Z")
      XCTAssertDenied(engine, subject: "delegate", request: request("start"), reason: "authorization.no-allow")
    }
  }

  func testDecisionCacheInvalidatesForBindingRoleAndDelegationChangesWithoutRestart() throws {
    try withSystem(subjects: ["member", "delegate"]) { repository, engine in
      let status = request("status")
      XCTAssertDenied(engine, subject: "member", request: status, reason: "authorization.no-allow")
      try bind("member", role: "viewer", id: "member-viewer", repository: repository)
      XCTAssertAllowed(engine, subject: "member", request: status, rules: ["builtin.viewer.viewer.allow"])
      try repository.deleteBinding(id: "member-viewer", expectedGeneration: 1)
      XCTAssertDenied(engine, subject: "member", request: status, reason: "authorization.no-allow")

      try createRole(
        "mutable", rules: [rule("mutable-read", effect: .allow, resources: [.project], verbs: [.get])],
        repository: repository)
      try bind("member", role: "mutable", id: "member-mutable", repository: repository)
      XCTAssertAllowed(engine, subject: "member", request: status, rules: ["mutable-read"])
      let updated = RBACRoleRecord(
        roleID: "mutable", builtIn: false,
        rules: [rule("mutable-deny", effect: .deny, resources: [.project], verbs: [.get])],
        createdBySubjectID: "owner", createdAt: createdAt, updatedAt: "2026-08-02T20:31:00Z")
      _ = try repository.updateCustomRole(
        updated, expectedGeneration: 1, actorSubjectID: "owner", timestamp: "2026-08-02T20:31:00Z")
      XCTAssertDenied(
        engine, subject: "member", request: status, reason: "authorization.explicit-deny",
        rules: ["mutable-deny"])

      _ = try repository.createDelegation(
        RBACDelegationRecord(
          delegationID: "delegate-viewer", delegatorSubjectID: "owner", delegateSubjectID: "delegate",
          roleIDs: ["viewer"], delegatedRules: [], scope: .init(kind: .global), expiresAt: expiryDate,
          createdAt: createdAt, updatedAt: createdAt))
      XCTAssertAllowed(engine, subject: "delegate", request: status, rules: ["builtin.viewer.viewer.allow"])
      _ = try repository.revokeDelegation(
        id: "delegate-viewer", expectedGeneration: 1, revokedAt: "2026-08-02T20:31:00Z")
      XCTAssertDenied(engine, subject: "delegate", request: status, reason: "authorization.no-allow")
    }
  }

  func testHorizontalAndVerticalEscalationAttemptsDeny() throws {
    try withSystem(subjects: ["viewer", "project-member"]) { repository, engine in
      try bind("viewer", role: "viewer", id: "viewer-role", repository: repository)
      try bind(
        "project-member", role: "operator", id: "project-operator",
        scope: .init(kind: .project, identifier: "project-a"), repository: repository)

      XCTAssertDenied(engine, subject: "viewer", request: request("start"), reason: "authorization.no-allow")
      XCTAssertAllowed(
        engine, subject: "project-member", request: request("start", body: body(project: "project-a")),
        rules: ["builtin.operator.operator.allow"])
      XCTAssertDenied(
        engine, subject: "project-member", request: request("start", body: body(project: "project-b")),
        reason: "authorization.no-allow")
    }
  }

  private func withSystem(
    subjects: [String], _ body: (RBACRepository, RBACAuthorizationEngine) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner"))
    let repository = store.rbac
    try repository.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: createdAt)
    for (offset, subject) in subjects.enumerated() {
      let hex = String(offset + 11, radix: 16).first ?? "b"
      try store.controlIdentities.declare(identity(subject, hash: hex, declaredBy: "owner"))
    }
    try body(repository, RBACAuthorizationEngine(repository: repository))
  }

  private func identity(_ subject: String, hash: Character, declaredBy: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subject, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
        codeDirectoryHash: String(repeating: String(hash), count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: createdAt, updatedAt: createdAt)
  }

  private func bind(
    _ subject: String, role: String, id: String, scope: RBACScope = .init(kind: .global),
    repository: RBACRepository
  ) throws {
    _ = try repository.createBinding(
      RBACBindingRecord(
        bindingID: id, subjectID: subject, roleID: role, scope: scope, createdBySubjectID: "owner",
        createdAt: createdAt, updatedAt: createdAt))
  }

  private func createRole(_ id: String, rules: [RBACRule], repository: RBACRepository) throws {
    _ = try repository.createCustomRole(
      RBACRoleRecord(
        roleID: id, builtIn: false, rules: rules, createdBySubjectID: "owner",
        createdAt: createdAt, updatedAt: createdAt), actorSubjectID: "owner", timestamp: createdAt)
  }

  private func rule(
    _ id: String, effect: RBACEffect = .allow, resources: [RBACResource], verbs: [RBACVerb],
    scope: RBACScope = .init(kind: .global), conditions: [RBACCondition] = []
  ) -> RBACRule {
    RBACRule(
      identifier: id, effect: effect, resources: resources, verbs: verbs, scope: scope,
      conditions: conditions)
  }

  private func request(
    _ operation: String, body: ControlPlaneJSONValue? = nil
  ) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: "request-\(operation)-\(UUID().uuidString)", operation: operation,
      timeoutMilliseconds: 1_000, body: body)
  }

  private func body(
    project: String? = nil, resource: String? = nil, profile: String? = nil
  ) -> ControlPlaneJSONValue {
    var fields: [String: ControlPlaneJSONValue] = [:]
    if let project { fields["projectUUID"] = .string(project) }
    if let resource { fields["resourceUUID"] = .string(resource) }
    if let profile { fields["profileHash"] = .string(profile) }
    return .object(fields)
  }

  private func subject(_ id: String) -> LocalSubject {
    let hashes: [String: Character] = [
      "owner": "a", "viewer": "b", "operator": "c", "maintainer": "d", "security": "e",
      "unbound": "b", "member": "b", "scoped": "b", "delegate": "b", "expired-delegate": "c",
      "project-member": "c",
    ]
    return LocalSubject(
      identifier: id, userID: 501,
      codeIdentityHash: String(repeating: String(hashes[id] ?? "b"), count: 40))
  }

  private func XCTAssertAllowed(
    _ engine: RBACAuthorizationEngine, subject: String, request: ControlRequestEnvelope,
    rules: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      let decision = try engine.authorize(subject: self.subject(subject), request: request, at: evaluationDate)
      XCTAssertEqual(decision.effect, .allow, file: file, line: line)
      XCTAssertEqual(decision.reasonCode, "authorization.allowed", file: file, line: line)
      XCTAssertEqual(decision.ruleIdentifiers, rules, file: file, line: line)
    } catch {
      XCTFail("authorization unexpectedly threw: \(error)", file: file, line: line)
    }
  }

  private func XCTAssertDenied(
    _ engine: RBACAuthorizationEngine, subject: String, request: ControlRequestEnvelope,
    reason: String, rules: [String] = [], file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      let decision = try engine.authorize(subject: self.subject(subject), request: request, at: evaluationDate)
      XCTAssertEqual(decision.effect, .deny, file: file, line: line)
      XCTAssertEqual(decision.reasonCode, reason, file: file, line: line)
      XCTAssertEqual(decision.ruleIdentifiers, rules, file: file, line: line)
    } catch {
      XCTFail("authorization unexpectedly threw: \(error)", file: file, line: line)
    }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-rbac-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
