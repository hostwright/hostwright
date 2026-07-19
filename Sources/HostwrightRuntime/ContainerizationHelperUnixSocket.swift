import Darwin
import Foundation

private let containerizationHelperAllPermissionBits = mode_t(
    S_ISUID | S_ISGID | S_ISTXT | S_IRWXU | S_IRWXG | S_IRWXO
)

public enum ContainerizationHelperSocketError: Error, Equatable, Sendable {
    case pathMustBeAbsolute
    case pathNotNormalized
    case pathTooLong
    case unsafeParent
    case unsafeRuntimeDirectory
    case runtimeDirectoryReplaced
    case socketPathOccupied
    case socketCreationFailed
    case socketConfigurationFailed
    case socketBindFailed
    case socketModeInvalid
    case socketListenFailed
    case socketPathReplaced
    case cleanupFailed
}

private struct ContainerizationHelperFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }
}

public struct ContainerizationHelperRuntimeDirectory: Sendable {
    public let directoryURL: URL
    public let socketURL: URL
    public let createdDirectory: Bool

    private let identity: ContainerizationHelperFileIdentity
    private let owner: uid_t

    private init(
        directoryURL: URL,
        socketURL: URL,
        createdDirectory: Bool,
        identity: ContainerizationHelperFileIdentity,
        owner: uid_t
    ) {
        self.directoryURL = directoryURL
        self.socketURL = socketURL
        self.createdDirectory = createdDirectory
        self.identity = identity
        self.owner = owner
    }

    public static func prepare(
        at directoryURL: URL,
        socketName: String = "containerization-helper.sock",
        owner: uid_t = geteuid()
    ) throws -> ContainerizationHelperRuntimeDirectory {
        guard directoryURL.path.hasPrefix("/") else {
            throw ContainerizationHelperSocketError.pathMustBeAbsolute
        }
        guard directoryURL.standardizedFileURL.path == directoryURL.path,
              !socketName.isEmpty,
              !socketName.contains("/"),
              socketName != ".",
              socketName != ".." else {
            throw ContainerizationHelperSocketError.pathNotNormalized
        }

        let parentURL = directoryURL.deletingLastPathComponent()
        try validateParent(parentURL, owner: owner)

        var created = false
        var metadata = stat()
        if lstat(directoryURL.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ContainerizationHelperSocketError.unsafeRuntimeDirectory
            }
            guard mkdir(directoryURL.path, S_IRWXU) == 0 else {
                throw ContainerizationHelperSocketError.unsafeRuntimeDirectory
            }
            created = true
            guard chmod(directoryURL.path, S_IRWXU) == 0,
                  lstat(directoryURL.path, &metadata) == 0 else {
                _ = rmdir(directoryURL.path)
                throw ContainerizationHelperSocketError.unsafeRuntimeDirectory
            }
        }

        do {
            try validateDirectory(metadata, owner: owner)
            let socketURL = directoryURL.appendingPathComponent(socketName, isDirectory: false)
            guard socketURL.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
                throw ContainerizationHelperSocketError.pathTooLong
            }
            return ContainerizationHelperRuntimeDirectory(
                directoryURL: directoryURL,
                socketURL: socketURL,
                createdDirectory: created,
                identity: ContainerizationHelperFileIdentity(metadata),
                owner: owner
            )
        } catch {
            if created {
                _ = rmdir(directoryURL.path)
            }
            throw error
        }
    }

    public func makeListeningSocket(backlog: Int32 = 16) throws -> ContainerizationHelperSocketLease {
        try validateCurrentDirectory()

        var existing = stat()
        guard lstat(socketURL.path, &existing) != 0, errno == ENOENT else {
            throw ContainerizationHelperSocketError.socketPathOccupied
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ContainerizationHelperSocketError.socketCreationFailed
        }
        var shouldClose = true
        var createdSocketIdentity: ContainerizationHelperFileIdentity?
        defer {
            if shouldClose {
                Darwin.close(descriptor)
                if let createdSocketIdentity {
                    var current = stat()
                    if lstat(socketURL.path, &current) == 0,
                       ContainerizationHelperFileIdentity(current) == createdSocketIdentity,
                       (current.st_mode & S_IFMT) == S_IFSOCK {
                        _ = unlink(socketURL.path)
                    }
                }
            }
        }

        let descriptorFlags = fcntl(descriptor, F_GETFL)
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              descriptorFlags >= 0,
              fcntl(descriptor, F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
            throw ContainerizationHelperSocketError.socketConfigurationFailed
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw ContainerizationHelperSocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { bytes in
                for index in pathBytes.indices {
                    bytes[index] = pathBytes[index]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw ContainerizationHelperSocketError.socketBindFailed
        }

        var socketMetadata = stat()
        guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0,
              lstat(socketURL.path, &socketMetadata) == 0,
              (socketMetadata.st_mode & S_IFMT) == S_IFSOCK,
              socketMetadata.st_uid == owner,
              socketMetadata.st_mode & containerizationHelperAllPermissionBits == S_IRUSR | S_IWUSR else {
            _ = unlink(socketURL.path)
            throw ContainerizationHelperSocketError.socketModeInvalid
        }
        createdSocketIdentity = ContainerizationHelperFileIdentity(socketMetadata)
        guard listen(descriptor, backlog) == 0 else {
            _ = unlink(socketURL.path)
            throw ContainerizationHelperSocketError.socketListenFailed
        }

        try validateCurrentDirectory()
        shouldClose = false
        return ContainerizationHelperSocketLease(
            descriptor: descriptor,
            socketURL: socketURL,
            socketIdentity: ContainerizationHelperFileIdentity(socketMetadata)
        )
    }

    public func cleanupDirectoryIfCreated() throws {
        guard createdDirectory else { return }
        try validateCurrentDirectory()
        guard rmdir(directoryURL.path) == 0 else {
            throw ContainerizationHelperSocketError.cleanupFailed
        }
    }

    public func validateCurrentDirectory() throws {
        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0,
              ContainerizationHelperFileIdentity(metadata) == identity else {
            throw ContainerizationHelperSocketError.runtimeDirectoryReplaced
        }
        try Self.validateDirectory(metadata, owner: owner)
    }

    private static func validateParent(_ parentURL: URL, owner: uid_t) throws {
        var metadata = stat()
        guard lstat(parentURL.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == owner,
              metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw ContainerizationHelperSocketError.unsafeParent
        }
    }

    private static func validateDirectory(_ metadata: stat, owner: uid_t) throws {
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == owner,
              metadata.st_mode & containerizationHelperAllPermissionBits == S_IRWXU else {
            throw ContainerizationHelperSocketError.unsafeRuntimeDirectory
        }
    }
}

public final class ContainerizationHelperSocketLease: @unchecked Sendable {
    public let descriptor: Int32
    public let socketURL: URL

    private let socketIdentity: ContainerizationHelperFileIdentity
    private let lock = NSLock()
    private var closed = false

    fileprivate init(
        descriptor: Int32,
        socketURL: URL,
        socketIdentity: ContainerizationHelperFileIdentity
    ) {
        self.descriptor = descriptor
        self.socketURL = socketURL
        self.socketIdentity = socketIdentity
    }

    public func closeAndRemove() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)

        var metadata = stat()
        if lstat(socketURL.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ContainerizationHelperSocketError.cleanupFailed
            }
            return
        }
        guard ContainerizationHelperFileIdentity(metadata) == socketIdentity,
              (metadata.st_mode & S_IFMT) == S_IFSOCK else {
            throw ContainerizationHelperSocketError.socketPathReplaced
        }
        guard unlink(socketURL.path) == 0 else {
            throw ContainerizationHelperSocketError.cleanupFailed
        }
    }

    deinit {
        try? closeAndRemove()
    }
}

public struct ContainerizationHelperPeerAuthenticator: Sendable {
    private let validation: @Sendable (Int32) throws -> Void

    public init(validation: @escaping @Sendable (Int32) throws -> Void) {
        self.validation = validation
    }

    public func validate(connectionDescriptor: Int32) throws {
        try validation(connectionDescriptor)
    }
}

public struct ContainerizationHelperIdlePolicy: Equatable, Sendable {
    public let timeoutMilliseconds: Int64

    public init(timeoutMilliseconds: Int64 = 30_000) {
        precondition(timeoutMilliseconds > 0)
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func shouldShutdown(
        nowMilliseconds: Int64,
        lastActivityMilliseconds: Int64,
        activeConnections: Int
    ) -> Bool {
        activeConnections == 0 &&
            nowMilliseconds >= lastActivityMilliseconds &&
            nowMilliseconds - lastActivityMilliseconds >= timeoutMilliseconds
    }
}

private actor ContainerizationHelperActivityTracker {
    private let policy: ContainerizationHelperIdlePolicy
    private var lastActivityMilliseconds: Int64
    private var activeConnections = 0

    init(policy: ContainerizationHelperIdlePolicy, nowMilliseconds: Int64) {
        self.policy = policy
        self.lastActivityMilliseconds = nowMilliseconds
    }

    func begin(nowMilliseconds: Int64) {
        activeConnections += 1
        lastActivityMilliseconds = nowMilliseconds
    }

    func end(nowMilliseconds: Int64) {
        activeConnections = max(0, activeConnections - 1)
        lastActivityMilliseconds = nowMilliseconds
    }

    func shouldShutdown(nowMilliseconds: Int64) -> Bool {
        policy.shouldShutdown(
            nowMilliseconds: nowMilliseconds,
            lastActivityMilliseconds: lastActivityMilliseconds,
            activeConnections: activeConnections
        )
    }
}

public struct ContainerizationHelperUnixServer: Sendable {
    public let runtimeDirectory: ContainerizationHelperRuntimeDirectory
    public let dispatcher: ContainerizationHelperDispatcher
    public let authenticator: ContainerizationHelperPeerAuthenticator
    public let idlePolicy: ContainerizationHelperIdlePolicy
    public let connectionReadTimeoutMilliseconds: Int64

    public init(
        runtimeDirectory: ContainerizationHelperRuntimeDirectory,
        dispatcher: ContainerizationHelperDispatcher,
        authenticator: ContainerizationHelperPeerAuthenticator,
        idlePolicy: ContainerizationHelperIdlePolicy = .init(),
        connectionReadTimeoutMilliseconds: Int64 = 5_000
    ) {
        precondition(connectionReadTimeoutMilliseconds > 0)
        self.runtimeDirectory = runtimeDirectory
        self.dispatcher = dispatcher
        self.authenticator = authenticator
        self.idlePolicy = idlePolicy
        self.connectionReadTimeoutMilliseconds = connectionReadTimeoutMilliseconds
    }

    public func run() async throws {
        let lease = try runtimeDirectory.makeListeningSocket()
        let tracker = ContainerizationHelperActivityTracker(
            policy: idlePolicy,
            nowMilliseconds: Self.monotonicMilliseconds()
        )

        await withTaskGroup(of: Void.self) { group in
            while !Task.isCancelled, !(await dispatcher.shouldTerminate()) {
                let now = Self.monotonicMilliseconds()
                if await tracker.shouldShutdown(nowMilliseconds: now) {
                    await dispatcher.requestShutdown()
                    break
                }

                var pollDescriptor = pollfd(
                    fd: lease.descriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let pollResult = Darwin.poll(&pollDescriptor, 1, 100)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    await dispatcher.requestShutdown()
                    break
                }
                guard pollResult > 0, pollDescriptor.revents & Int16(POLLIN) != 0 else {
                    continue
                }

                let connection = Darwin.accept(lease.descriptor, nil, nil)
                guard connection >= 0 else {
                    if errno == EINTR || errno == EAGAIN { continue }
                    await dispatcher.requestShutdown()
                    break
                }
                do {
                    let connectionFlags = fcntl(connection, F_GETFL)
                    guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                          connectionFlags >= 0,
                          fcntl(connection, F_SETFL, connectionFlags | O_NONBLOCK) == 0 else {
                        throw ContainerizationHelperSocketError.socketConfigurationFailed
                    }
                    try authenticator.validate(connectionDescriptor: connection)
                } catch {
                    Darwin.close(connection)
                    continue
                }

                await tracker.begin(nowMilliseconds: Self.monotonicMilliseconds())
                group.addTask {
                    await Self.handleConnection(
                        descriptor: connection,
                        dispatcher: dispatcher,
                        timeoutMilliseconds: connectionReadTimeoutMilliseconds
                    )
                    Darwin.close(connection)
                    await tracker.end(nowMilliseconds: Self.monotonicMilliseconds())
                }
            }

            group.cancelAll()
            await dispatcher.requestShutdown()
        }

        try lease.closeAndRemove()
        try runtimeDirectory.cleanupDirectoryIfCreated()
    }

    private static func handleConnection(
        descriptor: Int32,
        dispatcher: ContainerizationHelperDispatcher,
        timeoutMilliseconds: Int64
    ) async {
        do {
            let frame = try readFrame(
                descriptor: descriptor,
                timeoutMilliseconds: timeoutMilliseconds
            )
            let response = try await dispatcher.dispatch(
                frame: frame,
                nowUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            try writeAll(
                descriptor: descriptor,
                data: response,
                deadlineMilliseconds: monotonicMilliseconds() + timeoutMilliseconds
            )
        } catch {
            return
        }
    }

    private static func readFrame(descriptor: Int32, timeoutMilliseconds: Int64) throws -> Data {
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        let header = try readExact(
            descriptor: descriptor,
            byteCount: ContainerizationHelperProtocolV1.frameHeaderBytes,
            deadlineMilliseconds: deadline
        )
        let payloadLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard payloadLength > 0 else {
            throw ContainerizationHelperProtocolError.zeroLengthFrame
        }
        guard payloadLength <= UInt32(ContainerizationHelperProtocolV1.maximumPayloadBytes) else {
            throw ContainerizationHelperProtocolError.frameTooLarge
        }
        let payload = try readExact(
            descriptor: descriptor,
            byteCount: Int(payloadLength),
            deadlineMilliseconds: deadline
        )
        return header + payload
    }

    private static func readExact(
        descriptor: Int32,
        byteCount: Int,
        deadlineMilliseconds: Int64
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(byteCount)
        var buffer = [UInt8](repeating: 0, count: min(byteCount, 64 * 1_024))
        while result.count < byteCount {
            if Task<Never, Never>.isCancelled {
                throw CancellationError()
            }
            guard monotonicMilliseconds() < deadlineMilliseconds else {
                throw ContainerizationHelperProtocolError.expiredDeadline
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollDescriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ContainerizationHelperProtocolError.truncatedFrame
            }
            guard ready > 0 else { continue }
            let requested = min(buffer.count, byteCount - result.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count > 0 else {
                throw ContainerizationHelperProtocolError.truncatedFrame
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    private static func writeAll(
        descriptor: Int32,
        data: Data,
        deadlineMilliseconds: Int64
    ) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                if Task<Never, Never>.isCancelled {
                    throw CancellationError()
                }
                guard monotonicMilliseconds() < deadlineMilliseconds else {
                    throw ContainerizationHelperProtocolError.expiredDeadline
                }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&pollDescriptor, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ContainerizationHelperProtocolError.truncatedFrame
                }
                guard ready > 0 else { continue }
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else {
                    throw ContainerizationHelperProtocolError.truncatedFrame
                }
                offset += count
            }
        }
    }

    private static func monotonicMilliseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000 + Int64(time.tv_nsec) / 1_000_000
    }
}
