import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightPolicy
@testable import HostwrightState

final class AdmissionPolicyEngineTests: XCTestCase {
  private let createdAt = "2026-08-02T20:00:00Z"
  private let evaluationDate = ISO8601DateFormatter().date(from: "2026-08-02T20:30:00Z")!
  private let expiry = "2026-08-02T21:00:00Z"

  func testExactOperationApplicabilityAndDeterministicMutationOrder() throws {
    try withEngine { repository, engine in
      try install(
        policy(
          "builtin-a", source: .builtIn, stage: .builtInMutation,
          document: document(
            operations: ["service.update"],
            mutations: [write("/alpha", .integer(1))])),
        in: repository)
      try install(
        policy(
          "builtin-z", source: .builtIn, stage: .builtInMutation,
          document: document(
            operations: ["service.update"],
            mutations: [write("/zeta", .integer(2))])),
        in: repository)

      let update = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: .object([:])), at: evaluationDate)
      XCTAssertTrue(update.allowed)
      XCTAssertEqual(update.effectiveRequest.body, .object(["alpha": .integer(1), "zeta": .integer(2)]))
      XCTAssertEqual(
        update.decisions.filter { !$0.mutations.isEmpty }.map(\.policyIdentifier),
        ["builtin-a", "builtin-z"])

      let unrelated = try engine.evaluate(
        subjectID: "owner", request: request("service.delete", body: .object([:])), at: evaluationDate)
      XCTAssertTrue(unrelated.allowed)
      XCTAssertEqual(unrelated.effectiveRequest.body, .object([:]))
      XCTAssertTrue(unrelated.decisions.allSatisfy(\.mutations.isEmpty))
    }
  }

  func testConflictingMutationsDenyWithoutChoosingAWriter() throws {
    try withEngine { repository, engine in
      try install(
        policy(
          "extension-a", source: .extension, stage: .extensionMutation,
          document: document(
            operations: ["service.update"],
            mutations: [write("/mode", .string("safe"))])), in: repository)
      try install(
        policy(
          "extension-b", source: .extension, stage: .extensionMutation,
          document: document(
            operations: ["service.update"],
            mutations: [write("/mode", .string("unsafe"))])), in: repository)

      let evaluation = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: .object([:])), at: evaluationDate)
      XCTAssertFalse(evaluation.allowed)
      XCTAssertEqual(evaluation.reasonCode, "admission.mutation-conflict")
      XCTAssertEqual(evaluation.effectiveRequest.body, .object(["mode": .string("safe")]))
      XCTAssertEqual(evaluation.decisions.last?.policyIdentifier, "extension-b")
    }
  }

  func testBuiltInRequestBoundsFailClosedBeforePolicyExecution() throws {
    try withEngine { _, engine in
      var tooDeep: ControlPlaneJSONValue = .null
      for _ in 0...32 { tooDeep = .object(["nested": tooDeep]) }
      XCTAssertThrowsError(
        try engine.evaluate(
          subjectID: "owner", request: request("service.update", body: tooDeep), at: evaluationDate)
      ) { error in
        XCTAssertEqual(error as? AdmissionPolicyError, .invalidRequest)
      }
    }
  }

  func testDeclarativeValidationDeniesWithStableReasonCode() throws {
    try withEngine { repository, engine in
      try install(
        policy(
          "builtin-no-host-access", source: .builtIn, stage: .builtInValidation,
          document: document(
            operations: ["service.update"],
            validations: [validation("forbidden", "/hostAccess", "admission.host-access-forbidden")])),
        in: repository)

      let denied = try engine.evaluate(
        subjectID: "owner",
        request: request("service.update", body: .object(["hostAccess": .bool(true)])),
        at: evaluationDate)
      XCTAssertFalse(denied.allowed)
      XCTAssertEqual(denied.reasonCode, "admission.host-access-forbidden")
      XCTAssertEqual(denied.decisions.last?.stage, .builtInValidation)

      let allowed = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: .object([:])), at: evaluationDate)
      XCTAssertTrue(allowed.allowed)
    }
  }

  func testMalformedPolicyFailsClosedExceptFrozenAdvisoryIgnoreCase() throws {
    try withEngine { repository, engine in
      let malformed = ControlPlaneJSONValue.object(["not": .string("a-policy-document")])
      try install(
        policy(
          "extension-deny", source: .extension, stage: .extensionValidation,
          document: malformed), in: repository)

      let denied = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: .object([:])), at: evaluationDate)
      XCTAssertFalse(denied.allowed)
      XCTAssertEqual(denied.reasonCode, "admission.policy-failed")
      XCTAssertEqual(denied.decisions.last?.failurePolicy, .deny)

      _ = try repository.setPolicyEnabled(
        id: "extension-deny", enabled: false, expectedGeneration: 1,
        actorSubjectID: "owner", updatedAt: "2026-08-02T20:31:00Z")
      try install(
        policy(
          "extension-advisory", source: .extension, stage: .extensionValidation,
          failure: .ignore, advisory: true, document: malformed), in: repository)

      let ignored = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: .object([:])), at: evaluationDate)
      XCTAssertTrue(ignored.allowed)
      XCTAssertTrue(ignored.decisions.contains {
        $0.policyIdentifier == "extension-advisory"
          && $0.reasonCode == "admission.advisory-failure-ignored" && $0.allowed
      })
    }
  }

  func testExceptionRequiresExactPolicySubjectTargetPlanApprovalAndUnexpiredTime() throws {
    try withEngine { repository, engine in
      try install(
        policy(
          "extension-requires-label", source: .extension, stage: .extensionValidation,
          document: document(
            operations: ["service.update"],
            validations: [validation("required", "/approvedLabel", "admission.label-required")])),
        in: repository)
      let baselineBody: ControlPlaneJSONValue = .object(["projectUUID": .string("project-a")])
      let baseline = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: baselineBody), at: evaluationDate)
      XCTAssertFalse(baseline.allowed)

      let requestedBody: ControlPlaneJSONValue = .object([
        "projectUUID": .string("project-a"),
        "planHash": .string(baseline.planHash),
        "approvalIdentity": .string("security-approver"),
      ])
      let target = "operation:service.update|project:project-a|resource:-"
      try installException(
        policyID: "extension-requires-label", subjectID: "owner", target: target,
        planHash: baseline.planHash, approval: "security-approver", expires: expiry,
        into: repository)
      let approved = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: requestedBody), at: evaluationDate)
      XCTAssertTrue(approved.allowed)
      XCTAssertEqual(approved.exceptionIDs, ["exception-1"])
      XCTAssertEqual(approved.reasonCode, "admission.allowed")

      let wrongTarget = try engine.evaluate(
        subjectID: "owner",
        request: request(
          "service.update",
          body: .object([
            "projectUUID": .string("project-b"),
            "planHash": .string(baseline.planHash),
            "approvalIdentity": .string("security-approver"),
          ])), at: evaluationDate)
      XCTAssertFalse(wrongTarget.allowed)
      XCTAssertEqual(wrongTarget.reasonCode, "admission.label-required")

      let afterExpiry = ISO8601DateFormatter().date(from: "2026-08-02T21:00:01Z")!
      let expired = try engine.evaluate(
        subjectID: "owner", request: request("service.update", body: requestedBody), at: afterExpiry)
      XCTAssertFalse(expired.allowed)
      XCTAssertEqual(expired.reasonCode, "admission.label-required")
    }
  }

  func testPlanHashMismatchIsDeniedAndPlanAndDigestAreDeterministic() throws {
    try withEngine { repository, engine in
      try install(
        policy(
          "builtin-set-default", source: .builtIn, stage: .builtInMutation,
          document: document(
            operations: ["service.update"],
            mutations: [write("/network", .string("isolated"))])), in: repository)
      let firstRequest = request("service.update", body: .object(["projectUUID": .string("project-a")]))
      let first = try engine.evaluate(subjectID: "owner", request: firstRequest, at: evaluationDate)
      let repeatEvaluation = try engine.evaluate(subjectID: "owner", request: firstRequest, at: evaluationDate)
      XCTAssertTrue(first.allowed)
      XCTAssertEqual(first.planHash, repeatEvaluation.planHash)
      XCTAssertEqual(first.evaluationDigestSHA256, repeatEvaluation.evaluationDigestSHA256)

      let mismatch = try engine.evaluate(
        subjectID: "owner",
        request: request(
          "service.update",
          body: .object([
            "projectUUID": .string("project-a"),
            "planHash": .string(String(repeating: "f", count: 64)),
          ])), at: evaluationDate)
      XCTAssertFalse(mismatch.allowed)
      XCTAssertEqual(mismatch.reasonCode, "admission.plan-hash-mismatch")
    }
  }

  func testDryRunIsReportedAndDoesNotChangeTheComputedIntentPlan() throws {
    try withEngine { repository, engine in
      try install(
        policy(
          "builtin-set-default", source: .builtIn, stage: .builtInMutation,
          document: document(
            operations: ["service.update"],
            mutations: [write("/network", .string("isolated"))])), in: repository)
      let normal = try engine.evaluate(
        subjectID: "owner",
        request: request("service.update", body: .object(["projectUUID": .string("project-a")])),
        at: evaluationDate)
      let dryRun = try engine.evaluate(
        subjectID: "owner",
        request: request(
          "service.update",
          body: .object(["projectUUID": .string("project-a"), "dryRun": .bool(true)])),
        at: evaluationDate)
      XCTAssertTrue(dryRun.allowed)
      XCTAssertTrue(dryRun.dryRun)
      XCTAssertEqual(normal.planHash, dryRun.planHash)
      XCTAssertEqual(dryRun.effectiveRequest.body, .object([
        "projectUUID": .string("project-a"), "dryRun": .bool(true), "network": .string("isolated"),
      ]))
    }
  }

  func testPolicyDocumentsCannotMutateApprovalBindingFields() throws {
    for field in ["/planHash", "/approvalIdentity", "/dryRun"] {
      let record = try policy(
        "extension-reserved-\(field.dropFirst())", source: .extension,
        stage: .extensionMutation,
        document: document(
          operations: ["service.update"], mutations: [write(field, .string("spoofed"))]))
      XCTAssertThrowsError(try AdmissionPolicyEngine.validatePolicyDocument(record)) { error in
        XCTAssertEqual(error as? AdmissionPolicyError, .invalidDocument)
      }
    }
  }

  private func withEngine(
    _ body: (AdmissionRepository, AdmissionPolicyEngine) throws -> Void
  ) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner"))
    try body(store.admission, AdmissionPolicyEngine(repository: store.admission))
  }

  private func install(_ policy: AdmissionPolicyRecord, in repository: AdmissionRepository) throws {
    _ = try repository.createPolicy(policy)
  }

  private func installException(
    policyID: String, subjectID: String, target: String, planHash: String, approval: String,
    expires: String, into repository: AdmissionRepository
  ) throws {
    _ = try repository.createException(
      AdmissionExceptionRecord(
        exceptionID: "exception-1", policyID: policyID, subjectID: subjectID, target: target,
        planHash: planHash, approvalIdentity: approval, expiresAt: expires,
        createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt))
  }

  private func policy(
    _ id: String, source: AdmissionPolicySourceKind, stage: AdmissionStage,
    failure: AdmissionFailurePolicy = .deny, advisory: Bool = false,
    document: ControlPlaneJSONValue
  ) throws -> AdmissionPolicyRecord {
    try AdmissionPolicyRecord(
      policyID: id, version: 1, sourceKind: source, stage: stage, failurePolicy: failure,
      advisory: advisory, mutating: stage == .builtInMutation || stage == .extensionMutation,
      document: document, documentSHA256: AdmissionPolicyRecord.digest(document),
      createdBySubjectID: "owner", createdAt: createdAt, updatedAt: createdAt).canonicalized()
  }

  private func document(
    operations: [String], conditions: [ControlPlaneJSONValue] = [],
    mutations: [ControlPlaneJSONValue] = [], validations: [ControlPlaneJSONValue] = []
  ) -> ControlPlaneJSONValue {
    .object([
      "schemaVersion": .integer(1),
      "operations": .array(operations.map(ControlPlaneJSONValue.string)),
      "conditions": .array(conditions),
      "mutations": .array(mutations),
      "validations": .array(validations),
    ])
  }

  private func write(_ path: String, _ value: ControlPlaneJSONValue) -> ControlPlaneJSONValue {
    .object(["fieldPath": .string(path), "value": value])
  }

  private func validation(
    _ kind: String, _ path: String, _ reason: String, value: ControlPlaneJSONValue? = nil
  ) -> ControlPlaneJSONValue {
    var fields: [String: ControlPlaneJSONValue] = [
      "kind": .string(kind), "fieldPath": .string(path), "reasonCode": .string(reason),
    ]
    if let value { fields["value"] = value }
    return .object(fields)
  }

  private func request(_ operation: String, body: ControlPlaneJSONValue) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: "request-\(UUID().uuidString)", operation: operation,
      timeoutMilliseconds: 1_000, body: body)
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
      "hostwright-admission-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }
}
