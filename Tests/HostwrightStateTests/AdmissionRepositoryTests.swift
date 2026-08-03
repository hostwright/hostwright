import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightState

final class AdmissionRepositoryTests: XCTestCase {
  private let createdAt = "2026-08-02T20:00:00Z"
  private let updatedAt = "2026-08-02T20:01:00Z"
  private let expiry = "2026-08-02T21:00:00Z"

  func testPolicyCreationIsImmutableCanonicalAndDeterministicallyOrdered() throws {
    try withRepository { repository, _ in
      let extensionValidation = try policy(
        "extension-validate", source: .extension, stage: .extensionValidation)
      let builtinMutation = try policy(
        "builtin-mutate", source: .builtIn, stage: .builtInMutation)
      let extensionMutation = try policy(
        "extension-mutate", source: .extension, stage: .extensionMutation)

      XCTAssertEqual(try repository.createPolicy(extensionValidation), extensionValidation)
      XCTAssertEqual(try repository.createPolicy(builtinMutation), builtinMutation)
      XCTAssertEqual(try repository.createPolicy(extensionMutation), extensionMutation)
      XCTAssertEqual(
        try repository.listPolicies().map(\.policyID),
        ["builtin-mutate", "extension-mutate", "extension-validate"])
      XCTAssertEqual(try repository.listPolicies(enabledOnly: true).map(\.policyID),
                     ["builtin-mutate", "extension-mutate", "extension-validate"])
      XCTAssertThrowsError(try repository.createPolicy(extensionValidation))

      XCTAssertThrowsError(try repository.createPolicy(
        try policy("bad-digest", source: .extension, stage: .extensionValidation,
                   digest: String(repeating: "0", count: 64))))
      XCTAssertThrowsError(try repository.createPolicy(
        try policy("bad-ignore", source: .extension, stage: .extensionMutation,
                   failurePolicy: .ignore, advisory: true)))
      XCTAssertThrowsError(try repository.createPolicy(
        try policy("not-an-object", source: .extension, stage: .extensionValidation,
                   document: .array([]))))
    }
  }

  func testExtensionEnablementUsesGenerationAndBuiltinPoliciesCannotChange() throws {
    try withRepository { repository, _ in
      let extensionPolicy = try policy(
        "extension-policy", source: .extension, stage: .extensionValidation)
      let builtinPolicy = try policy(
        "builtin-policy", source: .builtIn, stage: .builtInValidation)
      _ = try repository.createPolicy(extensionPolicy)
      _ = try repository.createPolicy(builtinPolicy)

      let disabled = try repository.setPolicyEnabled(
        id: extensionPolicy.policyID, enabled: false, expectedGeneration: 1,
        actorSubjectID: "owner", updatedAt: updatedAt)
      XCTAssertFalse(disabled.enabled)
      XCTAssertEqual(disabled.generation, 2)
      XCTAssertEqual(try repository.listPolicies(enabledOnly: true).map(\.policyID), ["builtin-policy"])
      XCTAssertThrowsError(try repository.setPolicyEnabled(
        id: extensionPolicy.policyID, enabled: true, expectedGeneration: 1,
        actorSubjectID: "owner", updatedAt: updatedAt))
      XCTAssertThrowsError(try repository.setPolicyEnabled(
        id: builtinPolicy.policyID, enabled: false, expectedGeneration: 1,
        actorSubjectID: "owner", updatedAt: updatedAt))
    }
  }

  func testExceptionsBindPolicySubjectPlanAndExpiryAndProtectHistory() throws {
    try withRepository { repository, _ in
      let policy = try policy("extension-policy", source: .extension, stage: .extensionValidation)
      _ = try repository.createPolicy(policy)
      let exception = admissionException("exception-1", policyID: policy.policyID)

      XCTAssertEqual(try repository.createException(exception), exception)
      XCTAssertEqual(try repository.listExceptions(policyID: policy.policyID), [exception])
      XCTAssertEqual(try repository.listExceptions(subjectID: "owner", activeAt: updatedAt), [exception])
      XCTAssertEqual(try repository.listExceptions(subjectID: "owner", activeAt: expiry), [])
      XCTAssertThrowsError(try repository.createException(exception))
      XCTAssertThrowsError(try repository.deletePolicy(id: policy.policyID, expectedGeneration: 1))

      XCTAssertThrowsError(try repository.createException(
        admissionException("duplicate-binding", policyID: policy.policyID)))
      try repository.deleteException(id: exception.exceptionID, expectedGeneration: 1)
      XCTAssertNil(try repository.exception(id: exception.exceptionID))
      try repository.deletePolicy(id: policy.policyID, expectedGeneration: 1)
      XCTAssertNil(try repository.policy(id: policy.policyID))
    }
  }

  func testExceptionRejectsDisabledPolicyAndInvalidBinding() throws {
    try withRepository { repository, _ in
      let policy = try policy("extension-policy", source: .extension, stage: .extensionValidation)
      _ = try repository.createPolicy(policy)
      _ = try repository.setPolicyEnabled(
        id: policy.policyID, enabled: false, expectedGeneration: 1,
        actorSubjectID: "owner", updatedAt: updatedAt)
      XCTAssertThrowsError(try repository.createException(
        admissionException("disabled-policy", policyID: policy.policyID)))

      XCTAssertThrowsError(try repository.createException(
        AdmissionExceptionRecord(
          exceptionID: "invalid-plan", policyID: policy.policyID, subjectID: "owner",
          target: "project:one", planHash: "bad", approvalIdentity: "security-admin",
          expiresAt: expiry, createdBySubjectID: "owner", createdAt: createdAt,
          updatedAt: updatedAt)))
    }
  }

  func testStoredNoncanonicalOrMalformedPoliciesFailClosedAndIdentifiersAreNotSQL() throws {
    try withRepository { repository, store in
      let policy = try policy("extension-policy", source: .extension, stage: .extensionValidation)
      _ = try repository.createPolicy(policy)
      XCTAssertNil(try repository.policy(id: "extension-policy' OR 1=1 --"))
      XCTAssertEqual(try repository.listPolicies().map(\.policyID), [policy.policyID])

      let reorderedDocument: ControlPlaneJSONValue = .object([
        "a": .integer(2), "z": .integer(1),
      ])
      try store.withValidatedConnection { connection in
        try connection.run(
          "UPDATE admission_policies SET document_json = ?, document_sha256 = ? WHERE policy_id = ?",
          bindings: [
            .text("{\"z\":1,\"a\":2}"),
            .text(try AdmissionPolicyRecord.digest(reorderedDocument)), .text(policy.policyID),
          ])
      }
      XCTAssertThrowsError(try repository.listPolicies()) { error in
        guard case .invalidRecord = error as? StateStoreError else {
          return XCTFail("Expected stored noncanonical policy to fail closed, got \(error)")
        }
      }
      let integrity = StateIntegrityService(store: store).inspect()
      XCTAssertEqual(integrity.health, .unrecoverable)
      XCTAssertTrue(integrity.checks.contains {
        $0.identifier == "hostwright.authoritative-records" && $0.status == .failed
      })
    }
  }

  func testPoliciesAndExceptionsPersistAcrossReopen() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: path)
    try store.migrate()
    try bootstrapOwner(in: store)
    let repository = AdmissionRepository(store: store)
    let policy = try policy("extension-policy", source: .extension, stage: .extensionValidation)
    let exception = admissionException("exception-1", policyID: policy.policyID)
    _ = try repository.createPolicy(policy)
    _ = try repository.createException(exception)

    let reopened = AdmissionRepository(store: SQLiteStateStore(path: path))
    XCTAssertEqual(try reopened.policy(id: policy.policyID), policy)
    XCTAssertEqual(try reopened.exception(id: exception.exceptionID), exception)
  }

  private func withRepository(
    _ body: (AdmissionRepository, SQLiteStateStore) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try bootstrapOwner(in: store)
    try body(AdmissionRepository(store: store), store)
  }

  private func bootstrapOwner(in store: SQLiteStateStore) throws {
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "owner", userID: 501,
        codeIdentity: CodeIdentity(
          teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
          codeDirectoryHash: String(repeating: "a", count: 40),
          validationMode: .installedRequirement),
        declaredBySubjectID: "owner", declaredAt: createdAt, updatedAt: createdAt))
  }

  private func policy(
    _ id: String, source: AdmissionPolicySourceKind, stage: AdmissionStage,
    failurePolicy: AdmissionFailurePolicy = .deny, advisory: Bool = false,
    document: ControlPlaneJSONValue = .object(["kind": .string("test"), "version": .integer(1)]),
    digest: String? = nil
  ) throws -> AdmissionPolicyRecord {
    let mutating = stage == .builtInMutation || stage == .extensionMutation
    return AdmissionPolicyRecord(
      policyID: id, version: 1, sourceKind: source, stage: stage,
      failurePolicy: failurePolicy, advisory: advisory, mutating: mutating,
      document: document, documentSHA256: try digest ?? AdmissionPolicyRecord.digest(document),
      createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt)
  }

  private func admissionException(_ id: String, policyID: String) -> AdmissionExceptionRecord {
    AdmissionExceptionRecord(
      exceptionID: id, policyID: policyID, subjectID: "owner", target: "project:one",
      planHash: String(repeating: "b", count: 64), approvalIdentity: "security-admin",
      expiresAt: expiry, createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-admission-repository-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
