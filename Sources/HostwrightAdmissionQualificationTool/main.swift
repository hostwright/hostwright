import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightPolicy
import HostwrightState

private struct AdmissionQualificationResult: Encodable {
  let kind = "hostwright.phase09.admission.qualification.v1"
  let stateSchemaVersion: Int
  let integrityHealth: String
  let policyCount: Int
  let deterministicPlanHash: Bool
  let mutationApplied: Bool
  let conflictDenied: Bool
  let validationDenied: Bool
  let exceptionAllowed: Bool
  let expiredExceptionDenied: Bool
  let dryRunMarked: Bool
  let persistedAcrossReopen: Bool
}

@main
enum HostwrightAdmissionQualificationTool {
  static func main() throws {
    let root = try qualificationRoot()
    let statePath = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: statePath)
    try store.migrate()
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    try store.controlIdentities.bootstrap(identity(at: timestamp))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)

    _ = try store.admission.createPolicy(
      try policy(
        id: "qualification.mutate-isolation", stage: .extensionMutation,
        document: document(
          operations: ["service.update"],
          mutations: [["fieldPath": .string("/networkMode"), "value": .string("isolated")]])))
    _ = try store.admission.createPolicy(
      try policy(
        id: "qualification.validate-host-access", stage: .extensionValidation,
        document: document(
          operations: ["service.update"],
          validations: [[
            "kind": .string("equals"), "fieldPath": .string("/hostAccess"),
            "reasonCode": .string("admission.host-access-denied"), "value": .bool(false),
          ]])))

    let engine = AdmissionPolicyEngine(repository: store.admission)
    let safe = request(id: "safe", hostAccess: false)
    let first = try engine.evaluate(subjectID: "owner", request: safe, at: now)
    let repeated = try engine.evaluate(subjectID: "owner", request: safe, at: now)
    guard case .object(let effectiveFields)? = first.effectiveRequest.body else {
      throw AdmissionPolicyError.invalidRequest
    }
    let unsafe = try engine.evaluate(
      subjectID: "owner", request: request(id: "unsafe", hostAccess: true), at: now)

    let exception = AdmissionExceptionRecord(
      exceptionID: "qualification.exception", policyID: "qualification.validate-host-access",
      subjectID: "owner", target: unsafe.target, planHash: unsafe.planHash,
      approvalIdentity: "owner",
      expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(300)),
      createdBySubjectID: "owner", createdAt: timestamp, updatedAt: timestamp)
    _ = try store.admission.createException(exception)
    let approved = try engine.evaluate(
      subjectID: "owner",
      request: request(
        id: "approved", hostAccess: true, planHash: unsafe.planHash,
        approvalIdentity: "owner"),
      at: now.addingTimeInterval(1))
    let expired = try engine.evaluate(
      subjectID: "owner",
      request: request(
        id: "expired", hostAccess: true, planHash: unsafe.planHash,
        approvalIdentity: "owner"),
      at: now.addingTimeInterval(301))
    let dryRun = try engine.evaluate(
      subjectID: "owner", request: request(id: "dry", hostAccess: false, dryRun: true), at: now)

    _ = try store.admission.createPolicy(
      try policy(
        id: "qualification.mutate-conflict", stage: .extensionMutation,
        document: document(
          operations: ["service.update"],
          mutations: [["fieldPath": .string("/networkMode"), "value": .string("host")]])))
    let conflict = try engine.evaluate(subjectID: "owner", request: safe, at: now)
    let integrity = StateIntegrityService(store: store).inspect()
    let reopened = SQLiteStateStore(path: statePath)
    let persisted = try reopened.admission.listPolicies().count == 3
      && reopened.admission.listExceptions().count == 1

    let result = AdmissionQualificationResult(
      stateSchemaVersion: try store.schemaVersion(), integrityHealth: integrity.health.rawValue,
      policyCount: try store.admission.listPolicies().count,
      deterministicPlanHash: first.planHash == repeated.planHash,
      mutationApplied: effectiveFields["networkMode"] == .string("isolated"),
      conflictDenied: !conflict.allowed && conflict.reasonCode == "admission.mutation-conflict",
      validationDenied: !unsafe.allowed,
      exceptionAllowed: approved.allowed && approved.exceptionIDs == [exception.exceptionID],
      expiredExceptionDenied: !expired.allowed, dryRunMarked: dryRun.dryRun,
      persistedAcrossReopen: persisted)
    guard integrity.health == .healthy,
      result.stateSchemaVersion == HostwrightContractVersions.stateSchema,
      result.deterministicPlanHash, result.mutationApplied, result.conflictDenied,
      result.validationDenied, result.exceptionAllowed, result.expiredExceptionDenied,
      result.dryRunMarked, result.persistedAcrossReopen
    else {
      throw StateStoreError.transactionInvariantViolation(
        message: "Admission live qualification failed.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
  }

  private static func qualificationRoot() throws -> URL {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--root" else {
      throw StateStoreError.invalidRecord(
        "Usage: hostwright-admission-qualification --root PATH")
    }
    let root = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    guard root.path == arguments[2], values.isDirectory == true, values.isSymbolicLink != true,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
    else { throw StateStoreError.invalidRecord("Qualification root is unsafe.") }
    return root
  }

  private static func identity(at timestamp: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: "owner", userID: UInt32(geteuid()),
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q",
        signingIdentifier: "dev.hostwright.admission-qualification",
        codeDirectoryHash: String(repeating: "a", count: 40),
        validationMode: .installedRequirement),
      declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp)
  }

  private static func policy(
    id: String, stage: AdmissionStage, document: ControlPlaneJSONValue
  ) throws -> AdmissionPolicyRecord {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let record = AdmissionPolicyRecord(
      policyID: id, version: 1, sourceKind: .extension, stage: stage,
      failurePolicy: .deny, advisory: false, mutating: stage == .extensionMutation,
      document: document, documentSHA256: try AdmissionPolicyRecord.digest(document),
      createdBySubjectID: "owner", createdAt: timestamp, updatedAt: timestamp)
    try AdmissionPolicyEngine.validatePolicyDocument(record)
    return record
  }

  private static func document(
    operations: [String],
    mutations: [[String: ControlPlaneJSONValue]] = [],
    validations: [[String: ControlPlaneJSONValue]] = []
  ) -> ControlPlaneJSONValue {
    .object([
      "schemaVersion": .integer(1),
      "operations": .array(operations.map(ControlPlaneJSONValue.string)),
      "conditions": .array([]),
      "mutations": .array(mutations.map(ControlPlaneJSONValue.object)),
      "validations": .array(validations.map(ControlPlaneJSONValue.object)),
    ])
  }

  private static func request(
    id: String, hostAccess: Bool, planHash: String? = nil,
    approvalIdentity: String? = nil, dryRun: Bool = false
  ) -> ControlRequestEnvelope {
    var fields: [String: ControlPlaneJSONValue] = [
      "networkMode": .string("default"), "hostAccess": .bool(hostAccess),
    ]
    if let planHash { fields["planHash"] = .string(planHash) }
    if let approvalIdentity { fields["approvalIdentity"] = .string(approvalIdentity) }
    if dryRun { fields["dryRun"] = .bool(true) }
    return ControlRequestEnvelope(
      requestID: id, operation: "service.update", timeoutMilliseconds: 1_000,
      idempotencyKey: "key-\(id)", body: .object(fields))
  }
}
