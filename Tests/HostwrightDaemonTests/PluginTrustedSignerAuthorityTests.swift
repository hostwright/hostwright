import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightDaemon

final class PluginTrustedSignerAuthorityTests: XCTestCase {
  func testProductionAuthorityIsFixedOutsideCurrentUserApplicationSupport() {
    XCTAssertEqual(
      PluginTrustedSignerAuthority.systemDirectoryURL.path,
      "/Library/Application Support/Hostwright/plugin-trusted-signers-v1")
  }

  func testLoadsCanonicalOwnerPrivateDaemonSignerAuthority() throws {
    try withRoot { root in
      let certificate = try makeCertificate(in: root)
      let digest = sha256(certificate)
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try writePrivate(certificate, to: authority.appendingPathComponent("\(digest).der"))
      try writeManifest(
        PluginTrustedSignerManifest(
          schemaVersion: 1, kind: "hostwright.plugin.trusted-signers",
          signers: [.init(
            identifier: "dev.hostwright.plugin-signer",
            certificateSHA256: [digest])]),
        to: authority)

      XCTAssertEqual(
        try PluginTrustedSignerAuthority.loadForTesting(
          directoryURL: authority,
          owner: geteuid()),
        ["dev.hostwright.plugin-signer": [certificate]])
    }
  }

  func testAbsentAuthorityFailsClosedForPluginTrustWithoutCreatingUserState() throws {
    try withRoot { root in
      let authority = authorityDirectory(in: root)
      XCTAssertEqual(
        try PluginTrustedSignerAuthority.loadForTesting(
          directoryURL: authority,
          owner: geteuid()),
        [:])
      XCTAssertFalse(FileManager.default.fileExists(atPath: authority.path))
    }
  }

  func testRejectsUnsafeManifestCertificateAndUnexpectedInventory() throws {
    try withRoot { root in
      let certificate = try makeCertificate(in: root)
      let digest = sha256(certificate)
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let certificateURL = authority.appendingPathComponent("\(digest).der")
      try writePrivate(certificate, to: certificateURL)
      try writeManifest(
        PluginTrustedSignerManifest(
          schemaVersion: 1, kind: "hostwright.plugin.trusted-signers",
          signers: [.init(
            identifier: "dev.hostwright.plugin-signer",
            certificateSHA256: [digest])]),
        to: authority)

      XCTAssertEqual(chmod(certificateURL.path, 0o664), 0)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
      XCTAssertEqual(chmod(certificateURL.path, 0o644), 0)

      let original = root.appendingPathComponent("original.der")
      try certificate.write(to: original)
      try FileManager.default.removeItem(at: certificateURL)
      XCTAssertEqual(symlink(original.path, certificateURL.path), 0)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
      try FileManager.default.removeItem(at: certificateURL)
      try writePrivate(certificate, to: certificateURL)

      try writePrivate(Data("unexpected".utf8), to: authority.appendingPathComponent("extra.txt"))
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
    }
  }

  func testRejectsNonCanonicalOrOversizedAuthorityManifest() throws {
    try withRoot { root in
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let manifest = authority.appendingPathComponent(PluginTrustedSignerAuthority.manifestName)
      try writePrivate(
        Data("{\"kind\":\"hostwright.plugin.trusted-signers\",\"schemaVersion\":1,\"signers\":[]}".utf8),
        to: manifest)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))

      try FileManager.default.removeItem(at: manifest)
      try writePrivate(
        Data(repeating: 0x41, count: PluginTrustedSignerAuthority.maximumTotalBytes + 1),
        to: manifest)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
    }
  }

  func testRejectsAuthorityDirectoryWithNonAuthorityOwnerOrWritableMode() throws {
    try withRoot { root in
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])

      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: 0))
      XCTAssertEqual(chmod(authority.path, 0o770), 0)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
    }
  }

  func testRejectsMutableParentUnreadableFinalAndDirectorySymlink() throws {
    try withRoot { root in
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])

      XCTAssertEqual(chmod(root.path, 0o770), 0)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
      XCTAssertEqual(chmod(root.path, 0o700), 0)

      XCTAssertEqual(chmod(authority.path, 0o000), 0)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
      XCTAssertEqual(chmod(authority.path, 0o700), 0)

      let link = root.appendingPathComponent("authority-link", isDirectory: true)
      XCTAssertEqual(symlink(authority.path, link.path), 0)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: link,
        owner: geteuid()))
    }
  }

  func testRejectsPresentPartialAuthorityAndAccessGrantingACLs() throws {
    try withRoot { root in
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))

      let certificate = try makeCertificate(in: root)
      let digest = sha256(certificate)
      try writeManifest(
        PluginTrustedSignerManifest(
          schemaVersion: 1, kind: "hostwright.plugin.trusted-signers",
          signers: [.init(
            identifier: "dev.hostwright.plugin-signer",
            certificateSHA256: [digest])]),
        to: authority)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))

      try FileManager.default.removeItem(
        at: authority.appendingPathComponent(PluginTrustedSignerAuthority.manifestName))
      try writePrivate(certificate, to: authority.appendingPathComponent("\(digest).der"))
      try writeManifest(
        PluginTrustedSignerManifest(
          schemaVersion: 1, kind: "hostwright.plugin.trusted-signers",
          signers: [.init(
            identifier: "dev.hostwright.plugin-signer",
            certificateSHA256: [digest])]),
        to: authority)
      try setEveryoneReadACL(
        on: authority.appendingPathComponent("\(digest).der").path)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
    }

    try withRoot { root in
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try setEveryoneReadACL(on: authority.path)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
    }
  }

  func testLoadsStableMultiCertificateRotationForOneSigner() throws {
    try withRoot { root in
      let first = try makeCertificate(in: root, label: "first")
      let second = try makeCertificate(in: root, label: "second")
      let certificatesByDigest = [sha256(first): first, sha256(second): second]
      let digests = certificatesByDigest.keys.sorted()
      let authority = authorityDirectory(in: root)
      try FileManager.default.createDirectory(
        at: authority, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755])
      for digest in digests {
        try writePrivate(
          try XCTUnwrap(certificatesByDigest[digest]),
          to: authority.appendingPathComponent("\(digest).der"))
      }
      try writeManifest(
        PluginTrustedSignerManifest(
          schemaVersion: 1, kind: "hostwright.plugin.trusted-signers",
          signers: [.init(
            identifier: "dev.hostwright.plugin-signer",
            certificateSHA256: digests)]),
        to: authority)

      XCTAssertEqual(
        try PluginTrustedSignerAuthority.loadForTesting(
          directoryURL: authority,
          owner: geteuid()),
        ["dev.hostwright.plugin-signer": try digests.map {
          try XCTUnwrap(certificatesByDigest[$0])
        }])
    }
  }

  func testRejectsFileOwnerMismatchThroughDescriptorPinnedReader() throws {
    try withRoot { root in
      let certificate = root.appendingPathComponent(
        "\(String(repeating: "a", count: 64)).der")
      try writePrivate(Data("not-a-certificate".utf8), to: certificate)

      XCTAssertThrowsError(try PluginTrustedSignerAuthority.readFileForTesting(
        at: certificate,
        owner: geteuid() &+ 1))
    }
  }

  func testRejectsExtraSymlinkAndDirectoryInventory() throws {
    try withRoot { root in
      let authority = try prepareAuthority(in: root)
      let target = root.appendingPathComponent("outside-authority")
      try Data("outside\n".utf8).write(to: target)
      let link = authority.appendingPathComponent("unexpected-link")
      XCTAssertEqual(symlink(target.path, link.path), 0)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
      try FileManager.default.removeItem(at: link)

      try FileManager.default.createDirectory(
        at: authority.appendingPathComponent("unexpected-directory", isDirectory: true),
        withIntermediateDirectories: false)
      XCTAssertThrowsError(try PluginTrustedSignerAuthority.loadForTesting(
        directoryURL: authority,
        owner: geteuid()))
    }
  }

  private func authorityDirectory(in root: URL) -> URL {
    root.appendingPathComponent(
      PluginTrustedSignerAuthority.directoryName,
      isDirectory: true)
  }

  private func prepareAuthority(in root: URL) throws -> URL {
    let certificate = try makeCertificate(in: root)
    let digest = sha256(certificate)
    let authority = authorityDirectory(in: root)
    try FileManager.default.createDirectory(
      at: authority, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try writePrivate(certificate, to: authority.appendingPathComponent("\(digest).der"))
    try writeManifest(
      PluginTrustedSignerManifest(
        schemaVersion: 1, kind: "hostwright.plugin.trusted-signers",
        signers: [.init(
          identifier: "dev.hostwright.plugin-signer",
          certificateSHA256: [digest])]),
      to: authority)
    return authority
  }

  private func writeManifest(
    _ manifest: PluginTrustedSignerManifest,
    to authority: URL
  ) throws {
    try writePrivate(
      try ControlPlaneCanonicalJSON.encode(manifest),
      to: authority.appendingPathComponent(PluginTrustedSignerAuthority.manifestName))
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    XCTAssertEqual(chmod(url.path, 0o644), 0)
  }

  private func makeCertificate(
    in root: URL,
    label: String = "test"
  ) throws -> Data {
    let key = root.appendingPathComponent("\(label)-key.pem")
    let pem = root.appendingPathComponent("\(label)-certificate.pem")
    let der = root.appendingPathComponent("\(label)-certificate.der")
    try runOpenSSL([
      "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", key.path, "-out", pem.path,
      "-subj", "/CN=Hostwright Plugin Authority Test", "-days", "1", "-sha256",
    ])
    try runOpenSSL([
      "x509", "-in", pem.path, "-outform", "DER", "-out", der.path,
    ])
    return try Data(contentsOf: der)
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

  private func runOpenSSL(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.environment = [:]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func withRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".hostwright-plugin-authority-test-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    guard let canonical = realpath(root.path, nil) else {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    defer { free(canonical) }
    try body(URL(fileURLWithPath: String(cString: canonical), isDirectory: true))
  }
}
