import Darwin
import Foundation

public enum DockerContextError: Error, Equatable, Sendable {
    case invalidName
    case invalidSocketPath
    case unsafeDirectory
    case alreadyExists
    case notFound
    case invalidDocument
    case activeContextUnavailable
}

public struct DockerContext: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let name: String
    public let socketPath: String
    public let enabled: Bool
    public let generation: UInt64

    public init(
        name: String,
        socketPath: String,
        enabled: Bool = true,
        generation: UInt64 = 1
    ) throws {
        guard Self.isSafeName(name) else { throw DockerContextError.invalidName }
        guard Self.isSafeSocketPath(socketPath) else {
            throw DockerContextError.invalidSocketPath
        }
        guard generation > 0 else { throw DockerContextError.invalidDocument }
        self.schemaVersion = Self.schemaVersion
        self.name = name
        self.socketPath = socketPath
        self.enabled = enabled
        self.generation = generation
    }

    public var endpoint: String { "unix://" + socketPath }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              Self.isSafeName(name),
              Self.isSafeSocketPath(socketPath),
              generation > 0 else {
            throw DockerContextError.invalidDocument
        }
    }

    fileprivate static func isSafeName(_ name: String) -> Bool {
        name.utf8.count <= 64
            && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    fileprivate static func isSafeSocketPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/")
            && path.utf8.count < 100
            && !path.contains("\0")
            && !path.contains("//")
            && !path.hasSuffix("/")
            && !components.isEmpty
            && !components.contains(".")
            && !components.contains("..") else {
            return false
        }
        var current = "/"
        for component in components.dropLast() {
            current = current == "/" ? "/" + component : current + "/" + component
            var status = stat()
            if lstat(current, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else { return false }
            } else if errno == ENOENT {
                break
            } else {
                return false
            }
        }
        return true
    }
}

public final class DockerContextStore: @unchecked Sendable {
    public let rootDirectory: String
    private let lock = NSLock()

    public init(rootDirectory: String) throws {
        guard rootDirectory.hasPrefix("/"),
              rootDirectory.utf8.count <= 4_096,
              !rootDirectory.contains("\0"),
              !rootDirectory.contains("//"),
              !rootDirectory.hasSuffix("/"),
              !rootDirectory.split(separator: "/", omittingEmptySubsequences: true).contains("."),
              !rootDirectory.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw DockerContextError.unsafeDirectory
        }
        try Self.ensureRoot(rootDirectory)
        self.rootDirectory = rootDirectory
    }

    public func create(_ context: DockerContext) throws {
        try withLock {
            try context.validate()
            let path = try contextPath(context.name)
            var status = stat()
            guard lstat(path, &status) != 0, errno == ENOENT else {
                throw DockerContextError.alreadyExists
            }
            try write(context, at: path)
        }
    }

    public func inspect(name: String) throws -> DockerContext {
        try withLock {
            let path = try contextPath(name)
            var status = stat()
            guard lstat(path, &status) == 0 else {
                throw errno == ENOENT ? DockerContextError.notFound : DockerContextError.unsafeDirectory
            }
            guard (status.st_mode & S_IFMT) == S_IFREG,
                  (status.st_mode & 0o7777) == 0o600,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_size <= 16 * 1_024 else {
                throw DockerContextError.unsafeDirectory
            }
            guard let data = FileManager.default.contents(atPath: path), data.count <= 16 * 1_024,
                  let context = try? JSONDecoder().decode(DockerContext.self, from: data) else {
                throw DockerContextError.invalidDocument
            }
            try context.validate()
            guard context.name == name else { throw DockerContextError.invalidDocument }
            return context
        }
    }

    public func activate(name: String) throws {
        try withLock {
            let context = try inspectUnlocked(name: name)
            guard context.enabled else { throw DockerContextError.activeContextUnavailable }
            try writeActive(name)
        }
    }

    public func active() throws -> DockerContext {
        try withLock {
            guard let data = try? readActiveData(),
                  data.count <= 128,
                  let name = String(data: data, encoding: .utf8),
                  DockerContext.isSafeName(name.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DockerContextError.activeContextUnavailable
            }
            return try inspectUnlocked(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public func disable(name: String) throws -> DockerContext {
        try withLock {
            let current = try inspectUnlocked(name: name)
            let updated = try DockerContext(
                name: current.name,
                socketPath: current.socketPath,
                enabled: false,
                generation: current.generation
            )
            try write(updated, at: try contextPath(name))
            return updated
        }
    }

    public func repair(name: String) throws -> DockerContext {
        try withLock {
            let current = try inspectUnlocked(name: name)
            try write(current, at: try contextPath(name))
            return current
        }
    }

    public func rotate(name: String, socketPath: String) throws -> DockerContext {
        try withLock {
            let current = try inspectUnlocked(name: name)
            let updated = try DockerContext(
                name: current.name,
                socketPath: socketPath,
                enabled: current.enabled,
                generation: current.generation + 1
            )
            try write(updated, at: try contextPath(name))
            return updated
        }
    }

    public func delete(name: String) throws {
        try withLock {
            _ = try inspectUnlocked(name: name)
            let path = try contextPath(name)
            guard unlink(path) == 0 else {
                throw DockerContextError.unsafeDirectory
            }
            if let activeName = try? activeName(), activeName == name {
                _ = unlink(activePath)
            }
        }
    }

    private var activePath: String {
        URL(fileURLWithPath: rootDirectory, isDirectory: true)
            .appendingPathComponent("active", isDirectory: false).path
    }

    private func activeName() throws -> String {
        guard let data = try? readActiveData(),
              let name = String(data: data, encoding: .utf8) else {
            throw DockerContextError.activeContextUnavailable
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readActiveData() throws -> Data {
        let descriptor = Darwin.open(activePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerContextError.activeContextUnavailable }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & 0o7777) == 0o600,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size <= 128 else {
            throw DockerContextError.activeContextUnavailable
        }
        var buffer = [UInt8](repeating: 0, count: 129)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count >= 0, count <= 128 else {
            throw DockerContextError.activeContextUnavailable
        }
        return Data(buffer.prefix(count))
    }

    private func writeActive(_ name: String) throws {
        try writeData(Data(name.utf8), at: activePath)
    }

    private func inspectUnlocked(name: String) throws -> DockerContext {
        let path = try contextPath(name)
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw errno == ENOENT ? DockerContextError.notFound : DockerContextError.unsafeDirectory
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & 0o7777) == 0o600,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size <= 16 * 1_024,
              let data = FileManager.default.contents(atPath: path),
              let context = try? JSONDecoder().decode(DockerContext.self, from: data) else {
            throw DockerContextError.invalidDocument
        }
        try context.validate()
        guard context.name == name else { throw DockerContextError.invalidDocument }
        return context
    }

    private func contextPath(_ name: String) throws -> String {
        guard DockerContext.isSafeName(name) else { throw DockerContextError.invalidName }
        return URL(fileURLWithPath: rootDirectory, isDirectory: true)
            .appendingPathComponent(name + ".json", isDirectory: false).path
    }

    private func write(_ context: DockerContext, at path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(context)
        try writeData(data, at: path)
    }

    private func writeData(_ data: Data, at path: String) throws {
        guard data.count <= 16 * 1_024 else { throw DockerContextError.invalidDocument }
        let temporary = path + ".tmp-" + UUID().uuidString
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
            guard chmod(temporary, 0o600) == 0 else { throw DockerContextError.unsafeDirectory }
            guard rename(temporary, path) == 0 else { throw DockerContextError.unsafeDirectory }
            var status = stat()
            guard lstat(path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  (status.st_mode & 0o7777) == 0o600,
                  status.st_uid == geteuid(), status.st_nlink == 1 else {
                throw DockerContextError.unsafeDirectory
            }
        } catch {
            _ = unlink(temporary)
            throw error
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func ensureRoot(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = "/"
        for (index, component) in components.enumerated() {
            current = current == "/" ? "/" + component : current + "/" + component
            var status = stat()
            if lstat(current, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw DockerContextError.unsafeDirectory
                }
                if index == components.count - 1 {
                    guard (status.st_mode & 0o7777) == 0o700,
                          status.st_uid == geteuid() else {
                        throw DockerContextError.unsafeDirectory
                    }
                }
                continue
            }
            guard errno == ENOENT, index == components.count - 1,
                  mkdir(current, 0o700) == 0 else {
                throw DockerContextError.unsafeDirectory
            }
            guard chmod(current, 0o700) == 0 else {
                throw DockerContextError.unsafeDirectory
            }
        }
    }
}
