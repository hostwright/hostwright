import CryptoKit
import Darwin
import Foundation
import HostwrightNetworking
import HostwrightRuntime

public enum NetworkHelperClientError: Error, Equatable, Sendable {
    case invalidConfiguration
    case executableRejected
    case launchFailed
    case launchTimedOut
    case socketUnavailable
    case authenticationFailed
    case protocolFailure
    case invalidRequest
    case unsupportedProtocolVersion
    case invalidIdentity
    case invalidCorefile
    case invalidFrame
    case conflict
    case quarantined
    case unsafeState
    case ioFailure
    case permissionDenied
    case bindingUnavailable
    case certificateUnavailable
    case invalidCertificate
    case helperFailure
    case cleanupFailed
}

public enum NetworkHelperClientDisposition: String, Equatable, Sendable {
    case absent
    case active
    case conflict
    case quarantined
}

public struct NetworkHelperActiveCorefile: Equatable, Sendable {
    public let identity: NetworkHelperDNSIdentity
    public let url: URL
    public let sha256: String
    public let hostAccessSHA256: String?
    public let hostAccessActive: Bool
    public let ingressSHA256: String?
    public let ingressActive: Bool
    public let ingressAccessLog: [NetworkHelperIngressAccessLogEntry]
    public let mutualTLSAudit: [NetworkHelperMutualTLSAuditEntry]
    public let certificateSHA256: String?
    public let certificateActive: Bool
    public let certificateEvidenceSHA256: String?
    public let certificateSummaries: [NetworkHelperCertificateSummary]
    public let policySHA256: String?
    public let policyActive: Bool
    public let device: UInt64
    public let inode: UInt64

    public init(
        identity: NetworkHelperDNSIdentity,
        url: URL,
        sha256: String,
        hostAccessSHA256: String? = nil,
        hostAccessActive: Bool = true,
        ingressSHA256: String? = nil,
        ingressActive: Bool = true,
        ingressAccessLog: [NetworkHelperIngressAccessLogEntry] = [],
        mutualTLSAudit: [NetworkHelperMutualTLSAuditEntry] = [],
        certificateSHA256: String? = nil,
        certificateActive: Bool = true,
        certificateEvidenceSHA256: String? = nil,
        certificateSummaries: [NetworkHelperCertificateSummary] = [],
        policySHA256: String? = nil,
        policyActive: Bool = true,
        device: UInt64,
        inode: UInt64
    ) {
        self.identity = identity
        self.url = url
        self.sha256 = sha256
        self.hostAccessSHA256 = hostAccessSHA256
        self.hostAccessActive = hostAccessActive
        self.ingressSHA256 = ingressSHA256
        self.ingressActive = ingressActive
        self.ingressAccessLog = ingressAccessLog
        self.mutualTLSAudit = mutualTLSAudit
        self.certificateSHA256 = certificateSHA256
        self.certificateActive = certificateActive
        self.certificateEvidenceSHA256 = certificateEvidenceSHA256
        self.certificateSummaries = certificateSummaries
        self.policySHA256 = policySHA256
        self.policyActive = policyActive
        self.device = device
        self.inode = inode
    }
}

public struct NetworkHelperClientStatus: Equatable, Sendable {
    public let disposition: NetworkHelperClientDisposition
    public let activeCorefile: NetworkHelperActiveCorefile?
    public let reason: String?

    public init(
        disposition: NetworkHelperClientDisposition,
        activeCorefile: NetworkHelperActiveCorefile?,
        reason: String?
    ) {
        self.disposition = disposition
        self.activeCorefile = activeCorefile
        self.reason = reason
    }
}

public struct NetworkHelperClientConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let runtimeDirectoryURL: URL
    public let launchTimeoutMilliseconds: Int64
    public let requestTimeoutMilliseconds: Int64
    public let helperIdleTimeoutMilliseconds: Int64

    public init(
        executableURL: URL,
        runtimeDirectoryURL: URL,
        launchTimeoutMilliseconds: Int64 = 5_000,
        requestTimeoutMilliseconds: Int64 = 5_000,
        helperIdleTimeoutMilliseconds: Int64 = 1_000
    ) {
        self.executableURL = executableURL
        self.runtimeDirectoryURL = runtimeDirectoryURL
        self.launchTimeoutMilliseconds = launchTimeoutMilliseconds
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.helperIdleTimeoutMilliseconds = helperIdleTimeoutMilliseconds
    }

    func validated() throws -> Self {
        guard Self.isNormalizedAbsolute(executableURL.path),
              Self.isNormalizedAbsolute(runtimeDirectoryURL.path),
              launchTimeoutMilliseconds > 0,
              requestTimeoutMilliseconds > 0,
              helperIdleTimeoutMilliseconds > 0,
              helperIdleTimeoutMilliseconds <= 30_000 else {
            throw NetworkHelperClientError.invalidConfiguration
        }
        return self
    }

    private static func isNormalizedAbsolute(_ path: String) -> Bool {
        guard path.first == "/",
              path == "/" || !path.hasSuffix("/") else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first?.isEmpty == true else { return false }
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

final class NetworkHelperProcessLease: @unchecked Sendable {
    let processID: pid_t
    private let running: @Sendable () -> Bool
    private let terminate: @Sendable () -> Void

    init(
        processID: pid_t,
        isRunning: @escaping @Sendable () -> Bool,
        terminate: @escaping @Sendable () -> Void
    ) {
        self.processID = processID
        running = isRunning
        self.terminate = terminate
    }

    var isRunning: Bool {
        running()
    }

    func waitForExit(deadlineMilliseconds: Int64) -> Bool {
        while isRunning,
              Self.monotonicMilliseconds() < deadlineMilliseconds {
            usleep(10_000)
        }
        return !isRunning
    }

    func terminateIfRunning() {
        guard isRunning else { return }
        terminate()
    }

    private static func monotonicMilliseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000
            + Int64(time.tv_nsec) / 1_000_000
    }
}

struct NetworkHelperProcessLauncher: Sendable {
    let launch: @Sendable (
        NetworkHelperClientConfiguration
    ) throws -> NetworkHelperProcessLease

    static let live = Self { configuration in
        try NetworkHelperPOSIXLauncher.launch(configuration)
    }
}

private enum NetworkHelperPOSIXLauncher {
    private struct ExecutableIdentity: Equatable {
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

        init(path: String) throws {
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid() || metadata.st_uid == 0,
                  metadata.st_nlink == 1,
                  metadata.st_mode
                    & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISTXT)
                    == 0,
                  metadata.st_mode & S_IXUSR != 0 else {
                throw NetworkHelperClientError.executableRejected
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

    static func launch(
        _ configuration: NetworkHelperClientConfiguration
    ) throws -> NetworkHelperProcessLease {
        let executablePath = configuration.executableURL.path
        let executableIdentity = try ExecutableIdentity(path: executablePath)
        let rootDirectory = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDirectory >= 0 else {
            throw NetworkHelperClientError.launchFailed
        }
        defer { Darwin.close(rootDirectory) }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw NetworkHelperClientError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw NetworkHelperClientError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        try requireSuccess(
            posix_spawn_file_actions_addfchdir(
                &fileActions,
                rootDirectory
            )
        )
        try requireSuccess(
            posix_spawn_file_actions_addclose(
                &fileActions,
                rootDirectory
            )
        )
        try requireSuccess(
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            )
        )
        try requireSuccess(
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDOUT_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
        )
        try requireSuccess(
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
        )

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try requireSuccess(
            posix_spawnattr_setsigmask(&attributes, &signalMask)
        )
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGALRM, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        try requireSuccess(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        )
        let flags = Int16(
            POSIX_SPAWN_SETSID |
                POSIX_SPAWN_CLOEXEC_DEFAULT |
                POSIX_SPAWN_SETSIGMASK |
                POSIX_SPAWN_SETSIGDEF |
                POSIX_SPAWN_START_SUSPENDED
        )
        try requireSuccess(
            posix_spawnattr_setflags(&attributes, flags)
        )

        var arguments = try cStringVector([
            executablePath,
            "--runtime-directory",
            configuration.runtimeDirectoryURL.path,
            "--idle-timeout-milliseconds",
            String(configuration.helperIdleTimeoutMilliseconds)
        ])
        defer { freeCStringVector(&arguments) }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var processID = pid_t(0)
        let launchCode = arguments.withUnsafeMutableBufferPointer {
            argumentBuffer in
            environment.withUnsafeMutableBufferPointer {
                environmentBuffer in
                posix_spawn(
                    &processID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        guard launchCode == 0, processID > 0 else {
            throw NetworkHelperClientError.launchFailed
        }

        do {
            guard try ExecutableIdentity(path: executablePath)
                    == executableIdentity else {
                throw NetworkHelperClientError.executableRejected
            }
        } catch {
            terminateSuspended(processID)
            throw error
        }
        guard kill(processID, SIGCONT) == 0 else {
            terminateSuspended(processID)
            throw NetworkHelperClientError.launchFailed
        }

        let state = NetworkHelperPOSIXProcessState(processID: processID)
        return NetworkHelperProcessLease(
            processID: processID,
            isRunning: { state.isRunning },
            terminate: { state.terminate() }
        )
    }

    private static func requireSuccess(_ code: Int32) throws {
        guard code == 0 else {
            throw NetworkHelperClientError.launchFailed
        }
    }

    private static func cStringVector(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard !string.contains("\0"),
                  let pointer = strdup(string) else {
                freeCStringVector(&result)
                throw NetworkHelperClientError.launchFailed
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

private final class NetworkHelperPOSIXProcessState: @unchecked Sendable {
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
        let deadline = Date(
            timeIntervalSinceNow: Double(milliseconds) / 1_000
        )
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

public actor NetworkHelperClient {
    public let configuration: NetworkHelperClientConfiguration

    private let executableValidator: NetworkHelperExecutableValidator
    private let peerAuthenticator: NetworkHelperServerPeerAuthenticator
    private let launcher: NetworkHelperProcessLauncher
    private var processLease: NetworkHelperProcessLease?
    private var retainsActiveBindings = false

    public init(configuration: NetworkHelperClientConfiguration) {
        self.configuration = configuration
        executableValidator = .production
        peerAuthenticator = .production()
        launcher = .live
    }

    init(
        configuration: NetworkHelperClientConfiguration,
        executableValidator: NetworkHelperExecutableValidator,
        peerAuthenticator: NetworkHelperServerPeerAuthenticator,
        launcher: NetworkHelperProcessLauncher = .live
    ) {
        self.configuration = configuration
        self.executableValidator = executableValidator
        self.peerAuthenticator = peerAuthenticator
        self.launcher = launcher
    }

    public func bootstrap() throws {
        let lease = try ensureProcess()
        let descriptor = try connect(to: lease)
        Darwin.close(descriptor)
    }

    public func apply(
        identity: NetworkHelperDNSIdentity,
        corefile: String,
        hostAccessBindings: [ProjectDNSHostAccessBinding] = [],
        ingressBindings: [ProjectIngressListenerBinding] = [],
        certificateBindings: [ProjectCertificateRequestBinding] = [],
        policyPlan: NetworkPolicyPlan? = nil,
        predecessorFencingToken: String? = nil
    ) throws -> NetworkHelperActiveCorefile {
        let request = NetworkHelperRequest(
            operation: .apply,
            identity: identity,
            corefile: corefile,
            hostAccessBindings: hostAccessBindings,
            ingressBindings: ingressBindings,
            certificateBindings: certificateBindings,
            policyPlan: policyPlan,
            predecessorFencingToken: predecessorFencingToken
        )
        let status = try exchange(request)
        guard status.disposition == .active else {
            throw map(status.disposition)
        }
        retainsActiveBindings =
            status.hostAccessSHA256 != nil ||
            status.ingressSHA256 != nil
            || status.certificateSHA256 != nil ||
            status.policySHA256 != nil
        return try validateActiveCorefile(status: status)
    }

    public func status(
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperClientStatus {
        let status = try exchange(
            NetworkHelperRequest(
                operation: .status,
                identity: identity
            )
        )
        switch status.disposition {
        case .active:
            return NetworkHelperClientStatus(
                disposition: .active,
                activeCorefile: try validateActiveCorefile(status: status),
                reason: nil
            )
        case .absent:
            return NetworkHelperClientStatus(
                disposition: .absent,
                activeCorefile: nil,
                reason: nil
            )
        case .conflict:
            return NetworkHelperClientStatus(
                disposition: .conflict,
                activeCorefile: nil,
                reason: status.reason
            )
        case .quarantined:
            return NetworkHelperClientStatus(
                disposition: .quarantined,
                activeCorefile: nil,
                reason: status.reason
            )
        }
    }

    public func remove(identity: NetworkHelperDNSIdentity) throws {
        let status = try exchange(
            NetworkHelperRequest(
                operation: .remove,
                identity: identity
            )
        )
        guard status.disposition == .absent else {
            throw map(status.disposition)
        }
        retainsActiveBindings = false
    }

    public func close() throws {
        guard let lease = processLease else { return }
        processLease = nil
        if retainsActiveBindings {
            return
        }
        let idleDeadline = Self.monotonicMilliseconds()
            + configuration.helperIdleTimeoutMilliseconds + 2_000
        if !lease.waitForExit(deadlineMilliseconds: idleDeadline) {
            lease.terminateIfRunning()
            let terminationDeadline =
                Self.monotonicMilliseconds() + 1_000
            guard lease.waitForExit(
                deadlineMilliseconds: terminationDeadline
            ) else {
                throw NetworkHelperClientError.cleanupFailed
            }
        }
        let socketURL = configuration.runtimeDirectoryURL
            .appendingPathComponent(
                "network-helper.sock",
                isDirectory: false
            )
        let cleanupDeadline = Self.monotonicMilliseconds() + 1_000
        while FileManager.default.fileExists(atPath: socketURL.path),
              Self.monotonicMilliseconds() < cleanupDeadline {
            usleep(10_000)
        }
        guard !FileManager.default.fileExists(atPath: socketURL.path) else {
            throw NetworkHelperClientError.cleanupFailed
        }
    }

    private func exchange(
        _ request: NetworkHelperRequest
    ) throws -> NetworkHelperStatus {
        _ = try request.validated()
        let lease = try ensureProcess()
        let descriptor = try connect(to: lease)
        defer { Darwin.close(descriptor) }
        let frame = try NetworkHelperCanonicalJSON.frame(request)
        try Self.writeAll(
            descriptor: descriptor,
            data: frame,
            timeoutMilliseconds: configuration.requestTimeoutMilliseconds
        )
        let responseFrame = try NetworkHelperConnectionHandler.readFrame(
            descriptor: descriptor,
            timeoutMilliseconds:
                configuration.requestTimeoutMilliseconds
        )
        let response: NetworkHelperResponse
        do {
            response = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: responseFrame
            )
        } catch {
            throw NetworkHelperClientError.protocolFailure
        }
        guard response.protocolVersion == NetworkHelperProtocolV1.version,
              response.requestID == request.requestID,
              response.operation == request.operation,
              (response.status == nil) != (response.error == nil) else {
            throw NetworkHelperClientError.protocolFailure
        }
        if let error = response.error {
            throw Self.map(error.code)
        }
        guard let status = response.status else {
            throw NetworkHelperClientError.protocolFailure
        }
        return status
    }

    static func map(
        _ code: NetworkHelperErrorCode
    ) -> NetworkHelperClientError {
        switch code {
        case .invalidRequest:
            return .invalidRequest
        case .unsupportedProtocolVersion:
            return .unsupportedProtocolVersion
        case .invalidIdentity:
            return .invalidIdentity
        case .invalidCorefile:
            return .invalidCorefile
        case .invalidFrame:
            return .invalidFrame
        case .conflict:
            return .conflict
        case .quarantined:
            return .quarantined
        case .unsafePath:
            return .unsafeState
        case .ioFailure:
            return .ioFailure
        case .permissionDenied:
            return .permissionDenied
        case .bindingUnavailable:
            return .bindingUnavailable
        case .certificateUnavailable:
            return .certificateUnavailable
        case .invalidCertificate:
            return .invalidCertificate
        }
    }

    private func ensureProcess() throws -> NetworkHelperProcessLease? {
        let configuration = try configuration.validated()
        if let processLease, processLease.isRunning {
            return processLease
        }
        do {
            try executableValidator.validate(
                executableURL: configuration.executableURL
            )
        } catch {
            throw NetworkHelperClientError.executableRejected
        }
        let socketURL = configuration.runtimeDirectoryURL
            .appendingPathComponent(
                "network-helper.sock",
                isDirectory: false
            )
        if FileManager.default.fileExists(atPath: socketURL.path) {
            let attachDeadline =
                Self.monotonicMilliseconds() + 250
            while true {
                do {
                    let descriptor = try connect(to: nil)
                    Darwin.close(descriptor)
                    processLease = nil
                    return nil
                } catch NetworkHelperClientError.socketUnavailable {
                    guard Self.monotonicMilliseconds()
                            < attachDeadline else {
                        try removeOwnedStaleSocket(socketURL)
                        break
                    }
                    usleep(10_000)
                }
            }
        }
        let lease = try launcher.launch(configuration)
        processLease = lease
        do {
            try waitForSocket(lease: lease)
            return lease
        } catch {
            lease.terminateIfRunning()
            _ = lease.waitForExit(
                deadlineMilliseconds:
                    Self.monotonicMilliseconds() + 1_000
            )
            processLease = nil
            throw error
        }
    }

    private func waitForSocket(
        lease: NetworkHelperProcessLease
    ) throws {
        let socketURL = configuration.runtimeDirectoryURL
            .appendingPathComponent(
                "network-helper.sock",
                isDirectory: false
            )
        let deadline = Self.monotonicMilliseconds()
            + configuration.launchTimeoutMilliseconds
        while Self.monotonicMilliseconds() < deadline {
            var metadata = stat()
            if lstat(socketURL.path, &metadata) == 0 {
                guard (metadata.st_mode & S_IFMT) == S_IFSOCK,
                      metadata.st_uid == geteuid(),
                      metadata.st_mode & mode_t(0o7777) == 0o600 else {
                    throw NetworkHelperClientError.unsafeState
                }
                return
            }
            guard errno == ENOENT else {
                throw NetworkHelperClientError.socketUnavailable
            }
            guard lease.isRunning else {
                throw NetworkHelperClientError.launchFailed
            }
            usleep(10_000)
        }
        throw NetworkHelperClientError.launchTimedOut
    }

    private func connect(
        to lease: NetworkHelperProcessLease?
    ) throws -> Int32 {
        let socketURL = configuration.runtimeDirectoryURL
            .appendingPathComponent(
                "network-helper.sock",
                isDirectory: false
            )
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw NetworkHelperClientError.invalidConfiguration
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) { bytes in
                for index in pathBytes.indices {
                    bytes[index] = pathBytes[index]
                }
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NetworkHelperClientError.socketUnavailable
        }
        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw NetworkHelperClientError.socketUnavailable
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw NetworkHelperClientError.socketUnavailable
        }
        do {
            try peerAuthenticator.validate(
                connectionDescriptor: descriptor,
                expectedProcessID: lease?.processID
            )
        } catch {
            throw NetworkHelperClientError.authenticationFailed
        }
        shouldClose = false
        return descriptor
    }

    private func removeOwnedStaleSocket(_ socketURL: URL) throws {
        var before = stat()
        guard lstat(socketURL.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFSOCK,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & mode_t(0o7777) == 0o600 else {
            throw NetworkHelperClientError.unsafeState
        }
        var after = stat()
        guard lstat(socketURL.path, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              unlink(socketURL.path) == 0 else {
            throw NetworkHelperClientError.socketUnavailable
        }
    }

    private func validateActiveCorefile(
        status: NetworkHelperStatus
    ) throws -> NetworkHelperActiveCorefile {
        guard status.disposition == .active,
              let identity = status.identity,
              let expectedSHA256 = status.corefileSHA256,
              expectedSHA256.count == 64,
              expectedSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw NetworkHelperClientError.protocolFailure
        }
        let dnsRootURL = configuration.runtimeDirectoryURL
            .appendingPathComponent("dns-state", isDirectory: true)
            .appendingPathComponent(identity.projectUUID, isDirectory: true)
            .appendingPathComponent(identity.dnsUUID, isDirectory: true)
        let activeURL = dnsRootURL.appendingPathComponent(
            "active",
            isDirectory: true
        )
        let corefileURL = activeURL.appendingPathComponent(
            "Corefile",
            isDirectory: false
        )
        try Self.validatePrivateDirectoryChain(
            [
                configuration.runtimeDirectoryURL,
                configuration.runtimeDirectoryURL.appendingPathComponent(
                    "dns-state",
                    isDirectory: true
                ),
                configuration.runtimeDirectoryURL
                    .appendingPathComponent(
                        "dns-state",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        identity.projectUUID,
                        isDirectory: true
                    ),
                dnsRootURL,
                activeURL
            ]
        )
        let descriptor = open(
            corefileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw NetworkHelperClientError.unsafeState
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o7777) == 0o600,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(
                NetworkHelperProtocolV1.maximumCorefileBytes
              ) else {
            throw NetworkHelperClientError.unsafeState
        }
        let data = try Self.readExact(
            descriptor: descriptor,
            byteCount: Int(metadata.st_size)
        )
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedSHA256 else {
            throw NetworkHelperClientError.unsafeState
        }
        return NetworkHelperActiveCorefile(
            identity: identity,
            url: corefileURL,
            sha256: expectedSHA256,
            hostAccessSHA256: status.hostAccessSHA256,
            hostAccessActive:
                status.hostAccessActive ??
                (status.hostAccessSHA256 == nil),
            ingressSHA256: status.ingressSHA256,
            ingressActive:
                status.ingressActive ??
                (status.ingressSHA256 == nil),
            ingressAccessLog: status.ingressAccessLog ?? [],
            mutualTLSAudit: status.mutualTLSAudit ?? [],
            certificateSHA256: status.certificateSHA256,
            certificateActive:
                status.certificateActive ??
                (status.certificateSHA256 == nil),
            certificateEvidenceSHA256:
                status.certificateEvidenceSHA256,
            certificateSummaries:
                status.certificateSummaries ?? [],
            policySHA256: status.policySHA256,
            policyActive:
                status.policyActive ??
                (status.policySHA256 == nil),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    private func map(
        _ disposition: NetworkHelperDisposition
    ) -> NetworkHelperClientError {
        switch disposition {
        case .conflict:
            return .conflict
        case .quarantined:
            return .quarantined
        case .absent, .active:
            return .protocolFailure
        }
    }

    private static func validatePrivateDirectoryChain(
        _ directories: [URL]
    ) throws {
        for directory in directories {
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & mode_t(0o7777) == 0o700 else {
                throw NetworkHelperClientError.unsafeState
            }
        }
    }

    private static func readExact(
        descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(byteCount)
        var buffer = [UInt8](
            repeating: 0,
            count: min(max(byteCount, 1), 64 * 1_024)
        )
        while result.count < byteCount {
            let count = Darwin.read(
                descriptor,
                &buffer,
                min(buffer.count, byteCount - result.count)
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw NetworkHelperClientError.unsafeState
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    private static func writeAll(
        descriptor: Int32,
        data: Data,
        timeoutMilliseconds: Int64
    ) throws {
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard monotonicMilliseconds() < deadline else {
                    throw NetworkHelperClientError.protocolFailure
                }
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let ready = Darwin.poll(&pollDescriptor, 1, 100)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else {
                    if ready == 0 { continue }
                    throw NetworkHelperClientError.protocolFailure
                }
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw NetworkHelperClientError.protocolFailure
                }
                offset += count
            }
        }
    }

    private static func monotonicMilliseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000
            + Int64(time.tv_nsec) / 1_000_000
    }
}
