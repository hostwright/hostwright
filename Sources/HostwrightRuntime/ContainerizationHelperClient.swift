import Darwin
import Foundation
import HostwrightCore
import Security

public enum ContainerizationHelperClientError: Error, Equatable, Sendable {
    case pathNotAbsolute
    case pathNotNormalized
    case unsafeExecutable
    case unsafeConfiguration
    case unsafeRuntimeDirectory
    case socketUnavailable
    case socketUnsafe
    case connectionFailed
    case peerAuthenticationFailed
    case helperLaunchFailed
    case helperExited
    case timedOut
    case cancelled
    case truncatedResponse
    case responseTooLarge
    case responseMismatch
    case replayedResponse
    case invalidResponse
    case remote(RuntimeNormalizedFailure)
}

public struct ContainerizationHelperClientConfiguration: Equatable, Sendable {
    public static let socketName = "containerization-helper.sock"

    public let executableURL: URL
    public let configurationURL: URL
    public let runtimeDirectoryURL: URL
    public let socketURL: URL
    public let launchTimeoutMilliseconds: Int64
    public let requestTimeoutMilliseconds: Int64

    public init(
        executableURL: URL,
        configurationURL: URL,
        runtimeDirectoryURL: URL,
        launchTimeoutMilliseconds: Int64 = 5_000,
        requestTimeoutMilliseconds: Int64 = 30_000
    ) throws {
        guard launchTimeoutMilliseconds > 0, requestTimeoutMilliseconds > 0 else {
            throw ContainerizationHelperClientError.invalidResponse
        }
        try Self.requireNormalizedAbsolute(executableURL)
        try Self.requireNormalizedAbsolute(configurationURL)
        try Self.requireNormalizedAbsolute(runtimeDirectoryURL)
        let socketURL = runtimeDirectoryURL.appendingPathComponent(Self.socketName, isDirectory: false)
        try Self.requireNormalizedAbsolute(socketURL)
        guard socketURL.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ContainerizationHelperClientError.pathNotNormalized
        }
        self.executableURL = executableURL
        self.configurationURL = configurationURL
        self.runtimeDirectoryURL = runtimeDirectoryURL
        self.socketURL = socketURL
        self.launchTimeoutMilliseconds = launchTimeoutMilliseconds
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
    }

    public static func installed(
        hostExecutableURL: URL? = Bundle.main.executableURL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ContainerizationHelperClientConfiguration {
        guard let hostExecutableURL else {
            throw ContainerizationHelperClientError.unsafeExecutable
        }
        let helper = hostExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent("hostwright-containerization-helper", isDirectory: false)
        let support = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/Hostwright", isDirectory: true)
        return try ContainerizationHelperClientConfiguration(
            executableURL: helper,
            configurationURL: support
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("containerization-helper.json", isDirectory: false),
            runtimeDirectoryURL: support
                .appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent("helper", isDirectory: true)
        )
    }

    public func validateForLaunch(expectedUserID: uid_t = geteuid()) throws {
        try Self.requirePrivateFile(
            executableURL,
            owner: expectedUserID,
            allowRootOwner: true,
            executable: true,
            error: .unsafeExecutable
        )
        try Self.requirePrivateFile(
            configurationURL,
            owner: expectedUserID,
            allowRootOwner: false,
            executable: false,
            error: .unsafeConfiguration
        )

        var runtimeMetadata = stat()
        if lstat(runtimeDirectoryURL.path, &runtimeMetadata) == 0 {
            guard (runtimeMetadata.st_mode & S_IFMT) == S_IFDIR,
                  runtimeMetadata.st_uid == expectedUserID,
                  runtimeMetadata.st_mode & 0o7777 == 0o700 else {
                throw ContainerizationHelperClientError.unsafeRuntimeDirectory
            }
        } else {
            guard errno == ENOENT else {
                throw ContainerizationHelperClientError.unsafeRuntimeDirectory
            }
            var parentMetadata = stat()
            let parent = runtimeDirectoryURL.deletingLastPathComponent()
            guard lstat(parent.path, &parentMetadata) == 0,
                  (parentMetadata.st_mode & S_IFMT) == S_IFDIR,
                  parentMetadata.st_uid == expectedUserID,
                  parentMetadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
                throw ContainerizationHelperClientError.unsafeRuntimeDirectory
            }
        }
    }

    private static func requireNormalizedAbsolute(_ url: URL) throws {
        guard url.path.hasPrefix("/"),
              !url.path.contains("\0") else {
            throw ContainerizationHelperClientError.pathNotAbsolute
        }
        let normalized = NSString(string: url.path).standardizingPath
        guard normalized == url.path,
              url.path.utf8.count <= 1_024,
              url.path.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7f
              }) else {
            throw ContainerizationHelperClientError.pathNotNormalized
        }
    }

    private static func requirePrivateFile(
        _ url: URL,
        owner: uid_t,
        allowRootOwner: Bool,
        executable: Bool,
        error: ContainerizationHelperClientError
    ) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              (metadata.st_uid == owner || (allowRootOwner && metadata.st_uid == 0)),
              metadata.st_nlink == 1,
              metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISTXT) == 0,
              !executable || metadata.st_mode & S_IXUSR != 0 else {
            throw error
        }
    }
}

public final class ContainerizationHelperProcessLease: @unchecked Sendable {
    public let processID: pid_t
    private let running: @Sendable () -> Bool
    private let stop: @Sendable () -> Void

    public init(
        processID: pid_t,
        isRunning: @escaping @Sendable () -> Bool,
        terminate: @escaping @Sendable () -> Void
    ) {
        self.processID = processID
        self.running = isRunning
        self.stop = terminate
    }

    public var isRunning: Bool { running() }
    public func terminate() { stop() }

    deinit { stop() }
}

public struct ContainerizationHelperProcessLauncher: Sendable {
    private let launchImplementation: @Sendable (
        ContainerizationHelperClientConfiguration
    ) throws -> ContainerizationHelperProcessLease

    public init(
        launch: @escaping @Sendable (
            ContainerizationHelperClientConfiguration
        ) throws -> ContainerizationHelperProcessLease
    ) {
        self.launchImplementation = launch
    }

    public func launch(
        configuration: ContainerizationHelperClientConfiguration
    ) throws -> ContainerizationHelperProcessLease {
        try launchImplementation(configuration)
    }

    public static let system = ContainerizationHelperProcessLauncher { configuration in
        try ContainerizationHelperBootstrap.prepare(configuration: configuration)
        return try ContainerizationHelperPOSIXLauncher.launchPrepared(configuration: configuration)
    }
}

enum ContainerizationHelperPOSIXLauncher {
    private struct ConfigurationIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let mode: UInt16
        let links: UInt16
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(url: URL) throws {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
            device = UInt64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
            owner = UInt32(metadata.st_uid)
            mode = UInt16(metadata.st_mode & 0o7777)
            links = UInt16(metadata.st_nlink)
            size = Int64(metadata.st_size)
            modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }
    }

    static func launchPrepared(
        configuration: ContainerizationHelperClientConfiguration
    ) throws -> ContainerizationHelperProcessLease {
        try configuration.validateForLaunch()
        let configurationIdentity = try ConfigurationIdentity(url: configuration.configurationURL)
        let executableIdentity: SecureExecutableIdentity
        do {
            executableIdentity = try SecureExecutableResolver.verify(
                path: configuration.executableURL.path,
                ownershipPolicy: .rootOrCurrentUser
            )
        } catch {
            throw ContainerizationHelperClientError.unsafeExecutable
        }

        let rootDirectory = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDirectory >= 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        defer { Darwin.close(rootDirectory) }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        try requireSpawnSuccess(posix_spawn_file_actions_addfchdir(&fileActions, rootDirectory))
        try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, rootDirectory))
        try requireSpawnSuccess(
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        )

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try requireSpawnSuccess(posix_spawnattr_setsigmask(&attributes, &signalMask))
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGALRM, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        try requireSpawnSuccess(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        let flags = Int16(
            POSIX_SPAWN_SETSID |
                POSIX_SPAWN_CLOEXEC_DEFAULT |
                POSIX_SPAWN_SETSIGMASK |
                POSIX_SPAWN_SETSIGDEF |
                POSIX_SPAWN_START_SUSPENDED
        )
        try requireSpawnSuccess(posix_spawnattr_setflags(&attributes, flags))

        var arguments = try allocateCStringVector([
            executableIdentity.path,
            "--configuration",
            configuration.configurationURL.path
        ])
        defer { freeCStringVector(&arguments) }
        let environment = exactEnvironment()
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var environmentVector = try allocateCStringVector(environment)
        defer { freeCStringVector(&environmentVector) }

        var processID = pid_t(0)
        let launchCode = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            environmentVector.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executableIdentity.path,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        guard launchCode == 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }

        do {
            try configuration.validateForLaunch()
            guard try ConfigurationIdentity(url: configuration.configurationURL)
                == configurationIdentity else {
                throw ContainerizationHelperClientError.unsafeConfiguration
            }
            try SecureExecutableResolver.verifyUnchanged(executableIdentity)
        } catch let error as ContainerizationHelperClientError {
            terminateSuspended(processID)
            throw error
        } catch {
            terminateSuspended(processID)
            throw ContainerizationHelperClientError.unsafeExecutable
        }
        guard kill(processID, SIGCONT) == 0 else {
            terminateSuspended(processID)
            throw ContainerizationHelperClientError.helperLaunchFailed
        }

        let state = ContainerizationHelperPOSIXProcessState(processID: processID)
        return ContainerizationHelperProcessLease(
            processID: processID,
            isRunning: { state.isRunning },
            terminate: { state.terminate() }
        )
    }

    private static func exactEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let temporaryDirectory = safeAbsoluteEnvironmentPath(environment["TMPDIR"])
            ?? "/tmp"
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
            "TMPDIR": temporaryDirectory
        ]
    }

    private static func safeAbsoluteEnvironmentPath(_ value: String?) -> String? {
        guard let value,
              value.hasPrefix("/"),
              !value.contains("\0"),
              value.utf8.count <= Int(PATH_MAX),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7f
              }) else {
            return nil
        }
        return value
    }

    private static func requireSpawnSuccess(_ code: Int32) throws {
        guard code == 0 else {
            throw ContainerizationHelperClientError.helperLaunchFailed
        }
    }

    private static func allocateCStringVector(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard !string.contains("\0"), let pointer = strdup(string) else {
                freeCStringVector(&result)
                throw ContainerizationHelperClientError.helperLaunchFailed
            }
            result.append(pointer)
        }
        result.append(nil)
        return result
    }

    private static func freeCStringVector(
        _ vector: inout [UnsafeMutablePointer<CChar>?]
    ) {
        for pointer in vector {
            if let pointer { free(pointer) }
        }
        vector.removeAll(keepingCapacity: false)
    }

    private static func terminateSuspended(_ processID: pid_t) {
        if kill(-processID, SIGKILL) != 0, errno == ESRCH {
            _ = kill(processID, SIGKILL)
        }
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0, errno == EINTR {}
    }
}

private final class ContainerizationHelperPOSIXProcessState: @unchecked Sendable {
    private let processID: pid_t
    private let condition = NSCondition()
    private var reaped = false
    private var terminationStarted = false

    init(processID: pid_t) {
        self.processID = processID
        DispatchQueue.global(qos: .utility).async { [self] in
            observeLeaderExitCleanDescendantsAndReap()
        }
    }

    var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !reaped
    }

    func terminate() {
        condition.lock()
        let shouldSignal = !reaped && !terminationStarted
        if shouldSignal { terminationStarted = true }
        condition.unlock()

        if shouldSignal {
            signalProcessGroup(SIGTERM)
            if !waitUntilReaped(milliseconds: 100) {
                signalProcessGroup(SIGKILL)
            }
        }
        _ = waitUntilReaped(milliseconds: 2_000)
    }

    private func observeLeaderExitCleanDescendantsAndReap() {
        var information = siginfo_t()
        while waitid(
            P_PID,
            id_t(processID),
            &information,
            WEXITED | WNOWAIT
        ) != 0 {
            if errno == EINTR { continue }
            markReaped()
            return
        }
        guard information.si_pid == processID else {
            markReaped()
            return
        }

        // Keep the exited leader unreaped so its PID and process-group ID cannot
        // be reused until every descendant has been stopped.
        _ = kill(-processID, SIGKILL)
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0, errno == EINTR {}
        markReaped()
    }

    private func markReaped() {
        condition.lock()
        reaped = true
        condition.broadcast()
        condition.unlock()
    }

    private func waitUntilReaped(milliseconds: Int) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(milliseconds) / 1_000)
        condition.lock()
        while !reaped, condition.wait(until: deadline) {}
        let result = reaped
        condition.unlock()
        return result
    }

    private func signalProcessGroup(_ signal: Int32) {
        if kill(-processID, signal) != 0, errno == ESRCH {
            _ = kill(processID, signal)
        }
    }
}

public struct ContainerizationHelperTransportResponse: Equatable, Sendable {
    public let frame: Data
    public let peerProcessID: pid_t
    public let socketDevice: UInt64
    public let socketInode: UInt64

    public init(
        frame: Data,
        peerProcessID: pid_t,
        socketDevice: UInt64 = 0,
        socketInode: UInt64 = 0
    ) {
        self.frame = frame
        self.peerProcessID = peerProcessID
        self.socketDevice = socketDevice
        self.socketInode = socketInode
    }
}

public struct ContainerizationHelperClientTransport: Sendable {
    private let exchangeImplementation: @Sendable (
        Data,
        URL,
        Int64,
        pid_t?
    ) async throws -> ContainerizationHelperTransportResponse

    public init(
        exchange: @escaping @Sendable (
            _ frame: Data,
            _ socketURL: URL,
            _ deadlineUnixMilliseconds: Int64,
            _ expectedProcessID: pid_t?
        ) async throws -> ContainerizationHelperTransportResponse
    ) {
        self.exchangeImplementation = exchange
    }

    public func exchange(
        frame: Data,
        socketURL: URL,
        deadlineUnixMilliseconds: Int64,
        expectedProcessID: pid_t?
    ) async throws -> ContainerizationHelperTransportResponse {
        try await exchangeImplementation(
            frame,
            socketURL,
            deadlineUnixMilliseconds,
            expectedProcessID
        )
    }

    public static let unix = ContainerizationHelperClientTransport { frame, socketURL, deadline, expectedPID in
        try ContainerizationHelperUnixClient.exchange(
            frame: frame,
            socketURL: socketURL,
            deadlineUnixMilliseconds: deadline,
            expectedProcessID: expectedPID
        )
    }
}

private enum ContainerizationHelperUnixClient {
    static func exchange(
        frame: Data,
        socketURL: URL,
        deadlineUnixMilliseconds: Int64,
        expectedProcessID: pid_t?
    ) throws -> ContainerizationHelperTransportResponse {
        try Task.checkCancellation()
        guard frame.count <= ContainerizationHelperProtocolV1.maximumPayloadBytes
            + ContainerizationHelperProtocolV1.frameHeaderBytes else {
            throw ContainerizationHelperClientError.responseTooLarge
        }
        let socketIdentity = try requireSafeSocket(socketURL)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ContainerizationHelperClientError.connectionFailed
        }
        defer { Darwin.close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ContainerizationHelperClientError.connectionFailed
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw ContainerizationHelperClientError.pathNotNormalized
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in pathBytes.indices { destination[index] = pathBytes[index] }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                throw ContainerizationHelperClientError.connectionFailed
            }
            try wait(descriptor, event: POLLOUT, deadline: deadlineUnixMilliseconds)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else {
                throw ContainerizationHelperClientError.connectionFailed
            }
        }

        let peerPID = try authenticatePeer(descriptor, expectedProcessID: expectedProcessID)
        try writeAll(descriptor, data: frame, deadline: deadlineUnixMilliseconds)
        let header = try readExact(
            descriptor,
            count: ContainerizationHelperProtocolV1.frameHeaderBytes,
            deadline: deadlineUnixMilliseconds
        )
        let payloadLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard payloadLength > 0 else {
            throw ContainerizationHelperClientError.invalidResponse
        }
        guard payloadLength <= UInt32(ContainerizationHelperProtocolV1.maximumPayloadBytes) else {
            throw ContainerizationHelperClientError.responseTooLarge
        }
        let payload = try readExact(
            descriptor,
            count: Int(payloadLength),
            deadline: deadlineUnixMilliseconds
        )
        return ContainerizationHelperTransportResponse(
            frame: header + payload,
            peerProcessID: peerPID,
            socketDevice: UInt64(socketIdentity.st_dev),
            socketInode: UInt64(socketIdentity.st_ino)
        )
    }

    private static func requireSafeSocket(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                throw ContainerizationHelperClientError.socketUnavailable
            }
            throw ContainerizationHelperClientError.socketUnsafe
        }
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISTXT) == 0,
              metadata.st_mode & S_IRUSR != 0,
              metadata.st_mode & S_IWUSR != 0 else {
            throw ContainerizationHelperClientError.socketUnsafe
        }
        return metadata
    }

    private static func authenticatePeer(
        _ descriptor: Int32,
        expectedProcessID: pid_t?
    ) throws -> pid_t {
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }
        var peerPID = pid_t(0)
        var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) == 0,
              peerPIDSize == MemoryLayout<pid_t>.size,
              peerPID > 0,
              expectedProcessID == nil || expectedProcessID == peerPID else {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }

        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: peerPID)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoTeamIdentifier as String] as? String
                == ContainerizationHelperPeerIdentityPolicy.expectedTeamIdentifier,
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              ["dev.hostwright.containerization-helper", "hostwright-containerization-helper"]
                .contains(identifier) else {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }
        let requirementText = ContainerizationHelperPeerIdentityPolicy.codeRequirementSource(
            identifier: identifier
        )
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess else {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }
        return peerPID
    }

    private static func wait(_ descriptor: Int32, event: Int32, deadline: Int64) throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - nowMilliseconds()
            guard remaining > 0 else {
                throw ContainerizationHelperClientError.timedOut
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(event), revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, Int32(min(remaining, 100)))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw ContainerizationHelperClientError.connectionFailed }
            if result == 0 { continue }
            guard pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0,
                  pollDescriptor.revents & Int16(event) != 0 else {
                throw ContainerizationHelperClientError.connectionFailed
            }
            return
        }
    }

    private static func writeAll(_ descriptor: Int32, data: Data, deadline: Int64) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, event: POLLOUT, deadline: deadline)
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { throw ContainerizationHelperClientError.connectionFailed }
                offset += count
            }
        }
    }

    private static func readExact(_ descriptor: Int32, count: Int, deadline: Int64) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        var bytes = [UInt8](repeating: 0, count: min(max(1, count), 64 * 1_024))
        while result.count < count {
            try wait(descriptor, event: POLLIN, deadline: deadline)
            let amount = Darwin.read(descriptor, &bytes, min(bytes.count, count - result.count))
            if amount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard amount > 0 else { throw ContainerizationHelperClientError.truncatedResponse }
            result.append(contentsOf: bytes[0..<amount])
        }
        return result
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

public actor ContainerizationHelperClient {
    private struct OwnedSocketIdentity: Equatable, Sendable {
        let processID: pid_t
        let device: UInt64
        let inode: UInt64
    }

    private let configuration: ContainerizationHelperClientConfiguration
    private let launcher: ContainerizationHelperProcessLauncher
    private let transport: ContainerizationHelperClientTransport
    private var process: ContainerizationHelperProcessLease?
    private var ownedSocketIdentity: OwnedSocketIdentity?
    private var snapshot: RuntimeCapabilitySnapshot?
    private var completedResponseIDs: Set<UUID> = []
    private var responseOrder: [UUID] = []

    public init(
        configuration: ContainerizationHelperClientConfiguration,
        launcher: ContainerizationHelperProcessLauncher = .system,
        transport: ContainerizationHelperClientTransport = .unix
    ) {
        self.configuration = configuration
        self.launcher = launcher
        self.transport = transport
    }

    public func negotiate() async throws -> RuntimeCapabilitySnapshot {
        let result: RuntimeCapabilitySnapshot = try await request(
            operation: .negotiate,
            capabilityDigest: snapshot?.canonicalSHA256 ?? String(repeating: "0", count: 64),
            mutationContext: nil,
            idempotencyKey: "negotiate/\(UUID().uuidString.lowercased())",
            payload: ContainerizationHelperEmptyPayload()
        )
        guard result.descriptor.providerID == .appleContainerization,
              RuntimeProviderCapabilityNegotiator.validationFindings(for: result).isEmpty else {
            throw ContainerizationHelperClientError.invalidResponse
        }
        snapshot = result
        return result
    }

    public func observe() async throws -> RuntimeInventory {
        let snapshot = try await requireSnapshot()
        let result: ContainerizationHelperObservation = try await request(
            operation: .observe,
            capabilityDigest: snapshot.canonicalSHA256,
            mutationContext: nil,
            idempotencyKey: "observe/\(UUID().uuidString.lowercased())",
            payload: ContainerizationHelperObservePayload(includeResourceUsage: true)
        )
        do { return try result.validatedInventory() }
        catch { throw ContainerizationHelperClientError.invalidResponse }
    }

    public func localImageEvidence(_ reference: String) async throws -> RuntimeLocalImageEvidence {
        let snapshot = try await requireSnapshot()
        let result: ContainerizationHelperImageEvidence = try await request(
            operation: .localImageEvidence,
            capabilityDigest: snapshot.canonicalSHA256,
            mutationContext: nil,
            idempotencyKey: "image/\(UUID().uuidString.lowercased())",
            payload: ContainerizationHelperImageRequest(reference: reference)
        )
        return RuntimeLocalImageEvidence(
            reference: result.reference,
            descriptorDigest: result.descriptorDigest,
            variantDigest: result.variantDigest,
            architecture: result.architecture,
            operatingSystem: result.operatingSystem
        )
    }

    public func resourceUsage(_ resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        let snapshot = try await requireSnapshot()
        let result: ContainerizationHelperResourceUsage = try await request(
            operation: .resourceUsage,
            capabilityDigest: snapshot.canonicalSHA256,
            mutationContext: nil,
            idempotencyKey: "usage/\(UUID().uuidString.lowercased())",
            payload: ContainerizationHelperResourceRequest(resourceIdentifier: resourceIdentifier)
        )
        guard result.resourceIdentifier == resourceIdentifier else {
            throw ContainerizationHelperClientError.responseMismatch
        }
        return RuntimeResourceUsageSnapshot(
            resourceIdentifier: result.resourceIdentifier,
            cpuUsageMicroseconds: result.cpuUsageMicroseconds,
            memoryUsageBytes: result.memoryUsageBytes,
            memoryLimitBytes: result.memoryLimitBytes,
            networkReceiveBytes: result.networkReceiveBytes,
            networkTransmitBytes: result.networkTransmitBytes,
            blockReadBytes: result.blockReadBytes,
            blockWriteBytes: result.blockWriteBytes,
            processCount: result.processCount
        )
    }

    public func logs(_ resourceIdentifier: String, lineLimit: Int) async throws -> String {
        let snapshot = try await requireSnapshot()
        let boundedLimit = min(max(1, lineLimit), RuntimeProviderConformanceLimits.maximumLogLines)
        let result: ContainerizationHelperLogs = try await request(
            operation: .logs,
            capabilityDigest: snapshot.canonicalSHA256,
            mutationContext: nil,
            idempotencyKey: "logs/\(UUID().uuidString.lowercased())",
            payload: ContainerizationHelperLogsRequest(
                resourceIdentifier: resourceIdentifier,
                lineLimit: boundedLimit
            )
        )
        guard result.resourceIdentifier == resourceIdentifier,
              result.lineLimit == boundedLimit,
              Data(result.text.utf8).count <= RuntimeProviderConformanceLimits.maximumLogBytes else {
            throw ContainerizationHelperClientError.responseMismatch
        }
        return result.text
    }

    public func create(
        _ payload: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        try await mutation(.create, payload: payload, context: context)
    }

    public func start(
        _ payload: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        try await mutation(.start, payload: payload, context: context)
    }

    public func restart(
        _ payload: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        try await mutation(.restart, payload: payload, context: context)
    }

    public func stop(
        _ payload: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        try await mutation(.stop, payload: payload, context: context)
    }

    public func delete(
        _ payload: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        try await mutation(.delete, payload: payload, context: context)
    }

    public func shutdown() async {
        guard let snapshot else {
            process?.terminate()
            return
        }
        let _: ContainerizationHelperAcknowledgement? = try? await request(
            operation: .shutdown,
            capabilityDigest: snapshot.canonicalSHA256,
            mutationContext: nil,
            idempotencyKey: "shutdown/\(UUID().uuidString.lowercased())",
            payload: ContainerizationHelperEmptyPayload()
        )
        process?.terminate()
        process = nil
        ownedSocketIdentity = nil
        self.snapshot = nil
    }

    private func mutation<Payload: Codable & Sendable>(
        _ operation: ContainerizationHelperOperation,
        payload: Payload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        guard context.providerID == .appleContainerization,
              context.validationIssue == nil else {
            throw ContainerizationHelperClientError.invalidResponse
        }
        let current = try await requireSnapshot()
        guard current.canonicalSHA256 == context.capabilitySHA256 else {
            throw staleCapabilityFailure(context)
        }
        let result: ContainerizationHelperMutationResult = try await request(
            operation: operation,
            capabilityDigest: current.canonicalSHA256,
            mutationContext: context,
            idempotencyKey: context.operationID,
            payload: payload
        )
        guard result.verified else { throw ContainerizationHelperClientError.invalidResponse }
        return result
    }

    private func requireSnapshot() async throws -> RuntimeCapabilitySnapshot {
        if let snapshot { return snapshot }
        return try await negotiate()
    }

    private func request<Payload: Codable & Sendable, Result: Codable & Sendable>(
        operation: ContainerizationHelperOperation,
        capabilityDigest: String,
        mutationContext: RuntimeMutationContext?,
        idempotencyKey: String,
        payload: Payload
    ) async throws -> Result {
        let requestID = UUID()
        let deadline = nowMilliseconds() + configuration.requestTimeoutMilliseconds
        let envelope = ContainerizationHelperRequest(
            requestID: requestID,
            operation: operation,
            deadlineUnixMilliseconds: deadline,
            capabilityDigest: capabilityDigest,
            mutationContext: mutationContext,
            idempotencyKey: idempotencyKey,
            payload: payload
        )
        let frame: Data
        do {
            frame = try ContainerizationHelperFraming.frame(
                ContainerizationHelperCanonicalJSON.encode(envelope)
            )
        } catch {
            throw ContainerizationHelperClientError.invalidResponse
        }

        return try await withTaskCancellationHandler {
            let response = try await exchangeLaunchingIfNeeded(frame: frame, deadline: deadline)
            return try decode(
                Result.self,
                response: response,
                requestID: requestID,
                operation: operation,
                mutationContext: mutationContext
            )
        } onCancel: {
            Task.detached { [weak self] in
                await self?.sendCancellation(
                    targetRequestID: requestID,
                    capabilityDigest: capabilityDigest
                )
            }
        }
    }

    private func exchangeLaunchingIfNeeded(
        frame: Data,
        deadline: Int64
    ) async throws -> ContainerizationHelperTransportResponse {
        do {
            return try await exchange(frame: frame, deadline: deadline)
        } catch ContainerizationHelperClientError.socketUnavailable {
            return try await launchAndExchange(frame: frame, deadline: deadline)
        } catch ContainerizationHelperClientError.connectionFailed {
            if let process, !process.isRunning {
                try removeStaleOwnedSocket(processID: process.processID)
                self.process = nil
                return try await launchAndExchange(frame: frame, deadline: deadline)
            }
            throw ContainerizationHelperClientError.connectionFailed
        } catch is CancellationError {
            throw ContainerizationHelperClientError.cancelled
        }
    }

    private func launchAndExchange(
        frame: Data,
        deadline: Int64
    ) async throws -> ContainerizationHelperTransportResponse {
        if let process, !process.isRunning {
            try removeStaleOwnedSocket(processID: process.processID)
            self.process = nil
        }
        if process == nil {
            do { process = try launcher.launch(configuration: configuration) }
            catch let error as ContainerizationHelperClientError { throw error }
            catch { throw ContainerizationHelperClientError.helperLaunchFailed }
        }
        let launchDeadline = min(
            deadline,
            nowMilliseconds() + configuration.launchTimeoutMilliseconds
        )
        while nowMilliseconds() < launchDeadline {
            try Task.checkCancellation()
            guard let process, process.isRunning else {
                throw ContainerizationHelperClientError.helperExited
            }
            do {
                return try await exchange(frame: frame, deadline: deadline)
            } catch ContainerizationHelperClientError.socketUnavailable {
                try await Task.sleep(for: .milliseconds(25))
            } catch ContainerizationHelperClientError.connectionFailed {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw ContainerizationHelperClientError.timedOut
    }

    private func exchange(
        frame: Data,
        deadline: Int64
    ) async throws -> ContainerizationHelperTransportResponse {
        let expectedPID = process?.isRunning == true ? process?.processID : nil
        let response = try await transport.exchange(
            frame: frame,
            socketURL: configuration.socketURL,
            deadlineUnixMilliseconds: deadline,
            expectedProcessID: expectedPID
        )
        if let expectedPID, response.peerProcessID != expectedPID {
            throw ContainerizationHelperClientError.peerAuthenticationFailed
        }
        if let expectedPID {
            ownedSocketIdentity = OwnedSocketIdentity(
                processID: expectedPID,
                device: response.socketDevice,
                inode: response.socketInode
            )
        }
        return response
    }

    private func decode<Result: Codable & Sendable>(
        _ type: Result.Type,
        response: ContainerizationHelperTransportResponse,
        requestID: UUID,
        operation: ContainerizationHelperOperation,
        mutationContext: RuntimeMutationContext?
    ) throws -> Result {
        let payload: Data
        do { payload = try ContainerizationHelperFraming.decodeSingleFrame(response.frame) }
        catch ContainerizationHelperProtocolError.frameTooLarge {
            throw ContainerizationHelperClientError.responseTooLarge
        } catch {
            throw ContainerizationHelperClientError.truncatedResponse
        }

        if let envelope = try? ContainerizationHelperCanonicalJSON.decodeResult(type, from: payload) {
            try validateResponseIdentity(
                envelope.requestID,
                operation: envelope.operation,
                expectedRequestID: requestID,
                expectedOperation: operation
            )
            return envelope.result
        }
        if let envelope = try? ContainerizationHelperCanonicalJSON.decodeError(from: payload) {
            try validateResponseIdentity(
                envelope.requestID,
                operation: envelope.operation,
                expectedRequestID: requestID,
                expectedOperation: operation
            )
            if envelope.error.code == .capabilityMismatch { snapshot = nil }
            throw ContainerizationHelperClientError.remote(
                normalizedFailure(
                    envelope.error,
                    operation: operation,
                    mutationContext: mutationContext
                )
            )
        }
        throw ContainerizationHelperClientError.invalidResponse
    }

    private func validateResponseIdentity(
        _ responseID: UUID,
        operation: ContainerizationHelperOperation,
        expectedRequestID: UUID,
        expectedOperation: ContainerizationHelperOperation
    ) throws {
        guard responseID == expectedRequestID, operation == expectedOperation else {
            throw ContainerizationHelperClientError.responseMismatch
        }
        guard completedResponseIDs.insert(responseID).inserted else {
            throw ContainerizationHelperClientError.replayedResponse
        }
        responseOrder.append(responseID)
        if responseOrder.count > 4_096 {
            let expired = Array(responseOrder.prefix(responseOrder.count - 4_096))
            responseOrder.removeFirst(expired.count)
            completedResponseIDs.subtract(expired)
        }
    }

    private func normalizedFailure(
        _ error: ContainerizationHelperErrorPayload,
        operation: ContainerizationHelperOperation,
        mutationContext: RuntimeMutationContext?
    ) -> RuntimeNormalizedFailure {
        let values: (
            RuntimeFailureCategory,
            RuntimeRetryDisposition,
            RuntimeRecoveryDisposition,
            String
        )
        switch error.code {
        case .unsupportedVersion:
            values = (.incompatible, .never, .none, "Install the supported helper version.")
        case .authenticationFailed:
            values = (.permissionDenied, .never, .none, "Verify the signed Hostwright installation.")
        case .deadlineExceeded:
            values = (.timedOut, .safeAfterObservation, .reobserve, "Re-observe before retrying.")
        case .capabilityMismatch:
            values = (.staleCapability, .safeAfterObservation, .reobserve, "Negotiate capabilities again.")
        case .conflict:
            values = (.fencingConflict, .resumeFromCheckpoint, .resume, "Resume the fenced operation.")
        case .cancelled:
            values = (.cancelled, .safeAfterObservation, .reobserve, "Re-observe the resource state.")
        case .unavailable:
            values = (.unavailable, .safeAfterObservation, .reobserve, "Verify helper readiness.")
        case .executionFailed:
            values = mutationContext == nil
                ? (.rejected, .never, .none, "Correct the request and retry.")
                : (.ambiguousEffect, .resumeFromCheckpoint, .reobserve, "Re-observe before recovery.")
        case .invalidRequest:
            values = (.rejected, .never, .none, "Correct the request and retry.")
        case .internalFailure:
            values = mutationContext == nil
                ? (.crashed, .safeAfterObservation, .reobserve, "Restart the helper and retry.")
                : (.ambiguousEffect, .resumeFromCheckpoint, .reobserve, "Restart and resume after observation.")
        }
        return RuntimeNormalizedFailure(
            category: values.0,
            retryDisposition: values.1,
            recoveryDisposition: values.2,
            providerID: RuntimeProviderID.appleContainerization.rawValue,
            providerVersion: snapshot?.descriptor.components.first(where: {
                $0.identifier == .appleContainerizationHelper
            })?.version ?? "unknown",
            operationID: mutationContext?.operationID ?? operation.rawValue,
            diagnostic: error.message,
            guidance: values.3
        )
    }

    private func staleCapabilityFailure(
        _ context: RuntimeMutationContext
    ) -> ContainerizationHelperClientError {
        .remote(
            RuntimeNormalizedFailure(
                category: .staleCapability,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve,
                providerID: RuntimeProviderID.appleContainerization.rawValue,
                providerVersion: "unknown",
                operationID: context.operationID,
                diagnostic: "The confirmed helper capability snapshot is stale.",
                guidance: "Negotiate capabilities and regenerate the plan."
            )
        )
    }

    private func sendCancellation(targetRequestID: UUID, capabilityDigest: String) async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        let deadline = nowMilliseconds() + min(configuration.requestTimeoutMilliseconds, 5_000)
        let envelope = ContainerizationHelperRequest(
            requestID: requestID,
            operation: .cancel,
            deadlineUnixMilliseconds: deadline,
            capabilityDigest: capabilityDigest,
            mutationContext: nil,
            idempotencyKey: "cancel/\(targetRequestID.uuidString.lowercased())",
            payload: ContainerizationHelperCancellationPayload(targetRequestID: targetRequestID)
        )
        guard let payload = try? ContainerizationHelperCanonicalJSON.encode(envelope),
              let frame = try? ContainerizationHelperFraming.frame(payload),
              let response = try? await exchangeLaunchingIfNeeded(frame: frame, deadline: deadline),
              let responsePayload = try? ContainerizationHelperFraming.decodeSingleFrame(response.frame),
              let result = try? ContainerizationHelperCanonicalJSON.decodeResult(
                ContainerizationHelperAcknowledgement.self,
                from: responsePayload
              ),
              result.requestID == requestID,
              result.operation == .cancel else {
            return
        }
    }

    private func removeStaleOwnedSocket(processID: pid_t) throws {
        guard let ownedSocketIdentity, ownedSocketIdentity.processID == processID else { return }
        var metadata = stat()
        if lstat(configuration.socketURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw ContainerizationHelperClientError.socketUnsafe }
            self.ownedSocketIdentity = nil
            return
        }
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISTXT) == 0,
              UInt64(metadata.st_dev) == ownedSocketIdentity.device,
              UInt64(metadata.st_ino) == ownedSocketIdentity.inode else {
            throw ContainerizationHelperClientError.socketUnsafe
        }
        guard unlink(configuration.socketURL.path) == 0 else {
            throw ContainerizationHelperClientError.socketUnsafe
        }
        self.ownedSocketIdentity = nil
    }

    private func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

public struct AppleContainerizationRuntimeAdapter: RuntimeAdapter {
    private let client: ContainerizationHelperClient
    private let redactionPolicy: RuntimeRedactionPolicy

    public init(
        client: ContainerizationHelperClient,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.client = client
        self.redactionPolicy = redactionPolicy
    }

    public func metadata() async -> RuntimeAdapterMetadata {
        let snapshot = try? await client.negotiate()
        let version = snapshot?.descriptor.components.first(where: {
            $0.identifier == .appleContainerizationHelper
        })?.version
        return RuntimeAdapterMetadata(
            providerID: .appleContainerization,
            adapterName: "AppleContainerizationRuntimeAdapter",
            adapterVersion: HostwrightIdentity.version,
            runtimeName: "Apple Containerization",
            runtimeVersion: version,
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
        )
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        let snapshot = try await client.negotiate()
        let usable = Set(snapshot.features.filter {
            $0.state == .available || $0.state == .experimental
        }.map(\.feature))
        var result: [RuntimeCapability] = []
        if usable.contains(.observation) { result.append(.readOnlyObservation) }
        if usable.contains(.lifecycle) { result.append(.lifecycleMutation) }
        if usable.contains(.streaming) { result.append(.logStreaming) }
        if usable.contains(.cleanup) { result.append(.cleanup) }
        return result
    }

    public func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        try await translate { try await client.negotiate() }
    }

    public func inventory() async throws -> RuntimeInventory {
        try await translate { try await client.observe() }
    }

    public func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        let snapshot = try await capabilitySnapshot()
        let inventory = try await self.inventory()
        return ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: try observedServices(inventory, desiredState: desiredState),
            adapterMetadata: await metadata(),
            capabilitySHA256: snapshot.canonicalSHA256
        )
    }

    public func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(
            actions: desiredState.services
                .filter { desired in !observedState.services.contains { $0.identity == desired.identity } }
                .sorted { $0.identity.displayName < $1.identity.displayName }
                .map { desired in
                    PlannedRuntimeAction(
                        kind: .create,
                        identity: desired.identity,
                        resourceIdentifier: desired.identity.managedResourceIdentifier,
                        isDestructive: false,
                        summary: "Create missing service \(desired.identity.displayName).",
                        desiredService: desired
                    )
                },
            capabilitySHA256: observedState.capabilitySHA256
        )
    }

    public func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        let text = try await translate { try await client.logs(service.resourceIdentifier, lineLimit: tail) }
        return RuntimeLogResult(identity: service.identity, text: text, lineLimit: min(max(1, tail), 1_000))
    }

    public func runtimeVersion() async throws -> String {
        let snapshot = try await capabilitySnapshot()
        guard let component = snapshot.descriptor.components.first(where: {
            $0.identifier == .appleContainerizationFramework
        }) else {
            throw RuntimeAdapterError.outputParseFailed("Containerization framework version was unavailable.")
        }
        return component.version
    }

    public func runtimeReadiness() async throws -> RuntimeReadinessReport {
        let snapshot = try await capabilitySnapshot()
        let helper = snapshot.descriptor.components.first(where: {
            $0.identifier == .appleContainerizationHelper
        })
        let framework = snapshot.descriptor.components.first(where: {
            $0.identifier == .appleContainerizationFramework
        })
        return RuntimeReadinessReport(
            runtimeName: "Apple Containerization",
            cliVersion: helper?.version ?? "unknown",
            serviceState: .running,
            serviceVersion: framework?.version,
            serviceBuild: framework?.build
        )
    }

    public func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        try await translate { try await client.localImageEvidence(imageReference) }
    }

    public func resourceUsage(for resourceIdentifier: String) async throws -> RuntimeResourceUsageSnapshot {
        try await translate { try await client.resourceUsage(resourceIdentifier) }
    }

    public func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        guard confirmation?.confirmed == true,
              confirmation?.planHash?.isEmpty == false,
              let context = confirmation?.context,
              context.providerID == .appleContainerization,
              context.validationIssue == nil else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Containerization mutation requires a confirmed plan and valid fenced provider context."
            )
        }
        switch action.kind {
        case .create:
            guard let service = action.desiredService,
                  service.identity == action.identity,
                  action.resourceIdentifier == service.identity.managedResourceIdentifier else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "Containerization create requires the supported local-image lifecycle subset."
                )
            }
            try RuntimeCreateSubsetPolicy.validate(service, providerID: .appleContainerization)
            let image = try await localImageEvidence(for: service.image)
            let labels = try RuntimeManagedResourceIdentity.labels(for: action.identity, context: context)
                .map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }
            let result = try await translate {
                try await client.create(
                    ContainerizationHelperCreatePayload(
                        resourceIdentifier: action.resourceIdentifier,
                        resourceUUID: context.resourceUUID,
                        projectUUID: context.projectResourceUUID,
                        image: ContainerizationHelperImageEvidence(image),
                        command: service.command,
                        environment: service.environment.map {
                            RuntimeInventoryEnvironmentEntry(name: $0.name, value: $0.value)
                        },
                        labels: labels
                    ),
                    context: context
                )
            }
            return event(action, result: result, verb: "Created")
        case .start:
            let result = try await translate {
                try await client.start(mutationPayload(action, context: context), context: context)
            }
            return event(action, result: result, verb: "Started")
        case .restart:
            guard action.isDestructive else {
                throw RuntimeAdapterError.commandRejected(
                    classification: .mutating,
                    message: "Managed restart requires an explicitly destructive action."
                )
            }
            let result = try await translate {
                try await client.restart(mutationPayload(action, context: context), context: context)
            }
            return event(action, result: result, verb: "Restarted")
        case .remove:
            guard action.isDestructive else {
                throw RuntimeAdapterError.commandRejected(
                    classification: .mutating,
                    message: "Delete requires an explicitly destructive action."
                )
            }
            let result = try await translate {
                try await client.delete(mutationPayload(action, context: context), context: context)
            }
            return event(action, result: result, verb: "Deleted")
        case .stop:
            guard action.isDestructive else {
                throw RuntimeAdapterError.commandRejected(
                    classification: .mutating,
                    message: "Migration quiescence requires an explicitly destructive action."
                )
            }
            let result = try await translate {
                try await client.stop(mutationPayload(action, context: context), context: context)
            }
            return event(action, result: result, verb: "Stopped")
        case .update, .noOp:
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Runtime action '\(action.kind.rawValue)' is unavailable."
            )
        }
    }

    private func mutationPayload(
        _ action: PlannedRuntimeAction,
        context: RuntimeMutationContext
    ) throws -> ContainerizationHelperMutationPayload {
        guard RuntimeManagedResourceIdentity.isCurrentIdentifier(action.resourceIdentifier) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Containerization mutation requires an exact v2 Hostwright resource identifier."
            )
        }
        return ContainerizationHelperMutationPayload(
            resourceIdentifier: action.resourceIdentifier,
            resourceUUID: context.resourceUUID
        )
    }

    private func event(
        _ action: PlannedRuntimeAction,
        result: ContainerizationHelperMutationResult,
        verb: String
    ) -> RuntimeEvent {
        RuntimeEvent(
            identity: action.identity,
            message: "\(verb) and verified managed service \(action.identity.displayName).",
            resourceIdentifier: result.resourceIdentifier
        )
    }

    private func observedServices(
        _ inventory: RuntimeInventory,
        desiredState: DesiredRuntimeState
    ) throws -> [ObservedRuntimeService] {
        var hints: [String: RuntimeOwnedResourceHint] = [:]
        for hint in desiredState.ownedResourceHints {
            guard hint.identity.projectName == desiredState.projectName,
                  hints.updateValue(hint, forKey: hint.resourceIdentifier) == nil else {
                throw RuntimeAdapterError.outputParseFailed("Runtime state contained conflicting ownership hints.")
            }
        }
        let networks = Dictionary(uniqueKeysWithValues: inventory.networks.map { ($0.runtimeID, $0) })
        return try inventory.containers.compactMap { container in
            guard let hint = hints[container.runtimeID] else { return nil }
            let labels = Dictionary(uniqueKeysWithValues: container.labels.map { ($0.key, $0.value) })
            guard hint.identityVersion == RuntimeManagedResourceIdentity.currentVersion,
                  let expected = hint.ownership,
                  expected.providerID == .appleContainerization,
                  container.ownership == expected,
                  RuntimeManagedResourceIdentity.identity(from: labels) == hint.identity,
                  RuntimeManagedResourceIdentity.labelsMatch(
                    labels,
                    identity: hint.identity,
                    resourceIdentifier: hint.resourceIdentifier
                  ) else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Containerization inventory did not match exact UUID-backed ownership."
                )
            }
            return ObservedRuntimeService(
                identity: hint.identity,
                resourceIdentifier: container.runtimeID,
                image: container.imageReference,
                lifecycleState: lifecycle(container.lifecycle),
                healthState: health(container.health),
                ports: container.ports.map {
                    RuntimePortMapping(
                        hostPort: $0.hostPort,
                        containerPort: $0.containerPort,
                        protocolName: $0.protocolName == .udp ? .udp : .tcp,
                        bindAddress: $0.hostAddress
                    )
                },
                networks: container.networks.map { attachment in
                    let network = networks[attachment.networkID]
                    return RuntimeNetworkAttachment(
                        name: attachment.networkID,
                        kind: network?.kind,
                        address: attachment.addresses.first,
                        gateway: attachment.gateway,
                        interfaceName: attachment.interfaceName,
                        ipv4Address: attachment.addresses.first { $0.contains(".") },
                        ipv4Gateway: attachment.gateway?.contains(".") == true ? attachment.gateway : nil,
                        ipv6Address: attachment.addresses.first { $0.contains(":") },
                        macAddress: attachment.macAddress
                    )
                },
                mounts: container.mounts.map {
                    RuntimeMountReference(
                        source: $0.source,
                        target: $0.target,
                        access: $0.access == .readOnly ? .readOnly : .readWrite
                    )
                }
            )
        }.sorted { ($0.identity.displayName, $0.resourceIdentifier) < ($1.identity.displayName, $1.resourceIdentifier) }
    }

    private func lifecycle(_ value: RuntimeInventoryLifecycleState) -> RuntimeLifecycleState {
        switch value {
        case .unknown: .unknown
        case .missing: .missing
        case .created: .created
        case .running: .running
        case .stopped: .stopped
        case .exited: .exited
        case .failed: .failed
        }
    }

    private func health(_ value: RuntimeInventoryHealth) -> RuntimeHealthState {
        switch value.availability {
        case .notConfigured: return .notConfigured
        case .unsupported, .unavailable: return .unknown
        case .available:
            switch value.state {
            case .starting: return .starting
            case .healthy: return .healthy
            case .unhealthy: return .unhealthy
            case .unknown, .none: return .unknown
            }
        }
    }

    private func translate<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as RuntimeAdapterError { throw error.redacted(using: redactionPolicy) }
        catch let error as ContainerizationHelperClientError {
            switch error {
            case .remote(let failure):
                throw RuntimeAdapterError.normalizedFailure(failure)
            case .cancelled:
                throw RuntimeAdapterError.commandCancelled(
                    command: "containerization-helper",
                    partialOutput: "",
                    partialError: "The helper request was cancelled."
                )
            case .timedOut:
                throw RuntimeAdapterError.commandTimedOut(
                    command: "containerization-helper",
                    partialOutput: "",
                    partialError: "The helper request timed out."
                )
            case .responseTooLarge:
                throw RuntimeAdapterError.commandOutputLimitExceeded(
                    command: "containerization-helper",
                    partialOutput: "",
                    partialError: "The helper response exceeded its bound."
                )
            case .peerAuthenticationFailed, .unsafeExecutable, .unsafeConfiguration,
                 .unsafeRuntimeDirectory, .socketUnsafe:
                throw RuntimeAdapterError.permissionDenied("Containerization helper trust validation failed.")
            case .socketUnavailable, .connectionFailed, .helperLaunchFailed, .helperExited:
                throw RuntimeAdapterError.runtimeUnavailable("Containerization helper is unavailable.")
            default:
                throw RuntimeAdapterError.outputParseFailed("Containerization helper returned an invalid response.")
            }
        } catch is CancellationError {
            throw RuntimeAdapterError.commandCancelled(
                command: "containerization-helper",
                partialOutput: "",
                partialError: "The helper request was cancelled."
            )
        }
    }
}
