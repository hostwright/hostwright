import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightDaemon
@testable import HostwrightPolicy
@testable import HostwrightState

final class RBACControlOperationsTests: XCTestCase {
  private let timestamp = "2026-08-02T20:00:00Z"
  private let now = ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!
  private let expiry = ISO8601DateFormatter().date(from: "2026-08-02T21:00:00Z")!

  func testOwnerRoleListCreateUpdateAndDelete() throws {
    try withFixture { fixture in
      let listed = try XCTUnwrap(fixture.handle(request("rbac.role.list")))
      XCTAssertEqual(listed.status, .completed)
      XCTAssertEqual(try decode([RBACRoleRecord].self, from: listed.result).map(\.roleID), [
        "maintainer", "operator", "owner", "security-admin", "viewer",
      ])

      let initial = RoleDefinition(
        identifier: "audit-reader", builtIn: false,
        rules: [rule("audit-read", resources: [.audit], verbs: [.get])])
      let created = try XCTUnwrap(fixture.handle(request("rbac.role.create", body: ["role": value(initial)])))
      XCTAssertEqual(created.status, .completed)
      XCTAssertEqual(try decode(RBACRoleRecord.self, from: created.result).generation, 1)

      let updated = RoleDefinition(
        identifier: "audit-reader", builtIn: false,
        rules: [rule("audit-read", resources: [.audit], verbs: [.get, .list])])
      let replacement = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.role.update",
            body: ["role": value(updated), "expectedGeneration": .integer(1)])))
      XCTAssertEqual(replacement.status, .completed)
      XCTAssertEqual(try decode(RBACRoleRecord.self, from: replacement.result).generation, 2)

      let deleted = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.role.delete",
            body: ["identifier": .string("audit-reader"), "expectedGeneration": .integer(2)])))
      XCTAssertEqual(deleted.status, .completed)
      XCTAssertNil(try fixture.repository.role(id: "audit-reader"))
    }
  }

  func testBindingsSupportCreateListAndDelete() throws {
    try withFixture(subjects: ["member", "second-owner"]) { fixture in
      let member = RBACBinding(
        identifier: "member-viewer", subject: "member", roleIdentifier: "viewer",
        scope: .init(kind: .global))
      let created = try XCTUnwrap(
        fixture.handle(request("rbac.binding.create", body: ["binding": value(member)])))
      XCTAssertEqual(
        try decode(
          RBACBindingRecord.self,
          from: created.result).bindingID,
        "member-viewer")

      let listed = try XCTUnwrap(
        fixture.handle(request("rbac.binding.list", body: ["subjectID": .string("member")]))
      )
      XCTAssertEqual(try decode([RBACBindingRecord].self, from: listed.result).map(\.bindingID), ["member-viewer"])

      let deleted = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.binding.delete",
            body: ["identifier": .string("member-viewer"), "expectedGeneration": .integer(1)])))
      XCTAssertEqual(deleted.status, .completed)
      XCTAssertNil(try fixture.repository.binding(id: "member-viewer"))
    }
  }

  func testOwnerBindingsProtectLastOwnerWithoutMutatingState() throws {
    try withFixture(subjects: ["second-owner"]) { fixture in
      let secondOwner = RBACBinding(
        identifier: "second-owner", subject: "second-owner", roleIdentifier: "owner",
        scope: .init(kind: .global))
      let created = try XCTUnwrap(
        fixture.handle(request("rbac.binding.create", body: ["binding": value(secondOwner)])))
      XCTAssertEqual(created.status, .completed)

      let bootstrapDeletion = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.binding.delete",
            body: ["identifier": .string("bootstrap-owner"), "expectedGeneration": .integer(1)])))
      XCTAssertEqual(bootstrapDeletion.status, .completed)

      let refusal = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.binding.delete",
            body: ["identifier": .string("second-owner"), "expectedGeneration": .integer(1)])))
      XCTAssertEqual(refusal.status, .rejected)
      XCTAssertEqual(refusal.reasonCode, .unauthorized)
      XCTAssertEqual(refusal.error?.code, "rbacGrantExceedsAuthority")
      XCTAssertNotNil(try fixture.repository.binding(id: "second-owner"))
    }
  }

  func testPreviewIsDeterministicForAllowedAndDeniedTargetRequests() throws {
    try withFixture { fixture in
      let target = request("status")
      let allowed = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.preview",
            body: ["subjectID": .string("owner"), "request": value(target)])))
      let repeated = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.preview",
            body: ["subjectID": .string("owner"), "request": value(target)])))
      let denied = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.preview",
            body: ["subjectID": .string("unbound"), "request": value(target)])))

      XCTAssertEqual(try decode(RBACDecision.self, from: allowed.result), try decode(RBACDecision.self, from: repeated.result))
      XCTAssertEqual(try decode(RBACDecision.self, from: allowed.result).effect, .allow)
      XCTAssertEqual(try decode(RBACDecision.self, from: denied.result).effect, .deny)
      XCTAssertEqual(try decode(RBACDecision.self, from: denied.result).reasonCode, "authorization.no-allow")
    }
  }

  func testSchedulerReadsUseTopLevelProjectScopeForRBACAllowAndDeny() throws {
    try withFixture(subjects: ["project-reader"]) { fixture in
      _ = try fixture.repository.createCustomRole(
        RBACRoleRecord(
          roleID: "project-scheduler-reader",
          builtIn: false,
          rules: [RBACRule(
            identifier: "project-scheduler-plan",
            effect: .allow,
            resources: [.project],
            verbs: [.plan],
            scope: .init(kind: .project, identifier: "project-a")
          )],
          createdBySubjectID: "owner",
          createdAt: timestamp,
          updatedAt: timestamp
        ),
        actorSubjectID: "owner",
        timestamp: timestamp
      )
      _ = try fixture.repository.createBinding(
        RBACBindingRecord(
          bindingID: "project-scheduler-reader-binding",
          subjectID: "project-reader",
          roleID: "project-scheduler-reader",
          scope: .init(kind: .global),
          createdBySubjectID: "owner",
          createdAt: timestamp,
          updatedAt: timestamp
        )
      )
      let reader = fixture.withPeer(
        subjectID: "project-reader", codeHash: String(repeating: "b", count: 40))
      let input: ControlPlaneJSONValue = .object([
        "pendingWorkloads": .array([]),
        "nodes": .array([]),
      ])
      let allowed = ControlRequestEnvelope(
        protocolRevision: .current,
        requestID: "scheduler-project-a",
        operation: "scheduler.plan",
        timeoutMilliseconds: 1_000,
        body: .object(["projectID": .string("project-a"), "input": input])
      )
      let target = try RBACAuthorizationEngine.target(for: allowed)
      XCTAssertEqual(target.resource, .project)
      XCTAssertEqual(target.verb, .plan)
      XCTAssertEqual(target.projectIdentifier, "project-a")
      let allowDecision = try fixture.authorizer.authorize(
        subject: reader.peer.binding.subject, request: allowed, at: now)
      XCTAssertEqual(allowDecision.effect, .allow)

      let denied = ControlRequestEnvelope(
        protocolRevision: .current,
        requestID: "scheduler-project-b",
        operation: "scheduler.simulate",
        timeoutMilliseconds: 1_000,
        body: .object(["projectID": .string("project-b"), "input": input])
      )
      let denyDecision = try fixture.authorizer.authorize(
        subject: reader.peer.binding.subject, request: denied, at: now)
      XCTAssertEqual(denyDecision.effect, .deny)
      XCTAssertEqual(denyDecision.reasonCode, "authorization.no-allow")

      let missingProject = ControlRequestEnvelope(
        protocolRevision: .current,
        requestID: "scheduler-missing-project",
        operation: "scheduler.plan",
        timeoutMilliseconds: 1_000,
        body: .object(["input": input])
      )
      XCTAssertThrowsError(try RBACAuthorizationEngine.target(for: missingProject)) { error in
        XCTAssertEqual(error as? RBACAuthorizationError, .invalidTarget)
      }

      let operationVerbs: [(String, RBACVerb)] = [
        ("scheduler.status", .get),
        ("scheduler.explain", .get),
        ("scheduler.apply", .update),
      ]
      for (operation, verb) in operationVerbs {
        let scoped = ControlRequestEnvelope(
          protocolRevision: .current,
          requestID: "(operation)-scope",
          operation: operation,
          timeoutMilliseconds: 1_000,
          body: .object(["projectID": .string("project-a")])
        )
        let mapped = try RBACAuthorizationEngine.target(for: scoped)
        XCTAssertEqual(mapped.resource, .project)
        XCTAssertEqual(mapped.verb, verb)
        XCTAssertEqual(mapped.projectIdentifier, "project-a")
      }

      let inconsistentMutation = ControlRequestEnvelope(
        protocolRevision: .current,
        requestID: "scheduler-apply-mutating-field",
        operation: "scheduler.apply",
        timeoutMilliseconds: 1_000,
        body: .object([
          "projectID": .string("project-a"),
          "mutating": .bool(true),
        ])
      )
      XCTAssertThrowsError(try RBACAuthorizationEngine.target(for: inconsistentMutation)) { error in
        XCTAssertEqual(error as? RBACAuthorizationError, .invalidTarget)
      }
    }
  }

  func testOwnerCanCreateListAndRevokeDelegation() throws {
    try withFixture(subjects: ["delegate"]) { fixture in
      let delegation = RBACDelegation(
        identifier: "delegate-viewer", delegator: "owner", delegate: "delegate",
        roleIdentifiers: ["viewer"], delegatedRules: [], scope: .init(kind: .global),
        expiresAt: expiry)
      let created = try XCTUnwrap(
        fixture.handle(request("rbac.delegation.create", body: ["delegation": value(delegation)])))
      XCTAssertEqual(created.status, .completed)
      XCTAssertEqual(try decode(RBACDelegationRecord.self, from: created.result).generation, 1)

      let listed = try XCTUnwrap(
        fixture.handle(request("rbac.delegation.list", body: ["subjectID": .string("delegate")]))
      )
      XCTAssertEqual(
        try decode([RBACDelegationRecord].self, from: listed.result).map(\.delegationID),
        ["delegate-viewer"])

      let revoked = try XCTUnwrap(
        fixture.handle(
          request(
            "rbac.delegation.revoke",
            body: ["identifier": .string("delegate-viewer"), "expectedGeneration": .integer(1)])))
      XCTAssertEqual(revoked.status, .completed)
      XCTAssertNotNil(try decode(RBACDelegationRecord.self, from: revoked.result).revokedAt)
    }
  }

  func testSecurityAdminCannotMintServiceOperatorOrOwnerRights() throws {
    try withFixture(subjects: ["security", "member"]) { fixture in
      _ = try fixture.repository.createBinding(
        RBACBindingRecord(
          bindingID: "security-admin", subjectID: "security", roleID: "security-admin",
          scope: .init(kind: .global), createdBySubjectID: "owner", createdAt: timestamp,
          updatedAt: timestamp))
      let securityFixture = fixture.withPeer(subjectID: "security", codeHash: String(repeating: "b", count: 40))

      let serviceRole = RoleDefinition(
        identifier: "service-operator", builtIn: false,
        rules: [rule("service-start", resources: [.service], verbs: [.start])])
      assertGrantRefused(
        securityFixture.handle(request("rbac.role.create", body: ["role": value(serviceRole)])))

      let operatorBinding = RBACBinding(
        identifier: "member-operator", subject: "member", roleIdentifier: "operator",
        scope: .init(kind: .global))
      assertGrantRefused(
        securityFixture.handle(request("rbac.binding.create", body: ["binding": value(operatorBinding)])))

      let ownerBinding = RBACBinding(
        identifier: "member-owner", subject: "member", roleIdentifier: "owner",
        scope: .init(kind: .global))
      assertGrantRefused(
        securityFixture.handle(request("rbac.binding.create", body: ["binding": value(ownerBinding)])))

      XCTAssertNil(try fixture.repository.role(id: "service-operator"))
      XCTAssertNil(try fixture.repository.binding(id: "member-operator"))
      XCTAssertNil(try fixture.repository.binding(id: "member-owner"))
    }
  }

  func testMalformedAndUnknownBodiesAreRejectedWithoutStateChanges() throws {
    try withFixture { fixture in
      let beforeRoles = try fixture.repository.listRoles()
      let beforeBindings = try fixture.repository.listBindings()
      let beforeDelegations = try fixture.repository.listDelegations()

      let malformed = try XCTUnwrap(
        fixture.handle(request("rbac.role.create", body: ["unexpected": .string("value")])))
      let unknown = try XCTUnwrap(fixture.handle(request("rbac.unknown", body: .string("not-an-object"))))

      for response in [malformed, unknown] {
        XCTAssertEqual(response.status, .rejected)
        XCTAssertEqual(response.reasonCode, .invalidRequest)
        XCTAssertNotNil(response.error)
        XCTAssertFalse(response.error!.message.contains(fixture.store.path))
      }
      XCTAssertEqual(try fixture.repository.listRoles(), beforeRoles)
      XCTAssertEqual(try fixture.repository.listBindings(), beforeBindings)
      XCTAssertEqual(try fixture.repository.listDelegations(), beforeDelegations)
    }
  }

  func testEveryRBACOperationRejectsUnknownBodyFieldsWithoutStateChanges() throws {
    try withFixture(subjects: ["member", "delegate"]) { fixture in
      let updateRole = roleRecord("unknown-update-target")
      let deleteRole = roleRecord("unknown-delete-target")
      _ = try fixture.repository.createCustomRole(
        updateRole, actorSubjectID: "owner", timestamp: timestamp)
      _ = try fixture.repository.createCustomRole(
        deleteRole, actorSubjectID: "owner", timestamp: timestamp)
      _ = try fixture.repository.createBinding(
        bindingRecord("unknown-delete-binding", subject: "member", role: "viewer"))
      _ = try fixture.repository.createDelegation(
        delegationRecord("unknown-revoke-delegation", delegate: "delegate"))

      let createdRole = RoleDefinition(
        identifier: "unknown-create-role", builtIn: false,
        rules: [rule("unknown-create-read", resources: [.audit], verbs: [.get])])
      let replacementRole = RoleDefinition(
        identifier: updateRole.roleID, builtIn: false,
        rules: [rule("unknown-update-list", resources: [.audit], verbs: [.list])])
      let createdBinding = RBACBinding(
        identifier: "unknown-create-binding", subject: "member", roleIdentifier: "viewer",
        scope: .init(kind: .global))
      let createdDelegation = RBACDelegation(
        identifier: "unknown-create-delegation", delegator: "owner", delegate: "delegate",
        roleIdentifiers: ["viewer"], delegatedRules: [], scope: .init(kind: .global),
        expiresAt: expiry)
      let target = request("status")
      let cases: [(String, [String: ControlPlaneJSONValue])] = [
        ("rbac.preview", ["request": value(target), "subjectID": .string("owner")]),
        ("rbac.role.list", [:]),
        ("rbac.role.create", ["role": value(createdRole)]),
        (
          "rbac.role.update",
          ["role": value(replacementRole), "expectedGeneration": .integer(1)]
        ),
        (
          "rbac.role.delete",
          ["identifier": .string(deleteRole.roleID), "expectedGeneration": .integer(1)]
        ),
        ("rbac.binding.list", ["subjectID": .string("member")]),
        ("rbac.binding.create", ["binding": value(createdBinding)]),
        (
          "rbac.binding.delete",
          ["identifier": .string("unknown-delete-binding"), "expectedGeneration": .integer(1)]
        ),
        ("rbac.delegation.list", ["subjectID": .string("delegate")]),
        ("rbac.delegation.create", ["delegation": value(createdDelegation)]),
        (
          "rbac.delegation.revoke",
          [
            "identifier": .string("unknown-revoke-delegation"),
            "expectedGeneration": .integer(1),
          ]
        ),
      ]
      let rolesBefore = try fixture.repository.listRoles()
      let bindingsBefore = try fixture.repository.listBindings()
      let delegationsBefore = try fixture.repository.listDelegations()

      for (operation, allowedFields) in cases {
        var body = allowedFields
        body["unexpected"] = .bool(true)
        assertInvalidRequest(
          fixture.handle(request(operation, body: body)),
          message: "\(operation) accepted an unknown body field")
      }

      XCTAssertEqual(try fixture.repository.listRoles(), rolesBefore)
      XCTAssertEqual(try fixture.repository.listBindings(), bindingsBefore)
      XCTAssertEqual(try fixture.repository.listDelegations(), delegationsBefore)
    }
  }

  func testOptionalSubjectIDFieldsFailClosedWhenPresentButInvalid() throws {
    try withFixture(subjects: ["member"]) { fixture in
      let invalidValues: [(String, ControlPlaneJSONValue)] = [
        ("non-string", .integer(501)),
        ("empty", .string("")),
        ("oversized", .string(String(repeating: "x", count: 129))),
      ]
      let target = request("status")

      for (description, invalidSubject) in invalidValues {
        assertInvalidRequest(
          fixture.handle(
            request(
              "rbac.preview",
              body: ["request": value(target), "subjectID": invalidSubject])),
          message: "rbac.preview accepted \(description) subjectID")
        assertInvalidRequest(
          fixture.handle(
            request("rbac.binding.list", body: ["subjectID": invalidSubject])),
          message: "rbac.binding.list accepted \(description) subjectID")
        assertInvalidRequest(
          fixture.handle(
            request("rbac.delegation.list", body: ["subjectID": invalidSubject])),
          message: "rbac.delegation.list accepted \(description) subjectID")
      }
    }
  }

  func testMutationResultsDoNotContainPeerCredentialOrCodeHashMaterial() throws {
    try withFixture { fixture in
      let role = RoleDefinition(
        identifier: "audit-reader", builtIn: false,
        rules: [rule("audit-read", resources: [.audit], verbs: [.get])])
      let response = try XCTUnwrap(
        fixture.handle(request("rbac.role.create", body: ["role": value(role)])))
      let encoded = String(
        data: try JSONEncoder().encode(response), encoding: .utf8)!

      XCTAssertFalse(encoded.contains(fixture.peer.binding.peer.codeIdentity.codeDirectoryHash))
      XCTAssertFalse(encoded.contains("credential-must-not-leak"))
      XCTAssertFalse(encoded.contains(fixture.peer.binding.sessionID))
      XCTAssertFalse(encoded.contains(fixture.peer.binding.serverNonce))
    }
  }

  private func assertGrantRefused(_ response: ControlResponseEnvelope?) {
    XCTAssertEqual(response?.status, .rejected)
    XCTAssertEqual(response?.reasonCode, .unauthorized)
    XCTAssertEqual(response?.error?.code, "rbacGrantExceedsAuthority")
  }

  private func assertInvalidRequest(
    _ response: ControlResponseEnvelope?, message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(response?.status, .rejected, message, file: file, line: line)
    XCTAssertEqual(response?.reasonCode, .invalidRequest, message, file: file, line: line)
    XCTAssertEqual(response?.error?.code, "invalidRBACRequest", message, file: file, line: line)
  }

  private func request(
    _ operation: String,
    body: [String: ControlPlaneJSONValue]? = nil
  ) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: "request-\(UUID().uuidString)", operation: operation,
      timeoutMilliseconds: 1_000, body: body.map(ControlPlaneJSONValue.object))
  }

  private func request(_ operation: String, body: ControlPlaneJSONValue) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: "request-\(UUID().uuidString)", operation: operation,
      timeoutMilliseconds: 1_000, body: body)
  }

  private func rule(
    _ identifier: String, resources: [RBACResource], verbs: [RBACVerb]
  ) -> RBACRule {
    RBACRule(
      identifier: identifier, effect: .allow, resources: resources, verbs: verbs,
      scope: .init(kind: .global))
  }

  private func roleRecord(_ identifier: String) -> RBACRoleRecord {
    RBACRoleRecord(
      roleID: identifier, builtIn: false,
      rules: [rule("\(identifier)-read", resources: [.audit], verbs: [.get])],
      createdBySubjectID: "owner", createdAt: timestamp, updatedAt: timestamp)
  }

  private func bindingRecord(
    _ identifier: String, subject: String, role: String
  ) -> RBACBindingRecord {
    RBACBindingRecord(
      bindingID: identifier, subjectID: subject, roleID: role, scope: .init(kind: .global),
      createdBySubjectID: "owner", createdAt: timestamp, updatedAt: timestamp)
  }

  private func delegationRecord(
    _ identifier: String, delegate: String
  ) -> RBACDelegationRecord {
    RBACDelegationRecord(
      delegationID: identifier, delegatorSubjectID: "owner", delegateSubjectID: delegate,
      roleIDs: ["viewer"], delegatedRules: [], scope: .init(kind: .global),
      expiresAt: ISO8601DateFormatter().string(from: expiry), createdAt: timestamp,
      updatedAt: timestamp)
  }

  private func value<T: Encodable>(_ value: T) -> ControlPlaneJSONValue {
    try! JSONDecoder().decode(ControlPlaneJSONValue.self, from: JSONEncoder().encode(value))
  }

  private func decode<T: Decodable>(_ type: T.Type, from value: ControlPlaneJSONValue?) throws -> T {
    try JSONDecoder().decode(T.self, from: try XCTUnwrap(value).encoded())
  }

  private func withFixture(
    subjects: [String] = [], _ body: (Fixture) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-rbac-control-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }

    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner"))
    let repository = store.rbac
    try repository.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)
    for (index, subject) in subjects.enumerated() {
      let hash = String(UnicodeScalar(98 + index)!)
      try store.controlIdentities.declare(identity(subject, hash: hash, declaredBy: "owner"))
    }
    let authorizer = RBACAuthorizationEngine(repository: repository)
    let administration = RBACAdministrationService(repository: repository, authorizer: authorizer)
    try body(
      Fixture(
        store: store, repository: repository, administration: administration, authorizer: authorizer,
        peer: peer(subjectID: "owner", codeHash: String(repeating: "a", count: 40))))
  }

  private func identity(
    _ subjectID: String, hash: String, declaredBy: String
  ) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: subjectID, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test-\(subjectID)",
        codeDirectoryHash: String(repeating: hash, count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: timestamp, updatedAt: timestamp)
  }

  private func peer(subjectID: String, codeHash: String) -> AuthenticatedControlPeer {
    AuthenticatedControlPeer(
      binding: ControlSessionBinding(
        sessionID: "session-must-not-leak", daemonGeneration: 1,
        serverNonce: "nonce-must-not-leak", socketDevice: 1, socketInode: 2,
        peer: UnixPeerIdentity(
          effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
          codeIdentity: CodeIdentity(
            teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test-\(subjectID)",
            codeDirectoryHash: codeHash, validationMode: .installedRequirement)),
        subject: LocalSubject(
          identifier: subjectID, userID: 501, codeIdentityHash: codeHash,
          credentialID: "credential-must-not-leak")))
  }

  private struct Fixture {
    let store: SQLiteStateStore
    let repository: RBACRepository
    let administration: RBACAdministrationService
    let authorizer: RBACAuthorizationEngine
    let peer: AuthenticatedControlPeer

    func handle(_ request: ControlRequestEnvelope) -> ControlResponseEnvelope? {
      RBACControlOperations.handle(
        peer: peer, request: request, repository: repository, administration: administration,
        authorizer: authorizer, now: ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!)
    }

    func withPeer(subjectID: String, codeHash: String) -> Fixture {
      Fixture(
        store: store, repository: repository, administration: administration, authorizer: authorizer,
        peer: AuthenticatedControlPeer(
          binding: ControlSessionBinding(
            sessionID: "session-must-not-leak", daemonGeneration: 1,
            serverNonce: "nonce-must-not-leak", socketDevice: 1, socketInode: 2,
            peer: UnixPeerIdentity(
              effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
              codeIdentity: CodeIdentity(
                teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test-\(subjectID)",
                codeDirectoryHash: codeHash, validationMode: .installedRequirement)),
            subject: LocalSubject(identifier: subjectID, userID: 501, codeIdentityHash: codeHash))))
    }
  }
}

private extension ControlPlaneJSONValue {
  func encoded() throws -> Data {
    try JSONEncoder().encode(self)
  }
}
