import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightPolicy
import HostwrightState

enum WorkloadProfileControlOperations {
  static let mutatingOperations: Set<String> = [
    "profile.create", "profile.update", "profile.delete",
  ]

  static func handle(
    peer: AuthenticatedControlPeer, request: ControlRequestEnvelope,
    repository: WorkloadProfileRepository, administration: WorkloadProfileAdministrationService,
    engine: WorkloadProfilePolicyEngine, now: Date
  ) -> ControlResponseEnvelope? {
    guard request.operation.hasPrefix("profile.") else { return nil }
    do {
      let fields = try bodyFields(request.body)
      let subjectID = peer.binding.subject.identifier
      let result: ControlPlaneJSONValue
      switch request.operation {
      case "profile.list":
        try requireExactKeys(fields, allowed: [])
        result = try value(repository.listProfiles())
      case "profile.get":
        try requireExactKeys(fields, allowed: ["identifier"])
        guard let record = try repository.profile(id: try requiredString("identifier", from: fields)) else {
          throw WorkloadProfilePolicyError.missingProfile("requested")
        }
        result = try value(record)
      case "profile.resolve":
        try requireExactKeys(fields, allowed: ["identifier"])
        result = try value(engine.resolve(id: try requiredString("identifier", from: fields)))
      case "profile.preview":
        try requireExactKeys(fields, allowed: ["profile", "baseIdentifier"])
        let profile: WorkloadProfile = try decodeField("profile", from: fields)
        try profile.validate()
        let baseID = try requiredString("baseIdentifier", from: fields)
        guard baseID == profile.parent || baseID == profile.identifier else {
          throw WorkloadProfilePolicyError.invalidWeakeningApproval
        }
        let base = try engine.resolve(id: baseID)
        let proposal = try engine.proposedResolution(profile)
        result = .object([
          "profileSHA256": .string(proposal.profileSHA256),
          "recordSHA256": .string(try WorkloadProfileRecord.digest(profile)),
          "baseProfileSHA256": .string(base.profileSHA256),
          "inheritance": .array(proposal.inheritance.map(ControlPlaneJSONValue.string)),
          "sourceDigests": .array(proposal.sourceDigests.map(ControlPlaneJSONValue.string)),
          "weakeningReasons": .array(
            WorkloadProfilePolicyEngine.weakeningReasons(
              candidate: proposal.profile, base: base.profile)
              .map(ControlPlaneJSONValue.string)),
        ])
      case "profile.drift":
        try requireExactKeys(fields, allowed: ["identifier", "observedProfileSHA256", "reasons"])
        result = try value(
          engine.drift(
            id: try requiredString("identifier", from: fields),
            observedProfileSHA256: try optionalDigest("observedProfileSHA256", from: fields),
            observedReasons: try optionalStringArray("reasons", from: fields) ?? []))
      case "profile.create":
        try requireExactKeys(fields, allowed: ["profile", "weakeningApproval"])
        let profile: WorkloadProfile = try decodeField("profile", from: fields)
        result = try value(
          administration.create(
            profile, approval: try optionalDecode("weakeningApproval", from: fields),
            actorSubjectID: subjectID, at: now))
      case "profile.update":
        try requireExactKeys(
          fields, allowed: ["profile", "expectedGeneration", "weakeningApproval"])
        let profile: WorkloadProfile = try decodeField("profile", from: fields)
        result = try value(
          administration.update(
            profile, expectedGeneration: try positiveInt("expectedGeneration", from: fields),
            approval: try optionalDecode("weakeningApproval", from: fields),
            actorSubjectID: subjectID, at: now))
      case "profile.delete":
        try requireExactKeys(fields, allowed: ["identifier", "expectedGeneration"])
        try administration.delete(
          id: try requiredString("identifier", from: fields),
          expectedGeneration: try positiveInt("expectedGeneration", from: fields),
          actorSubjectID: subjectID, at: now)
        result = .object(["deleted": .bool(true)])
      default:
        return failure(
          requestID: request.requestID, reason: .invalidRequest,
          code: "unsupportedProfileOperation",
          message: "The workload-profile operation is not supported.")
      }
      return ControlResponseEnvelope(
        requestID: request.requestID, status: .completed, reasonCode: .completed, result: result)
    } catch RBACAuthorizationError.delegationExceedsAuthority {
      return failure(
        requestID: request.requestID, reason: .unauthorized,
        code: "profileManagementDenied",
        message: "The subject is not authorized to manage workload profiles.")
    } catch WorkloadProfilePolicyError.weakeningRequiresApproval {
      return failure(
        requestID: request.requestID, reason: .admissionDenied,
        code: "profileWeakeningApprovalRequired",
        message: "The workload profile would weaken an active constraint and requires exact approval.")
    } catch {
      return failure(
        requestID: request.requestID, reason: .invalidRequest,
        code: "invalidProfileRequest",
        message: "The workload-profile request is invalid or conflicts with current state.")
    }
  }

  private static func bodyFields(_ body: ControlPlaneJSONValue?) throws -> [String: ControlPlaneJSONValue] {
    if body == nil { return [:] }
    guard case .object(let fields) = body else { throw WorkloadProfilePolicyError.inheritanceCycle }
    return fields
  }

  private static func requireExactKeys(
    _ fields: [String: ControlPlaneJSONValue], allowed: Set<String>
  ) throws {
    guard Set(fields.keys).isSubset(of: allowed) else { throw WorkloadProfilePolicyError.inheritanceCycle }
  }

  private static func requiredField(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> ControlPlaneJSONValue {
    guard let value = fields[name] else { throw WorkloadProfilePolicyError.inheritanceCycle }
    return value
  }

  private static func decodeField<T: Decodable>(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> T {
    try JSONDecoder().decode(T.self, from: ControlPlaneCanonicalJSON.encode(try requiredField(name, from: fields)))
  }

  private static func optionalDecode<T: Decodable>(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> T? {
    guard fields[name] != nil else { return nil }
    return try decodeField(name, from: fields)
  }

  private static func requiredString(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> String {
    guard case .string(let value)? = fields[name],
      value.range(
        of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    else { throw WorkloadProfilePolicyError.inheritanceCycle }
    return value
  }

  private static func optionalDigest(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> String? {
    guard let field = fields[name] else { return nil }
    guard case .string(let value) = field,
      value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    else { throw WorkloadProfilePolicyError.inheritanceCycle }
    return value
  }

  private static func optionalStringArray(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> [String]? {
    guard let field = fields[name] else { return nil }
    guard case .array(let values) = field, values.count <= 128 else {
      throw WorkloadProfilePolicyError.inheritanceCycle
    }
    let strings = try values.map { value -> String in
      guard case .string(let string) = value, !string.isEmpty, string.utf8.count <= 128 else {
        throw WorkloadProfilePolicyError.inheritanceCycle
      }
      return string
    }
    guard strings == strings.sorted(), Set(strings).count == strings.count else {
      throw WorkloadProfilePolicyError.inheritanceCycle
    }
    return strings
  }

  private static func positiveInt(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> Int {
    guard case .integer(let raw)? = fields[name], raw >= 1, raw <= Int64(Int.max) else {
      throw WorkloadProfilePolicyError.inheritanceCycle
    }
    return Int(raw)
  }

  private static func value<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(ControlPlaneJSONValue.self, from: ControlPlaneCanonicalJSON.encode(value))
  }

  private static func failure(
    requestID: String, reason: ControlReasonCode, code: String, message: String
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      requestID: requestID, status: .rejected, reasonCode: reason,
      error: SanitizedError(code: code, message: message))
  }
}
