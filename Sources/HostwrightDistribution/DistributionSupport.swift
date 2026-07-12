import CryptoKit
import Darwin
import Foundation
import HostwrightCore

public struct DistributionCommandResult: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitStatus: Int32
    public let durationMilliseconds: Int

    public init(
        standardOutput: String,
        standardError: String,
        exitStatus: Int32,
        durationMilliseconds: Int
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitStatus = exitStatus
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct DistributionProcessRunner: Sendable {
    public init() {}

    public func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        label: String,
        timeoutSeconds: Int = 900
    ) throws -> DistributionCommandResult {
        guard executablePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executablePath),
              timeoutSeconds > 0 else {
            throw DistributionError.invalidArguments("Distribution command executable or timeout is invalid.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try process.run()
        } catch {
            throw DistributionError.commandFailed(label, -1)
        }

        let output = DistributionPipeBuffer()
        let errors = DistributionPipeBuffer()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        if terminated.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + .seconds(2))
            }
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + .seconds(2))
            throw DistributionError.commandTimedOut(label)
        }

        if readers.wait(timeout: .now() + .seconds(5)) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + .seconds(2))
            throw DistributionError.commandFailed("\(label) output drain", -1)
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let result = DistributionCommandResult(
            standardOutput: String(data: output.value(), encoding: .utf8) ?? "",
            standardError: String(data: errors.value(), encoding: .utf8) ?? "",
            exitStatus: process.terminationStatus,
            durationMilliseconds: Int(clamping: elapsed / 1_000_000)
        )
        guard result.exitStatus == 0 else {
            throw DistributionError.commandFailed(label, result.exitStatus)
        }
        return result
    }
}

private final class DistributionPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.withLock { data = value }
    }

    func value() -> Data {
        lock.withLock { data }
    }
}

public enum DistributionHash {
    public static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileURL: URL) throws -> String {
        guard try DistributionFileSystem.isRegularNonSymlink(fileURL) else {
            throw DistributionError.invalidArtifact("hash input is not a regular non-symlink file")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DistributionJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard try DistributionFileSystem.isRegularNonSymlink(url) else {
            throw DistributionError.invalidArtifact("JSON input is not a regular non-symlink file")
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

public enum DistributionFileSystem {
    public static func createExclusiveDirectory(_ url: URL, mode: Int = 0o700) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw DistributionError.existingOutput(url.path)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    public static func writeNewFile(_ data: Data, to url: URL, mode: Int) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        guard descriptor >= 0 else {
            if errno == EEXIST { throw DistributionError.existingOutput(url.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var complete = false
        defer {
            close(descriptor)
            if !complete { unlink(url.path) }
        }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        complete = true
    }

    public static func copyRegularFile(from source: URL, to destination: URL, mode: Int) throws {
        guard try isRegularNonSymlink(source) else {
            throw DistributionError.invalidArtifact("source file is not regular: \(source.lastPathComponent)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DistributionError.existingOutput(destination.path)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
    }

    public static func isRegularNonSymlink(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (metadata.st_mode & S_IFMT) == S_IFREG
    }

    public static func isDirectoryNonSymlink(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    public static func entryExists(_ url: URL) -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return true }
        return errno != ENOENT && errno != ENOTDIR
    }

    public static func size(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw DistributionError.invalidArtifact("file size is unavailable")
        }
        return number.intValue
    }

    public static func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else {
            throw DistributionError.invalidArtifact("file mode is unavailable")
        }
        return number.intValue & 0o777
    }

    public static func removeOwnedTemporaryItem(_ url: URL) throws {
        try DistributionTemporaryPathPolicy.validate(url, role: "temporary cleanup")
        if entryExists(url) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public struct DistributionEnvironmentProbe: Sendable {
    public let operatingSystem: String
    public let operatingSystemBuild: String
    public let architecture: String
    public let hardwareModel: String
    public let memoryBytes: Int

    public static var current: DistributionEnvironmentProbe {
        let memory = min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max))
        return DistributionEnvironmentProbe(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            operatingSystemBuild: sysctlString("kern.osversion") ?? "unavailable",
            architecture: architectureName(),
            hardwareModel: sysctlString("hw.model") ?? "unavailable",
            memoryBytes: Int(memory)
        )
    }

    public func evidenceEnvironment(toolVersions: [String: String]) -> HostwrightEvidenceEnvironment {
        HostwrightEvidenceEnvironment(
            operatingSystem: operatingSystem,
            build: operatingSystemBuild,
            architecture: architecture,
            hardwareModel: hardwareModel,
            memoryBytes: memoryBytes,
            toolVersions: toolVersions
        )
    }

    public var unavailableFacts: [String] {
        [operatingSystem, operatingSystemBuild, architecture, hardwareModel].filter {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.isEmpty || value == "unknown" || value == "unavailable"
        }
    }

    private static func architectureName() -> String {
        var system = utsname()
        uname(&system)
        let mirror = Mirror(reflecting: system.machine)
        let bytes = mirror.children.compactMap { $0.value as? Int8 }.prefix { $0 != 0 }
        return String(bytes: bytes.map(UInt8.init(bitPattern:)), encoding: .utf8) ?? "unavailable"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public enum DistributionTimestamp {
    public static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
