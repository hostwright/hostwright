import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightPolicy
import HostwrightState

enum RBACControlOperations {
  static func handle(
    peer: AuthenticatedControlPeer,
    request: ControlRequestEnvelope,
    repository: RBACRepository,
    administration: RBACAdministrationService,
    authorizer: RBACAuthorizationEngine,
    now: Date
  ) -> ControlResponseEnvelope? {
    guard request.operation.hasPrefix("rbac.") else { return nil }
    do {
      let fields = try bodyFields(request.body)
      let timestamp = ISO8601DateFormatter().string(from: now)
      let subjectID = peer.binding.subject.identifier
      let result: ControlPlaneJSONValue
      switch request.operation {
      case "rbac.preview":
        try requireExactKeys(fields, allowed: ["request", "subjectID"])
        let previewRequest: ControlRequestEnvelope = try decodeField("request", from: fields)
        let targetSubject = try optionalString("subjectID", from: fields) ?? subjectID
        let decision = try authorizer.preview(
          subjectID: targetSubject, request: previewRequest, at: now)
        result = try value(decision)
      case "rbac.role.list":
        try requireExactKeys(fields, allowed: [])
        result = try value(repository.listRoles())
      case "rbac.role.create":
        try requireExactKeys(fields, allowed: ["role"])
        let definition: RoleDefinition = try decodeField("role", from: fields)
        try definition.validate()
        guard !definition.builtIn else { throw RBACAuthorizationError.delegationExceedsAuthority }
        result = try value(
          administration.createRole(
            RBACRoleRecord(
              roleID: definition.identifier, builtIn: false, rules: definition.rules,
              createdBySubjectID: subjectID, createdAt: timestamp, updatedAt: timestamp),
            actorSubjectID: subjectID, timestamp: timestamp))
      case "rbac.role.update":
        try requireExactKeys(fields, allowed: ["role", "expectedGeneration"])
        let definition: RoleDefinition = try decodeField("role", from: fields)
        try definition.validate()
        guard !definition.builtIn else { throw RBACAuthorizationError.delegationExceedsAuthority }
        let expected = try generation(from: fields)
        result = try value(
          administration.updateRole(
            RBACRoleRecord(
              roleID: definition.identifier, builtIn: false, rules: definition.rules,
              createdBySubjectID: subjectID, createdAt: timestamp, updatedAt: timestamp),
            expectedGeneration: expected, actorSubjectID: subjectID, timestamp: timestamp))
      case "rbac.role.delete":
        try requireExactKeys(fields, allowed: ["identifier", "expectedGeneration"])
        try administration.deleteRole(
          id: try requiredString("identifier", from: fields),
          expectedGeneration: try generation(from: fields),
          actorSubjectID: subjectID,
          at: now)
        result = .object(["deleted": .bool(true)])
      case "rbac.binding.list":
        try requireExactKeys(fields, allowed: ["subjectID"])
        result = try value(
          repository.listBindings(subjectID: try optionalString("subjectID", from: fields)))
      case "rbac.binding.create":
        try requireExactKeys(fields, allowed: ["binding"])
        let binding: RBACBinding = try decodeField("binding", from: fields)
        try binding.validate()
        result = try value(
          administration.createBinding(
            RBACBindingRecord(
              bindingID: binding.identifier, subjectID: binding.subject,
              roleID: binding.roleIdentifier, scope: binding.scope,
              createdBySubjectID: subjectID, createdAt: timestamp, updatedAt: timestamp),
            actorSubjectID: subjectID, at: now))
      case "rbac.binding.delete":
        try requireExactKeys(fields, allowed: ["identifier", "expectedGeneration"])
        try administration.deleteBinding(
          id: try requiredString("identifier", from: fields),
          expectedGeneration: try generation(from: fields), actorSubjectID: subjectID,
          at: now)
        result = .object(["deleted": .bool(true)])
      case "rbac.delegation.list":
        try requireExactKeys(fields, allowed: ["subjectID"])
        result = try value(
          repository.listDelegations(
            delegateSubjectID: try optionalString("subjectID", from: fields), activeAt: nil))
      case "rbac.delegation.create":
        try requireExactKeys(fields, allowed: ["delegation"])
        let delegation: RBACDelegation = try decodeField("delegation", from: fields)
        try delegation.validate()
        result = try value(
          administration.createDelegation(
            RBACDelegationRecord(
              delegationID: delegation.identifier,
              delegatorSubjectID: delegation.delegator,
              delegateSubjectID: delegation.delegate,
              roleIDs: delegation.roleIdentifiers,
              delegatedRules: delegation.delegatedRules,
              scope: delegation.scope,
              expiresAt: ISO8601DateFormatter().string(from: delegation.expiresAt),
              createdAt: timestamp,
              updatedAt: timestamp),
            actorSubjectID: subjectID, at: now))
      case "rbac.delegation.revoke":
        try requireExactKeys(fields, allowed: ["identifier", "expectedGeneration"])
        result = try value(
          administration.revokeDelegation(
            id: try requiredString("identifier", from: fields),
            expectedGeneration: try generation(from: fields),
            actorSubjectID: subjectID, revokedAt: timestamp))
      default:
        return failure(
          requestID: request.requestID, reason: .invalidRequest,
          code: "unsupportedRBACOperation",
          message: "The RBAC operation is not supported.")
      }
      return ControlResponseEnvelope(
        requestID: request.requestID, status: .completed, reasonCode: .completed,
        result: result)
    } catch RBACAuthorizationError.delegationExceedsAuthority {
      return failure(
        requestID: request.requestID, reason: .unauthorized,
        code: "rbacGrantExceedsAuthority",
        message: "The requested RBAC grant exceeds the actor's effective authority.")
    } catch {
      return failure(
        requestID: request.requestID, reason: .invalidRequest,
        code: "invalidRBACRequest",
        message: "The RBAC request is invalid or conflicts with current policy state.")
    }
  }

  private static func bodyFields(
    _ body: ControlPlaneJSONValue?
  ) throws -> [String: ControlPlaneJSONValue] {
    if body == nil { return [:] }
    guard case .object(let fields) = body else { throw RBACAuthorizationError.invalidTarget }
    return fields
  }

  private static func decodeField<T: Decodable>(
    _ name: String,
    from fields: [String: ControlPlaneJSONValue]
  ) throws -> T {
    guard let field = fields[name] else { throw RBACAuthorizationError.invalidTarget }
    return try JSONDecoder().decode(T.self, from: ControlPlaneCanonicalJSON.encode(field))
  }

  private static func requireExactKeys(
    _ fields: [String: ControlPlaneJSONValue],
    allowed: Set<String>
  ) throws {
    guard Set(fields.keys).isSubset(of: allowed) else {
      throw RBACAuthorizationError.invalidTarget
    }
  }

  private static func optionalString(
    _ name: String,
    from fields: [String: ControlPlaneJSONValue]
  ) throws -> String? {
    guard let field = fields[name] else { return nil }
    guard case .string(let value) = field,
      !value.isEmpty,
      value.utf8.count <= 128,
      value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) })
    else { throw RBACAuthorizationError.invalidTarget }
    return value
  }

  private static func requiredString(
    _ name: String,
    from fields: [String: ControlPlaneJSONValue]
  ) throws -> String {
    guard let value = try optionalString(name, from: fields) else {
      throw RBACAuthorizationError.invalidTarget
    }
    return value
  }

  private static func generation(
    from fields: [String: ControlPlaneJSONValue]
  ) throws -> Int {
    guard case .integer(let value)? = fields["expectedGeneration"],
      value >= 1, value <= Int64(Int.max)
    else { throw RBACAuthorizationError.invalidTarget }
    return Int(value)
  }

  private static func value<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self,
      from: ControlPlaneCanonicalJSON.encode(value))
  }

  private static func failure(
    requestID: String,
    reason: ControlReasonCode,
    code: String,
    message: String
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      requestID: requestID,
      status: .rejected,
      reasonCode: reason,
      error: SanitizedError(code: code, message: message))
  }
}
