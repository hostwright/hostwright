import CryptoKit
import Foundation
import HostwrightControlPlane

public enum AdmissionPolicySourceKind: String, Codable, CaseIterable, Sendable {
  case builtIn = "built-in"
  case `extension`
}

public struct AdmissionPolicyRecord: Codable, Equatable, Sendable {
  public let policyID: String
  public let version: Int
  public let sourceKind: AdmissionPolicySourceKind
  public let stage: AdmissionStage
  public let failurePolicy: AdmissionFailurePolicy
  public let advisory: Bool
  public let mutating: Bool
  public let document: ControlPlaneJSONValue
  public let documentSHA256: String
  public let enabled: Bool
  public let generation: Int
  public let createdBySubjectID: String
  public let createdAt: String
  public let updatedAt: String

  public init(
    policyID: String, version: Int, sourceKind: AdmissionPolicySourceKind,
    stage: AdmissionStage, failurePolicy: AdmissionFailurePolicy,
    advisory: Bool, mutating: Bool, document: ControlPlaneJSONValue,
    documentSHA256: String, enabled: Bool = true, generation: Int = 1,
    createdBySubjectID: String, createdAt: String, updatedAt: String
  ) {
    self.policyID = policyID
    self.version = version
    self.sourceKind = sourceKind
    self.stage = stage
    self.failurePolicy = failurePolicy
    self.advisory = advisory
    self.mutating = mutating
    self.document = document
    self.documentSHA256 = documentSHA256
    self.enabled = enabled
    self.generation = generation
    self.createdBySubjectID = createdBySubjectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func digest(_ document: ControlPlaneJSONValue) throws -> String {
    let data = try ControlPlaneCanonicalJSON.encode(document)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public func canonicalized() throws -> AdmissionPolicyRecord {
    try RBACStateValidation.identifier(policyID, named: "admission policy ID")
    try RBACStateValidation.identifier(createdBySubjectID, named: "admission policy creator")
    guard version >= 1, generation >= 1 else {
      throw StateStoreError.invalidRecord("Admission policy version and generation must be positive.")
    }
    guard stage == .builtInMutation || stage == .extensionMutation
      || stage == .builtInValidation || stage == .extensionValidation
    else { throw StateStoreError.invalidRecord("Admission policy stage is not executable.") }
    guard mutating == (stage == .builtInMutation || stage == .extensionMutation) else {
      throw StateStoreError.invalidRecord("Admission policy mutation flag disagrees with its stage.")
    }
    if sourceKind == .builtIn {
      guard stage == .builtInMutation || stage == .builtInValidation else {
        throw StateStoreError.invalidRecord("Built-in admission policy uses an extension stage.")
      }
    } else {
      guard stage == .extensionMutation || stage == .extensionValidation else {
        throw StateStoreError.invalidRecord("Extension admission policy uses a built-in stage.")
      }
    }
    if failurePolicy == .ignore {
      guard sourceKind == .extension, stage == .extensionValidation, advisory, !mutating else {
        throw StateStoreError.invalidRecord(
          "Only advisory non-mutating extension validation may ignore execution failure."
        )
      }
    }
    guard case .object = document else {
      throw StateStoreError.invalidRecord("Admission policy document must be a JSON object.")
    }
    let canonicalDocument = try ControlPlaneCanonicalJSON.encode(document)
    guard (2...1_048_576).contains(canonicalDocument.count),
      documentSHA256 == (try Self.digest(document))
    else { throw StateStoreError.invalidRecord("Admission policy document digest is invalid.") }
    let created = try RBACStateValidation.timestamp(createdAt, named: "policy creation timestamp")
    let updated = try RBACStateValidation.timestamp(updatedAt, named: "policy update timestamp")
    guard updated >= created else {
      throw StateStoreError.invalidRecord("Admission policy update predates creation.")
    }
    return self
  }
}

public struct AdmissionExceptionRecord: Codable, Equatable, Sendable {
  public let exceptionID: String
  public let policyID: String
  public let subjectID: String
  public let target: String
  public let planHash: String
  public let approvalIdentity: String
  public let expiresAt: String
  public let createdBySubjectID: String
  public let generation: Int
  public let createdAt: String
  public let updatedAt: String

  public init(
    exceptionID: String, policyID: String, subjectID: String, target: String,
    planHash: String, approvalIdentity: String, expiresAt: String,
    createdBySubjectID: String, generation: Int = 1,
    createdAt: String, updatedAt: String
  ) {
    self.exceptionID = exceptionID
    self.policyID = policyID
    self.subjectID = subjectID
    self.target = target
    self.planHash = planHash
    self.approvalIdentity = approvalIdentity
    self.expiresAt = expiresAt
    self.createdBySubjectID = createdBySubjectID
    self.generation = generation
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func canonicalized() throws -> AdmissionExceptionRecord {
    try RBACStateValidation.identifier(exceptionID, named: "admission exception ID")
    try RBACStateValidation.identifier(policyID, named: "admission exception policy ID")
    try RBACStateValidation.identifier(subjectID, named: "admission exception subject ID")
    try RBACStateValidation.identifier(
      createdBySubjectID, named: "admission exception creator subject ID")
    try RBACStateValidation.identifier(approvalIdentity, named: "admission approval identity")
    guard !target.isEmpty, target.utf8.count <= 512,
      target.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }),
      planHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      generation >= 1
    else { throw StateStoreError.invalidRecord("Admission exception binding is invalid.") }
    let created = try RBACStateValidation.timestamp(createdAt, named: "exception creation timestamp")
    let updated = try RBACStateValidation.timestamp(updatedAt, named: "exception update timestamp")
    let expires = try RBACStateValidation.timestamp(expiresAt, named: "exception expiry timestamp")
    guard updated >= created, expires > created else {
      throw StateStoreError.invalidRecord("Admission exception timestamps are invalid.")
    }
    return self
  }
}
