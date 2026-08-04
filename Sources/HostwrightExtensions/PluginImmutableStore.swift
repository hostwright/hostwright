import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightState

public struct PluginInstallRequest: Sendable {
  public let operationID: String
  public let idempotencyKey: String
  public let actorSubjectID: String
  public let timestamp: String

  public init(
    operationID: String, idempotencyKey: String, actorSubjectID: String,
    timestamp: String
  ) {
    self.operationID = operationID
    self.idempotencyKey = idempotencyKey
    self.actorSubjectID = actorSubjectID
    self.timestamp = timestamp
  }
}

public struct PluginImmutableStore: Sendable {
  public let rootURL: URL
  private let packagesURL: URL
  private let stagingURL: URL

  public init(rootURL: URL) throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw Self.invalid("The plugin storage root must be an absolute local path.")
    }
    self.rootURL = rootURL.standardizedFileURL
    packagesURL = self.rootURL.appendingPathComponent("packages", isDirectory: true)
    stagingURL = self.rootURL.appendingPathComponent("staging", isDirectory: true)
    try Self.prepareDirectory(self.rootURL)
    try Self.prepareDirectory(packagesURL)
    try Self.prepareDirectory(stagingURL)
  }

  public func install(
    verified: VerifiedPluginPackage, request: PluginInstallRequest,
    repository: PluginLifecycleRepository
  ) throws -> PluginPackageRecord {
    let finalURL = packageURL(digest: verified.packageDigest)
    var operation = try repository.beginRollback(PluginRollbackRecord(
      operationID: request.operationID,
      pluginIdentifier: verified.manifest.identifier,
      fromPackageDigest: nil,
      toPackageDigest: verified.packageDigest,
      stage: "install-intent", status: "pending", idempotencyKey: request.idempotencyKey,
      ownershipEffects: [], failureReasonCode: nil,
      requestedBySubjectID: request.actorSubjectID, generation: 1,
      createdAt: request.timestamp, updatedAt: request.timestamp))
    let stageURL = stagingURL.appendingPathComponent(request.operationID, isDirectory: true)
    var packagePersisted = false
    do {
      guard !FileManager.default.fileExists(atPath: finalURL.path),
        !FileManager.default.fileExists(atPath: stageURL.path)
      else { throw Self.blocked("Plugin staging or immutable digest storage already exists.") }
      guard mkdir(stageURL.path, mode_t(S_IRWXU)) == 0 else {
        throw Self.failed("Could not create the owned plugin staging directory.")
      }
      try copyPackage(verified, to: stageURL)
      let ledger = try ownershipLedger(
        packageURL: stageURL, recordedRootURL: finalURL,
        manifest: verified.manifest, manifestData: verified.manifestData)
      operation = try repository.advanceRollback(
        operationID: operation.operationID, expectedGeneration: operation.generation,
        stage: "staged", status: "running", ownershipEffects: ledger,
        updatedAt: request.timestamp)
      guard rename(stageURL.path, finalURL.path) == 0 else {
        throw Self.failed("Could not atomically activate immutable plugin storage.")
      }
      let record = try PluginPackageRecord(
        packageDigest: verified.packageDigest, manifest: verified.manifest,
        storagePath: finalURL.path, ownershipLedger: ledger,
        lifecycleState: .staged, createdBySubjectID: request.actorSubjectID,
        createdAt: request.timestamp, updatedAt: request.timestamp)
      let stored = try repository.persistVerifiedPackage(record)
      packagePersisted = true
      _ = try repository.advanceRollback(
        operationID: operation.operationID, expectedGeneration: operation.generation,
        stage: "complete", status: "succeeded", ownershipEffects: ledger,
        updatedAt: request.timestamp)
      return stored
    } catch {
      if !packagePersisted {
        try? cleanupOwnedTree(at: stageURL, expectedLedger: nil)
        if FileManager.default.fileExists(atPath: finalURL.path) {
          try? cleanupOwnedTree(at: finalURL, expectedLedger: operation.ownershipEffects)
        }
      }
      if let current = try? repository.rollback(operationID: operation.operationID),
        !["succeeded", "failed", "cancelled"].contains(current.status)
      {
        _ = try? repository.advanceRollback(
          operationID: current.operationID, expectedGeneration: current.generation,
          stage: current.stage, status: "failed", ownershipEffects: current.ownershipEffects,
          failureReasonCode: "plugin.install-failed", updatedAt: request.timestamp)
      }
      throw error
    }
  }

  public func removeInstalledPackage(_ record: PluginPackageRecord) throws {
    guard record.lifecycleState == .uninstalled,
      record.storagePath == packageURL(digest: record.packageDigest).path
    else { throw Self.blocked("Only an uninstalled package in its exact digest root can be cleaned.") }
    try cleanupOwnedTree(
      at: URL(fileURLWithPath: record.storagePath, isDirectory: true),
      expectedLedger: record.ownershipLedger)
  }

  @discardableResult
  public func recoverInterruptedOperations(
    repository: PluginLifecycleRepository, timestamp: String
  ) throws -> Int {
    let operations = try repository.incompleteRollbackOperations()
    for operation in operations {
      try recoverInterruptedOperation(
        operation, repository: repository, timestamp: timestamp)
    }
    return operations.count
  }

  public func recoverInterruptedOperation(
    _ operation: PluginRollbackRecord, repository: PluginLifecycleRepository,
    timestamp: String
  ) throws {
    if ["recovery-success-audit", "recovery-failure-audit"].contains(operation.stage) {
      return
    }
    if operation.stage == "uninstall-intent" || operation.stage == "cleanup" {
      try recoverUninstall(operation, repository: repository, timestamp: timestamp)
    } else if operation.fromPackageDigest == nil {
      try recoverInstall(operation, repository: repository, timestamp: timestamp)
    } else {
      try recoverRollback(operation, repository: repository, timestamp: timestamp)
    }
  }

  public func finalizeRecoveredOperation(
    operationID: String, repository: PluginLifecycleRepository, timestamp: String
  ) throws -> PluginRollbackRecord {
    guard let operation = try repository.rollback(operationID: operationID),
      operation.status == "running"
    else { throw Self.invalid("Recovered plugin operation is not awaiting final audit.") }
    if operation.stage == "recovery-success-audit" {
      return try repository.advanceRollback(
        operationID: operation.operationID, expectedGeneration: operation.generation,
        stage: "complete", status: "succeeded", updatedAt: timestamp)
    }
    guard operation.stage == "recovery-failure-audit" else {
      throw Self.invalid("Recovered plugin operation has no terminal audit outcome.")
    }
    return try repository.advanceRollback(
      operationID: operation.operationID, expectedGeneration: operation.generation,
      stage: operation.stage, status: "failed",
      failureReasonCode: "plugin.lifecycle-interrupted", updatedAt: timestamp)
  }

  public func packageURL(digest: String) -> URL {
    let component = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : "invalid"
    return packagesURL.appendingPathComponent(component, isDirectory: true)
  }

  private func recoverInstall(
    _ operation: PluginRollbackRecord, repository: PluginLifecycleRepository,
    timestamp: String
  ) throws {
    let finalURL = packageURL(digest: operation.toPackageDigest)
    let stageURL = stagingURL.appendingPathComponent(operation.operationID, isDirectory: true)
    if let package = try repository.package(digest: operation.toPackageDigest) {
      guard package.storagePath == finalURL.path else {
        throw Self.blocked("Interrupted plugin install storage path changed.")
      }
      try validateOwnedTree(at: finalURL, expectedLedger: package.ownershipLedger)
      _ = try repository.advanceRollback(
        operationID: operation.operationID, expectedGeneration: operation.generation,
        stage: "recovery-success-audit", status: "running",
        ownershipEffects: package.ownershipLedger,
        updatedAt: timestamp)
      return
    }
    try cleanupOwnedTree(at: stageURL, expectedLedger: nil)
    if FileManager.default.fileExists(atPath: finalURL.path) {
      guard !operation.ownershipEffects.isEmpty else {
        throw Self.blocked("Interrupted plugin install has unowned immutable content.")
      }
      try cleanupOwnedTree(at: finalURL, expectedLedger: operation.ownershipEffects)
    }
    _ = try repository.advanceRollback(
      operationID: operation.operationID, expectedGeneration: operation.generation,
      stage: "recovery-failure-audit", status: "running", updatedAt: timestamp)
  }

  private func recoverUninstall(
    _ operation: PluginRollbackRecord, repository: PluginLifecycleRepository,
    timestamp: String
  ) throws {
    guard let package = try repository.package(digest: operation.toPackageDigest),
      package.lifecycleState == .uninstalled
    else {
      _ = try repository.advanceRollback(
        operationID: operation.operationID, expectedGeneration: operation.generation,
        stage: "recovery-failure-audit", status: "running", updatedAt: timestamp)
      return
    }
    if FileManager.default.fileExists(atPath: package.storagePath) {
      try removeInstalledPackage(package)
    }
    _ = try repository.advanceRollback(
      operationID: operation.operationID, expectedGeneration: operation.generation,
      stage: "recovery-success-audit", status: "running",
      ownershipEffects: package.ownershipLedger,
      updatedAt: timestamp)
  }

  private func recoverRollback(
    _ operation: PluginRollbackRecord, repository: PluginLifecycleRepository,
    timestamp: String
  ) throws {
    if try repository.activation(identifier: operation.pluginIdentifier)?.activePackageDigest
      == operation.toPackageDigest
    {
      _ = try repository.advanceRollback(
        operationID: operation.operationID, expectedGeneration: operation.generation,
        stage: "recovery-success-audit", status: "running", updatedAt: timestamp)
    } else {
      _ = try repository.advanceRollback(
        operationID: operation.operationID, expectedGeneration: operation.generation,
        stage: "recovery-failure-audit", status: "running", updatedAt: timestamp)
    }
  }

  private func copyPackage(_ package: VerifiedPluginPackage, to destination: URL) throws {
    let paths = [PluginPackageVerifier.manifestFileName] + package.manifest.contentDigests.map(\.path)
    for path in paths {
      let maximum = path == PluginPackageVerifier.manifestFileName
        ? PluginPackageVerifier.maximumManifestBytes
        : package.manifest.providerKind == .wasi && path == package.manifest.entrypoint
          ? PluginPackageVerifier.maximumWASIModuleBytes
          : PluginPackageVerifier.maximumContentFileBytes
      let sourceData = try SecurePluginPackageReader.read(
        root: package.sourceDirectoryURL, relativePath: path, maximumBytes: maximum,
        requireOwnerExecute: package.manifest.providerKind == .xpc
          && path == package.manifest.entrypoint)
      if path == PluginPackageVerifier.manifestFileName, sourceData != package.manifestData {
        throw Self.blocked("The plugin manifest changed after verification.")
      }
      if path != PluginPackageVerifier.manifestFileName {
        guard let expected = package.manifest.contentDigests.first(where: { $0.path == path }),
          expected.digest == Self.digest(sourceData)
        else { throw Self.blocked("Plugin content changed after verification.") }
      }
      let destinationURL = destination.appendingPathComponent(path, isDirectory: false)
      try createPrivateParents(for: destinationURL, below: destination)
      try Self.writeExclusive(
        sourceData, to: destinationURL,
        executable: package.manifest.providerKind == .xpc && path == package.manifest.entrypoint)
    }
  }

  private func ownershipLedger(
    packageURL: URL, recordedRootURL: URL, manifest: PluginPackageManifest,
    manifestData: Data
  ) throws -> [PluginOwnedArtifact] {
    var artifacts: [PluginOwnedArtifact] = []
    var directories: Set<String> = [packageURL.path]
    for path in [PluginPackageVerifier.manifestFileName] + manifest.contentDigests.map(\.path) {
      let fileURL = packageURL.appendingPathComponent(path)
      var parent = fileURL.deletingLastPathComponent()
      while parent.path.hasPrefix(packageURL.path), parent.path != packageURL.deletingLastPathComponent().path {
        directories.insert(parent.path)
        if parent.path == packageURL.path { break }
        parent.deleteLastPathComponent()
      }
      let maximum = path == PluginPackageVerifier.manifestFileName
        ? PluginPackageVerifier.maximumManifestBytes : PluginPackageVerifier.maximumContentFileBytes
      let data = try SecurePluginPackageReader.read(
        root: packageURL, relativePath: path, maximumBytes: maximum,
        requireOwnerExecute: manifest.providerKind == .xpc && path == manifest.entrypoint)
      if path == PluginPackageVerifier.manifestFileName, data != manifestData {
        throw Self.blocked("Stored plugin manifest changed during installation.")
      }
      let identity = try Self.identity(fileURL, expectedKind: S_IFREG)
      artifacts.append(try PluginOwnedArtifact(
        path: recordedPath(fileURL.path, actualRoot: packageURL, recordedRoot: recordedRootURL),
        kind: .file, deviceID: UInt64(identity.st_dev),
        inode: UInt64(identity.st_ino), sha256Digest: Self.digest(data)))
    }
    for path in directories.sorted() {
      let identity = try Self.identity(URL(fileURLWithPath: path, isDirectory: true), expectedKind: S_IFDIR)
      artifacts.append(try PluginOwnedArtifact(
        path: recordedPath(path, actualRoot: packageURL, recordedRoot: recordedRootURL),
        kind: .directory, deviceID: UInt64(identity.st_dev),
        inode: UInt64(identity.st_ino)))
    }
    return artifacts.sorted { $0.path < $1.path }
  }

  private func recordedPath(_ path: String, actualRoot: URL, recordedRoot: URL) -> String {
    precondition(path == actualRoot.path || path.hasPrefix(actualRoot.path + "/"))
    return recordedRoot.path + String(path.dropFirst(actualRoot.path.count))
  }

  private func cleanupOwnedTree(
    at root: URL, expectedLedger: [PluginOwnedArtifact]?
  ) throws {
    guard root.path.hasPrefix(stagingURL.path + "/") || root.path.hasPrefix(packagesURL.path + "/") else {
      throw Self.blocked("Plugin cleanup escaped the owned storage roots.")
    }
    if let expectedLedger {
      try validateOwnedTree(at: root, expectedLedger: expectedLedger)
      try removeOwnedTreeDescriptorRelative(at: root, expectedLedger: expectedLedger)
      return
    }
    try removeStagingTreeDescriptorRelative(at: root)
  }

  private func removeStagingTreeDescriptorRelative(at root: URL) throws {
    let canonicalRoot = root.standardizedFileURL
    guard canonicalRoot.path == root.path,
      canonicalRoot.deletingLastPathComponent().path == stagingURL.path,
      !canonicalRoot.lastPathComponent.isEmpty,
      canonicalRoot.lastPathComponent != ".",
      canonicalRoot.lastPathComponent != ".."
    else { throw Self.blocked("Staging cleanup requires an exact staging root.") }

    let stagingDescriptor = open(
      stagingURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard stagingDescriptor >= 0 else {
      throw Self.blocked("Plugin staging parent cannot be pinned.")
    }
    defer { close(stagingDescriptor) }

    var stagingMetadata = stat()
    guard fstat(stagingDescriptor, &stagingMetadata) == 0,
      Self.isSafeStagingArtifact(stagingMetadata, kind: S_IFDIR)
    else { throw Self.blocked("Plugin staging parent identity or mode is unsafe.") }

    let rootName = canonicalRoot.lastPathComponent
    var rootMetadata = stat()
    guard fstatat(stagingDescriptor, rootName, &rootMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw Self.failed("Could not inspect the owned plugin staging directory.")
    }
    guard Self.isSafeStagingArtifact(rootMetadata, kind: S_IFDIR) else {
      throw Self.blocked("Owned staging cleanup found an unsafe root.")
    }

    let rootDescriptor = openat(
      stagingDescriptor, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootDescriptor >= 0 else {
      throw Self.blocked("Owned plugin staging directory cannot be pinned.")
    }
    defer { close(rootDescriptor) }
    var pinnedRoot = stat()
    guard fstat(rootDescriptor, &pinnedRoot) == 0,
      Self.sameIdentity(pinnedRoot, rootMetadata),
      Self.isSafeStagingArtifact(pinnedRoot, kind: S_IFDIR)
    else { throw Self.blocked("Owned plugin staging directory identity changed.") }

    try removeStagingContents(rootDescriptor)

    var currentRoot = stat()
    guard fstatat(stagingDescriptor, rootName, &currentRoot, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameIdentity(currentRoot, pinnedRoot),
      unlinkat(stagingDescriptor, rootName, AT_REMOVEDIR) == 0
    else { throw Self.blocked("Owned plugin staging directory identity changed during deletion.") }
  }

  private func removeStagingContents(_ directoryDescriptor: Int32) throws {
    let enumerationDescriptor = dup(directoryDescriptor)
    guard enumerationDescriptor >= 0, let directory = fdopendir(enumerationDescriptor) else {
      if enumerationDescriptor >= 0 { close(enumerationDescriptor) }
      throw Self.failed("Could not enumerate the owned plugin staging directory.")
    }
    defer { closedir(directory) }

    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw Self.failed("Could not enumerate the owned plugin staging directory.")
        }
        return
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      guard !name.isEmpty, !name.contains("/") else {
        throw Self.blocked("Owned staging cleanup found an unsafe entry name.")
      }
      try removeStagingEntry(named: name, from: directoryDescriptor)
    }
  }

  private func removeStagingEntry(named name: String, from parentDescriptor: Int32) throws {
    var metadata = stat()
    guard fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw Self.failed("Could not inspect an owned staged plugin artifact.")
    }

    switch metadata.st_mode & S_IFMT {
    case S_IFREG:
      guard Self.isSafeStagingArtifact(metadata, kind: S_IFREG),
        unlinkat(parentDescriptor, name, 0) == 0
      else { throw Self.blocked("Owned staging cleanup found an unsafe file.") }
    case S_IFLNK:
      guard metadata.st_uid == geteuid(), unlinkat(parentDescriptor, name, 0) == 0 else {
        throw Self.blocked("Owned staging cleanup found an unsafe symlink.")
      }
    case S_IFDIR:
      guard Self.isSafeStagingArtifact(metadata, kind: S_IFDIR) else {
        throw Self.blocked("Owned staging cleanup found an unsafe directory.")
      }
      let childDescriptor = openat(
        parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard childDescriptor >= 0 else {
        throw Self.blocked("Owned staged plugin directory cannot be pinned.")
      }
      defer { close(childDescriptor) }
      var pinnedChild = stat()
      guard fstat(childDescriptor, &pinnedChild) == 0,
        Self.sameIdentity(pinnedChild, metadata),
        Self.isSafeStagingArtifact(pinnedChild, kind: S_IFDIR)
      else { throw Self.blocked("Owned staged plugin directory identity changed.") }
      try removeStagingContents(childDescriptor)
      var currentChild = stat()
      guard fstatat(parentDescriptor, name, &currentChild, AT_SYMLINK_NOFOLLOW) == 0,
        Self.sameIdentity(currentChild, pinnedChild),
        unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0
      else { throw Self.blocked("Owned staged plugin directory identity changed during deletion.") }
    default:
      throw Self.blocked("Owned staging cleanup refuses special files.")
    }
  }

  private static func isSafeStagingArtifact(_ metadata: stat, kind: mode_t) -> Bool {
    metadata.st_mode & S_IFMT == kind && metadata.st_uid == geteuid()
      && metadata.st_mode & (S_ISUID | S_ISGID | S_IWGRP | S_IWOTH) == 0
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private func removeOwnedTreeDescriptorRelative(
    at root: URL, expectedLedger: [PluginOwnedArtifact]
  ) throws {
    guard let rootArtifact = expectedLedger.first(where: {
      $0.path == root.path && $0.kind == .directory
    }) else { throw Self.blocked("Plugin ownership ledger does not own its package root.") }
    let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootDescriptor >= 0 else { throw Self.blocked("Owned plugin root cannot be pinned.") }
    defer { close(rootDescriptor) }
    var pinnedRoot = stat()
    guard fstat(rootDescriptor, &pinnedRoot) == 0,
      Self.matches(pinnedRoot, rootArtifact, kind: S_IFDIR)
    else { throw Self.blocked("Owned plugin root identity changed.") }

    for artifact in expectedLedger.filter({ $0.kind == .file }).sorted(by: { $0.path > $1.path }) {
      let relative = try relativeComponents(path: artifact.path, root: root.path)
      let (parent, leaf) = try Self.openPinnedParent(rootDescriptor: rootDescriptor, components: relative)
      let descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else {
        close(parent)
        throw Self.blocked("Owned plugin file cannot be pinned.")
      }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
        Self.matches(metadata, artifact, kind: S_IFREG),
        artifact.sha256Digest == Self.digest(
          try Self.readOwnedFile(descriptor: descriptor, expected: metadata,
            maximumBytes: PluginPackageVerifier.maximumContentFileBytes))
      else {
        close(descriptor)
        close(parent)
        throw Self.blocked("Owned plugin file changed before deletion.")
      }
      close(descriptor)
      var current = stat()
      let removed = fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0
        && Self.matches(current, artifact, kind: S_IFREG)
        && unlinkat(parent, leaf, 0) == 0
      close(parent)
      guard removed else {
        throw Self.blocked("Owned plugin file identity changed during deletion.")
      }
    }
    for artifact in expectedLedger.filter({
      $0.kind == .directory && $0.path != root.path
    }).sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
      let relative = try relativeComponents(path: artifact.path, root: root.path)
      let (parent, leaf) = try Self.openPinnedParent(rootDescriptor: rootDescriptor, components: relative)
      var current = stat()
      let removed = fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0
        && Self.matches(current, artifact, kind: S_IFDIR)
        && unlinkat(parent, leaf, AT_REMOVEDIR) == 0
      close(parent)
      guard removed
      else { throw Self.blocked("Owned plugin directory identity changed during deletion.") }
    }
    let parentURL = root.deletingLastPathComponent()
    let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw Self.blocked("Owned plugin parent cannot be pinned.") }
    defer { close(parent) }
    let leaf = root.lastPathComponent
    var currentRoot = stat()
    guard fstatat(parent, leaf, &currentRoot, AT_SYMLINK_NOFOLLOW) == 0,
      Self.matches(currentRoot, rootArtifact, kind: S_IFDIR),
      unlinkat(parent, leaf, AT_REMOVEDIR) == 0
    else { throw Self.blocked("Owned plugin root identity changed during deletion.") }
  }

  private func relativeComponents(path: String, root: String) throws -> [String] {
    guard path.hasPrefix(root + "/") else {
      throw Self.blocked("Owned plugin artifact escaped its pinned root.")
    }
    let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw Self.blocked("Owned plugin artifact path is not canonical.") }
    return components
  }

  private static func openPinnedParent(
    rootDescriptor: Int32, components: [String]
  ) throws -> (Int32, String) {
    guard let leaf = components.last else {
      throw blocked("Owned plugin artifact path has no leaf.")
    }
    var current = dup(rootDescriptor)
    guard current >= 0 else { throw failed("Could not duplicate the pinned plugin root.") }
    for component in components.dropLast() {
      let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      close(current)
      guard next >= 0 else { throw blocked("Owned plugin parent identity changed.") }
      current = next
    }
    return (current, leaf)
  }

  private static func matches(
    _ metadata: stat, _ artifact: PluginOwnedArtifact, kind: mode_t
  ) -> Bool {
    metadata.st_mode & S_IFMT == kind && metadata.st_uid == geteuid()
      && UInt64(metadata.st_dev) == artifact.deviceID
      && UInt64(metadata.st_ino) == artifact.inode
  }

  private func validateOwnedTree(
    at root: URL, expectedLedger: [PluginOwnedArtifact]
  ) throws {
    guard !expectedLedger.isEmpty,
      expectedLedger.contains(where: { $0.path == root.path && $0.kind == .directory })
    else { throw Self.blocked("Plugin ownership ledger does not own its package root.") }
    for artifact in expectedLedger {
      let metadata = try Self.identity(
        URL(fileURLWithPath: artifact.path, isDirectory: artifact.kind == .directory),
        expectedKind: artifact.kind == .file ? S_IFREG : S_IFDIR)
      guard UInt64(metadata.st_dev) == artifact.deviceID,
        UInt64(metadata.st_ino) == artifact.inode
      else { throw Self.blocked("Plugin cleanup identity changed; refusing deletion.") }
      if artifact.kind == .file {
        let data = try Self.readOwnedFile(
          at: artifact.path, expected: metadata,
          maximumBytes: PluginPackageVerifier.maximumContentFileBytes)
        guard artifact.sha256Digest == Self.digest(data) else {
          throw Self.blocked("Plugin cleanup content changed; refusing deletion.")
        }
      }
    }
    let actual = try FileManager.default.subpathsOfDirectory(atPath: root.path)
      .map { root.appendingPathComponent($0).path }
    let expected = Set(expectedLedger.map(\.path)).subtracting([root.path])
    guard Set(actual) == expected else {
      throw Self.blocked("Plugin cleanup found unowned package artifacts.")
    }
  }

  private func createPrivateParents(for file: URL, below root: URL) throws {
    let relative = file.deletingLastPathComponent().path.dropFirst(root.path.count)
    var current = root
    for component in relative.split(separator: "/") {
      current.appendPathComponent(String(component), isDirectory: true)
      if mkdir(current.path, mode_t(S_IRWXU)) != 0, errno != EEXIST {
        throw Self.failed("Could not create a private plugin storage directory.")
      }
      _ = try Self.identity(current, expectedKind: S_IFDIR)
    }
  }

  private static func prepareDirectory(_ url: URL) throws {
    if mkdir(url.path, mode_t(S_IRWXU)) != 0, errno != EEXIST {
      throw failed("Could not create the private plugin storage root.")
    }
    let metadata = try identity(url, expectedKind: S_IFDIR)
    guard metadata.st_uid == geteuid(), metadata.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
      throw blocked("Plugin storage directories must be caller-owned mode 0700.")
    }
  }

  private static func writeExclusive(_ data: Data, to url: URL, executable: Bool) throws {
    let mode = executable ? mode_t(S_IRUSR | S_IXUSR) : mode_t(S_IRUSR)
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw failed("Could not create immutable plugin content.") }
    defer { close(descriptor) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw failed("Could not write immutable plugin content.") }
        offset += count
      }
    }
    guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else {
      throw failed("Could not seal immutable plugin content.")
    }
  }

  private static func identity(_ url: URL, expectedKind: mode_t) throws -> stat {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == expectedKind,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & (S_ISUID | S_ISGID) == 0
    else { throw blocked("Owned plugin artifact identity or mode is unsafe.") }
    return metadata
  }

  private static func readOwnedFile(
    at path: String, expected: stat, maximumBytes: Int
  ) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw blocked("Plugin cleanup could not securely open an owned file.")
    }
    defer { close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == geteuid(), opened.st_dev == expected.st_dev,
      opened.st_ino == expected.st_ino, opened.st_size >= 0,
      opened.st_size <= off_t(maximumBytes)
    else { throw blocked("Plugin cleanup file identity changed; refusing deletion.") }
    return try readOwnedFile(
      descriptor: descriptor, expected: opened, maximumBytes: maximumBytes)
  }

  private static func readOwnedFile(
    descriptor: Int32, expected opened: stat, maximumBytes: Int
  ) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw failed("Could not position an owned plugin file.")
    }
    var data = Data()
    data.reserveCapacity(Int(opened.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw failed("Could not read an owned plugin file.") }
      if count == 0 { break }
      guard data.count + count <= maximumBytes else {
        throw blocked("Plugin cleanup file exceeds its recorded safety bound.")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    var final = stat()
    guard fstat(descriptor, &final) == 0, final.st_dev == opened.st_dev,
      final.st_ino == opened.st_ino, final.st_size == opened.st_size,
      final.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
      final.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec
    else { throw blocked("Plugin cleanup file changed during verification.") }
    return data
  }

  private static func digest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func invalid(_ message: String) -> HostwrightDiagnostic {
    HostwrightDiagnostic(code: .extensionInvalid, message: message)
  }
  private static func blocked(_ message: String) -> HostwrightDiagnostic {
    HostwrightDiagnostic(code: .extensionBlocked, message: message)
  }
  private static func failed(_ message: String) -> HostwrightDiagnostic {
    HostwrightDiagnostic(code: .extensionExecutionFailed, message: message)
  }
}
