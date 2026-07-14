import Darwin
import Foundation
import HostwrightCore
import HostwrightHealth
import HostwrightRuntime
import HostwrightSecrets

public struct CLIEnvironment: @unchecked Sendable {
    public var fileExists: (String) -> Bool
    public var readTextFile: (String) throws -> String
    public var writeTextFile: (String, String) throws -> Void
    public var writeNewTextFile: (String, String) throws -> Void
    public var executablePath: (String) -> String?
    public var localPathResolution: (String?) throws -> HostwrightLocalPathResolution
    public var runtimeAdapter: () -> any RuntimeAdapter
    public var secretStore: () -> any SecretStore
    public var swiftVersion: () -> String?
    public var platformSnapshot: () -> PlatformSnapshot
    public var operatingSystemDescription: () -> String
    public var resourceSnapshot: () -> ResourceIntelligenceSnapshot?
    public var benchmarkHostSnapshot: () -> BenchmarkHostSnapshot
    public var benchmarkDate: () -> Date
    public var benchmarkMonotonicNanoseconds: () -> UInt64
    public var benchmarkSleep: (TimeInterval) -> Void
    public var benchmarkUUID: () -> UUID
    public var benchmarkNotice: (String) -> Void

    public init(
        fileExists: @escaping (String) -> Bool,
        readTextFile: @escaping (String) throws -> String,
        writeTextFile: @escaping (String, String) throws -> Void,
        writeNewTextFile: @escaping (String, String) throws -> Void = { path, text in
            try hostwrightCreateNewTextFile(path: path, text: text)
        },
        executablePath: @escaping (String) -> String?,
        localPathResolution: @escaping (String?) throws -> HostwrightLocalPathResolution = { explicitPath in
            try HostwrightLocalPathResolver.resolve(explicitStateDatabasePath: explicitPath)
        },
        runtimeAdapter: @escaping () -> any RuntimeAdapter = { RuntimeAdapterFactory.defaultLocal() },
        secretStore: @escaping () -> any SecretStore = { UnavailableKeychainSecretStore() },
        swiftVersion: @escaping () -> String?,
        platformSnapshot: @escaping () -> PlatformSnapshot,
        operatingSystemDescription: @escaping () -> String,
        resourceSnapshot: @escaping () -> ResourceIntelligenceSnapshot? = { nil },
        benchmarkHostSnapshot: @escaping () -> BenchmarkHostSnapshot = { .current },
        benchmarkDate: @escaping () -> Date = { Date() },
        benchmarkMonotonicNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        benchmarkSleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        benchmarkUUID: @escaping () -> UUID = { UUID() },
        benchmarkNotice: @escaping (String) -> Void = { _ in }
    ) {
        self.fileExists = fileExists
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.writeNewTextFile = writeNewTextFile
        self.executablePath = executablePath
        self.localPathResolution = localPathResolution
        self.runtimeAdapter = runtimeAdapter
        self.secretStore = secretStore
        self.swiftVersion = swiftVersion
        self.platformSnapshot = platformSnapshot
        self.operatingSystemDescription = operatingSystemDescription
        self.resourceSnapshot = resourceSnapshot
        self.benchmarkHostSnapshot = benchmarkHostSnapshot
        self.benchmarkDate = benchmarkDate
        self.benchmarkMonotonicNanoseconds = benchmarkMonotonicNanoseconds
        self.benchmarkSleep = benchmarkSleep
        self.benchmarkUUID = benchmarkUUID
        self.benchmarkNotice = benchmarkNotice
    }

    public static let live = CLIEnvironment(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
        writeTextFile: { path, text in try text.write(toFile: path, atomically: true, encoding: .utf8) },
        writeNewTextFile: { path, text in
            try hostwrightCreateNewTextFile(path: path, text: text)
        },
        executablePath: { ProcessLookup.executablePath(named: $0) },
        localPathResolution: { explicitPath in
            try HostwrightLocalPathResolver.resolve(explicitStateDatabasePath: explicitPath)
        },
        runtimeAdapter: { RuntimeAdapterFactory.defaultLocal() },
        secretStore: { UnavailableKeychainSecretStore() },
        swiftVersion: { ProcessLookup.swiftVersionSummary() },
        platformSnapshot: { PlatformSnapshot.current },
        operatingSystemDescription: { ProcessInfo.processInfo.operatingSystemVersionString },
        resourceSnapshot: {
            let platform = PlatformSnapshot.current
            let operatingSystemDescription = ProcessInfo.processInfo.operatingSystemVersionString
            return ResourceIntelligenceSnapshot.current(
                operatingSystemDescription: operatingSystemDescription,
                platform: platform,
                appleContainerExecutablePath: ProcessLookup.executablePath(named: "container")
            )
        },
        benchmarkHostSnapshot: { .current },
        benchmarkDate: { Date() },
        benchmarkMonotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds },
        benchmarkSleep: { Thread.sleep(forTimeInterval: $0) },
        benchmarkUUID: { UUID() },
        benchmarkNotice: { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    )
}

@usableFromInline
func hostwrightCreateNewTextFile(path: String, text: String) throws {
    let descriptor = open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var completed = false
    defer {
        close(descriptor)
        if !completed {
            unlink(path)
        }
    }

    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
        fileDescriptor: descriptor,
        path: path,
        role: "new local output file"
    )
    let data = Data(text.utf8)
    try data.withUnsafeBytes { rawBuffer in
        var offset = 0
        while offset < rawBuffer.count {
            let result = Darwin.write(
                descriptor,
                rawBuffer.baseAddress!.advanced(by: offset),
                rawBuffer.count - offset
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += result
        }
    }
    guard fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let parent = (path as NSString).deletingLastPathComponent
    let parentPath = parent.isEmpty ? "." : parent
    let parentDescriptor = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parentDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(parentDescriptor) }
    guard fsync(parentDescriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    completed = true
}
