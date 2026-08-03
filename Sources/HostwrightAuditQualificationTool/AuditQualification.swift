import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightState

enum AuditQualificationError: String, Error, Equatable {
  case invalidArguments
  case invalidStatePath
  case unsafeStateParent
  case unsafeStateFile
  case invalidKeychainService
  case statePreparationFailed
  case auditFailed
  case invalidResult
  case resultTooLarge
}

struct AuditQualificationCommand: Equatable {
  let stateDatabasePath: String
  let keychainService: String

  static func parse(_ arguments: [String]) throws -> Self {
    guard arguments.count == 4,
      arguments[0] == "--state-db",
      arguments[2] == "--keychain-service"
    else { throw AuditQualificationError.invalidArguments }
    let path = try validatedStateDatabasePath(arguments[1])
    let service = try validatedKeychainService(arguments[3])
    return Self(stateDatabasePath: path, keychainService: service)
  }
}

struct AuditQualificationResult: Codable, Equatable {
  let qualification: String
  let health: String
  let stateSchema: Int
  let recordCount: UInt64
  let segmentCount: UInt64
  let exportBytes: Int
  let exportSHA256: String
  let activeKeyID: String

  func canonicalJSON() throws -> Data {
    guard qualification == "phase09-gate4-live-v1",
      health == "healthy",
      stateSchema == HostwrightContractVersions.stateSchema,
      recordCount >= 3,
      segmentCount >= 3,
      exportBytes > 0,
      exportSHA256.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
      !activeKeyID.isEmpty,
      activeKeyID.utf8.count <= 256
    else { throw AuditQualificationError.invalidResult }
    let data = try ControlPlaneCanonicalJSON.encode(self)
    guard data.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
      throw AuditQualificationError.resultTooLarge
    }
    return data
  }
}

enum AuditQualificationRunner {
  static func run(_ command: AuditQualificationCommand) throws -> Data {
    let store = SQLiteStateStore(path: command.stateDatabasePath)
    do {
      try store.migrate()
      try store.validateSchema()
      guard try store.schemaVersion() == HostwrightContractVersions.stateSchema else {
        throw AuditQualificationError.statePreparationFailed
      }
    } catch let error as AuditQualificationError {
      throw error
    } catch {
      throw AuditQualificationError.statePreparationFailed
    }

    let keyStore: MacOSAuditSigningKeyStore
    do {
      keyStore = try MacOSAuditSigningKeyStore(service: command.keychainService)
    } catch {
      throw AuditQualificationError.invalidKeychainService
    }
    defer { try? keyStore.removeOwnedItems() }

    do {
      let trail = TamperEvidentAuditTrail(store: store, keyStore: keyStore)
      _ = try trail.append(
        AuditAppendInput(
          subjectID: "qualification-owner",
          requestID: "qualification-request-1",
          target: "audit-qualification",
          action: .request,
          outcome: "accepted",
          reasonCode: "requestAccepted",
          payloadDigest: digest("request")
        )
      )
      _ = try trail.append(
        AuditAppendInput(
          subjectID: "qualification-owner",
          requestID: "qualification-request-1",
          target: "audit-qualification",
          action: .authorization,
          outcome: "allowed",
          reasonCode: "authorizationAllowed",
          payloadDigest: digest("authorization")
        )
      )
      _ = try trail.rotateSigningKey()
      _ = try trail.append(
        AuditAppendInput(
          subjectID: "qualification-owner",
          requestID: "qualification-request-1",
          target: "audit-qualification",
          action: .operation,
          outcome: "completed",
          reasonCode: "operationCompleted",
          operationRef: "operation:qualification-1",
          payloadDigest: digest("operation")
        )
      )
      let report = trail.verify()
      guard report.health == .healthy,
        report.recordCount >= 3,
        report.segmentCount >= 3,
        let activeKeyID = report.activeKeyID
      else { throw AuditQualificationError.auditFailed }
      let export = try trail.exportVerified()
      let result = AuditQualificationResult(
        qualification: "phase09-gate4-live-v1",
        health: report.health.rawValue,
        stateSchema: HostwrightContractVersions.stateSchema,
        recordCount: report.recordCount,
        segmentCount: report.segmentCount,
        exportBytes: export.count,
        exportSHA256: digest(export),
        activeKeyID: activeKeyID
      )
      return try result.canonicalJSON()
    } catch let error as AuditQualificationError {
      throw error
    } catch {
      throw AuditQualificationError.auditFailed
    }
  }
}

private func validatedStateDatabasePath(_ value: String) throws -> String {
  guard value.hasPrefix("/"), !value.contains("\0") else {
    throw AuditQualificationError.invalidStatePath
  }
  let fileURL = URL(fileURLWithPath: value)
  let parent = fileURL.deletingLastPathComponent().path
  let name = fileURL.lastPathComponent
  guard !parent.isEmpty, parent != value, !name.isEmpty, name != ".", name != ".." else {
    throw AuditQualificationError.invalidStatePath
  }
  let canonicalParent = try canonicalPrivateDirectory(parent)
  let canonicalPath = canonicalParent == "/" ? "/\(name)" : "\(canonicalParent)/\(name)"
  guard value == canonicalPath else { throw AuditQualificationError.invalidStatePath }

  var metadata = stat()
  if lstat(value, &metadata) == 0 {
    guard (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      (metadata.st_mode & 0o7777) == 0o600,
      metadata.st_nlink == 1
    else { throw AuditQualificationError.unsafeStateFile }
  } else if errno != ENOENT {
    throw AuditQualificationError.invalidStatePath
  }
  return canonicalPath
}

private func canonicalPrivateDirectory(_ path: String) throws -> String {
  guard path.hasPrefix("/") else { throw AuditQualificationError.invalidStatePath }
  guard let resolved = realpath(path, nil) else { throw AuditQualificationError.invalidStatePath }
  defer { free(resolved) }
  let canonical = String(cString: resolved)
  guard canonical == path else { throw AuditQualificationError.invalidStatePath }
  var metadata = stat()
  guard lstat(canonical, &metadata) == 0,
    (metadata.st_mode & S_IFMT) == S_IFDIR,
    metadata.st_uid == geteuid(),
    (metadata.st_mode & 0o7777) == 0o700
  else { throw AuditQualificationError.unsafeStateParent }
  return canonical
}

private func validatedKeychainService(_ value: String) throws -> String {
  guard value.range(
    of: "^dev\\.hostwright\\.audit\\.qualification\\.[a-f0-9]{16}$",
    options: .regularExpression
  ) != nil else { throw AuditQualificationError.invalidKeychainService }
  return value
}

private func digest(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func digest(_ value: String) -> String {
  digest(Data(value.utf8))
}
