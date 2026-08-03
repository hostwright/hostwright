import Darwin
import Foundation
import XCTest

@testable import HostwrightAuditQualificationTool

final class AuditQualificationTests: XCTestCase {
  func testParseAcceptsExactArgumentsWithPrivateCanonicalParent() throws {
    let directory = try makePrivateDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let statePath = directory + "/state.sqlite"
    let command = try AuditQualificationCommand.parse([
      "--state-db", statePath,
      "--keychain-service", "dev.hostwright.audit.qualification.0123456789abcdef",
    ])
    XCTAssertEqual(command.stateDatabasePath, statePath)
    XCTAssertEqual(command.keychainService, "dev.hostwright.audit.qualification.0123456789abcdef")
  }

  func testParseRejectsUnexpectedArgumentsAndUnsafeInputs() throws {
    XCTAssertThrowsError(try AuditQualificationCommand.parse([]))
    XCTAssertThrowsError(try AuditQualificationCommand.parse([
      "--keychain-service", "dev.hostwright.audit.qualification.0123456789abcdef",
      "--state-db", "/tmp/state.sqlite",
    ]))
    XCTAssertThrowsError(try AuditQualificationCommand.parse([
      "--state-db", "/tmp/state.sqlite",
      "--keychain-service", "dev.hostwright.audit.v1.0123456789abcdef",
    ]))
  }

  func testResultProducesBoundedCanonicalJSON() throws {
    let result = AuditQualificationResult(
      qualification: "phase09-gate4-live-v1",
      health: "healthy",
      stateSchema: 19,
      recordCount: 3,
      segmentCount: 3,
      exportBytes: 512,
      exportSHA256: "sha256:" + String(repeating: "a", count: 64),
      activeKeyID: "p256:qualification"
    )
    let data = try result.canonicalJSON()
    XCTAssertEqual(try JSONDecoder().decode(AuditQualificationResult.self, from: data), result)
    XCTAssertEqual(data, try result.canonicalJSON())
  }

  func testResultRejectsIncompleteEvidence() {
    let result = AuditQualificationResult(
      qualification: "phase09-gate4-live-v1",
      health: "healthy",
      stateSchema: 19,
      recordCount: 3,
      segmentCount: 3,
      exportBytes: 0,
      exportSHA256: "sha256:" + String(repeating: "a", count: 64),
      activeKeyID: "p256:qualification"
    )
    XCTAssertThrowsError(try result.canonicalJSON())
  }

  private func makePrivateDirectory() throws -> String {
    let temporaryDirectory = FileManager.default.temporaryDirectory.path
    guard let resolved = realpath(temporaryDirectory, nil) else {
      throw POSIXError(.ENOENT)
    }
    defer { free(resolved) }
    let directory = String(cString: resolved) + "/hostwright-audit-qualification-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    return directory
  }
}
