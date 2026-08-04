import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightNetworkProviders
import HostwrightXPCProvider

public struct VerifiedPluginPackage: Equatable, Sendable {
  public let manifest: PluginPackageManifest
  public let manifestData: Data
  public let packageDigest: String
  public let sourceDirectoryURL: URL

  public init(
    manifest: PluginPackageManifest, manifestData: Data, packageDigest: String,
    sourceDirectoryURL: URL
  ) {
    self.manifest = manifest
    self.manifestData = manifestData
    self.packageDigest = packageDigest
    self.sourceDirectoryURL = sourceDirectoryURL
  }
}

public struct PluginPackageVerifier: Sendable {
  public static let manifestFileName = "manifest.json"
  public static let maximumManifestBytes = 1 * 1_024 * 1_024
  public static let maximumWASIModuleBytes = 16 * 1_024 * 1_024
  public static let maximumContentFileBytes = 256 * 1_024 * 1_024
  public static let maximumPackageBytes = 512 * 1_024 * 1_024

  private let trustedSignerCertificates: [String: Data]
  private let hostVersion: String?

  public init(
    trustedSignerCertificates: [String: Data], hostVersion: String? = nil
  ) throws {
    guard !trustedSignerCertificates.isEmpty,
      trustedSignerCertificates.allSatisfy({ key, value in
        !key.isEmpty && key.utf8.count <= 256 && !value.isEmpty && value.count <= 32 * 1_024
      })
    else { throw Self.blocked("At least one bounded trusted plugin signer is required.") }
    if let hostVersion { _ = try PluginCompatibilityRange.Version(hostVersion) }
    self.trustedSignerCertificates = trustedSignerCertificates
    self.hostVersion = hostVersion
  }

  public func verifyMaterializedPackage(
    at directoryURL: URL, expectedSource: PluginSource
  ) throws -> VerifiedPluginPackage {
    try expectedSource.validate()
    guard let resolvedRoot = realpath(directoryURL.standardizedFileURL.path, nil) else {
      throw Self.invalid("The plugin package root cannot be resolved.")
    }
    defer { free(resolvedRoot) }
    let root = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
    try SecurePluginPackageReader.validateRoot(root)
    let manifestData = try SecurePluginPackageReader.read(
      root: root, relativePath: Self.manifestFileName,
      maximumBytes: Self.maximumManifestBytes, requireOwnerExecute: false)
    try StrictExtensionJSONObject.validate(
      manifestData,
      expectedKeys: [
        "abiVersion", "identifier", "packageVersion", "hostwrightCompatibility",
        "providerKind", "entrypoint", "grants", "artifactDigest", "contentDigests",
        "provenance", "cmsSignature", "signerIdentifier",
      ],
      role: "plugin package manifest")
    let manifest: PluginPackageManifest
    do { manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: manifestData) }
    catch { throw Self.invalid("The plugin package manifest cannot be decoded.") }
    do { _ = try PluginCompatibilityRange.Version(manifest.packageVersion) }
    catch { throw Self.invalid("The plugin package version is not valid SemVer.") }
    do { try manifest.validate() }
    catch { throw Self.invalid("The plugin package manifest violates Plugin ABI v1.") }
    let compatibility: PluginCompatibilityRange
    do { compatibility = try PluginCompatibilityRange(manifest.hostwrightCompatibility) }
    catch { throw Self.invalid("The plugin package compatibility range is invalid.") }
    if let hostVersion, try !compatibility.contains(hostVersion) {
      throw Self.blocked("The plugin package is not compatible with this Hostwright version.")
    }
    let canonical = try ControlPlaneCanonicalJSON.encode(manifest)
    guard canonical == manifestData else {
      throw Self.invalid("The plugin package manifest must be exact canonical JSON.")
    }
    guard manifest.provenance.source == expectedSource else {
      throw Self.blocked("The plugin package provenance source does not match the selected source.")
    }
    let sortedContent = manifest.contentDigests.sorted(by: Self.contentOrder)
    let sortedGrants = manifest.grants.sorted(by: Self.grantOrder)
    guard manifest.contentDigests == sortedContent, manifest.grants == sortedGrants else {
      throw Self.invalid("Plugin content digests and grants must use canonical order.")
    }
    guard Set(sortedGrants.map { "\($0.capability.rawValue)\u{1f}\($0.scope)" }).count
      == sortedGrants.count
    else { throw Self.invalid("Plugin grants must not contain duplicates.") }

    let declaredPaths = Set(sortedContent.map(\.path))
    guard declaredPaths.contains(manifest.entrypoint),
      let entrypoint = sortedContent.first(where: { $0.path == manifest.entrypoint }),
      entrypoint.digest == manifest.artifactDigest
    else { throw Self.invalid("The plugin entrypoint must have the exact declared artifact digest.") }
    let materializedFiles = try SecurePluginPackageReader.regularFilePaths(root: root)
    guard materializedFiles == declaredPaths.union([Self.manifestFileName]) else {
      throw Self.blocked("The plugin package contains missing or undeclared dependency files.")
    }

    var totalBytes = manifestData.count
    for content in sortedContent {
      let maximum = manifest.providerKind == .wasi && content.path == manifest.entrypoint
        ? Self.maximumWASIModuleBytes : Self.maximumContentFileBytes
      let data = try SecurePluginPackageReader.read(
        root: root, relativePath: content.path, maximumBytes: maximum,
        requireOwnerExecute: manifest.providerKind == .xpc && content.path == manifest.entrypoint)
      totalBytes += data.count
      guard totalBytes <= Self.maximumPackageBytes,
        PluginStateDigest.prefixed(data) == content.digest
      else { throw Self.blocked("Plugin package content exceeds its bound or digest.") }
    }
    if manifest.providerKind == .xpc {
      do {
        _ = try XPCProviderCodeIdentity.file(
          root.appendingPathComponent(manifest.entrypoint, isDirectory: false))
      } catch {
        throw Self.blocked(
          "The native plugin entrypoint does not satisfy the frozen XPC signer and entitlement contract.")
      }
    }

    let packageDigest = PluginStateDigest.prefixed(
      try ControlPlaneCanonicalJSON.encode(PluginContentIndex(contentDigests: sortedContent)))
    guard manifest.provenance.checksum == packageDigest else {
      throw Self.blocked("The plugin package checksum does not match its immutable content index.")
    }
    guard manifest.signerIdentifier == manifest.provenance.signerIdentifier,
      let certificate = trustedSignerCertificates[manifest.signerIdentifier]
    else { throw Self.blocked("The plugin package signer is not trusted.") }
    let certificateFingerprint = PluginStateDigest.prefixed(certificate)
    let verifier = SecurityDetachedCMSVerifier(trustedCertificateDER: [certificate])
    guard let provenanceSignature = Data(base64Encoded: manifest.provenance.signature),
      let manifestSignature = Data(base64Encoded: manifest.cmsSignature),
      !provenanceSignature.isEmpty, !manifestSignature.isEmpty
    else { throw Self.blocked("Plugin package signatures are not valid bounded base64 CMS.") }
    do {
      try verifier.verifyDetachedCMS(
        signature: provenanceSignature, content: Data(packageDigest.utf8),
        trustedSigner: certificateFingerprint)
      try verifier.verifyDetachedCMS(
        signature: manifestSignature,
        content: try ControlPlaneCanonicalJSON.encode(PluginManifestSigningPayload(manifest)),
        trustedSigner: certificateFingerprint)
    } catch {
      throw Self.blocked("Plugin package CMS verification failed.")
    }
    return VerifiedPluginPackage(
      manifest: manifest, manifestData: manifestData, packageDigest: packageDigest,
      sourceDirectoryURL: directoryURL.standardizedFileURL)
  }

  public static func manifestSigningPayload(_ manifest: PluginPackageManifest) throws -> Data {
    try manifest.validate()
    return try ControlPlaneCanonicalJSON.encode(PluginManifestSigningPayload(manifest))
  }

  public static func packageDigest(contentDigests: [PluginContentDigest]) throws -> String {
    try contentDigests.forEach { try $0.validate() }
    let sorted = contentDigests.sorted(by: contentOrder)
    guard Set(sorted.map(\.path)).count == sorted.count else {
      throw invalid("Plugin content paths must be unique.")
    }
    return PluginStateDigest.prefixed(
      try ControlPlaneCanonicalJSON.encode(PluginContentIndex(contentDigests: sorted)))
  }

  private static func contentOrder(_ lhs: PluginContentDigest, _ rhs: PluginContentDigest) -> Bool {
    (lhs.path, lhs.digest) < (rhs.path, rhs.digest)
  }

  private static func grantOrder(_ lhs: PluginGrant, _ rhs: PluginGrant) -> Bool {
    (lhs.capability.rawValue, lhs.scope) < (rhs.capability.rawValue, rhs.scope)
  }

  private static func invalid(_ message: String) -> HostwrightDiagnostic {
    HostwrightDiagnostic(code: .extensionInvalid, message: message)
  }

  private static func blocked(_ message: String) -> HostwrightDiagnostic {
    HostwrightDiagnostic(code: .extensionBlocked, message: message)
  }
}

public struct PluginCompatibilityRange: Equatable, Sendable {
  public struct Version: Comparable, Equatable, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
      case numeric(String)
      case text(String)
    }
    let major: String
    let minor: String
    let patch: String
    private let prerelease: [PrereleaseIdentifier]?

    public init(_ raw: String) throws {
      let buildParts = raw.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
      guard buildParts.count <= 2,
        buildParts.count == 1 || Self.validIdentifiers(buildParts[1])
      else { throw ContractValidationError.invalid("plugin compatibility version") }
      let versionParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      guard versionParts.count <= 2, !versionParts[0].isEmpty else {
        throw ContractValidationError.invalid("plugin compatibility version")
      }
      let parts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 3,
        parts.allSatisfy(Self.validNumericIdentifier)
      else { throw ContractValidationError.invalid("plugin compatibility version") }
      major = String(parts[0])
      minor = String(parts[1])
      patch = String(parts[2])
      if versionParts.count == 2 {
        let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard Self.validIdentifiers(versionParts[1]) else {
          throw ContractValidationError.invalid("plugin compatibility version")
        }
        prerelease = try identifiers.map { identifier in
          let value = String(identifier)
          if Self.validDigits(identifier) {
            guard Self.validNumericIdentifier(identifier) else {
              throw ContractValidationError.invalid("plugin compatibility version")
            }
            return .numeric(value)
          }
          return .text(value)
        }
      } else {
        prerelease = nil
      }
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
      let lhsCore = (lhs.major, lhs.minor, lhs.patch)
      let rhsCore = (rhs.major, rhs.minor, rhs.patch)
      if lhsCore != rhsCore {
        for (left, right) in zip([lhs.major, lhs.minor, lhs.patch], [rhs.major, rhs.minor, rhs.patch])
          where left != right {
          return Self.numericLessThan(left, right)
        }
      }
      switch (lhs.prerelease, rhs.prerelease) {
      case (nil, nil): return false
      case (nil, _?): return false
      case (_?, nil): return true
      case (.some(let left), .some(let right)):
        for (a, b) in zip(left, right) where a != b {
          switch (a, b) {
          case (.numeric(let x), .numeric(let y)): return Self.numericLessThan(x, y)
          case (.numeric, .text): return true
          case (.text, .numeric): return false
          case (.text(let x), .text(let y)): return x < y
          }
        }
        return left.count < right.count
      }
    }

    private static func validNumericIdentifier(_ value: Substring) -> Bool {
      validDigits(value) && (value == "0" || !value.hasPrefix("0"))
    }

    private static func validIdentifiers(_ value: Substring) -> Bool {
      let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
      return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
        !identifier.isEmpty && identifier.utf8.allSatisfy { byte in
          (48...57).contains(byte) || (65...90).contains(byte)
            || (97...122).contains(byte) || byte == 45
        }
      }
    }

    private static func validDigits(_ value: Substring) -> Bool {
      !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func numericLessThan(_ lhs: String, _ rhs: String) -> Bool {
      lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
  }

  private enum Operator: String, Sendable { case equal = "=", greater = ">", greaterEqual = ">=", less = "<", lessEqual = "<=" }
  private struct Clause: Equatable, Sendable { let operation: Operator; let version: Version }
  private let clauses: [Clause]

  public init(_ raw: String) throws {
    guard !raw.isEmpty, raw.utf8.count <= 128 else {
      throw ContractValidationError.invalid("plugin compatibility range")
    }
    guard !raw.contains("|") else {
      throw ContractValidationError.invalid("plugin compatibility range")
    }
    let values = raw
      .replacingOccurrences(of: ",", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !values.isEmpty, values.count <= 4 else {
      throw ContractValidationError.invalid("plugin compatibility range")
    }
    clauses = try values.map { clause in
      let operation: Operator
      let versionText: String
      if clause.hasPrefix(">=") { operation = .greaterEqual; versionText = String(clause.dropFirst(2)) }
      else if clause.hasPrefix("<=") { operation = .lessEqual; versionText = String(clause.dropFirst(2)) }
      else if clause.hasPrefix(">") { operation = .greater; versionText = String(clause.dropFirst()) }
      else if clause.hasPrefix("<") { operation = .less; versionText = String(clause.dropFirst()) }
      else if clause.hasPrefix("=") { operation = .equal; versionText = String(clause.dropFirst()) }
      else { operation = .equal; versionText = clause }
      guard !versionText.isEmpty else {
        throw ContractValidationError.invalid("plugin compatibility range")
      }
      return Clause(operation: operation, version: try Version(versionText))
    }
  }

  public func contains(_ rawVersion: String) throws -> Bool {
    let candidate = try Version(rawVersion)
    return clauses.allSatisfy { clause in
      switch clause.operation {
      case .equal: candidate == clause.version
      case .greater: candidate > clause.version
      case .greaterEqual: candidate >= clause.version
      case .less: candidate < clause.version
      case .lessEqual: candidate <= clause.version
      }
    }
  }
}

private struct PluginContentIndex: Codable {
  let schemaVersion: Int
  let contentDigests: [PluginContentDigest]

  init(contentDigests: [PluginContentDigest]) {
    schemaVersion = 1
    self.contentDigests = contentDigests
  }
}

private struct PluginManifestSigningPayload: Codable {
  let abiVersion: Int
  let identifier: String
  let packageVersion: String
  let hostwrightCompatibility: String
  let providerKind: PluginProviderKind
  let entrypoint: String
  let grants: [PluginGrant]
  let artifactDigest: String
  let contentDigests: [PluginContentDigest]
  let provenance: PluginProvenance
  let signerIdentifier: String

  init(_ manifest: PluginPackageManifest) {
    abiVersion = manifest.abiVersion
    identifier = manifest.identifier
    packageVersion = manifest.packageVersion
    hostwrightCompatibility = manifest.hostwrightCompatibility
    providerKind = manifest.providerKind
    entrypoint = manifest.entrypoint
    grants = manifest.grants
    artifactDigest = manifest.artifactDigest
    contentDigests = manifest.contentDigests
    provenance = manifest.provenance
    signerIdentifier = manifest.signerIdentifier
  }
}

enum SecurePluginPackageReader {
  static func validateRoot(_ root: URL) throws {
    guard root.isFileURL, root.path.hasPrefix("/") else {
      throw invalid("The plugin package root must be an absolute local directory.")
    }
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw invalid("The plugin package root must be a non-symlink directory.")
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else { throw blocked("The plugin package root must be caller-owned and private.") }
  }

  static func read(
    root: URL, relativePath: String, maximumBytes: Int, requireOwnerExecute: Bool
  ) throws -> Data {
    let components = try validatedComponents(relativePath)
    let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootDescriptor >= 0 else { throw invalid("Could not open the plugin package root.") }
    defer { close(rootDescriptor) }
    var directoryDescriptor = rootDescriptor
    var ownedDirectories: [Int32] = []
    defer { ownedDirectories.reversed().forEach { close($0) } }
    for component in components.dropLast() {
      let next = openat(
        directoryDescriptor, component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw blocked("Plugin content traverses an unsafe directory component.") }
      var metadata = stat()
      guard fstat(next, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
        metadata.st_uid == geteuid(), metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
      else { close(next); throw blocked("Plugin content uses an unsafe directory.") }
      ownedDirectories.append(next)
      directoryDescriptor = next
    }
    let descriptor = openat(
      directoryDescriptor, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw invalid("Could not open declared plugin content.") }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & (S_ISUID | S_ISGID) == 0,
      !requireOwnerExecute || metadata.st_mode & S_IXUSR != 0,
      metadata.st_size > 0, metadata.st_size <= maximumBytes
    else { throw blocked("Declared plugin content has unsafe identity, mode, type, or size.") }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw invalid("Could not read declared plugin content.") }
      if count == 0 { break }
      guard result.count + count <= maximumBytes else {
        throw blocked("Declared plugin content exceeded its bounded size while reading.")
      }
      result.append(contentsOf: buffer[0..<count])
    }
    return result
  }

  static func regularFilePaths(root: URL) throws -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: [], errorHandler: { _, _ in false })
    else { throw invalid("Could not enumerate the plugin package.") }
    var files = Set<String>()
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true,
        values.isRegularFile == true || values.isDirectory == true
      else { throw blocked("Plugin packages cannot contain symlinks or special files.") }
      if values.isRegularFile == true {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw blocked("Plugin content escaped its root.") }
        let relative = String(url.path.dropFirst(prefix.count))
        _ = try validatedComponents(relative)
        guard files.insert(relative).inserted else {
          throw invalid("Plugin package file paths must be unique.")
        }
      }
    }
    return files
  }

  private static func validatedComponents(_ path: String) throws -> [String] {
    guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 4096,
      !path.contains("\0")
    else { throw invalid("Plugin content path is invalid.") }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw invalid("Plugin content path is not canonical.") }
    return components
  }

  private static func invalid(_ message: String) -> HostwrightDiagnostic {
    HostwrightDiagnostic(code: .extensionInvalid, message: message)
  }

  private static func blocked(_ message: String) -> HostwrightDiagnostic {
    HostwrightDiagnostic(code: .extensionBlocked, message: message)
  }
}

private enum PluginStateDigest {
  static func prefixed(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
