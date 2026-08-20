import Darwin
import Foundation

public enum PodSandboxRecoveryStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPath
    case parentMissing
    case unsafePath
    case notRegularFile
    case fileTooLarge
    case malformed
    case duplicateField(String)
    case unknownField(String)
    case missingField(String)
    case nonCanonical
    case unsupportedVersion(Int)
    case ioFailure

    public var description: String {
        switch self {
        case .invalidPath: "The pod-sandbox recovery path is invalid."
        case .parentMissing: "The pod-sandbox recovery parent is unavailable."
        case .unsafePath: "The pod-sandbox recovery path is unsafe."
        case .notRegularFile: "The pod-sandbox recovery record is not a regular file."
        case .fileTooLarge: "The pod-sandbox recovery record exceeds its bounded size."
        case .malformed: "The pod-sandbox recovery record is malformed."
        case .duplicateField(let field): "The pod-sandbox recovery record repeats field \(field)."
        case .unknownField(let field): "The pod-sandbox recovery record contains unsupported field \(field)."
        case .missingField(let field): "The pod-sandbox recovery record is missing field \(field)."
        case .nonCanonical: "The pod-sandbox recovery record is not canonical JSON."
        case .unsupportedVersion(let version): "Pod-sandbox recovery schema version \(version) is unsupported."
        case .ioFailure: "The pod-sandbox recovery record could not be read or written."
        }
    }
}

public protocol PodSandboxRecoveryStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public final class FilePodSandboxRecoveryStore: @unchecked Sendable, PodSandboxRecoveryStore {
    public static let maximumBytes = 1 * 1_024 * 1_024

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) throws {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else {
            throw PodSandboxRecoveryStoreError.invalidPath
        }
        let standardized = fileURL.standardizedFileURL
        guard standardized.path != "/" else {
            throw PodSandboxRecoveryStoreError.invalidPath
        }
        try Self.requirePrivateParent(standardized.deletingLastPathComponent())
        try Self.validateExistingFile(standardized)
        self.fileURL = standardized
    }

    public func load() throws -> Data? {
        try lock.withLock {
            try Self.validateExistingFile(fileURL)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            } catch {
                throw PodSandboxRecoveryStoreError.ioFailure
            }
            if let size = attributes[.size] as? NSNumber,
               size.intValue > Self.maximumBytes {
                throw PodSandboxRecoveryStoreError.fileTooLarge
            }
            do {
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                guard data.count <= Self.maximumBytes else {
                    throw PodSandboxRecoveryStoreError.fileTooLarge
                }
                return data
            } catch let error as PodSandboxRecoveryStoreError {
                throw error
            } catch {
                throw PodSandboxRecoveryStoreError.ioFailure
            }
        }
    }

    public func save(_ data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw PodSandboxRecoveryStoreError.fileTooLarge
        }
        try lock.withLock {
            try Self.requirePrivateParent(fileURL.deletingLastPathComponent())
            try Self.validateExistingFile(fileURL)
            let temporary = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporary, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: temporary.path
                )
                guard rename(temporary.path, fileURL.path) == 0 else {
                    throw PodSandboxRecoveryStoreError.ioFailure
                }
            } catch let error as PodSandboxRecoveryStoreError {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw PodSandboxRecoveryStoreError.ioFailure
            }
        }
    }

    private static func requirePrivateParent(_ parent: URL) throws {
        var metadata = stat()
        guard lstat(parent.path, &metadata) == 0 else {
            throw errno == ENOENT
                ? PodSandboxRecoveryStoreError.parentMissing
                : PodSandboxRecoveryStoreError.ioFailure
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw PodSandboxRecoveryStoreError.unsafePath
        }
        guard parent.resolvingSymlinksInPath().path == parent.path else {
            throw PodSandboxRecoveryStoreError.unsafePath
        }
    }

    private static func validateExistingFile(_ fileURL: URL) throws {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0 else {
            guard errno == ENOENT else {
                throw PodSandboxRecoveryStoreError.ioFailure
            }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw metadata.st_mode & S_IFMT == S_IFLNK
                ? PodSandboxRecoveryStoreError.unsafePath
                : PodSandboxRecoveryStoreError.notRegularFile
        }
    }
}

let podSandboxRecoverySchemaVersion = 1

struct PodSandboxRecoveryJournal: Codable, Equatable {
    let schemaVersion: Int
    let records: [PodSandboxRecoveryRecord]
    let tombstones: [PodSandboxRecoveryTombstone]
}

struct PodSandboxRecoveryRecord: Codable, Equatable {
    let spec: PodSandboxSpec
    let state: PodSandboxState
    let resourcePresent: Bool
    let prepared: Bool
    let running: Bool
    let cleanupComplete: Bool
    let cleanupResourceCount: Int
    let lastTransition: PodSandboxTransition?
    let replays: [PodSandboxRecoveryReplay]
}

struct PodSandboxRecoveryTombstone: Codable, Equatable {
    let id: PodSandboxID
    let ownerID: String
    let generation: UInt64
    let lastTransition: PodSandboxTransition
    let replays: [PodSandboxRecoveryReplay]
}

struct PodSandboxRecoveryReplay: Codable, Equatable {
    let requestID: String
    let transition: PodSandboxTransition
    let ownerID: String
    let generation: UInt64
    let spec: PodSandboxSpec?
    let result: PodSandboxLifecycleResult
}

func encodePodSandboxRecoveryJournal(_ journal: PodSandboxRecoveryJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(journal)
}

func decodePodSandboxRecoveryJournal(_ data: Data) throws -> PodSandboxRecoveryJournal {
    guard !data.isEmpty, data.count <= FilePodSandboxRecoveryStore.maximumBytes else {
        throw PodSandboxRecoveryStoreError.fileTooLarge
    }

    let keys: [String]
    do {
        keys = try JSONTopLevelObject.keys(in: data)
    } catch let error as GuestAgentProtocolError {
        switch error {
        case .duplicateField(let field):
            throw PodSandboxRecoveryStoreError.duplicateField(field)
        case .unknownField(let field):
            throw PodSandboxRecoveryStoreError.unknownField(field)
        case .missingField(let field):
            throw PodSandboxRecoveryStoreError.missingField(field)
        default:
            throw PodSandboxRecoveryStoreError.malformed
        }
    } catch {
        throw PodSandboxRecoveryStoreError.malformed
    }

    let allowed: Set<String> = ["schemaVersion", "records", "tombstones"]
    for key in keys where !allowed.contains(key) {
        throw PodSandboxRecoveryStoreError.unknownField(key)
    }
    guard Set(keys) == allowed else {
        throw PodSandboxRecoveryStoreError.missingField("journal")
    }

    let journal: PodSandboxRecoveryJournal
    do {
        journal = try JSONDecoder().decode(PodSandboxRecoveryJournal.self, from: data)
    } catch {
        throw PodSandboxRecoveryStoreError.malformed
    }
    guard journal.schemaVersion == podSandboxRecoverySchemaVersion else {
        throw PodSandboxRecoveryStoreError.unsupportedVersion(journal.schemaVersion)
    }
    let canonical: Data
    do {
        canonical = try encodePodSandboxRecoveryJournal(journal)
    } catch {
        throw PodSandboxRecoveryStoreError.malformed
    }
    guard canonical == data else {
        throw PodSandboxRecoveryStoreError.nonCanonical
    }
    return journal
}
