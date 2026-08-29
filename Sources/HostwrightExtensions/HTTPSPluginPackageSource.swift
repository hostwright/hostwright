import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightRegistry

/// A materialized plugin package obtained from one explicit HTTPS package source.
///
/// The directory is private to the invoking user and must be cleaned with `cleanup()`
/// once package verification and installation have completed.
public struct MaterializedHTTPSPluginPackage: @unchecked Sendable {
    private let materialization: HTTPSPluginPackageMaterialization

    fileprivate init(materialization: HTTPSPluginPackageMaterialization) {
        self.materialization = materialization
    }

    public var directoryURL: URL {
        materialization.directoryURL
    }

    public func cleanup() throws {
        try materialization.cleanup()
    }
}

/// Downloads a package from an explicitly configured HTTPS source into a private,
/// short-lived directory. It deliberately has no registry discovery or default source.
public struct HTTPSPluginPackageSourceMaterializer: Sendable {
    public static let maximumContentFiles = 1_024
    public static let defaultTimeoutMilliseconds = 30_000

    private let transport: any RegistrySynchronousHTTPTransporting
    private let temporaryRootURL: URL
    private let timeoutMilliseconds: Int

    public init(
        transport: any RegistrySynchronousHTTPTransporting =
            SynchronousURLSessionRegistryTransport(
                maximumResponseBodyBytes: PluginPackageVerifier.maximumContentFileBytes
            ),
        temporaryRootURL: URL = FileManager.default.temporaryDirectory,
        timeoutMilliseconds: Int = defaultTimeoutMilliseconds
    ) {
        self.transport = transport
        self.temporaryRootURL = temporaryRootURL.standardizedFileURL
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func materialize(
        source: PluginSource,
        cancellation: RegistryTransportCancellation = RegistryTransportCancellation()
    ) throws -> MaterializedHTTPSPluginPackage {
        try validateConfiguration(source: source, cancellation: cancellation)
        let packageRootURL = try configuredPackageRootURL(source)
        let materialization = try HTTPSPluginPackageMaterialization(rootURL: temporaryRootURL)

        do {
            let manifestData = try fetch(
                url: try remoteURL(packageRootURL, relativePath: PluginPackageVerifier.manifestFileName),
                maximumBytes: PluginPackageVerifier.maximumManifestBytes,
                accept: "application/json",
                cancellation: cancellation
            )
            let manifest = try decodeManifest(manifestData)
            guard manifest.provenance.source == source else {
                throw blocked("The HTTPS plugin package manifest does not match the configured source.")
            }
            guard manifest.contentDigests.count <= Self.maximumContentFiles else {
                throw blocked("The HTTPS plugin package manifest declares too many content files.")
            }

            try materialization.write(
                manifestData,
                relativePath: PluginPackageVerifier.manifestFileName
            )
            var totalBytes = manifestData.count
            for content in manifest.contentDigests {
                try requireNotCancelled(cancellation)
                guard content.path != PluginPackageVerifier.manifestFileName else {
                    throw invalid("The HTTPS plugin package cannot declare its manifest as content.")
                }
                let maximumBytes = manifest.providerKind == .wasi && content.path == manifest.entrypoint
                    ? PluginPackageVerifier.maximumWASIModuleBytes
                    : PluginPackageVerifier.maximumContentFileBytes
                let data = try fetch(
                    url: try remoteURL(packageRootURL, relativePath: content.path),
                    maximumBytes: maximumBytes,
                    accept: "application/octet-stream",
                    cancellation: cancellation
                )
                guard totalBytes <= PluginPackageVerifier.maximumPackageBytes - data.count else {
                    throw blocked("The HTTPS plugin package exceeds its bounded materialization size.")
                }
                totalBytes += data.count
                try materialization.write(data, relativePath: content.path)
            }
            try requireNotCancelled(cancellation)
            return MaterializedHTTPSPluginPackage(materialization: materialization)
        } catch {
            do {
                try materialization.cleanup()
            } catch {
                throw executionFailed(
                    "HTTPS plugin package materialization failed and exact temporary cleanup also failed."
                )
            }
            if let diagnostic = error as? HostwrightDiagnostic {
                throw diagnostic
            }
            throw executionFailed("Could not materialize the HTTPS plugin package.")
        }
    }

    private func validateConfiguration(
        source: PluginSource,
        cancellation: RegistryTransportCancellation
    ) throws {
        guard (100...120_000).contains(timeoutMilliseconds) else {
            throw invalid("The HTTPS plugin package materialization timeout is invalid.")
        }
        guard source.kind == .httpsRegistry else {
            throw blocked("HTTPS plugin package materialization requires an explicit HTTPS source.")
        }
        do {
            try source.validate()
        } catch {
            throw invalid("The configured HTTPS plugin package source is invalid.")
        }
        var metadata = stat()
        guard temporaryRootURL.isFileURL,
              temporaryRootURL.path.hasPrefix("/"),
              lstat(temporaryRootURL.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw executionFailed("The HTTPS plugin package temporary root must be caller-owned and private.")
        }
        try requireNotCancelled(cancellation)
    }

    private func configuredPackageRootURL(_ source: PluginSource) throws -> URL {
        guard let url = URL(string: source.locator),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw invalid("The configured HTTPS plugin package source is invalid.")
        }
        return url
    }

    private func decodeManifest(_ data: Data) throws -> PluginPackageManifest {
        try StrictExtensionJSONObject.validate(
            data,
            expectedKeys: [
                "abiVersion", "identifier", "packageVersion", "hostwrightCompatibility",
                "providerKind", "entrypoint", "grants", "artifactDigest", "contentDigests",
                "provenance", "cmsSignature", "signerIdentifier",
            ],
            role: "HTTPS plugin package manifest"
        )
        let manifest: PluginPackageManifest
        do {
            manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: data)
            try manifest.validate()
        } catch {
            throw invalid("The HTTPS plugin package manifest is invalid.")
        }
        for content in manifest.contentDigests {
            _ = try safePathComponents(content.path)
        }
        _ = try safePathComponents(manifest.entrypoint)
        return manifest
    }

    private func fetch(
        url: URL,
        maximumBytes: Int,
        accept: String,
        cancellation: RegistryTransportCancellation
    ) throws -> Data {
        try requireNotCancelled(cancellation)
        let request = RegistryTransportRequest(
            url: url,
            method: .get,
            headers: ["Accept": accept],
            timeoutMilliseconds: timeoutMilliseconds,
            maximumResponseBodyBytes: maximumBytes
        )
        let response: RegistryTransportResponse
        do {
            response = try transport.send(request, cancellation: cancellation)
        } catch let error as RegistryTransportError {
            if error == .cancelled {
                throw executionFailed("HTTPS plugin package materialization was cancelled.")
            }
            throw executionFailed("HTTPS plugin package transport failed.")
        } catch {
            throw executionFailed("HTTPS plugin package transport failed.")
        }
        try requireNotCancelled(cancellation)
        guard response.statusCode == 200 else {
            throw executionFailed("The HTTPS plugin package source returned an unexpected response.")
        }
        guard response.body.count <= maximumBytes else {
            throw blocked("The HTTPS plugin package source exceeded a bounded file size.")
        }
        return response.body
    }

    private func remoteURL(_ root: URL, relativePath: String) throws -> URL {
        let components = try safePathComponents(relativePath)
        var result = root
        for component in components {
            result.appendPathComponent(component, isDirectory: false)
        }
        guard result.scheme?.lowercased() == "https" else {
            throw invalid("The configured HTTPS plugin package source is invalid.")
        }
        return result
    }

    private func safePathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              path.utf8.count <= 4_096,
              !path.contains("\0") else {
            throw invalid("The HTTPS plugin package content path is invalid.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw invalid("The HTTPS plugin package content path is not canonical.")
        }
        return components
    }

    private func requireNotCancelled(_ cancellation: RegistryTransportCancellation) throws {
        guard !cancellation.isCancelled else {
            throw executionFailed("HTTPS plugin package materialization was cancelled.")
        }
    }

    private func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionInvalid, message: message)
    }

    private func blocked(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionBlocked, message: message)
    }

    private func executionFailed(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionExecutionFailed, message: message)
    }
}

fileprivate final class HTTPSPluginPackageMaterialization: @unchecked Sendable {
    let directoryURL: URL

    private let lock = NSLock()
    private var snapshots: [HTTPSPluginMaterializedArtifact] = []
    private var directories: [HTTPSPluginMaterializedDirectory] = []
    private var cleaned = false

    init(rootURL: URL) throws {
        var template = Array(rootURL.appendingPathComponent("hostwright-plugin-package.XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else {
            throw HostwrightDiagnostic(
                code: .extensionExecutionFailed,
                message: "Could not create a private HTTPS plugin package directory."
            )
        }
        directoryURL = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        guard chmod(directoryURL.path, S_IRWXU) == 0 else {
            _ = rmdir(directoryURL.path)
            throw HostwrightDiagnostic(
                code: .extensionExecutionFailed,
                message: "Could not secure the private HTTPS plugin package directory."
            )
        }
        do {
            directories = [try snapshotDirectory(directoryURL)]
        } catch {
            _ = rmdir(directoryURL.path)
            throw HostwrightDiagnostic(
                code: .extensionExecutionFailed,
                message: "Could not validate the private HTTPS plugin package directory."
            )
        }
    }

    func write(_ data: Data, relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned else {
            throw Self.failed("The private HTTPS plugin package directory is already cleaned.")
        }
        let components = try safePathComponents(relativePath)
        var parent = directoryURL
        for component in components.dropLast() {
            parent = parent.appendingPathComponent(component, isDirectory: true)
            try createDirectory(parent)
        }
        let destination = parent.appendingPathComponent(components.last!, isDirectory: false)
        let descriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw Self.failed("Could not create a private HTTPS plugin package file.")
        }
        var writeFailure: Error?
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    writeFailure = Self.failed("Could not write a private HTTPS plugin package file.")
                    break
                }
            }
        }
        if fsync(descriptor) != 0, writeFailure == nil {
            writeFailure = Self.failed("Could not synchronize a private HTTPS plugin package file.")
        }
        close(descriptor)
        if let writeFailure {
            _ = unlink(destination.path)
            throw writeFailure
        }
        do {
            snapshots.append(try snapshotFile(destination, data: data, expectedBytes: data.count))
        } catch {
            _ = unlink(destination.path)
            throw Self.failed("Could not validate a private HTTPS plugin package file.")
        }
    }

    func cleanup() throws {
        lock.lock()
        defer { lock.unlock() }
        if cleaned { return }
        try verifyOwnedTree()
        let rootDescriptor = open(
            directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0,
              let rootSnapshot = directories.first else {
            if rootDescriptor >= 0 { close(rootDescriptor) }
            throw Self.failed("Could not pin the private HTTPS plugin package root.")
        }
        defer { close(rootDescriptor) }
        for snapshot in snapshots.reversed() {
            let relative = relativePath(snapshot.url).split(separator: "/").map(String.init)
            let (parent, leaf) = try Self.openPinnedParent(
                rootDescriptor: rootDescriptor, components: relative)
            var current = stat()
            let removed = fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0
                && current.st_mode & S_IFMT == S_IFREG
                && UInt64(current.st_dev) == snapshot.deviceID
                && UInt64(current.st_ino) == snapshot.inode
                && unlinkat(parent, leaf, 0) == 0
            close(parent)
            guard removed else {
                throw Self.failed("Could not remove an exact private HTTPS plugin package file.")
            }
        }
        for directory in directories.dropFirst().sorted(by: { $0.url.path.count > $1.url.path.count }) {
            let relative = relativePath(directory.url).split(separator: "/").map(String.init)
            let (parent, leaf) = try Self.openPinnedParent(
                rootDescriptor: rootDescriptor, components: relative)
            var current = stat()
            let removed = fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0
                && current.st_mode & S_IFMT == S_IFDIR
                && UInt64(current.st_dev) == directory.deviceID
                && UInt64(current.st_ino) == directory.inode
                && unlinkat(parent, leaf, AT_REMOVEDIR) == 0
            close(parent)
            guard removed else {
                throw Self.failed("Could not remove an exact private HTTPS plugin package directory.")
            }
        }
        let parentURL = directoryURL.deletingLastPathComponent()
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            throw Self.failed("Could not pin the private HTTPS plugin package parent.")
        }
        var currentRoot = stat()
        let removedRoot = fstatat(
            parent, directoryURL.lastPathComponent, &currentRoot, AT_SYMLINK_NOFOLLOW) == 0
            && currentRoot.st_mode & S_IFMT == S_IFDIR
            && UInt64(currentRoot.st_dev) == rootSnapshot.deviceID
            && UInt64(currentRoot.st_ino) == rootSnapshot.inode
            && unlinkat(parent, directoryURL.lastPathComponent, AT_REMOVEDIR) == 0
        close(parent)
        guard removedRoot else {
            throw Self.failed("Could not remove the exact private HTTPS plugin package root.")
        }
        cleaned = true
    }

    deinit {
        try? cleanup()
    }

    private func createDirectory(_ url: URL) throws {
        if mkdir(url.path, S_IRWXU) == 0 {
            directories.append(try snapshotDirectory(url))
            return
        }
        guard errno == EEXIST,
              let existing = directories.first(where: { $0.url == url }) else {
            throw Self.failed("Could not create a private HTTPS plugin package directory.")
        }
        guard try snapshotDirectory(url) == existing else {
            throw Self.failed("Could not create a private HTTPS plugin package directory.")
        }
    }

    private func verifyOwnedTree() throws {
        let expected = Set(
            snapshots.map { relativePath($0.url) } + directories.dropFirst().map { relativePath($0.url) }
        )
        let actual: Set<String>
        do {
            actual = Set(try FileManager.default.subpathsOfDirectory(atPath: directoryURL.path))
        } catch {
            throw Self.failed("Could not inspect the private HTTPS plugin package directory for cleanup.")
        }
        guard actual == expected else {
            throw Self.failed("Private HTTPS plugin package cleanup refused unowned artifacts.")
        }
        for directory in directories {
            let current = try snapshotDirectory(directory.url)
            guard current == directory else {
                throw Self.failed("Private HTTPS plugin package cleanup refused changed directory identity.")
            }
        }
        for snapshot in snapshots {
            let current = try snapshotFile(
                snapshot.url,
                data: nil,
                expectedBytes: snapshot.byteCount
            )
            guard current.deviceID == snapshot.deviceID,
                  current.inode == snapshot.inode,
                  current.byteCount == snapshot.byteCount,
                  current.sha256 == snapshot.sha256 else {
                throw Self.failed("Private HTTPS plugin package cleanup refused changed file identity.")
            }
        }
    }

    private func snapshotDirectory(_ url: URL) throws -> HTTPSPluginMaterializedDirectory {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw Self.failed("Private HTTPS plugin package directory identity is unsafe.")
        }
        return HTTPSPluginMaterializedDirectory(
            url: url,
            deviceID: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    private func snapshotFile(
        _ url: URL,
        data: Data?,
        expectedBytes: Int
    ) throws -> HTTPSPluginMaterializedArtifact {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size >= 0,
              metadata.st_size == off_t(expectedBytes) else {
            throw Self.failed("Private HTTPS plugin package file identity is unsafe.")
        }
        let digest: String
        if let data {
            digest = Self.digest(data)
        } else {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw Self.failed("Could not inspect a private HTTPS plugin package file.")
            }
            defer { close(descriptor) }
            digest = try Self.digest(contentsOf: descriptor, maximumBytes: expectedBytes)
        }
        return HTTPSPluginMaterializedArtifact(
            url: url,
            deviceID: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: expectedBytes,
            sha256: digest
        )
    }

    private func relativePath(_ url: URL) -> String {
        let prefix = directoryURL.path.hasSuffix("/") ? directoryURL.path : directoryURL.path + "/"
        return String(url.path.dropFirst(prefix.count))
    }

    private static func openPinnedParent(
        rootDescriptor: Int32, components: [String]
    ) throws -> (Int32, String) {
        guard let leaf = components.last,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw failed("Private HTTPS plugin cleanup path is not canonical.")
        }
        var current = dup(rootDescriptor)
        guard current >= 0 else {
            throw failed("Could not duplicate the private HTTPS plugin package root.")
        }
        for component in components.dropLast() {
            let next = openat(
                current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else {
                throw failed("Private HTTPS plugin cleanup parent identity changed.")
            }
            current = next
        }
        return (current, leaf)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(contentsOf descriptor: Int32, maximumBytes: Int) throws -> String {
        guard maximumBytes >= 0 else {
            throw Self.failed("Private HTTPS plugin package file size is invalid.")
        }
        var hasher = SHA256()
        var remaining = maximumBytes
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= remaining else {
                throw Self.failed("Could not inspect a private HTTPS plugin package file.")
            }
            if count == 0 { break }
            remaining -= count
            hasher.update(data: Data(buffer[0..<count]))
        }
        guard remaining == 0 else {
            throw Self.failed("Private HTTPS plugin package file changed during cleanup.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func safePathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              path.utf8.count <= 4_096,
              !path.contains("\0") else {
            throw Self.failed("The private HTTPS plugin package content path is invalid.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Self.failed("The private HTTPS plugin package content path is not canonical.")
        }
        return components
    }

    private static func failed(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionExecutionFailed, message: message)
    }
}

private struct HTTPSPluginMaterializedArtifact: Equatable {
    let url: URL
    let deviceID: UInt64
    let inode: UInt64
    let byteCount: Int
    let sha256: String
}

private struct HTTPSPluginMaterializedDirectory: Equatable {
    let url: URL
    let deviceID: UInt64
    let inode: UInt64
}
