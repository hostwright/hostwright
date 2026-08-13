import CryptoKit
import Darwin
import Dispatch
import Foundation
import HostwrightCore
import HostwrightManifest

public enum DaemonConfigurationTargetKind: String, Codable, CaseIterable, Equatable, Sendable {
    case manifest
    case profile
    case policy
    case provider
    case daemon
}

public struct DaemonConfigurationTarget: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: DaemonConfigurationTargetKind
    public let path: String
    public let contentSHA256: String
    public let byteCount: Int
    public let device: UInt64
    public let inode: UInt64

    public init(
        schemaVersion: Int = 1,
        kind: DaemonConfigurationTargetKind,
        path: String,
        contentSHA256: String,
        byteCount: Int,
        device: UInt64,
        inode: UInt64
    ) throws {
        guard schemaVersion == 1,
              path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              contentSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              (0...SecureDaemonConfigurationReader.maximumBytes).contains(byteCount),
              device > 0,
              inode > 0 else {
            throw HostwrightDiagnostic(
                code: .daemonInvalid,
                message: "A watched configuration target requires schema v1, one canonical absolute path, bounded bytes, and exact file identity."
            )
        }
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.path = path
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.device = device
        self.inode = inode
    }
}

public struct DaemonConfigurationSnapshot: Equatable, Sendable {
    public let target: DaemonConfigurationTarget
    public let text: String

    public init(target: DaemonConfigurationTarget, text: String) {
        self.target = target
        self.text = text
    }
}

public enum DaemonConfigurationSetDigest {
    public static func sha256(_ targets: [DaemonConfigurationTarget]) -> String {
        let canonical = targets.sorted {
            ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path)
        }.map {
            [
                $0.kind.rawValue,
                $0.path,
                $0.contentSHA256,
                String($0.byteCount),
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum SecureDaemonConfigurationReader {
    public static let maximumBytes = 1_048_576

    public static func read(
        path: String,
        kind: DaemonConfigurationTargetKind,
        expected: DaemonConfigurationTarget? = nil
    ) throws -> DaemonConfigurationSnapshot {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix("/"), normalized == path else {
            throw invalid("Configuration paths must be normalized and absolute.")
        }
        try validateAncestors(of: path)

        var named = stat()
        guard lstat(path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG,
              named.st_nlink == 1,
              allowedOwner(named.st_uid),
              named.st_mode & (S_IWGRP | S_IWOTH) == 0,
              named.st_size >= 0,
              named.st_size <= maximumBytes else {
            throw invalid("Configuration must be one bounded, singly linked, owner-controlled regular file.")
        }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw invalid("Configuration could not be opened without following links.")
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameIdentity(named, opened),
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1,
              allowedOwner(opened.st_uid),
              opened.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw invalid("Configuration identity changed while it was opened.")
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw invalid("Configuration read failed.")
            }
            guard data.count + count <= maximumBytes else {
                throw invalid("Configuration exceeds the maximum byte count.")
            }
            data.append(buffer, count: count)
        }

        var finalDescriptor = stat()
        var finalNamed = stat()
        guard fstat(descriptor, &finalDescriptor) == 0,
              lstat(path, &finalNamed) == 0,
              sameIdentity(opened, finalDescriptor),
              sameIdentity(opened, finalNamed),
              finalDescriptor.st_size == data.count,
              opened.st_mtimespec.tv_sec == finalDescriptor.st_mtimespec.tv_sec,
              opened.st_mtimespec.tv_nsec == finalDescriptor.st_mtimespec.tv_nsec,
              opened.st_ctimespec.tv_sec == finalDescriptor.st_ctimespec.tv_sec,
              opened.st_ctimespec.tv_nsec == finalDescriptor.st_ctimespec.tv_nsec else {
            throw invalid("Configuration changed during the bounded read.")
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw invalid("Configuration must be NUL-free UTF-8 text.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = try DaemonConfigurationTarget(
            kind: kind,
            path: path,
            contentSHA256: digest,
            byteCount: data.count,
            device: UInt64(opened.st_dev),
            inode: UInt64(opened.st_ino)
        )
        if let expected, expected != target {
            throw HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "A watched configuration target changed after validation; a fresh generation is required."
            )
        }
        return DaemonConfigurationSnapshot(target: target, text: text)
    }

    private static func validateAncestors(of path: String) throws {
        let components = path.split(separator: "/").dropLast()
        var current = "/"
        for component in components {
            current = current == "/" ? "/\(component)" : "\(current)/\(component)"
            var metadata = stat()
            guard lstat(current, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  allowedOwner(metadata.st_uid),
                  metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                throw invalid("Configuration ancestors must be canonical owner-controlled directories.")
            }
        }
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
            lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid &&
            lhs.st_mode == rhs.st_mode && lhs.st_nlink == rhs.st_nlink
    }

    private static func allowedOwner(_ owner: uid_t) -> Bool {
        owner == 0 || owner == geteuid()
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .daemonInvalid, message: message)
    }
}

public enum DaemonConfigurationTargetResolver {
    public static func paths(manifestPath: String, manifest: HostwrightManifest) -> [(DaemonConfigurationTargetKind, String)] {
        let normalizedManifestPath = URL(fileURLWithPath: manifestPath).standardizedFileURL.path
        let manifestDirectory = URL(fileURLWithPath: normalizedManifestPath).deletingLastPathComponent()
        func resolved(_ path: String) -> String {
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
            return manifestDirectory.appendingPathComponent(path).standardizedFileURL.path
        }
        var values: [(DaemonConfigurationTargetKind, String)] = [(.manifest, normalizedManifestPath)]
        if let root = manifest.imageTrust?.trustedRoot {
            values.append((.policy, resolved(root)))
        }
        for authority in manifest.imageTrust?.authorities ?? [] {
            if let key = authority.publicKey {
                values.append((.policy, resolved(key)))
            }
        }
        for signer in manifest.imageProvenance?.signers ?? [] {
            values.append((.policy, resolved(signer.publicKey)))
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.1).inserted }
            .sorted { ($0.0.rawValue, $0.1) < ($1.0.rawValue, $1.1) }
    }
}

public final class DaemonConfigurationChangeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.hostwright.daemon.configuration-watch")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedParents: [String] = []
    private var pending = false

    public init() {}

    deinit { stop() }

    public func replace(paths: [String]) throws {
        let parents = Set(paths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }).sorted()
        lock.lock()
        let unchanged = parents == watchedParents
        lock.unlock()
        if unchanged { return }
        var replacements: [DispatchSourceFileSystemObject] = []
        do {
            for parent in parents {
                let descriptor = open(parent, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    throw HostwrightDiagnostic(code: .daemonInvalid, message: "A configuration parent directory could not be monitored safely.")
                }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                    queue: queue
                )
                source.setEventHandler { [weak self] in
                    self?.markPending()
                }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                replacements.append(source)
            }
        } catch {
            replacements.forEach { $0.cancel() }
            throw error
        }
        lock.lock()
        let prior = sources
        sources = replacements
        watchedParents = parents
        lock.unlock()
        prior.forEach { $0.cancel() }
    }

    public func consumePendingChange() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = false
        return value
    }

    public func stop() {
        lock.lock()
        let prior = sources
        sources = []
        watchedParents = []
        pending = false
        lock.unlock()
        prior.forEach { $0.cancel() }
    }

    private func markPending() {
        lock.lock()
        pending = true
        lock.unlock()
    }
}
