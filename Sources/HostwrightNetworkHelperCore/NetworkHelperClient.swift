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
    case conflict
    case quarantined
    case unsafeState
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
    public let device: UInt64
    public let inode: UInt64

    public init(
        identity: NetworkHelperDNSIdentity,
        url: URL,
        sha256: String,
        hostAccessSHA256: String? = nil,
        device: UInt64,
        inode: UInt64
    ) {
        self.identity = identity
        self.url = url
        self.sha256 = sha256
        self.hostAccessSHA256 = hostAccessSHA256
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
    let process: Process
    let processID: pid_t

    init(process: Process) {
        self.process = process
        processID = process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    func waitForExit(deadlineMilliseconds: Int64) -> Bool {
        while process.isRunning,
              Self.monotonicMilliseconds() < deadlineMilliseconds {
            usleep(10_000)
        }
        return !process.isRunning
    }

    func terminateIfRunning() {
        guard process.isRunning else { return }
        process.terminate()
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
        var metadata = stat()
        guard lstat(configuration.executableURL.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid() || metadata.st_uid == 0,
              metadata.st_nlink == 1,
              access(configuration.executableURL.path, X_OK) == 0 else {
            throw NetworkHelperClientError.executableRejected
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = [
            "--runtime-directory",
            configuration.runtimeDirectoryURL.path,
            "--idle-timeout-milliseconds",
            String(configuration.helperIdleTimeoutMilliseconds)
        ]
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw NetworkHelperClientError.launchFailed
        }
        guard process.processIdentifier > 0 else {
            throw NetworkHelperClientError.launchFailed
        }
        return NetworkHelperProcessLease(process: process)
    }
}

public actor NetworkHelperClient {
    public let configuration: NetworkHelperClientConfiguration

    private let executableValidator: NetworkHelperExecutableValidator
    private let peerAuthenticator: NetworkHelperServerPeerAuthenticator
    private let launcher: NetworkHelperProcessLauncher
    private var processLease: NetworkHelperProcessLease?
    private var retainsActiveHostAccess = false

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
        predecessorFencingToken: String? = nil
    ) throws -> NetworkHelperActiveCorefile {
        let request = NetworkHelperRequest(
            operation: .apply,
            identity: identity,
            corefile: corefile,
            hostAccessBindings: hostAccessBindings,
            predecessorFencingToken: predecessorFencingToken
        )
        let status = try exchange(request)
        guard status.disposition == .active else {
            throw map(status.disposition)
        }
        retainsActiveHostAccess = status.hostAccessSHA256 != nil
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
        retainsActiveHostAccess = false
    }

    public func close() throws {
        guard let lease = processLease else { return }
        processLease = nil
        if retainsActiveHostAccess {
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
            switch error.code {
            case .conflict:
                throw NetworkHelperClientError.conflict
            case .quarantined:
                throw NetworkHelperClientError.quarantined
            case .unsafePath:
                throw NetworkHelperClientError.unsafeState
            default:
                throw NetworkHelperClientError.helperFailure
            }
        }
        guard let status = response.status else {
            throw NetworkHelperClientError.protocolFailure
        }
        return status
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
