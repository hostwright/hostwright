import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightPolicy
import HostwrightState

enum AdmissionControlOperations {
  static func handle(
    peer: AuthenticatedControlPeer,
    request: ControlRequestEnvelope,
    repository: AdmissionRepository,
    administration: AdmissionAdministrationService,
    engine: AdmissionPolicyEngine,
    now: Date
  ) -> ControlResponseEnvelope? {
    guard request.operation.hasPrefix("admission.") else { return nil }
    do {
      let fields = try bodyFields(request.body)
      let timestamp = ISO8601DateFormatter().string(from: now)
      let subjectID = peer.binding.subject.identifier
      let result: ControlPlaneJSONValue
      switch request.operation {
      case "admission.preview":
        try requireExactKeys(fields, allowed: ["request", "subjectID"])
        let previewRequest: ControlRequestEnvelope = try decodeField("request", from: fields)
        let targetSubject = try optionalString("subjectID", from: fields) ?? subjectID
        result = try value(
          engine.evaluate(subjectID: targetSubject, request: previewRequest, at: now))
      case "admission.policy.list":
        try requireExactKeys(fields, allowed: ["enabledOnly"])
        result = try value(
          repository.listPolicies(enabledOnly: try optionalBool("enabledOnly", from: fields) ?? false))
      case "admission.policy.create":
        try requireExactKeys(
          fields,
          allowed: [
            "identifier", "version", "stage", "failurePolicy", "advisory", "document",
          ])
        let stage: AdmissionStage = try enumField("stage", from: fields)
        let failurePolicy: AdmissionFailurePolicy = try enumField(
          "failurePolicy", from: fields)
        let document = try requiredField("document", from: fields)
        let policy = AdmissionPolicyRecord(
          policyID: try requiredString("identifier", from: fields),
          version: try positiveInt("version", from: fields), sourceKind: .extension,
          stage: stage, failurePolicy: failurePolicy,
          advisory: try requiredBool("advisory", from: fields),
          mutating: stage == .extensionMutation, document: document,
          documentSHA256: try AdmissionPolicyRecord.digest(document),
          createdBySubjectID: subjectID, createdAt: timestamp, updatedAt: timestamp)
        try AdmissionPolicyEngine.validatePolicyDocument(policy)
        result = try value(
          administration.createPolicy(policy, actorSubjectID: subjectID, at: now))
      case "admission.policy.set-enabled":
        try requireExactKeys(
          fields, allowed: ["identifier", "enabled", "expectedGeneration"])
        result = try value(
          administration.setPolicyEnabled(
            id: try requiredString("identifier", from: fields),
            enabled: try requiredBool("enabled", from: fields),
            expectedGeneration: try positiveInt("expectedGeneration", from: fields),
            actorSubjectID: subjectID, updatedAt: timestamp, at: now))
      case "admission.policy.delete":
        try requireExactKeys(fields, allowed: ["identifier", "expectedGeneration"])
        try administration.deletePolicy(
          id: try requiredString("identifier", from: fields),
          expectedGeneration: try positiveInt("expectedGeneration", from: fields),
          actorSubjectID: subjectID, at: now)
        result = .object(["deleted": .bool(true)])
      case "admission.exception.list":
        try requireExactKeys(fields, allowed: ["policyID", "subjectID", "activeAt"])
        result = try value(
          repository.listExceptions(
            policyID: try optionalString("policyID", from: fields),
            subjectID: try optionalString("subjectID", from: fields),
            activeAt: try optionalString("activeAt", from: fields)))
      case "admission.exception.create":
        try requireExactKeys(
          fields,
          allowed: [
            "identifier", "policyID", "subjectID", "target", "planHash",
            "approvalIdentity", "expiresAt",
          ])
        let exception = AdmissionExceptionRecord(
          exceptionID: try requiredString("identifier", from: fields),
          policyID: try requiredString("policyID", from: fields),
          subjectID: try requiredString("subjectID", from: fields),
          target: try requiredString("target", from: fields, maximumBytes: 512),
          planHash: try digestString("planHash", from: fields),
          approvalIdentity: try requiredString("approvalIdentity", from: fields),
          expiresAt: try requiredString("expiresAt", from: fields),
          createdBySubjectID: subjectID, createdAt: timestamp, updatedAt: timestamp)
        result = try value(
          administration.createException(exception, actorSubjectID: subjectID, at: now))
      case "admission.exception.delete":
        try requireExactKeys(fields, allowed: ["identifier", "expectedGeneration"])
        try administration.deleteException(
          id: try requiredString("identifier", from: fields),
          expectedGeneration: try positiveInt("expectedGeneration", from: fields),
          actorSubjectID: subjectID, at: now)
        result = .object(["deleted": .bool(true)])
      default:
        return failure(
          requestID: request.requestID, reason: .invalidRequest,
          code: "unsupportedAdmissionOperation",
          message: "The admission operation is not supported.")
      }
      return ControlResponseEnvelope(
        requestID: request.requestID, status: .completed, reasonCode: .completed,
        result: result)
    } catch RBACAuthorizationError.delegationExceedsAuthority {
      return failure(
        requestID: request.requestID, reason: .unauthorized,
        code: "admissionManagementDenied",
        message: "The subject is not authorized to manage admission policy.")
    } catch {
      return failure(
        requestID: request.requestID, reason: .invalidRequest,
        code: "invalidAdmissionRequest",
        message: "The admission request is invalid or conflicts with current policy state.")
    }
  }

  private static func bodyFields(
    _ body: ControlPlaneJSONValue?
  ) throws -> [String: ControlPlaneJSONValue] {
    if body == nil { return [:] }
    guard case .object(let fields) = body else { throw AdmissionPolicyError.invalidRequest }
    return fields
  }

  private static func requireExactKeys(
    _ fields: [String: ControlPlaneJSONValue], allowed: Set<String>
  ) throws {
    guard Set(fields.keys).isSubset(of: allowed) else {
      throw AdmissionPolicyError.invalidRequest
    }
  }

  private static func requiredField(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> ControlPlaneJSONValue {
    guard let value = fields[name] else { throw AdmissionPolicyError.invalidRequest }
    return value
  }

  private static func decodeField<T: Decodable>(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> T {
    try JSONDecoder().decode(
      T.self, from: ControlPlaneCanonicalJSON.encode(try requiredField(name, from: fields)))
  }

  private static func enumField<T: RawRepresentable>(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> T where T.RawValue == String {
    guard let raw = try optionalString(name, from: fields), let value = T(rawValue: raw) else {
      throw AdmissionPolicyError.invalidRequest
    }
    return value
  }

  private static func optionalString(
    _ name: String, from fields: [String: ControlPlaneJSONValue], maximumBytes: Int = 128
  ) throws -> String? {
    guard let field = fields[name] else { return nil }
    guard case .string(let value) = field, !value.isEmpty,
      value.utf8.count <= maximumBytes,
      value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) })
    else { throw AdmissionPolicyError.invalidRequest }
    return value
  }

  private static func requiredString(
    _ name: String, from fields: [String: ControlPlaneJSONValue], maximumBytes: Int = 128
  ) throws -> String {
    guard let value = try optionalString(name, from: fields, maximumBytes: maximumBytes) else {
      throw AdmissionPolicyError.invalidRequest
    }
    return value
  }

  private static func digestString(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> String {
    let value = try requiredString(name, from: fields)
    guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw AdmissionPolicyError.invalidRequest
    }
    return value
  }

  private static func optionalBool(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> Bool? {
    guard let field = fields[name] else { return nil }
    guard case .bool(let value) = field else { throw AdmissionPolicyError.invalidRequest }
    return value
  }

  private static func requiredBool(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> Bool {
    guard let value = try optionalBool(name, from: fields) else {
      throw AdmissionPolicyError.invalidRequest
    }
    return value
  }

  private static func positiveInt(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> Int {
    guard case .integer(let raw)? = fields[name], raw >= 1, raw <= Int64(Int.max) else {
      throw AdmissionPolicyError.invalidRequest
    }
    return Int(raw)
  }

  private static func value<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self, from: ControlPlaneCanonicalJSON.encode(value))
  }

  private static func failure(
    requestID: String, reason: ControlReasonCode, code: String, message: String
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      requestID: requestID, status: .rejected, reasonCode: reason,
      error: SanitizedError(code: code, message: message))
  }
}
