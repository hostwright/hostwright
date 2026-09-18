import Foundation
import HostwrightControlPlane

public struct ControlIdentityBootstrapRequest: Sendable {
  public let expectedIdentities: [ControlPeerIdentityRecord]
  public let userID: UInt32
  public let installer: CodeIdentity
  public let companion: CodeIdentity?
  public let desktop: CodeIdentity?
  public let timestamp: String

  public init(
    expectedIdentities: [ControlPeerIdentityRecord], userID: UInt32,
    installer: CodeIdentity, companion: CodeIdentity? = nil,
    desktop: CodeIdentity? = nil, timestamp: String
  ) {
    self.expectedIdentities = expectedIdentities
    self.userID = userID
    self.installer = installer
    self.companion = companion
    self.desktop = desktop
    self.timestamp = timestamp
  }
}

public extension ControlIdentityRepository {
  func applyBootstrap(_ request: ControlIdentityBootstrapRequest) throws {
    try request.installer.validate()
    try request.companion?.validate()
    try request.desktop?.validate()
    try ControlIdentityValidation.utcTimestamp(request.timestamp, named: "bootstrap timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        let identities = try listIdentities(on: connection)
        guard identities == request.expectedIdentities.sorted(by: { $0.subjectID < $1.subjectID }) else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Bootstrap identity snapshot changed before commit."
          )
        }
        let owner: ControlPeerIdentityRecord
        if identities.isEmpty {
          let subjectID = "owner-\(request.userID)-\(request.installer.codeDirectoryHash.prefix(16))"
          owner = ControlPeerIdentityRecord(
            subjectID: subjectID, userID: request.userID, codeIdentity: request.installer,
            declaredBySubjectID: subjectID, declaredAt: request.timestamp, updatedAt: request.timestamp
          )
          try bootstrap(owner, on: connection)
        } else {
          owner = try resolveBootstrapIdentity(
            request.installer, userID: request.userID, declaringSubjectID: nil,
            timestamp: request.timestamp, on: connection
          )
        }
        let rbac = RBACRepository(store: store)
        try rbac.bootstrapDefaultRolesAndOwner(
          subjectID: owner.subjectID, timestamp: request.timestamp, on: connection
        )
        if let companion = request.companion {
          _ = try resolveBootstrapIdentity(
            companion, userID: request.userID, declaringSubjectID: owner.subjectID,
            timestamp: request.timestamp, allowInitialDeclaration: identities.isEmpty, on: connection
          )
        }
        if let desktop = request.desktop {
          let declared = try resolveBootstrapIdentity(
            desktop, userID: request.userID, declaringSubjectID: owner.subjectID,
            timestamp: request.timestamp, allowInitialDeclaration: identities.isEmpty, on: connection
          )
          try rbac.ensureBootstrapOperatorBinding(
            subjectID: declared.subjectID, ownerSubjectID: owner.subjectID,
            timestamp: request.timestamp, on: connection
          )
        }
      }
    }
  }
}

extension ControlIdentityRepository {
  private func resolveBootstrapIdentity(
    _ current: CodeIdentity, userID: UInt32, declaringSubjectID: String?, timestamp: String,
    allowInitialDeclaration: Bool = false, on connection: SQLiteConnection
  ) throws -> ControlPeerIdentityRecord {
    let identities = try listIdentities(on: connection)
    let exact = identities.filter {
      $0.userID == userID && $0.revokedAt == nil && $0.codeIdentity == current
    }
    guard exact.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(message: "The exact active control identity is ambiguous.")
    }
    if let existing = exact.first { return existing }
    guard current.validationMode == .installedRequirement || allowInitialDeclaration else {
      throw StateStoreError.invalidRecord("The ad-hoc bootstrap identity is not an active declared identity.")
    }
    let bucket = identities.filter {
      $0.userID == userID && $0.revokedAt == nil
        && $0.codeIdentity.validationMode == .installedRequirement
        && $0.codeIdentity.teamIdentifier == current.teamIdentifier
        && $0.codeIdentity.signingIdentifier == current.signingIdentifier
    }
    guard bucket.count <= 1 else {
      throw StateStoreError.transactionInvariantViolation(message: "The installed control identity bucket is ambiguous.")
    }
    if let existing = bucket.first {
      return try rotateInstalledCodeIdentity(
        subjectID: existing.subjectID, expectedGeneration: existing.generation,
        replacement: current, updatedAt: timestamp, on: connection
      )
    }
    guard let declaringSubjectID else {
      throw StateStoreError.invalidRecord("The installing process is not an active declared control identity.")
    }
    let declared = ControlPeerIdentityRecord(
      subjectID: "bootstrap-companion-\(userID)-\(current.codeDirectoryHash.prefix(16))",
      userID: userID, codeIdentity: current, declaredBySubjectID: declaringSubjectID,
      declaredAt: timestamp, updatedAt: timestamp
    )
    try declare(declared, on: connection)
    return declared
  }
}
