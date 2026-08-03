import CryptoKit
import Foundation
import HostwrightControlPlane
import HostwrightState

public enum AdmissionPolicyError: Error, Equatable, Sendable {
  case invalidDocument
  case invalidRequest
  case mutationConflict
  case policyDenied
}

public struct AdmissionPipelineEvaluation: Codable, Equatable, Sendable {
  public let effectiveRequest: ControlRequestEnvelope
  public let decisions: [AdmissionDecision]
  public let target: String
  public let planHash: String
  public let approvalIdentity: String?
  public let exceptionIDs: [String]
  public let allowed: Bool
  public let reasonCode: String
  public let evaluationDigestSHA256: String
  public let dryRun: Bool

  public init(
    effectiveRequest: ControlRequestEnvelope, decisions: [AdmissionDecision], target: String,
    planHash: String, approvalIdentity: String?, exceptionIDs: [String], allowed: Bool,
    reasonCode: String, evaluationDigestSHA256: String, dryRun: Bool
  ) {
    self.effectiveRequest = effectiveRequest
    self.decisions = decisions
    self.target = target
    self.planHash = planHash
    self.approvalIdentity = approvalIdentity
    self.exceptionIDs = exceptionIDs
    self.allowed = allowed
    self.reasonCode = reasonCode
    self.evaluationDigestSHA256 = evaluationDigestSHA256
    self.dryRun = dryRun
  }
}

public struct AdmissionPolicyEngine: Sendable {
  private let repository: AdmissionRepository

  public init(repository: AdmissionRepository) {
    self.repository = repository
  }

  public static func validatePolicyDocument(_ policy: AdmissionPolicyRecord) throws {
    _ = try policy.canonicalized()
    _ = try Document(policy: policy)
  }

  public func evaluate(
    subjectID: String, request: ControlRequestEnvelope, at: Date
  ) throws -> AdmissionPipelineEvaluation {
    guard Self.safeIdentifier(subjectID), Self.safeIdentifier(request.operation) else {
      throw AdmissionPolicyError.invalidRequest
    }
    try request.validate()
    let originalBody = request.body ?? .object([:])
    try Self.validateJSONBounds(originalBody)
    var effectiveBody = originalBody
    var decisions: [AdmissionDecision] = []
    var writes: [String: (ControlPlaneJSONValue, String)] = [:]
    let policies = try repository.listPolicies(enabledOnly: true)
    let parsed = policies.map { policy in (policy, Result { try Document(policy: policy) }) }

    for (policy, documentResult) in parsed where policy.stage == .builtInMutation {
      guard try execute(
        policy: policy, documentResult: documentResult, operation: request.operation,
        body: &effectiveBody,
        writes: &writes, decisions: &decisions)
      else {
        return try denied(
          subjectID: subjectID, request, body: effectiveBody, decisions: decisions, at: at)
      }
    }
    for (policy, documentResult) in parsed where policy.stage == .extensionMutation {
      guard try execute(
        policy: policy, documentResult: documentResult, operation: request.operation,
        body: &effectiveBody,
        writes: &writes, decisions: &decisions)
      else {
        return try denied(
          subjectID: subjectID, request, body: effectiveBody, decisions: decisions, at: at)
      }
    }

    do {
      try Self.validateJSONBounds(effectiveBody)
    } catch {
      decisions.append(
        AdmissionDecision(
          policyIdentifier: "hostwright.builtin.request-safety@1",
          stage: .builtInValidation, allowed: false, failurePolicy: .deny,
          reasonCode: "admission.request-bounds", advisory: false))
      return try denied(
        subjectID: subjectID, request, body: effectiveBody, decisions: decisions, at: at)
    }
    decisions.append(
      AdmissionDecision(
        policyIdentifier: "hostwright.builtin.request-safety@1",
        stage: .builtInValidation, allowed: true, failurePolicy: .deny,
        reasonCode: "admission.request-bounds-valid", advisory: false))

    let provisional = try makeEvaluationContext(
      subjectID: subjectID, request: request, effectiveBody: effectiveBody,
      policies: policies, decisions: decisions)
    var exceptionIDs: [String] = []
    for (policy, documentResult) in parsed where policy.stage == .builtInValidation {
      let result = try validate(
        policy: policy, documentResult: documentResult, operation: request.operation,
        body: effectiveBody)
      let resolution = try resolve(
        result, policy: policy, context: provisional, subjectID: subjectID, at: at)
      decisions.append(resolution.decision)
      exceptionIDs += resolution.exceptionIDs
      if !resolution.decision.allowed {
        return try denied(
          subjectID: subjectID, request, body: effectiveBody, decisions: decisions, at: at,
          context: provisional, exceptionIDs: exceptionIDs)
      }
    }
    for (policy, documentResult) in parsed where policy.stage == .extensionValidation {
      let result = try validate(
        policy: policy, documentResult: documentResult, operation: request.operation,
        body: effectiveBody)
      let resolution = try resolve(
        result, policy: policy, context: provisional, subjectID: subjectID, at: at)
      decisions.append(resolution.decision)
      exceptionIDs += resolution.exceptionIDs
      if !resolution.decision.allowed {
        return try denied(
          subjectID: subjectID, request, body: effectiveBody, decisions: decisions, at: at,
          context: provisional, exceptionIDs: exceptionIDs)
      }
    }

    let context = try makeEvaluationContext(
      subjectID: subjectID, request: request, effectiveBody: effectiveBody,
      policies: policies, decisions: decisions)
    if let supplied = context.suppliedPlanHash, supplied != context.planHash {
      decisions.append(
        AdmissionDecision(
          policyIdentifier: "hostwright.builtin.plan-binding@1",
          stage: .bindApproval, allowed: false, failurePolicy: .deny,
          reasonCode: "admission.plan-hash-mismatch", advisory: false))
      return try denied(
        subjectID: subjectID, request, body: effectiveBody, decisions: decisions, at: at,
        context: context, exceptionIDs: exceptionIDs)
    }
    decisions.append(
      AdmissionDecision(
        policyIdentifier: "hostwright.builtin.plan-binding@1",
        stage: .bindApproval, allowed: true, failurePolicy: .deny,
        reasonCode: context.suppliedPlanHash == nil
          ? "admission.plan-hash-computed" : "admission.plan-hash-bound",
        advisory: false))
    let effectiveRequest = Self.request(request, body: effectiveBody)
    let digest = try Self.evaluationDigest(
      request: effectiveRequest, decisions: decisions, planHash: context.planHash,
      exceptionIDs: exceptionIDs)
    return AdmissionPipelineEvaluation(
      effectiveRequest: effectiveRequest, decisions: decisions,
      target: context.target, planHash: context.planHash,
      approvalIdentity: context.approvalIdentity,
      exceptionIDs: Array(Set(exceptionIDs)).sorted(), allowed: true,
      reasonCode: "admission.allowed", evaluationDigestSHA256: digest,
      dryRun: context.dryRun)
  }

  private func execute(
    policy: AdmissionPolicyRecord, documentResult: Result<Document, Error>,
    operation: String,
    body: inout ControlPlaneJSONValue,
    writes: inout [String: (ControlPlaneJSONValue, String)],
    decisions: inout [AdmissionDecision]
  ) throws -> Bool {
    let document: Document
    do { document = try documentResult.get() } catch {
      let ignored = policy.failurePolicy == .ignore && policy.advisory && !policy.mutating
      decisions.append(Self.failureDecision(policy, ignored: ignored))
      return ignored
    }
    guard document.operations.contains(operation) else { return true }
    guard try document.conditions.allSatisfy({ try $0.matches(body) }) else { return true }
    var mutations: [AdmissionMutation] = []
    do {
      for write in document.mutations {
        if let prior = writes[write.path], prior.0 != write.value {
          decisions.append(
            AdmissionDecision(
              policyIdentifier: policy.policyID, stage: .conflictDetection,
              allowed: false, failurePolicy: .deny,
              reasonCode: "admission.mutation-conflict", advisory: false))
          return false
        }
        try Self.write(write.value, at: write.path, in: &body)
        writes[write.path] = (write.value, policy.policyID)
        mutations.append(
          AdmissionMutation(
            policyIdentifier: policy.policyID, stage: policy.stage,
            fieldPath: write.path, value: write.value))
      }
      decisions.append(
        AdmissionDecision(
          policyIdentifier: policy.policyID, stage: policy.stage, allowed: true,
          failurePolicy: policy.failurePolicy, reasonCode: "admission.mutated",
          mutations: mutations, advisory: policy.advisory))
      return true
    } catch {
      decisions.append(Self.failureDecision(policy, ignored: false))
      return false
    }
  }

  private func validate(
    policy: AdmissionPolicyRecord, documentResult: Result<Document, Error>,
    operation: String,
    body: ControlPlaneJSONValue
  ) throws -> AdmissionDecision {
    let document: Document
    do { document = try documentResult.get() } catch {
      let ignored = policy.failurePolicy == .ignore && policy.advisory && !policy.mutating
      return Self.failureDecision(policy, ignored: ignored)
    }
    guard document.operations.contains(operation) else {
      return AdmissionDecision(
        policyIdentifier: policy.policyID, stage: policy.stage, allowed: true,
        failurePolicy: policy.failurePolicy, reasonCode: "admission.not-applicable",
        advisory: policy.advisory)
    }
    guard try document.conditions.allSatisfy({ try $0.matches(body) }) else {
      return AdmissionDecision(
        policyIdentifier: policy.policyID, stage: policy.stage, allowed: true,
        failurePolicy: policy.failurePolicy, reasonCode: "admission.condition-not-matched",
        advisory: policy.advisory)
    }
    for validation in document.validations where !(try validation.allows(body)) {
      return AdmissionDecision(
        policyIdentifier: policy.policyID, stage: policy.stage, allowed: false,
        failurePolicy: policy.failurePolicy, reasonCode: validation.reasonCode,
        advisory: policy.advisory)
    }
    return AdmissionDecision(
      policyIdentifier: policy.policyID, stage: policy.stage, allowed: true,
      failurePolicy: policy.failurePolicy, reasonCode: "admission.validated",
      advisory: policy.advisory)
  }

  private func resolve(
    _ decision: AdmissionDecision, policy: AdmissionPolicyRecord,
    context: EvaluationContext, subjectID: String, at: Date
  ) throws -> (decision: AdmissionDecision, exceptionIDs: [String]) {
    guard !decision.allowed else { return (decision, []) }
    guard let suppliedPlanHash = context.suppliedPlanHash,
      suppliedPlanHash == context.planHash,
      let approval = context.approvalIdentity
    else { return (decision, []) }
    let timestamp = ISO8601DateFormatter().string(from: at)
    let matches = try repository.listExceptions(
      policyID: policy.policyID, subjectID: subjectID, activeAt: timestamp
    ).filter {
      $0.target == context.target && $0.planHash == suppliedPlanHash
        && $0.approvalIdentity == approval
    }
    guard matches.count == 1, let exception = matches.first else { return (decision, []) }
    return (
      AdmissionDecision(
        policyIdentifier: policy.policyID, stage: policy.stage, allowed: true,
        failurePolicy: policy.failurePolicy,
        reasonCode: "admission.exception-approved", advisory: policy.advisory),
      [exception.exceptionID]
    )
  }

  private func denied(
    subjectID: String, _ request: ControlRequestEnvelope, body: ControlPlaneJSONValue,
    decisions: [AdmissionDecision], at: Date,
    context: EvaluationContext? = nil, exceptionIDs: [String] = []
  ) throws -> AdmissionPipelineEvaluation {
    let fallback: EvaluationContext
    if let context {
      fallback = context
    } else {
      fallback = try makeEvaluationContext(
        subjectID: subjectID, request: request, effectiveBody: body,
        policies: repository.listPolicies(enabledOnly: true), decisions: decisions)
    }
    let effective = Self.request(request, body: body)
    return AdmissionPipelineEvaluation(
      effectiveRequest: effective, decisions: decisions, target: fallback.target,
      planHash: fallback.planHash, approvalIdentity: fallback.approvalIdentity,
      exceptionIDs: exceptionIDs.sorted(), allowed: false,
      reasonCode: decisions.last?.reasonCode ?? "admission.denied",
      evaluationDigestSHA256: try Self.evaluationDigest(
        request: effective, decisions: decisions, planHash: fallback.planHash,
        exceptionIDs: exceptionIDs), dryRun: fallback.dryRun)
  }

  private struct EvaluationContext {
    let target: String
    let planHash: String
    let suppliedPlanHash: String?
    let approvalIdentity: String?
    let dryRun: Bool
  }

  private func makeEvaluationContext(
    subjectID: String, request: ControlRequestEnvelope,
    effectiveBody: ControlPlaneJSONValue, policies: [AdmissionPolicyRecord],
    decisions: [AdmissionDecision]
  ) throws -> EvaluationContext {
    let fields = Self.object(effectiveBody)
    let supplied = try Self.optionalBoundString("planHash", fields: fields, digest: true)
    let approval = try Self.optionalBoundString("approvalIdentity", fields: fields)
    let dryRun: Bool
    if let value = fields["dryRun"] {
      guard case .bool(let flag) = value else { throw AdmissionPolicyError.invalidRequest }
      dryRun = flag
    } else { dryRun = false }
    let target = try Self.target(operation: request.operation, fields: fields)
    var intentFields = fields
    intentFields.removeValue(forKey: "planHash")
    intentFields.removeValue(forKey: "approvalIdentity")
    intentFields.removeValue(forKey: "dryRun")
    let policyBindings = policies.map {
      PolicyBinding(
        policyID: $0.policyID, version: $0.version, stage: $0.stage,
        documentSHA256: $0.documentSHA256)
    }
    let input = PlanInput(
      subjectID: subjectID, operation: request.operation,
      effectiveIntent: .object(intentFields), policies: policyBindings,
      mutations: decisions.flatMap(\.mutations))
    let data = try ControlPlaneCanonicalJSON.encode(input)
    let planHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return EvaluationContext(
      target: target, planHash: planHash, suppliedPlanHash: supplied,
      approvalIdentity: approval, dryRun: dryRun)
  }

  private struct PolicyBinding: Codable {
    let policyID: String
    let version: Int
    let stage: AdmissionStage
    let documentSHA256: String
  }
  private struct PlanInput: Codable {
    let subjectID: String
    let operation: String
    let effectiveIntent: ControlPlaneJSONValue
    let policies: [PolicyBinding]
    let mutations: [AdmissionMutation]
  }
  private struct DigestInput: Codable {
    let request: ControlRequestEnvelope
    let decisions: [AdmissionDecision]
    let planHash: String
    let exceptionIDs: [String]
  }

  private static func evaluationDigest(
    request: ControlRequestEnvelope, decisions: [AdmissionDecision],
    planHash: String, exceptionIDs: [String]
  ) throws -> String {
    let data = try ControlPlaneCanonicalJSON.encode(
      DigestInput(
        request: request, decisions: decisions, planHash: planHash,
        exceptionIDs: Array(Set(exceptionIDs)).sorted()))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func failureDecision(
    _ policy: AdmissionPolicyRecord, ignored: Bool
  ) -> AdmissionDecision {
    AdmissionDecision(
      policyIdentifier: policy.policyID, stage: policy.stage, allowed: ignored,
      failurePolicy: policy.failurePolicy,
      reasonCode: ignored ? "admission.advisory-failure-ignored" : "admission.policy-failed",
      advisory: policy.advisory)
  }

  private static func request(
    _ request: ControlRequestEnvelope, body: ControlPlaneJSONValue
  ) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      apiVersion: request.apiVersion, protocolRevision: request.protocolRevision,
      requestID: request.requestID, operation: request.operation,
      timeoutMilliseconds: request.timeoutMilliseconds,
      idempotencyKey: request.idempotencyKey, body: body)
  }

  private static func object(_ value: ControlPlaneJSONValue) -> [String: ControlPlaneJSONValue] {
    if case .object(let fields) = value { return fields }
    return ["value": value]
  }

  private static func optionalBoundString(
    _ key: String, fields: [String: ControlPlaneJSONValue], digest: Bool = false
  ) throws -> String? {
    guard let value = fields[key] else { return nil }
    guard case .string(let string) = value,
      digest
        ? string.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        : safeIdentifier(string)
    else { throw AdmissionPolicyError.invalidRequest }
    return string
  }

  private static func target(
    operation: String, fields: [String: ControlPlaneJSONValue]
  ) throws -> String {
    let project = try oneString(fields, keys: ["projectUUID", "projectID", "project"])
    let resource = try oneString(
      fields, keys: ["resourceUUID", "resourceID", "serviceUUID", "service", "identifier"])
    return "operation:\(operation)|project:\(project ?? "-")|resource:\(resource ?? "-")"
  }

  private static func oneString(
    _ fields: [String: ControlPlaneJSONValue], keys: [String]
  ) throws -> String? {
    var found = Set<String>()
    for key in keys where fields[key] != nil {
      guard case .string(let value)? = fields[key], safeIdentifier(value) else {
        throw AdmissionPolicyError.invalidRequest
      }
      found.insert(value)
    }
    guard found.count <= 1 else { throw AdmissionPolicyError.invalidRequest }
    return found.first
  }

  private static func safeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) })
  }

  private static func validateJSONBounds(_ value: ControlPlaneJSONValue) throws {
    var nodes = 0
    func visit(_ value: ControlPlaneJSONValue, depth: Int) throws {
      guard depth <= 32 else { throw AdmissionPolicyError.invalidRequest }
      nodes += 1
      guard nodes <= 8_192 else { throw AdmissionPolicyError.invalidRequest }
      switch value {
      case .number(let number):
        guard number.isFinite else { throw AdmissionPolicyError.invalidRequest }
      case .string(let string):
        guard string.utf8.count <= 1_048_576 else { throw AdmissionPolicyError.invalidRequest }
      case .array(let values):
        guard values.count <= 4_096 else { throw AdmissionPolicyError.invalidRequest }
        try values.forEach { try visit($0, depth: depth + 1) }
      case .object(let fields):
        guard fields.count <= 4_096,
          fields.keys.allSatisfy({ safeIdentifier($0) })
        else { throw AdmissionPolicyError.invalidRequest }
        for key in fields.keys.sorted() { try visit(fields[key]!, depth: depth + 1) }
      case .null, .bool, .integer: break
      }
    }
    try visit(value, depth: 0)
    guard try ControlPlaneCanonicalJSON.encode(value).count <= ControlPlaneContract.maximumRequestBytes
    else { throw AdmissionPolicyError.invalidRequest }
  }

  private static func read(
    _ path: String, from value: ControlPlaneJSONValue
  ) throws -> ControlPlaneJSONValue? {
    var current = value
    for component in try components(path) {
      guard case .object(let fields) = current, let next = fields[component] else { return nil }
      current = next
    }
    return current
  }

  private static func write(
    _ newValue: ControlPlaneJSONValue, at path: String, in value: inout ControlPlaneJSONValue
  ) throws {
    let parts = try components(path)
    guard !parts.isEmpty else { throw AdmissionPolicyError.invalidDocument }
    func setting(
      _ current: ControlPlaneJSONValue, index: Int
    ) throws -> ControlPlaneJSONValue {
      guard case .object(var fields) = current else {
        throw AdmissionPolicyError.invalidRequest
      }
      let key = parts[index]
      if index == parts.count - 1 {
        fields[key] = newValue
      } else {
        guard let child = fields[key] else { throw AdmissionPolicyError.invalidRequest }
        fields[key] = try setting(child, index: index + 1)
      }
      return .object(fields)
    }
    value = try setting(value, index: 0)
  }

  private static func components(_ path: String) throws -> [String] {
    guard path.hasPrefix("/"), path.utf8.count <= 512, !path.contains("~") else {
      throw AdmissionPolicyError.invalidDocument
    }
    let values = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !values.isEmpty, values.allSatisfy({ safeIdentifier($0) }) else {
      throw AdmissionPolicyError.invalidDocument
    }
    return values
  }
}

private extension AdmissionPolicyEngine {
  struct Document {
    let operations: [String]
    let conditions: [Condition]
    let mutations: [Write]
    let validations: [Validation]

    init(policy: AdmissionPolicyRecord) throws {
      guard case .object(let fields) = policy.document,
        Set(fields.keys) == ["schemaVersion", "operations", "conditions", "mutations", "validations"],
        case .integer(1)? = fields["schemaVersion"],
        case .array(let operationValues)? = fields["operations"],
        case .array(let conditionValues)? = fields["conditions"],
        case .array(let mutationValues)? = fields["mutations"],
        case .array(let validationValues)? = fields["validations"]
      else { throw AdmissionPolicyError.invalidDocument }
      operations = try operationValues.map {
        guard case .string(let value) = $0,
          value.range(
            of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil
        else { throw AdmissionPolicyError.invalidDocument }
        return value
      }
      guard !operations.isEmpty, operations.count <= 128,
        Set(operations).count == operations.count, operations == operations.sorted()
      else { throw AdmissionPolicyError.invalidDocument }
      conditions = try conditionValues.map(Condition.init)
      mutations = try mutationValues.map(Write.init)
      validations = try validationValues.map(Validation.init)
      guard conditions.count <= 64, mutations.count <= 64, validations.count <= 64 else {
        throw AdmissionPolicyError.invalidDocument
      }
      if policy.mutating {
        guard !mutations.isEmpty, validations.isEmpty else {
          throw AdmissionPolicyError.invalidDocument
        }
      } else {
        guard mutations.isEmpty, !validations.isEmpty else {
          throw AdmissionPolicyError.invalidDocument
        }
      }
    }
  }

  struct Condition {
    enum Kind: String { case exists, equals }
    let kind: Kind
    let path: String
    let value: ControlPlaneJSONValue?
    init(_ input: ControlPlaneJSONValue) throws {
      guard case .object(let fields) = input,
        let kindValue = fields["kind"], case .string(let rawKind) = kindValue,
        let kind = Kind(rawValue: rawKind),
        let pathValue = fields["fieldPath"], case .string(let path) = pathValue
      else { throw AdmissionPolicyError.invalidDocument }
      let expected: Set<String> = kind == .exists ? ["kind", "fieldPath"] : ["kind", "fieldPath", "value"]
      guard Set(fields.keys) == expected else { throw AdmissionPolicyError.invalidDocument }
      _ = try AdmissionPolicyEngine.components(path)
      self.kind = kind; self.path = path; value = fields["value"]
    }
    func matches(_ body: ControlPlaneJSONValue) throws -> Bool {
      let actual = try AdmissionPolicyEngine.read(path, from: body)
      switch kind { case .exists: return actual != nil; case .equals: return actual == value }
    }
  }

  struct Write {
    let path: String
    let value: ControlPlaneJSONValue
    init(_ input: ControlPlaneJSONValue) throws {
      guard case .object(let fields) = input,
        Set(fields.keys) == ["fieldPath", "value"],
        case .string(let path)? = fields["fieldPath"], let value = fields["value"]
      else { throw AdmissionPolicyError.invalidDocument }
      _ = try AdmissionPolicyEngine.components(path)
      guard !["/planHash", "/approvalIdentity", "/dryRun"].contains(path) else {
        throw AdmissionPolicyError.invalidDocument
      }
      self.path = path; self.value = value
    }
  }

  struct Validation {
    enum Kind: String { case required, forbidden, equals }
    let kind: Kind
    let path: String
    let value: ControlPlaneJSONValue?
    let reasonCode: String
    init(_ input: ControlPlaneJSONValue) throws {
      guard case .object(let fields) = input,
        let kindValue = fields["kind"], case .string(let rawKind) = kindValue,
        let kind = Kind(rawValue: rawKind),
        case .string(let path)? = fields["fieldPath"],
        case .string(let reason)? = fields["reasonCode"],
        AdmissionPolicyEngine.safeIdentifier(reason)
      else { throw AdmissionPolicyError.invalidDocument }
      let expected: Set<String> = kind == .equals
        ? ["kind", "fieldPath", "reasonCode", "value"]
        : ["kind", "fieldPath", "reasonCode"]
      guard Set(fields.keys) == expected else { throw AdmissionPolicyError.invalidDocument }
      _ = try AdmissionPolicyEngine.components(path)
      self.kind = kind; self.path = path; value = fields["value"]; reasonCode = reason
    }
    func allows(_ body: ControlPlaneJSONValue) throws -> Bool {
      let actual = try AdmissionPolicyEngine.read(path, from: body)
      switch kind {
      case .required: return actual != nil
      case .forbidden: return actual == nil
      case .equals: return actual == value
      }
    }
  }
}
