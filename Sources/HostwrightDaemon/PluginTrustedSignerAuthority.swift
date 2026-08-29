import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import Security

struct PluginTrustedSignerManifest: Codable, Equatable, Sendable {
  struct Signer: Codable, Equatable, Sendable {
    let identifier: String
    let certificateSHA256: [String]
  }

  let schemaVersion: Int
  let kind: String
  let signers: [Signer]
}

enum PluginTrustedSignerAuthorityError: Error, Equatable, Sendable {
  case unsafeDirectory
  case unsafeManifest
  case unsafeCertificate
}

enum PluginTrustedSignerAuthority {
  static let directoryName = "plugin-trusted-signers-v1"
  static let systemDirectoryURL = URL(
    fileURLWithPath: "/Library/Application Support/Hostwright",
    isDirectory: true
  ).appendingPathComponent(directoryName, isDirectory: true)
  static let manifestName = "authority-v1.json"
  static let maximumSigners = 64
  static let maximumCertificatesPerSigner = 8
  static let maximumCertificateBytes = 64 * 1_024
  static let maximumTotalBytes = 1 * 1_024 * 1_024

  static func load() throws -> [String: [Data]] {
    try load(directoryURL: systemDirectoryURL, owner: 0)
  }

  #if DEBUG
  static func loadForTesting(
    directoryURL: URL,
    owner: uid_t
  ) throws -> [String: [Data]] {
    try load(directoryURL: directoryURL, owner: owner)
  }

  static func readFileForTesting(
    at url: URL,
    owner: uid_t,
    maximumBytes: Int = maximumCertificateBytes
  ) throws -> Data {
    let directoryURL = url.deletingLastPathComponent()
    let descriptor = open(
      directoryURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    defer { close(descriptor) }
    return try readPrivateFile(
      named: url.lastPathComponent,
      in: descriptor,
      displayURL: url,
      owner: owner,
      maximumBytes: maximumBytes
    )
  }
  #endif

  private static func load(
    directoryURL: URL,
    owner: uid_t
  ) throws -> [String: [Data]] {
    guard directoryURL.path.hasPrefix("/"),
      URL(fileURLWithPath: directoryURL.path, isDirectory: true).standardizedFileURL.path
        == directoryURL.path
    else { throw PluginTrustedSignerAuthorityError.unsafeDirectory }
    var named = stat()
    if lstat(directoryURL.path, &named) != 0 {
      if errno == ENOENT {
        try validateNearestExistingParent(
          of: directoryURL.deletingLastPathComponent(),
          owner: owner
        )
        return [:]
      }
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    try validateDirectoryChain(directoryURL, owner: owner)
    let directoryDescriptor = open(
      directoryURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard directoryDescriptor >= 0 else {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    defer { close(directoryDescriptor) }
    var opened = stat()
    guard fstat(directoryDescriptor, &opened) == 0,
      (opened.st_mode & S_IFMT) == S_IFDIR,
      opened.st_uid == owner,
      opened.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISVTX) == 0
    else { throw PluginTrustedSignerAuthorityError.unsafeDirectory }
    do {
      try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
        fileDescriptor: directoryDescriptor,
        path: directoryURL.path,
        role: "plugin trusted-signer authority"
      )
    } catch {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    let entries = try entryNames(in: directoryDescriptor)
    guard !entries.isEmpty else {
      throw PluginTrustedSignerAuthorityError.unsafeManifest
    }
    guard entries.contains(manifestName) else {
      throw PluginTrustedSignerAuthorityError.unsafeManifest
    }
    let manifestData = try readPrivateFile(
      named: manifestName,
      in: directoryDescriptor,
      displayURL: directoryURL.appendingPathComponent(manifestName),
      owner: owner,
      maximumBytes: maximumTotalBytes
    )
    try validateJSONObject(
      manifestData,
      expectedKeys: ["kind", "schemaVersion", "signers"]
    )
    let manifest: PluginTrustedSignerManifest
    do {
      manifest = try JSONDecoder().decode(PluginTrustedSignerManifest.self, from: manifestData)
    } catch {
      throw PluginTrustedSignerAuthorityError.unsafeManifest
    }
    guard manifest.schemaVersion == 1,
      manifest.kind == "hostwright.plugin.trusted-signers",
      !manifest.signers.isEmpty,
      manifest.signers.count <= maximumSigners,
      manifest.signers == manifest.signers.sorted(by: { $0.identifier < $1.identifier }),
      Set(manifest.signers.map(\.identifier)).count == manifest.signers.count,
      try ControlPlaneCanonicalJSON.encode(manifest) == manifestData
    else { throw PluginTrustedSignerAuthorityError.unsafeManifest }

    var expectedFiles: Set<String> = [manifestName]
    var certificatesByDigest = [String: Data]()
    var result = [String: [Data]]()
    var totalBytes = manifestData.count
    for signer in manifest.signers {
      guard signer.identifier.range(
        of: "^[A-Za-z0-9._-]{1,256}$",
        options: .regularExpression
      ) != nil,
        !signer.certificateSHA256.isEmpty,
        signer.certificateSHA256.count <= maximumCertificatesPerSigner,
        signer.certificateSHA256 == signer.certificateSHA256.sorted(),
        Set(signer.certificateSHA256).count == signer.certificateSHA256.count,
        signer.certificateSHA256.allSatisfy({
          $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        })
      else { throw PluginTrustedSignerAuthorityError.unsafeManifest }

      var signerCertificates = [Data]()
      for digest in signer.certificateSHA256 {
        let name = "\(digest).der"
        expectedFiles.insert(name)
        let certificate: Data
        if let loaded = certificatesByDigest[digest] {
          certificate = loaded
        } else {
          certificate = try readPrivateFile(
            named: name,
            in: directoryDescriptor,
            displayURL: directoryURL.appendingPathComponent(name),
            owner: owner,
            maximumBytes: maximumCertificateBytes
          )
          totalBytes += certificate.count
          guard totalBytes <= maximumTotalBytes,
            SHA256.hash(data: certificate).map({ String(format: "%02x", $0) }).joined()
              == digest,
            SecCertificateCreateWithData(nil, certificate as CFData) != nil
          else { throw PluginTrustedSignerAuthorityError.unsafeCertificate }
          certificatesByDigest[digest] = certificate
        }
        signerCertificates.append(certificate)
      }
      result[signer.identifier] = signerCertificates
    }
    guard Set(entries) == expectedFiles else {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    var completed = stat()
    guard fstat(directoryDescriptor, &completed) == 0,
      opened.st_dev == completed.st_dev,
      opened.st_ino == completed.st_ino,
      opened.st_uid == completed.st_uid,
      opened.st_mode == completed.st_mode,
      opened.st_nlink == completed.st_nlink,
      opened.st_mtimespec.tv_sec == completed.st_mtimespec.tv_sec,
      opened.st_mtimespec.tv_nsec == completed.st_mtimespec.tv_nsec,
      opened.st_ctimespec.tv_sec == completed.st_ctimespec.tv_sec,
      opened.st_ctimespec.tv_nsec == completed.st_ctimespec.tv_nsec
    else { throw PluginTrustedSignerAuthorityError.unsafeDirectory }
    return result
  }

  private static func validateDirectoryChain(_ url: URL, owner: uid_t) throws {
    guard let resolved = realpath(url.path, nil) else {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    defer { free(resolved) }
    guard String(cString: resolved) == url.path else {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    try validateDirectory(path: "/", owner: owner)
    var current = "/"
    for component in url.path.split(separator: "/") {
      current = URL(fileURLWithPath: current, isDirectory: true)
        .appendingPathComponent(String(component), isDirectory: true).path
      try validateDirectory(path: current, owner: owner)
    }
    var authority = stat()
    guard lstat(url.path, &authority) == 0,
      authority.st_uid == owner,
      authority.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISVTX) == 0
    else { throw PluginTrustedSignerAuthorityError.unsafeDirectory }
  }

  private static func entryNames(in directoryDescriptor: Int32) throws -> [String] {
    let duplicate = dup(directoryDescriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { close(duplicate) }
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    defer { closedir(directory) }
    var entries = [String]()
    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(
          to: CChar.self,
          capacity: Int(MAXNAMLEN) + 1
        ) { String(validatingCString: $0) }
      }
      guard let name else {
        throw PluginTrustedSignerAuthorityError.unsafeDirectory
      }
      if name == "." || name == ".." { continue }
      entries.append(name)
      errno = 0
    }
    guard errno == 0 else {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
    return entries.sorted()
  }

  private static func validateNearestExistingParent(
    of directoryURL: URL,
    owner: uid_t
  ) throws {
    var candidate = directoryURL
    while candidate.path != "/" {
      var metadata = stat()
      if lstat(candidate.path, &metadata) == 0 {
        try validateDirectoryChain(candidate, owner: owner)
        return
      }
      guard errno == ENOENT else {
        throw PluginTrustedSignerAuthorityError.unsafeDirectory
      }
      candidate.deleteLastPathComponent()
    }
    try validateDirectoryChain(candidate, owner: owner)
  }

  private static func validateDirectory(path: String, owner: uid_t) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == 0 || metadata.st_uid == owner,
      metadata.st_mode & (S_ISUID | S_ISGID) == 0,
      metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISVTX) == 0
    else { throw PluginTrustedSignerAuthorityError.unsafeDirectory }
    do {
      try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
        atPath: path,
        role: "plugin trusted-signer authority"
      )
    } catch {
      throw PluginTrustedSignerAuthorityError.unsafeDirectory
    }
  }

  private static func readPrivateFile(
    named name: String,
    in directoryDescriptor: Int32,
    displayURL: URL,
    owner: uid_t,
    maximumBytes: Int
  ) throws -> Data {
    guard name.range(
      of: "^(authority-v1\\.json|[a-f0-9]{64}\\.der)$",
      options: .regularExpression
    ) != nil else { throw PluginTrustedSignerAuthorityError.unsafeCertificate }
    var named = stat()
    guard name.withCString({
      fstatat(directoryDescriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
    }) == 0,
      (named.st_mode & S_IFMT) == S_IFREG,
      named.st_uid == owner,
      named.st_nlink == 1,
      named.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISVTX
        | S_IXUSR | S_IXGRP | S_IXOTH) == 0
    else { throw PluginTrustedSignerAuthorityError.unsafeCertificate }
    let descriptor = name.withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw PluginTrustedSignerAuthorityError.unsafeCertificate
    }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == owner,
      before.st_nlink == 1,
      before.st_dev == named.st_dev,
      before.st_ino == named.st_ino,
      before.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISVTX
        | S_IXUSR | S_IXGRP | S_IXOTH) == 0,
      before.st_size > 0,
      before.st_size <= off_t(maximumBytes)
    else { throw PluginTrustedSignerAuthorityError.unsafeCertificate }
    do {
      try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
        fileDescriptor: descriptor,
        path: displayURL.path,
        role: "plugin trusted-signer authority file"
      )
    } catch {
      throw PluginTrustedSignerAuthorityError.unsafeCertificate
    }
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = pread(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset,
          off_t(offset)
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw PluginTrustedSignerAuthorityError.unsafeCertificate
        }
        offset += count
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_uid == after.st_uid,
      before.st_mode == after.st_mode,
      before.st_nlink == after.st_nlink,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw PluginTrustedSignerAuthorityError.unsafeCertificate }
    return data
  }

  private static func validateJSONObject(
    _ data: Data,
    expectedKeys: Set<String>
  ) throws {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw PluginTrustedSignerAuthorityError.unsafeManifest
    }
    guard let fields = object as? [String: Any], Set(fields.keys) == expectedKeys,
      let signers = fields["signers"] as? [[String: Any]],
      signers.allSatisfy({ Set($0.keys) == ["identifier", "certificateSHA256"] })
    else { throw PluginTrustedSignerAuthorityError.unsafeManifest }
  }
}
