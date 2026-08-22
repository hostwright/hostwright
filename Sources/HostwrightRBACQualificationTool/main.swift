import Foundation
import HostwrightControlPlane
import HostwrightPolicy
import HostwrightState

struct RBACQualificationResult: Encodable {
  let kind = "hostwright.phase09.rbac.qualification.v1"
  let stateSchemaVersion: Int
  let integrityHealth: String
  let roleCount: Int
  let initialViewerRead: String
  let initialViewerMutation: String
  let roleChangeWithoutRestart: String
  let delegatedBeforeRevocation: String
  let delegatedAfterRevocation: String
  let globalOwnerCount: Int
}

@main
enum HostwrightRBACQualificationTool {
  static func main() throws {
    let root = try qualificationRoot()
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    try store.controlIdentities.bootstrap(identity("owner", hash: "a", declaredBy: "owner", bucket: "owner", at: timestamp))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)
    try store.controlIdentities.declare(identity("member", hash: "b", declaredBy: "owner", bucket: "member", at: timestamp))
    try store.controlIdentities.declare(identity("delegate", hash: "c", declaredBy: "owner", bucket: "delegate", at: timestamp))
    let repository = store.rbac
    let engine = RBACAuthorizationEngine(repository: repository)
    let member = subject("member", hash: "b")
    let delegate = subject("delegate", hash: "c")
    _ = try repository.createBinding(
      RBACBindingRecord(
        bindingID: "qualification-viewer", subjectID: "member", roleID: "viewer",
        scope: .init(kind: .global), createdBySubjectID: "owner",
        createdAt: timestamp, updatedAt: timestamp))

    let viewerRead = try engine.authorize(
      subject: member, request: request("status", id: "viewer-read"), at: now)
    let viewerMutation = try engine.authorize(
      subject: member, request: request("start", id: "viewer-mutation"), at: now)
    try repository.deleteBinding(id: "qualification-viewer", expectedGeneration: 1)
    _ = try repository.createBinding(
      RBACBindingRecord(
        bindingID: "qualification-operator", subjectID: "member", roleID: "operator",
        scope: .init(kind: .global), createdBySubjectID: "owner",
        createdAt: timestamp, updatedAt: timestamp))
    let afterRoleChange = try engine.authorize(
      subject: member, request: request("start", id: "role-change"), at: now)

    let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
    _ = try repository.createDelegation(
      RBACDelegationRecord(
        delegationID: "qualification-delegation", delegatorSubjectID: "owner",
        delegateSubjectID: "delegate", roleIDs: ["operator"], delegatedRules: [],
        scope: .init(kind: .global), expiresAt: expiry,
        createdAt: timestamp, updatedAt: timestamp))
    let delegated = try engine.authorize(
      subject: delegate, request: request("start", id: "delegated-before"), at: now)
    _ = try repository.revokeDelegation(
      id: "qualification-delegation", expectedGeneration: 1,
      revokedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(1)))
    let revoked = try engine.authorize(
      subject: delegate, request: request("start", id: "delegated-after"),
      at: now.addingTimeInterval(2))
    let integrity = StateIntegrityService(store: store).inspect()
    guard integrity.health == .healthy,
      viewerRead.effect == .allow, viewerMutation.effect == .deny,
      afterRoleChange.effect == .allow, delegated.effect == .allow, revoked.effect == .deny
    else { throw StateStoreError.transactionInvariantViolation(message: "RBAC live qualification failed.") }
    let ownerCount = try repository.listBindings().filter {
      $0.roleID == "owner" && $0.scope.kind == .global
    }.count
    let result = RBACQualificationResult(
      stateSchemaVersion: try store.schemaVersion(),
      integrityHealth: integrity.health.rawValue,
      roleCount: try repository.listRoles().count,
      initialViewerRead: viewerRead.effect.rawValue,
      initialViewerMutation: viewerMutation.effect.rawValue,
      roleChangeWithoutRestart: afterRoleChange.effect.rawValue,
      delegatedBeforeRevocation: delegated.effect.rawValue,
      delegatedAfterRevocation: revoked.effect.rawValue,
      globalOwnerCount: ownerCount)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
  }

  private static func qualificationRoot() throws -> URL {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--root" else {
      throw StateStoreError.invalidRecord("Usage: hostwright-rbac-qualification --root PATH")
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

  private static func identity(
    _ identifier: String,
    hash: Character,
    declaredBy: String,
    bucket: String,
    at timestamp: String
  ) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: identifier, userID: UInt32(geteuid()),
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q",
        signingIdentifier: "dev.hostwright.rbac-qualification.\(bucket)",
        codeDirectoryHash: String(repeating: String(hash), count: 40),
        validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: timestamp, updatedAt: timestamp)
  }

  private static func subject(_ identifier: String, hash: Character) -> LocalSubject {
    LocalSubject(
      identifier: identifier, userID: UInt32(geteuid()),
      codeIdentityHash: String(repeating: String(hash), count: 40))
  }

  private static func request(_ operation: String, id: String) -> ControlRequestEnvelope {
    ControlRequestEnvelope(
      requestID: id, operation: operation, timeoutMilliseconds: 1_000)
  }
}
