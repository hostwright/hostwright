import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import HostwrightCore

final class QualificationExportVerifierTests: XCTestCase {
  func testBindsPrivateRegularOutputToReceiptBytesAndDigest() throws {
    try withRoot { root in
      let output = root.appendingPathComponent("metrics.json")
      let data = Data("{\"kind\":\"hostwright.metrics.snapshot\"}\n".utf8)
      try data.write(to: output)
      XCTAssertEqual(chmod(output.path, 0o600), 0)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

      XCTAssertEqual(
        try QualificationExportVerifier.verify(
          path: output.path,
          expectedSHA256: digest,
          expectedBytes: UInt64(data.count)
        ),
        QualificationExportVerification(
          data: data,
          sha256: digest,
          bytes: UInt64(data.count)
        )
      )
    }
  }

  func testRejectsReceiptMismatchUnsafeModesAndSymlinks() throws {
    try withRoot { root in
      let output = root.appendingPathComponent("metrics.json")
      let data = Data("{}\n".utf8)
      try data.write(to: output)
      XCTAssertEqual(chmod(output.path, 0o600), 0)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

      XCTAssertThrowsError(try QualificationExportVerifier.verify(
        path: output.path,
        expectedSHA256: String(repeating: "0", count: 64),
        expectedBytes: UInt64(data.count)
      )) { error in
        XCTAssertEqual(error as? QualificationExportVerificationError, .receiptMismatch)
      }
      XCTAssertThrowsError(try QualificationExportVerifier.verify(
        path: output.path,
        expectedSHA256: digest,
        expectedBytes: UInt64(data.count + 1)
      ))
      XCTAssertThrowsError(try QualificationExportVerifier.verify(
        path: output.path + "/.",
        expectedSHA256: digest,
        expectedBytes: UInt64(data.count)
      )) { error in
        XCTAssertEqual(error as? QualificationExportVerificationError, .invalidExpectation)
      }

      let physicalAlias = output.standardizedFileURL.path
      XCTAssertNotEqual(physicalAlias, output.path)
      XCTAssertThrowsError(try QualificationExportVerifier.verify(
        path: physicalAlias,
        expectedSHA256: digest,
        expectedBytes: UInt64(data.count)
      )) { error in
        XCTAssertEqual(error as? QualificationExportVerificationError, .unsafeParent)
      }

      XCTAssertEqual(chmod(output.path, 0o644), 0)
      XCTAssertThrowsError(try QualificationExportVerifier.verify(
        path: output.path,
        expectedSHA256: digest,
        expectedBytes: UInt64(data.count)
      ))
      XCTAssertEqual(chmod(output.path, 0o600), 0)

      let link = root.appendingPathComponent("link.json")
      XCTAssertEqual(symlink(output.path, link.path), 0)
      XCTAssertThrowsError(try QualificationExportVerifier.verify(
        path: link.path,
        expectedSHA256: digest,
        expectedBytes: UInt64(data.count)
      ))
    }
  }

  func testRejectsAccessGrantingACLsOnPinnedParentAndOutput() throws {
    try withRoot { root in
      let output = root.appendingPathComponent("metrics.json")
      let data = Data("{}\n".utf8)
      try data.write(to: output)
      XCTAssertEqual(chmod(output.path, 0o600), 0)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      try setEveryoneReadACL(on: root.path)

      XCTAssertThrowsError(try QualificationExportVerifier.verify(
        path: output.path,
        expectedSHA256: digest,
        expectedBytes: UInt64(data.count)
      )) { error in
        XCTAssertEqual(error as? QualificationExportVerificationError, .unsafeParent)
      }
    }

    try withRoot { root in
      let receipt = root.appendingPathComponent("qualification.metrics-export-v1.json")
      try Data("{}\n".utf8).write(to: receipt)
      XCTAssertEqual(chmod(receipt.path, 0o600), 0)
      try setEveryoneReadACL(on: receipt.path)

      XCTAssertThrowsError(try QualificationExportVerifier.readPrivate(
        path: receipt.path
      )) { error in
        XCTAssertEqual(error as? QualificationExportVerificationError, .unsafeOutput)
      }
    }
  }

  func testSemanticDecodeUsesDescriptorPinnedBytesAfterPathReplacement() throws {
    struct Identity: Decodable, Equatable {
      let kind: String
      let traceSHA256: String
    }
    try withRoot { root in
      let output = root.appendingPathComponent("trace.json")
      let expectedIdentity = Identity(
        kind: "hostwright.trace",
        traceSHA256: String(repeating: "a", count: 64))
      let original = Data(
        "{\"kind\":\"hostwright.trace\",\"traceSHA256\":\"\(expectedIdentity.traceSHA256)\"}\n".utf8)
      try original.write(to: output)
      XCTAssertEqual(chmod(output.path, 0o600), 0)
      let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()

      let verified = try QualificationExportVerifier.verify(
        path: output.path,
        expectedSHA256: digest,
        expectedBytes: UInt64(original.count)
      )
      try FileManager.default.removeItem(at: output)
      let replacementIdentity = Identity(
        kind: "attacker",
        traceSHA256: String(repeating: "b", count: 64))
      let replacement = Data(
        "{\"kind\":\"\(replacementIdentity.kind)\",\"traceSHA256\":\"\(replacementIdentity.traceSHA256)\"}\n".utf8)
      try replacement.write(to: output)
      XCTAssertEqual(chmod(output.path, 0o600), 0)

      let verifiedIdentity = try JSONDecoder().decode(Identity.self, from: verified.data)
      XCTAssertEqual(verifiedIdentity, expectedIdentity)
      XCTAssertNotEqual(verifiedIdentity, replacementIdentity)
      XCTAssertNotEqual(verified.data, replacement)
    }
  }

  private func withRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-export-verifier-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    guard let canonical = realpath(root.path, nil) else {
      throw QualificationExportVerificationError.unsafeParent
    }
    defer { free(canonical) }
    try body(URL(fileURLWithPath: String(cString: canonical), isDirectory: true))
  }

  private func setEveryoneReadACL(on path: String) throws {
    let text = """
    !#acl 1
    group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read

    """
    guard let accessControlList = acl_from_text(text) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
    guard acl_set_file(path, ACL_TYPE_EXTENDED, accessControlList) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
