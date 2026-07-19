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
        timeoutSeconds: Int = 900,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionCommandResult {
        guard executablePath.hasPrefix("/"), (1...86_400).contains(timeoutSeconds) else {
            throw DistributionError.invalidArguments("Distribution command executable or timeout is invalid.")
        }
        var environment = SecureSubprocessEnvironment.currentUser
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["PAGER"] = "cat"
        environment["TERM"] = "dumb"
        let request = SecureSubprocessRequest(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory?.path ?? "/",
            timeoutMilliseconds: timeoutSeconds * 1_000,
            maximumStandardOutputBytes: 16 * 1_024 * 1_024,
            maximumStandardErrorBytes: 16 * 1_024 * 1_024
        )
        let secureResult: SecureSubprocessResult
        do {
            secureResult = try SecureSubprocessRunner().run(request, cancellation: cancellation)
        } catch let error as SecureSubprocessError {
            switch error {
            case .timedOut:
                throw DistributionError.commandTimedOut(label)
            case .cancelled:
                throw DistributionError.commandCancelled(label)
            case .outputLimitExceeded:
                throw DistributionError.commandOutputLimitExceeded(label)
            case .descendantProcessDetected, .processTreeCleanupFailed:
                throw DistributionError.commandProcessTreeViolation(label)
            case .executableRejected, .workingDirectoryRejected, .invalidRequest:
                throw DistributionError.invalidArguments("Distribution command failed secure path or request validation.")
            case .inputWriteFailed, .outputReadFailed, .waitFailed, .spawnSetupFailed, .launchFailed, .executableChanged:
                throw DistributionError.commandFailed(label, -1)
            }
        }
        guard let standardOutput = String(data: secureResult.standardOutput, encoding: .utf8),
              let standardError = String(data: secureResult.standardError, encoding: .utf8) else {
            throw DistributionError.commandFailed("\(label) output decoding", -1)
        }
        let result = DistributionCommandResult(
            standardOutput: standardOutput,
            standardError: standardError,
            exitStatus: secureResult.exitStatus,
            durationMilliseconds: secureResult.durationMilliseconds
        )
        guard result.exitStatus == 0 else {
            throw DistributionError.commandFailed(label, result.exitStatus)
        }
        return result
    }
}

public enum DistributionHash {
    public static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(
        fileURL: URL,
        cancellation: SecureSubprocessCancellation? = nil
    ) throws -> String {
        guard try DistributionFileSystem.isRegularNonSymlink(fileURL) else {
            throw DistributionError.invalidArtifact("hash input is not a regular non-symlink file")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard cancellation?.isCancelled != true else {
                throw DistributionError.commandCancelled("hash distribution file")
            }
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

    public static func decode<T: Codable>(_ type: T.Type, from url: URL) throws -> T {
        guard try DistributionFileSystem.isRegularNonSymlink(url) else {
            throw DistributionError.invalidArtifact("JSON input is not a regular non-symlink file")
        }
        let size = try DistributionFileSystem.size(of: url)
        guard size > 0, size <= 32 * 1_024 * 1_024 else {
            throw DistributionError.invalidArtifact("JSON input is empty or oversized")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value) == data else {
            throw DistributionError.invalidArtifact(
                "JSON input is not the exact canonical schema encoding"
            )
        }
        return value
    }
}

struct DistributionValidatedSourceIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let userID: UInt32
    let groupID: UInt32
    let permissions: UInt16
    let linkCount: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        userID = UInt32(metadata.st_uid)
        groupID = UInt32(metadata.st_gid)
        permissions = UInt16(metadata.st_mode & 0o7777)
        linkCount = UInt64(metadata.st_nlink)
        size = Int64(metadata.st_size)
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }

    init?(serialized: Substring) {
        let fields = serialized.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard fields.count == 11,
              let device = UInt64(fields[0]),
              let inode = UInt64(fields[1]),
              let userID = UInt32(fields[2]),
              let groupID = UInt32(fields[3]),
              let permissions = UInt16(fields[4]),
              let linkCount = UInt64(fields[5]),
              let size = Int64(fields[6]),
              let modifiedSeconds = Int64(fields[7]),
              let modifiedNanoseconds = Int64(fields[8]),
              let changedSeconds = Int64(fields[9]),
              let changedNanoseconds = Int64(fields[10]) else {
            return nil
        }
        self.device = device
        self.inode = inode
        self.userID = userID
        self.groupID = groupID
        self.permissions = permissions
        self.linkCount = linkCount
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
    }

    var serialized: String {
        [
            String(device), String(inode), String(userID), String(groupID),
            String(permissions), String(linkCount), String(size),
            String(modifiedSeconds), String(modifiedNanoseconds),
            String(changedSeconds), String(changedNanoseconds)
        ].joined(separator: ",")
    }
}

struct DistributionValidatedSourceBinding: Equatable, Sendable {
    private static let fragmentPrefix = "hostwright-validated-source-v2:"

    let fileIdentity: DistributionValidatedSourceIdentity
    let directoryIdentities: [DistributionValidatedSourceIdentity]

    init(
        fileIdentity: DistributionValidatedSourceIdentity,
        directoryIdentities: [DistributionValidatedSourceIdentity]
    ) {
        self.fileIdentity = fileIdentity
        self.directoryIdentities = directoryIdentities
    }

    init?(fragment: String) {
        guard fragment.hasPrefix(Self.fragmentPrefix) else { return nil }
        let fields = fragment.dropFirst(Self.fragmentPrefix.count).split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 2,
              let fileIdentity = DistributionValidatedSourceIdentity(serialized: fields[0]) else {
            return nil
        }
        let directoryIdentities: [DistributionValidatedSourceIdentity]
        if fields[1].isEmpty {
            directoryIdentities = []
        } else {
            let parsed = fields[1].split(separator: ";", omittingEmptySubsequences: false)
                .compactMap(DistributionValidatedSourceIdentity.init(serialized:))
            guard parsed.count == fields[1].split(
                separator: ";",
                omittingEmptySubsequences: false
            ).count else { return nil }
            directoryIdentities = parsed
        }
        self.fileIdentity = fileIdentity
        self.directoryIdentities = directoryIdentities
    }

    var fragment: String {
        Self.fragmentPrefix + fileIdentity.serialized + ":"
            + directoryIdentities.map(\.serialized).joined(separator: ";")
    }
}

public enum DistributionFileSystem {
    public static func createExclusiveDirectory(_ url: URL, mode: Int = 0o700) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw DistributionError.existingOutput(url.path)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        try synchronizeDirectory(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
        guard fchmod(descriptor, mode_t(mode)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
        guard source.isFileURL else {
            throw DistributionError.invalidArtifact("source file is not regular: \(source.lastPathComponent)")
        }
        let binding: DistributionValidatedSourceBinding?
        if let fragment = source.fragment {
            guard let validatedBinding = DistributionValidatedSourceBinding(fragment: fragment) else {
                throw DistributionError.invalidArtifact("source file identity binding is invalid")
            }
            binding = validatedBinding
        } else {
            binding = nil
        }

        let sourceDescriptor = try openSource(source, binding: binding)
        guard sourceDescriptor >= 0 else {
            throw DistributionError.invalidArtifact(
                "source file is not regular: \(source.lastPathComponent)"
            )
        }
        defer { close(sourceDescriptor) }
        var sourceMetadata = stat()
        guard fstat(sourceDescriptor, &sourceMetadata) == 0,
              sourceMetadata.st_mode & S_IFMT == S_IFREG else {
            throw DistributionError.invalidArtifact(
                "source file is not regular: \(source.lastPathComponent)"
            )
        }
        let openedIdentity = DistributionValidatedSourceIdentity(metadata: sourceMetadata)
        guard binding == nil || binding?.fileIdentity == openedIdentity else {
            throw DistributionError.invalidArtifact(
                "source file changed after validation: \(source.lastPathComponent)"
            )
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let destinationDescriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(mode)
        )
        guard destinationDescriptor >= 0 else {
            if errno == EEXIST { throw DistributionError.existingOutput(destination.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var complete = false
        defer {
            close(destinationDescriptor)
            if !complete { unlink(destination.path) }
        }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(sourceDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            try buffer.withUnsafeBytes { rawBuffer in
                var offset = 0
                while offset < count {
                    let result = Darwin.write(
                        destinationDescriptor,
                        rawBuffer.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += result
                }
            }
        }
        var finalSourceMetadata = stat()
        guard fstat(sourceDescriptor, &finalSourceMetadata) == 0,
              DistributionValidatedSourceIdentity(metadata: finalSourceMetadata) == openedIdentity else {
            throw DistributionError.invalidArtifact(
                "source file changed while copying: \(source.lastPathComponent)"
            )
        }
        guard fchmod(destinationDescriptor, mode_t(mode)) == 0,
              fsync(destinationDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var destinationMetadata = stat()
        guard fstat(destinationDescriptor, &destinationMetadata) == 0,
              destinationMetadata.st_mode & S_IFMT == S_IFREG,
              destinationMetadata.st_uid == geteuid(),
              destinationMetadata.st_nlink == 1,
              Int(destinationMetadata.st_mode & 0o7777) == mode else {
            throw DistributionError.invalidArtifact("copied distribution file metadata is unsafe")
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: destinationDescriptor,
                path: destination.path,
                role: "copied distribution file"
            )
        } catch {
            throw DistributionError.invalidArtifact("copied distribution file grants access through an ACL")
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
        complete = true
    }

    static func bindValidatedSource(
        _ url: URL,
        metadata: stat,
        directoryIdentities: [DistributionValidatedSourceIdentity] = []
    ) throws -> URL {
        guard url.isFileURL, url.fragment == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DistributionError.invalidArtifact("validated source URL is invalid")
        }
        components.fragment = DistributionValidatedSourceBinding(
            fileIdentity: DistributionValidatedSourceIdentity(metadata: metadata),
            directoryIdentities: directoryIdentities
        ).fragment
        guard let boundURL = components.url, boundURL.path == url.path else {
            throw DistributionError.invalidArtifact("validated source URL could not be bound")
        }
        return boundURL
    }

    private static func openSource(
        _ source: URL,
        binding: DistributionValidatedSourceBinding?
    ) throws -> Int32 {
        guard let binding, !binding.directoryIdentities.isEmpty else {
            return open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        let components = source.path.split(separator: "/").map(String.init)
        let parentComponents = components.dropLast()
        guard parentComponents.count >= binding.directoryIdentities.count else {
            throw DistributionError.invalidArtifact("source file identity binding is invalid")
        }
        let firstValidatedIndex = parentComponents.count - binding.directoryIdentities.count
        var currentDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var currentPath = ""
        for (index, component) in parentComponents.enumerated() {
            let childDescriptor = openat(
                currentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            close(currentDescriptor)
            guard childDescriptor >= 0 else {
                throw DistributionError.invalidArtifact(
                    "source directory changed after validation: \(component)"
                )
            }
            currentDescriptor = childDescriptor
            currentPath += "/\(component)"
            guard index >= firstValidatedIndex else { continue }
            var metadata = stat()
            let expected = binding.directoryIdentities[index - firstValidatedIndex]
            guard fstat(currentDescriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o7777 == 0o700,
                  DistributionValidatedSourceIdentity(metadata: metadata) == expected else {
                close(currentDescriptor)
                throw DistributionError.invalidArtifact(
                    "source directory changed after validation: \(component)"
                )
            }
            do {
                try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                    fileDescriptor: currentDescriptor,
                    path: currentPath,
                    role: "validated source directory"
                )
            } catch {
                close(currentDescriptor)
                throw DistributionError.invalidArtifact(
                    "source directory changed after validation: \(component)"
                )
            }
        }
        let descriptor = openat(
            currentDescriptor,
            components.last!,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        close(currentDescriptor)
        return descriptor
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

package enum DistributionTemporaryCleanupStatus: String, Codable, Equatable, Sendable {
    case complete
    case pending
}

package struct DistributionTemporaryCleanupReport: Codable, Equatable, Sendable {
    package let status: DistributionTemporaryCleanupStatus
    package let pendingPaths: [String]

    package init(status: DistributionTemporaryCleanupStatus, pendingPaths: [String]) {
        self.status = status
        self.pendingPaths = pendingPaths
    }
}

package enum DistributionPostCommitCleanup {
    package static func removeOwnedTemporaryItem(
        _ url: URL,
        remover: (URL) throws -> Void = { try DistributionFileSystem.removeOwnedTemporaryItem($0) }
    ) -> DistributionTemporaryCleanupReport {
        do {
            try remover(url)
            return DistributionTemporaryCleanupReport(status: .complete, pendingPaths: [])
        } catch {
            return DistributionTemporaryCleanupReport(status: .pending, pendingPaths: [url.path])
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
