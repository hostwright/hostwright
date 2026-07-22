import Containerization
import CryptoKit
import Darwin
import Foundation
import HostwrightRuntime

enum ContainerizationHelperPersistenceError: Error, Equatable {
    case pathMustBeAbsolute
    case pathNotNormalized
    case unsafeParent
    case unsafeDirectory
    case unsafeFile
    case invalidRecord
    case inputTooLarge
    case operationFailed
}

enum ContainerizationHelperPersistedPhase: String, Codable, Sendable {
    case preparedCreate = "prepared-create"
    case created
    case preparedStart = "prepared-start"
    case running
    case preparedRestart = "prepared-restart"
    case stopped
    case preparedDelete = "prepared-delete"
    case failed
}

struct ContainerizationHelperPersistedRecord: Codable, Sendable {
    let resourceIdentifier: String
    let resourceUUID: String
    let projectUUID: String
    let image: ContainerizationHelperImageEvidence
    var command: [String]
    var environment: [RuntimeInventoryEnvironmentEntry]
    var labels: [RuntimeInventoryLabel]
    var workingDirectory: String?
    var user: String?
    let mutationContext: RuntimeMutationContext
    var runtimeInstanceID: String?
    var phase: ContainerizationHelperPersistedPhase
    var failureCategory: String?

    init(
        request: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) {
        resourceIdentifier = request.resourceIdentifier
        resourceUUID = request.resourceUUID.lowercased()
        projectUUID = request.projectUUID.lowercased()
        image = request.image
        command = request.command
        environment = request.environment
        labels = request.labels
        workingDirectory = nil
        user = nil
        mutationContext = context
        runtimeInstanceID = UUID().uuidString.lowercased()
        phase = .preparedCreate
        failureCategory = nil
    }
}

final class ContainerizationHelperStateStore: @unchecked Sendable {
    static let maximumRecordBytes = 1 * 1_024 * 1_024
    static let maximumLogBytes = 8 * 1_024 * 1_024

    let rootURL: URL
    let recordsURL: URL
    let logsURL: URL

    init(rootURL: URL) throws {
        try Self.validateNormalizedAbsolute(rootURL)
        self.rootURL = rootURL
        self.recordsURL = rootURL.appendingPathComponent("records", isDirectory: true)
        self.logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        try Self.preparePrivateDirectory(rootURL)
        try Self.preparePrivateDirectory(recordsURL)
        try Self.preparePrivateDirectory(logsURL)
    }

    func loadRecords() throws -> [ContainerizationHelperPersistedRecord] {
        let names = try FileManager.default.contentsOfDirectory(atPath: recordsURL.path).sorted()
        var records: [ContainerizationHelperPersistedRecord] = []
        var seenIdentifiers = Set<String>()
        let decoder = JSONDecoder()

        for name in names {
            guard name.hasSuffix(".json"),
                  name.range(of: "^[a-f0-9]{64}\\.json$", options: .regularExpression) != nil else {
                throw ContainerizationHelperPersistenceError.unsafeFile
            }
            let fileURL = recordsURL.appendingPathComponent(name, isDirectory: false)
            let metadata = try Self.requirePrivateRegularFile(fileURL)
            guard metadata.st_size >= 0,
                  metadata.st_size <= Self.maximumRecordBytes else {
                throw ContainerizationHelperPersistenceError.inputTooLarge
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let record: ContainerizationHelperPersistedRecord
            do {
                record = try decoder.decode(ContainerizationHelperPersistedRecord.self, from: data)
            } catch {
                throw ContainerizationHelperPersistenceError.invalidRecord
            }
            guard Self.validResourceIdentifier(record.resourceIdentifier),
                  Self.digest(record.resourceIdentifier) + ".json" == name,
                  seenIdentifiers.insert(record.resourceIdentifier).inserted else {
                throw ContainerizationHelperPersistenceError.invalidRecord
            }
            records.append(record)
        }
        return records.sorted { $0.resourceIdentifier < $1.resourceIdentifier }
    }

    func save(_ record: ContainerizationHelperPersistedRecord) throws {
        guard Self.validResourceIdentifier(record.resourceIdentifier) else {
            throw ContainerizationHelperPersistenceError.invalidRecord
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw ContainerizationHelperPersistenceError.invalidRecord
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw ContainerizationHelperPersistenceError.inputTooLarge
        }

        let finalURL = recordURL(for: record.resourceIdentifier)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try Self.requirePrivateRegularFile(finalURL)
        }
        let temporaryURL = recordsURL.appendingPathComponent(
            ".write-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                _ = unlink(temporaryURL.path)
            }
        }
        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0,
              rename(temporaryURL.path, finalURL.path) == 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        removeTemporary = false
        try syncDirectory(recordsURL)
    }

    func removeRecord(resourceIdentifier: String) throws {
        let fileURL = recordURL(for: resourceIdentifier)
        var metadata = stat()
        if lstat(fileURL.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ContainerizationHelperPersistenceError.operationFailed
            }
            return
        }
        _ = try Self.requirePrivateRegularFile(fileURL)
        guard unlink(fileURL.path) == 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        try syncDirectory(recordsURL)
    }

    func logWriter(resourceIdentifier: String) throws -> any Writer {
        guard Self.validResourceIdentifier(resourceIdentifier) else {
            throw ContainerizationHelperPersistenceError.invalidRecord
        }
        return ContainerizationHelperBoundedLogWriter(
            fileURL: logURL(for: resourceIdentifier),
            maximumBytes: Self.maximumLogBytes
        )
    }

    func readLog(resourceIdentifier: String, lineLimit: Int) throws -> String {
        guard (1...10_000).contains(lineLimit) else {
            throw ContainerizationHelperPersistenceError.invalidRecord
        }
        let fileURL = logURL(for: resourceIdentifier)
        var metadata = stat()
        if lstat(fileURL.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ContainerizationHelperPersistenceError.operationFailed
            }
            return ""
        }
        metadata = try Self.requirePrivateRegularFile(fileURL)
        guard metadata.st_size >= 0,
              metadata.st_size <= Self.maximumLogBytes else {
            throw ContainerizationHelperPersistenceError.inputTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(lineLimit).joined(separator: "\n")
    }

    func removeLog(resourceIdentifier: String) throws {
        let fileURL = logURL(for: resourceIdentifier)
        var metadata = stat()
        if lstat(fileURL.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ContainerizationHelperPersistenceError.operationFailed
            }
            return
        }
        _ = try Self.requirePrivateRegularFile(fileURL)
        guard unlink(fileURL.path) == 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        try syncDirectory(logsURL)
    }

    func logURL(for resourceIdentifier: String) -> URL {
        logsURL.appendingPathComponent(Self.digest(resourceIdentifier) + ".log", isDirectory: false)
    }

    private func recordURL(for resourceIdentifier: String) -> URL {
        recordsURL.appendingPathComponent(Self.digest(resourceIdentifier) + ".json", isDirectory: false)
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
    }

    static func preparePrivateDirectory(_ directoryURL: URL) throws {
        try validateNormalizedAbsolute(directoryURL)
        let parent = directoryURL.deletingLastPathComponent()
        var parentMetadata = stat()
        guard lstat(parent.path, &parentMetadata) == 0,
              (parentMetadata.st_mode & S_IFMT) == S_IFDIR,
              parentMetadata.st_uid == geteuid(),
              parentMetadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw ContainerizationHelperPersistenceError.unsafeParent
        }

        var metadata = stat()
        if lstat(directoryURL.path, &metadata) != 0 {
            guard errno == ENOENT,
                  mkdir(directoryURL.path, S_IRWXU) == 0,
                  chmod(directoryURL.path, S_IRWXU) == 0,
                  lstat(directoryURL.path, &metadata) == 0 else {
                throw ContainerizationHelperPersistenceError.unsafeDirectory
            }
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISTXT) == 0,
              metadata.st_mode & S_IRWXU == S_IRWXU else {
            throw ContainerizationHelperPersistenceError.unsafeDirectory
        }
    }

    static func requirePrivateRegularFile(_ fileURL: URL) throws -> stat {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISTXT) == 0,
              metadata.st_mode & S_IRUSR != 0,
              metadata.st_mode & S_IWUSR != 0 else {
            throw ContainerizationHelperPersistenceError.unsafeFile
        }
        return metadata
    }

    static func validResourceIdentifier(_ value: String) -> Bool {
        value.utf8.count <= LinuxContainer.maxIDLength &&
            value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
                options: .regularExpression
            ) != nil
    }

    static func validateNormalizedAbsolute(_ url: URL) throws {
        guard url.path.hasPrefix("/") else {
            throw ContainerizationHelperPersistenceError.pathMustBeAbsolute
        }
        guard url.standardizedFileURL.path == url.path else {
            throw ContainerizationHelperPersistenceError.pathNotNormalized
        }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 && errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw ContainerizationHelperPersistenceError.operationFailed
                }
                offset += written
            }
        }
    }
}

final class ContainerizationHelperBoundedLogWriter: Writer, @unchecked Sendable {
    private let fileURL: URL
    private let maximumBytes: Int
    private let lock = NSLock()

    init(fileURL: URL, maximumBytes: Int) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        let descriptor = Darwin.open(
            fileURL.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISTXT) == 0,
              metadata.st_size >= 0 else {
            throw ContainerizationHelperPersistenceError.unsafeFile
        }
        let remaining = max(0, maximumBytes - Int(metadata.st_size))
        guard remaining > 0 else { return }
        let bounded = data.prefix(remaining)
        try bounded.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 && errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw ContainerizationHelperPersistenceError.operationFailed
                }
                offset += written
            }
        }
    }

    func close() throws {}
}
