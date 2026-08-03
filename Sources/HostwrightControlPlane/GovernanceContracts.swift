import Foundation

public enum CodeValidationMode: String, Codable, CaseIterable, Sendable {
  case installedRequirement, pinnedAdHoc
}
public struct CodeIdentity: Codable, Equatable, Sendable {
  public let teamIdentifier: String?
  public let signingIdentifier: String
  public let codeDirectoryHash: String
  public let validationMode: CodeValidationMode
  public init(
    teamIdentifier: String? = nil, signingIdentifier: String, codeDirectoryHash: String,
    validationMode: CodeValidationMode
  ) {
    self.teamIdentifier = teamIdentifier
    self.signingIdentifier = signingIdentifier
    self.codeDirectoryHash = codeDirectoryHash
    self.validationMode = validationMode
  }
  public func validate() throws {
    guard !signingIdentifier.isEmpty,
      codeDirectoryHash.range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression)
        != nil
    else { throw ContractValidationError.required("code identity") }
    switch validationMode {
    case .installedRequirement:
      guard teamIdentifier?.isEmpty == false else {
        throw ContractValidationError.required("team identifier")
      }
    case .pinnedAdHoc:
      guard teamIdentifier == nil else { throw ContractValidationError.invalid("ad hoc team") }
    }
  }
}
public struct UnixPeerIdentity: Codable, Equatable, Sendable {
  public let effectiveUID: UInt32
  public let effectiveGID: UInt32
  public let pid: Int32
  public let pidVersion: UInt32
  public let auditSessionID: UInt32
  public let codeIdentity: CodeIdentity
  public init(
    effectiveUID: UInt32, effectiveGID: UInt32, pid: Int32, pidVersion: UInt32,
    auditSessionID: UInt32, codeIdentity: CodeIdentity
  ) {
    self.effectiveUID = effectiveUID
    self.effectiveGID = effectiveGID
    self.pid = pid
    self.pidVersion = pidVersion
    self.auditSessionID = auditSessionID
    self.codeIdentity = codeIdentity
  }
  public func validate() throws {
    guard pid > 0 else { throw ContractValidationError.invalid("peer PID") }
    try codeIdentity.validate()
  }
}
public struct LocalSubject: Codable, Equatable, Sendable {
  public let identifier: String
  public let userID: UInt32
  public let codeIdentityHash: String
  public let credentialID: String?
  public init(
    identifier: String, userID: UInt32, codeIdentityHash: String, credentialID: String? = nil
  ) {
    self.identifier = identifier
    self.userID = userID
    self.codeIdentityHash = codeIdentityHash
    self.credentialID = credentialID
  }
  public func validate() throws {
    guard !identifier.isEmpty && !codeIdentityHash.isEmpty else {
      throw ContractValidationError.required("local subject")
    }
  }
}
public struct ControlSessionBinding: Codable, Equatable, Sendable {
  public let sessionID: String
  public let daemonGeneration: UInt64
  public let serverNonce: String
  public let socketDevice: UInt64
  public let socketInode: UInt64
  public let peer: UnixPeerIdentity
  public let subject: LocalSubject
  public init(
    sessionID: String, daemonGeneration: UInt64, serverNonce: String, socketDevice: UInt64,
    socketInode: UInt64, peer: UnixPeerIdentity, subject: LocalSubject
  ) {
    self.sessionID = sessionID
    self.daemonGeneration = daemonGeneration
    self.serverNonce = serverNonce
    self.socketDevice = socketDevice
    self.socketInode = socketInode
    self.peer = peer
    self.subject = subject
  }
  public func validate() throws {
    guard !sessionID.isEmpty && !serverNonce.isEmpty && daemonGeneration > 0 && socketInode > 0
    else { throw ContractValidationError.required("session binding") }
    try peer.validate()
    try subject.validate()
    guard peer.effectiveUID == subject.userID,
      subject.codeIdentityHash == peer.codeIdentity.codeDirectoryHash
    else { throw ContractValidationError.invalid("peer/subject identity") }
  }
}

public enum RBACResource: String, Codable, CaseIterable, Hashable, Sendable {
  case project, service, image, volume, registry
  case secretMetadata = "secret-metadata"
  case runtime, state, daemon, observability, audit, policy, profile, plugin, provider
}
public enum RBACVerb: String, Codable, CaseIterable, Hashable, Sendable {
  case get, list, watch, plan, create, update, delete, start, stop, restart, execute, approve,
    delegate, admin
}
public enum RBACScopeKind: String, Codable, CaseIterable, Sendable {
  case global, project, resource
}
public struct RBACScope: Codable, Equatable, Sendable {
  public let kind: RBACScopeKind
  public let identifier: String?
  public init(kind: RBACScopeKind, identifier: String? = nil) {
    self.kind = kind
    self.identifier = identifier
  }
  public func validate() throws {
    switch kind {
    case .global:
      guard identifier == nil else {
        throw ContractValidationError.invalid("global scope identifier")
      }
    case .project, .resource:
      guard let identifier, !identifier.isEmpty else {
        throw ContractValidationError.required("scope identifier")
      }
    }
  }
}
public enum RBACConditionKind: String, Codable, CaseIterable, Hashable, Sendable {
  case project, resource, operation, profileHash, expiresAt
}
public enum RBACEffect: String, Codable, CaseIterable, Sendable { case allow, deny }
public enum DefaultRole: String, Codable, CaseIterable, Sendable {
  case viewer, `operator`, maintainer
  case securityAdmin = "security-admin"
  case owner
}
public struct DefaultRolePermission: Codable, Equatable, Sendable {
  public let role: DefaultRole
  public let resources: [RBACResource]
  public let verbs: [RBACVerb]
  public let inheritedRole: DefaultRole?
  enum CodingKeys: String, CodingKey {
    case role, resources, verbs
    case inheritedRole = "inherits"
  }
  public init(
    role: DefaultRole, resources: [RBACResource], verbs: [RBACVerb],
    inheritedRole: DefaultRole? = nil
  ) {
    self.role = role
    self.resources = resources
    self.verbs = verbs
    self.inheritedRole = inheritedRole
  }
}
public enum DefaultRolePolicy {
  public static let denyOverridesAllow = true
  public static let conditionsCombineWithANDOnly = true
  public static let builtInRolesImmutable = true
  public static let matrix = [
    DefaultRolePermission(
      role: .viewer,
      resources: [
        .project, .service, .image, .volume, .registry, .secretMetadata, .runtime, .state, .daemon,
        .observability,
      ], verbs: [.get, .list, .watch]),
    DefaultRolePermission(
      role: .operator, resources: [.project, .service, .runtime],
      verbs: [.plan, .start, .stop, .restart, .execute], inheritedRole: .viewer),
    DefaultRolePermission(
      role: .maintainer, resources: [.project, .service, .image, .volume, .registry, .runtime],
      verbs: [.create, .update, .delete, .approve], inheritedRole: .operator),
    DefaultRolePermission(
      role: .securityAdmin,
      resources: [.audit, .policy, .profile, .plugin, .provider, .secretMetadata],
      verbs: [.get, .list, .watch, .create, .update, .delete, .approve, .delegate, .admin]),
    DefaultRolePermission(role: .owner, resources: RBACResource.allCases, verbs: RBACVerb.allCases),
  ]
}
public struct RBACCondition: Codable, Equatable, Sendable {
  public let kind: RBACConditionKind
  public let value: String
  public init(kind: RBACConditionKind, value: String) {
    self.kind = kind
    self.value = value
  }
  public func validate() throws {
    guard !value.isEmpty, value.utf8.count <= 128,
      value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e })
    else { throw ContractValidationError.invalid("rbac condition") }
    if kind == .expiresAt {
      guard ISO8601DateFormatter().date(from: value) != nil else {
        throw ContractValidationError.invalid("rbac condition expiry")
      }
    }
  }
}
public struct RBACRule: Codable, Equatable, Sendable {
  public let identifier: String
  public let effect: RBACEffect
  public let resources: [RBACResource]
  public let verbs: [RBACVerb]
  public let scope: RBACScope
  public let conditions: [RBACCondition]
  public init(
    identifier: String, effect: RBACEffect, resources: [RBACResource], verbs: [RBACVerb],
    scope: RBACScope, conditions: [RBACCondition] = []
  ) {
    self.identifier = identifier
    self.effect = effect
    self.resources = resources
    self.verbs = verbs
    self.scope = scope
    self.conditions = conditions
  }
  public func validate() throws {
    guard !identifier.isEmpty && !resources.isEmpty && !verbs.isEmpty else {
      throw ContractValidationError.required("rbac rule")
    }
    guard Set(resources).count == resources.count, Set(verbs).count == verbs.count,
      Set(conditions.map(\.kind)).count == conditions.count
    else { throw ContractValidationError.invalid("duplicate rbac rule member") }
    try scope.validate()
    try conditions.forEach { try $0.validate() }
  }
}
public struct RoleDefinition: Codable, Equatable, Sendable {
  public let identifier: String
  public let builtIn: Bool
  public let rules: [RBACRule]
  public init(identifier: String, builtIn: Bool, rules: [RBACRule]) {
    self.identifier = identifier
    self.builtIn = builtIn
    self.rules = rules
  }
  public func validate() throws {
    guard !identifier.isEmpty else { throw ContractValidationError.required("role identifier") }
    try rules.forEach { try $0.validate() }
  }
}
public struct RBACBinding: Codable, Equatable, Sendable {
  public let identifier: String
  public let subject: String
  public let roleIdentifier: String
  public let scope: RBACScope
  public init(identifier: String, subject: String, roleIdentifier: String, scope: RBACScope) {
    self.identifier = identifier
    self.subject = subject
    self.roleIdentifier = roleIdentifier
    self.scope = scope
  }
  public func validate() throws {
    guard !identifier.isEmpty, !subject.isEmpty, !roleIdentifier.isEmpty else {
      throw ContractValidationError.required("rbac binding")
    }
    try scope.validate()
  }
}
public struct RBACDelegation: Codable, Equatable, Sendable {
  public let identifier: String
  public let delegator: String
  public let delegate: String
  public let roleIdentifiers: [String]
  public let delegatedRules: [RBACRule]
  public let scope: RBACScope
  public let expiresAt: Date
  public init(
    identifier: String, delegator: String, delegate: String, roleIdentifiers: [String],
    delegatedRules: [RBACRule], scope: RBACScope, expiresAt: Date
  ) {
    self.identifier = identifier
    self.delegator = delegator
    self.delegate = delegate
    self.roleIdentifiers = roleIdentifiers
    self.delegatedRules = delegatedRules
    self.scope = scope
    self.expiresAt = expiresAt
  }
  public func validate() throws {
    guard
      !identifier.isEmpty && !delegator.isEmpty && !delegate.isEmpty
        && (!roleIdentifiers.isEmpty || !delegatedRules.isEmpty)
        && roleIdentifiers.allSatisfy({ !$0.isEmpty })
        && Set(roleIdentifiers).count == roleIdentifiers.count
    else { throw ContractValidationError.required("delegation") }
    try scope.validate()
    try delegatedRules.forEach { try $0.validate() }
    guard !roleIdentifiers.contains(DefaultRole.owner.rawValue) else {
      throw ContractValidationError.invalid("owner delegation")
    }
  }
}
public struct RBACDecision: Codable, Equatable, Sendable {
  public let effect: RBACEffect
  public let ruleIdentifiers: [String]
  public let reasonCode: String
  public init(effect: RBACEffect, ruleIdentifiers: [String], reasonCode: String) {
    self.effect = effect
    self.ruleIdentifiers = ruleIdentifiers
    self.reasonCode = reasonCode
  }
  public func validate() throws {
    guard !reasonCode.isEmpty, Set(ruleIdentifiers).count == ruleIdentifiers.count,
      ruleIdentifiers.allSatisfy({ !$0.isEmpty })
    else { throw ContractValidationError.invalid("rbac decision") }
  }
}

public enum AdmissionFailurePolicy: String, Codable, CaseIterable, Sendable { case deny, ignore }
public enum AdmissionStage: String, Codable, CaseIterable, Sendable {
  case authenticate, authorizeRequestedIntent, canonicalize, builtInMutation, extensionMutation,
    conflictDetection, builtInValidation, extensionValidation, authorizeEffectiveIntent,
    bindApproval, persistRequestOperationAudit, acknowledge
}
public struct AdmissionRequest: Codable, Equatable, Sendable {
  public let requestID: String
  public let subjectID: String
  public let operation: String
  public let originalBody: ControlPlaneJSONValue?
  public let canonicalBody: ControlPlaneJSONValue?
  public let dryRun: Bool
  public let planHash: String?
  public init(
    requestID: String, subjectID: String, operation: String,
    originalBody: ControlPlaneJSONValue? = nil, canonicalBody: ControlPlaneJSONValue? = nil,
    dryRun: Bool, planHash: String? = nil
  ) {
    self.requestID = requestID
    self.subjectID = subjectID
    self.operation = operation
    self.originalBody = originalBody
    self.canonicalBody = canonicalBody
    self.dryRun = dryRun
    self.planHash = planHash
  }
}
public struct AdmissionMutation: Codable, Equatable, Sendable {
  public let policyIdentifier: String
  public let stage: AdmissionStage
  public let fieldPath: String
  public let value: ControlPlaneJSONValue
  public init(
    policyIdentifier: String, stage: AdmissionStage, fieldPath: String, value: ControlPlaneJSONValue
  ) {
    self.policyIdentifier = policyIdentifier
    self.stage = stage
    self.fieldPath = fieldPath
    self.value = value
  }
  public func validate() throws {
    guard stage == .builtInMutation || stage == .extensionMutation else {
      throw ContractValidationError.invalid("mutation stage")
    }
    guard !policyIdentifier.isEmpty && !fieldPath.isEmpty else {
      throw ContractValidationError.required("mutation")
    }
  }
}
public struct AdmissionDecision: Codable, Equatable, Sendable {
  public let policyIdentifier: String
  public let stage: AdmissionStage
  public let allowed: Bool
  public let failurePolicy: AdmissionFailurePolicy
  public let reasonCode: String
  public let mutations: [AdmissionMutation]
  public let advisory: Bool
  public init(
    policyIdentifier: String, stage: AdmissionStage, allowed: Bool,
    failurePolicy: AdmissionFailurePolicy, reasonCode: String, mutations: [AdmissionMutation] = [],
    advisory: Bool = false
  ) {
    self.policyIdentifier = policyIdentifier
    self.stage = stage
    self.allowed = allowed
    self.failurePolicy = failurePolicy
    self.reasonCode = reasonCode
    self.mutations = mutations
    self.advisory = advisory
  }
  public func validate() throws {
    try mutations.forEach { try $0.validate() }
    if failurePolicy == .ignore {
      guard advisory, stage == .extensionValidation, mutations.isEmpty else {
        throw ContractValidationError.invalid("admission ignore")
      }
    }
  }
}
public struct AdmissionException: Codable, Equatable, Sendable {
  public let id: String
  public let policyIdentifier: String
  public let subjectID: String
  public let target: String
  public let planHash: String
  public let approvalIdentity: String
  public let expiresAt: Date
  public init(
    id: String, policyIdentifier: String, subjectID: String, target: String, planHash: String,
    approvalIdentity: String, expiresAt: Date
  ) {
    self.id = id
    self.policyIdentifier = policyIdentifier
    self.subjectID = subjectID
    self.target = target
    self.planHash = planHash
    self.approvalIdentity = approvalIdentity
    self.expiresAt = expiresAt
  }
}

public enum StateMigrationStage: String, Codable, CaseIterable, Sendable {
  case identity, audit, policyProfile, plugin
}
public struct StateMigration: Codable, Equatable, Sendable {
  public let version: Int
  public let stage: StateMigrationStage
  public init(version: Int, stage: StateMigrationStage) {
    self.version = version
    self.stage = stage
  }
}
public enum StateMigrationPlan {
  public static let phase09 = [
    StateMigration(version: 18, stage: .identity), StateMigration(version: 19, stage: .audit),
    StateMigration(version: 20, stage: .policyProfile), StateMigration(version: 21, stage: .plugin),
  ]
}
public struct StateMigrationEdge: Codable, Equatable, Sendable {
  public let fromVersion: Int
  public let toVersion: Int
  public let ownedTableGroups: [String]
  public let requiresVerifiedPreMigrationBackup: Bool
  public let oldBinaryPolicy: String
  public let rollbackPolicy: String
  public init(
    fromVersion: Int, toVersion: Int, ownedTableGroups: [String],
    requiresVerifiedPreMigrationBackup: Bool = true, oldBinaryPolicy: String = "safe-refusal",
    rollbackPolicy: String = "restore-backup"
  ) {
    self.fromVersion = fromVersion
    self.toVersion = toVersion
    self.ownedTableGroups = ownedTableGroups
    self.requiresVerifiedPreMigrationBackup = requiresVerifiedPreMigrationBackup
    self.oldBinaryPolicy = oldBinaryPolicy
    self.rollbackPolicy = rollbackPolicy
  }
}
extension StateMigrationPlan {
  public static let phase09Edges = [
    StateMigrationEdge(
      fromVersion: 17, toVersion: 18,
      ownedTableGroups: [
        "peer_identities", "control_sessions", "identity_revocations", "control_requests",
        "idempotency_records",
      ]),
    StateMigrationEdge(
      fromVersion: 18, toVersion: 19,
      ownedTableGroups: [
        "audit_segments", "audit_records", "audit_key_metadata", "audit_retention_anchors",
      ]),
    StateMigrationEdge(
      fromVersion: 19, toVersion: 20,
      ownedTableGroups: [
        "rbac_roles", "rbac_bindings", "rbac_delegations", "admission_policies",
        "admission_exceptions", "workload_profiles",
      ]),
    StateMigrationEdge(
      fromVersion: 20, toVersion: 21,
      ownedTableGroups: [
        "plugin_packages", "plugin_provenance", "plugin_grants", "plugin_activations",
        "plugin_revocations", "plugin_quarantine", "plugin_rollback_state",
      ]),
  ]
}

public enum AuditAction: String, Codable, CaseIterable, Sendable {
  case request, authentication, authorization, admission, operation, effect, recovery, plugin,
    admin, export, retention
}
public struct AuditRecord: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let identifier: String
  public let segmentID: String
  public let sequence: UInt64
  public let timestamp: Date
  public let previousDigest: String?
  public let subjectID: String
  public let requestID: String?
  public let target: String?
  public let action: AuditAction
  public let outcome: String
  public let reasonCode: String
  public let policyRef: String?
  public let planRef: String?
  public let approvalRef: String?
  public let operationRef: String?
  public let pluginRef: String?
  public let payloadDigest: String
  public let recordDigest: String
  public let signingKeyID: String
  public init(
    schemaVersion: Int = 1, identifier: String, segmentID: String, sequence: UInt64,
    timestamp: Date, previousDigest: String? = nil, subjectID: String, requestID: String? = nil,
    target: String? = nil, action: AuditAction, outcome: String, reasonCode: String,
    policyRef: String? = nil, planRef: String? = nil, approvalRef: String? = nil,
    operationRef: String? = nil, pluginRef: String? = nil, payloadDigest: String,
    recordDigest: String, signingKeyID: String
  ) {
    self.schemaVersion = schemaVersion
    self.identifier = identifier
    self.segmentID = segmentID
    self.sequence = sequence
    self.timestamp = timestamp
    self.previousDigest = previousDigest
    self.subjectID = subjectID
    self.requestID = requestID
    self.target = target
    self.action = action
    self.outcome = outcome
    self.reasonCode = reasonCode
    self.policyRef = policyRef
    self.planRef = planRef
    self.approvalRef = approvalRef
    self.operationRef = operationRef
    self.pluginRef = pluginRef
    self.payloadDigest = payloadDigest
    self.recordDigest = recordDigest
    self.signingKeyID = signingKeyID
  }
  public func validate() throws {
    let chainIsValid =
      sequence == 1 ? previousDigest == nil : previousDigest.map(Self.digest) == true
    guard
      schemaVersion == 1 && sequence > 0 && !identifier.isEmpty && !segmentID.isEmpty
        && !subjectID.isEmpty && !outcome.isEmpty && !reasonCode.isEmpty && !signingKeyID.isEmpty
        && Self.digest(payloadDigest) && Self.digest(recordDigest) && chainIsValid
    else { throw ContractValidationError.invalid("audit record") }
  }
  static func digest(_ value: String) -> Bool {
    value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
  }
}
public struct AuditSegmentSeal: Codable, Equatable, Sendable {
  public let segmentID: String
  public let firstSequence: UInt64
  public let lastSequence: UInt64
  public let recordCount: UInt64
  public let priorSegmentDigest: String?
  public let sha256Digest: String
  public let p256Signature: String
  public let keyID: String
  public init(
    segmentID: String, firstSequence: UInt64, lastSequence: UInt64, recordCount: UInt64,
    priorSegmentDigest: String? = nil, sha256Digest: String, p256Signature: String, keyID: String
  ) {
    self.segmentID = segmentID
    self.firstSequence = firstSequence
    self.lastSequence = lastSequence
    self.recordCount = recordCount
    self.priorSegmentDigest = priorSegmentDigest
    self.sha256Digest = sha256Digest
    self.p256Signature = p256Signature
    self.keyID = keyID
  }
  public func validate() throws {
    guard
      !segmentID.isEmpty && firstSequence > 0 && lastSequence >= firstSequence
        && recordCount == lastSequence - firstSequence + 1
        && (priorSegmentDigest == nil || AuditRecord.digest(priorSegmentDigest!))
        && AuditRecord.digest(sha256Digest) && !p256Signature.isEmpty && !keyID.isEmpty
    else { throw ContractValidationError.invalid("audit seal") }
  }
}
public struct AuditRetentionCheckpoint: Codable, Equatable, Sendable {
  public let removedThroughSegmentID: String
  public let priorAnchorDigest: String
  public let newAnchorDigest: String
  public let approver: String
  public let reason: String
  public let timestamp: Date
  public let p256Signature: String
  public let keyID: String
  public init(
    removedThroughSegmentID: String, priorAnchorDigest: String, newAnchorDigest: String,
    approver: String, reason: String, timestamp: Date, p256Signature: String, keyID: String
  ) {
    self.removedThroughSegmentID = removedThroughSegmentID
    self.priorAnchorDigest = priorAnchorDigest
    self.newAnchorDigest = newAnchorDigest
    self.approver = approver
    self.reason = reason
    self.timestamp = timestamp
    self.p256Signature = p256Signature
    self.keyID = keyID
  }
  public func validate() throws {
    guard
      !removedThroughSegmentID.isEmpty && AuditRecord.digest(priorAnchorDigest)
        && AuditRecord.digest(newAnchorDigest) && !approver.isEmpty && !reason.isEmpty
        && !p256Signature.isEmpty && !keyID.isEmpty
    else { throw ContractValidationError.invalid("retention checkpoint") }
  }
}

public struct ControlSecurityAuditEvent: Equatable, Sendable {
  public let subjectID: String
  public let requestID: String
  public let target: String
  public let action: AuditAction
  public let outcome: String
  public let reasonCode: String
  public let operationRef: String?
  public let payloadDigest: String
  public let deduplicationKey: String

  public init(
    subjectID: String,
    requestID: String,
    target: String,
    action: AuditAction,
    outcome: String,
    reasonCode: String,
    operationRef: String? = nil,
    payloadDigest: String,
    deduplicationKey: String
  ) {
    self.subjectID = subjectID
    self.requestID = requestID
    self.target = target
    self.action = action
    self.outcome = outcome
    self.reasonCode = reasonCode
    self.operationRef = operationRef
    self.payloadDigest = payloadDigest
    self.deduplicationKey = deduplicationKey
  }

  public func validate() throws {
    guard !subjectID.isEmpty, !requestID.isEmpty, !target.isEmpty,
      !outcome.isEmpty, !reasonCode.isEmpty, !deduplicationKey.isEmpty,
      AuditRecord.digest(payloadDigest)
    else { throw ContractValidationError.invalid("control security audit event") }
  }
}

public protocol ControlSecurityAuditRecording: Sendable {
  @discardableResult
  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord
}
