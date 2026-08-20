import Darwin
import Foundation

public enum DockerSocketError: Error, Equatable, Sendable {
    case unsafePath
    case socketAlreadyExists
    case socketCreationFailed
    case socketBindFailed
    case socketListenFailed
    case socketIdentityChanged
    case acceptFailed
    case acceptTimedOut
    case peerMismatch
    case ioFailure
    case cancelled
}

public struct DockerSocketIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public final class DockerUnixSocketListener: @unchecked Sendable {
    public typealias PeerUserIDReader = @Sendable (Int32) -> UInt32?

    public let path: String
    public let identity: DockerSocketIdentity
    public let rootIdentity: DockerSocketIdentity

    private let descriptor: Int32
    private let peerUserIDReader: PeerUserIDReader
    private let lock = NSLock()
    private var closed = false

    public init(
        socketPath: String,
        recoverStaleSocket: Bool = false,
        peerUserIDReader: @escaping PeerUserIDReader = DockerUnixSocketListener.currentPeerUserID
    ) throws {
        guard Self.isSafeSocketPath(socketPath) else {
            throw DockerSocketError.unsafePath
        }
        let url = URL(fileURLWithPath: socketPath)
        let parent = url.deletingLastPathComponent().path
        try Self.ensurePrivateDirectory(parent)

        var root = stat()
        guard lstat(parent, &root) == 0,
              Self.isPrivateDirectory(root),
              root.st_uid == geteuid() else {
            throw DockerSocketError.unsafePath
        }
        let rootIdentity = DockerSocketIdentity(
            device: UInt64(root.st_dev),
            inode: UInt64(root.st_ino)
        )

        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard recoverStaleSocket else {
                throw DockerSocketError.socketAlreadyExists
            }
            try Self.removeVerifiedStaleSocket(path: socketPath, status: existing)
        } else if errno != ENOENT {
            throw DockerSocketError.unsafePath
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DockerSocketError.socketCreationFailed }
        var createdIdentity: DockerSocketIdentity?
        do {
            var address = try Self.address(socketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, Self.addressLength(socketPath))
                }
            }
            guard bound == 0, chmod(socketPath, 0o600) == 0 else {
                throw DockerSocketError.socketBindFailed
            }
            var socket = stat()
            var currentRoot = stat()
            guard lstat(socketPath, &socket) == 0,
                  Self.isSocket(socket),
                  (socket.st_mode & 0o7777) == 0o600,
                  socket.st_uid == geteuid(),
                  lstat(parent, &currentRoot) == 0,
                  DockerSocketIdentity(
                    device: UInt64(currentRoot.st_dev),
                    inode: UInt64(currentRoot.st_ino)
                  ) == rootIdentity else {
                throw DockerSocketError.socketIdentityChanged
            }
            let identity = DockerSocketIdentity(
                device: UInt64(socket.st_dev),
                inode: UInt64(socket.st_ino)
            )
            createdIdentity = identity
            guard Darwin.listen(descriptor, 128) == 0 else {
                throw DockerSocketError.socketListenFailed
            }
            self.path = socketPath
            self.identity = identity
            self.rootIdentity = rootIdentity
            self.descriptor = descriptor
            self.peerUserIDReader = peerUserIDReader
        } catch {
            _ = Darwin.close(descriptor)
            if let createdIdentity {
                Self.removeOwnedSocket(path: socketPath, identity: createdIdentity)
            }
            throw error
        }
    }

    deinit { closeAndRemoveOwnedSocket() }

    public func accept(timeoutMilliseconds: Int) throws -> Int32 {
        guard timeoutMilliseconds > 0 else { throw DockerSocketError.acceptFailed }
        try validatePathIdentity()
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(
            &entry,
            1,
            Int32(min(timeoutMilliseconds, Int(Int32.max)))
        )
        if result == 0 { throw DockerSocketError.acceptTimedOut }
        guard result > 0, entry.revents & Int16(POLLIN) != 0 else {
            throw DockerSocketError.acceptFailed
        }
        let accepted = Darwin.accept(descriptor, nil, nil)
        guard accepted >= 0 else { throw DockerSocketError.acceptFailed }
        do {
            try validatePeer(accepted)
            try configureConnectedSocket(accepted)
            return accepted
        } catch {
            _ = Darwin.close(accepted)
            throw error
        }
    }

    public func closeAndRemoveOwnedSocket() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(descriptor)
        Self.removeOwnedSocket(path: path, identity: identity)
    }

    private func validatePathIdentity() throws {
        var root = stat()
        var socket = stat()
        guard lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &root) == 0,
              lstat(path, &socket) == 0,
              DockerSocketIdentity(
                device: UInt64(root.st_dev), inode: UInt64(root.st_ino)
              ) == rootIdentity,
              DockerSocketIdentity(
                device: UInt64(socket.st_dev), inode: UInt64(socket.st_ino)
              ) == identity,
              Self.isPrivateDirectory(root),
              Self.isSocket(socket),
              (socket.st_mode & 0o7777) == 0o600,
              socket.st_uid == geteuid() else {
            throw DockerSocketError.socketIdentityChanged
        }
    }

    private func validatePeer(_ descriptor: Int32) throws {
        guard peerUserIDReader(descriptor) == UInt32(geteuid()) else {
            throw DockerSocketError.peerMismatch
        }
    }

    public static func currentPeerUserID(_ descriptor: Int32) -> UInt32? {
        var uid = uid_t.max
        var gid = gid_t.max
        guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        return UInt32(uid)
    }

    private func configureConnectedSocket(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw DockerSocketError.ioFailure }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DockerSocketError.ioFailure
        }
    }

    private static func ensurePrivateDirectory(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = "/"
        for component in components {
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(String(component), isDirectory: true)
                .path
            var status = stat()
            if lstat(current, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw DockerSocketError.unsafePath
                }
                if current == path {
                    guard isPrivateDirectory(status), status.st_uid == geteuid() else {
                        throw DockerSocketError.unsafePath
                    }
                }
                continue
            }
            guard errno == ENOENT, mkdir(current, 0o700) == 0 else {
                throw DockerSocketError.unsafePath
            }
            guard chmod(current, 0o700) == 0 else { throw DockerSocketError.unsafePath }
        }
    }

    private static func removeVerifiedStaleSocket(path: String, status: stat) throws {
        guard isSocket(status),
              (status.st_mode & 0o7777) == 0o600,
              status.st_uid == geteuid() else {
            throw DockerSocketError.unsafePath
        }
        let pinned = DockerSocketIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw DockerSocketError.socketCreationFailed }
        defer { _ = Darwin.close(probe) }
        var address = try Self.address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, Self.addressLength(path))
            }
        }
        if result == 0 { throw DockerSocketError.socketAlreadyExists }
        guard errno == ECONNREFUSED || errno == ENOENT else {
            throw DockerSocketError.socketAlreadyExists
        }
        if errno == ENOENT { return }
        var current = stat()
        guard lstat(path, &current) == 0,
              isSocket(current),
              (current.st_mode & 0o7777) == 0o600,
              current.st_uid == geteuid(),
              DockerSocketIdentity(
                device: UInt64(current.st_dev), inode: UInt64(current.st_ino)
              ) == pinned,
              unlink(path) == 0 else {
            throw DockerSocketError.socketIdentityChanged
        }
    }

    private static func removeOwnedSocket(path: String, identity: DockerSocketIdentity) {
        var status = stat()
        guard lstat(path, &status) == 0,
              isSocket(status),
              DockerSocketIdentity(
                device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
              ) == identity else { return }
        _ = unlink(path)
    }

    private static func isSafeSocketPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return path.hasPrefix("/")
            && path.utf8.count < 100
            && !path.contains("\0")
            && !path.contains("//")
            && !path.hasSuffix("/")
            && !components.isEmpty
            && !components.contains(".")
            && !components.contains("..")
    }

    private static func isPrivateDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR && (status.st_mode & 0o7777) == 0o700
    }

    private static func isSocket(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty,
              bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw DockerSocketError.unsafePath
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private static func addressLength(_ path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }
}

public final class DockerProxyDaemon: @unchecked Sendable {
    public let server: DockerProxyServer
    public let listener: DockerUnixSocketListener

    public init(
        server: DockerProxyServer,
        listener: DockerUnixSocketListener
    ) {
        self.server = server
        self.listener = listener
    }

    public func run(
        isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        defer { listener.closeAndRemoveOwnedSocket() }
        while !isCancelled() {
            do {
                let descriptor = try listener.accept(timeoutMilliseconds: 250)
                try serve(descriptor: descriptor, isCancelled: isCancelled)
            } catch DockerSocketError.acceptTimedOut {
                continue
            } catch DockerSocketError.peerMismatch {
                continue
            } catch DockerSocketError.cancelled {
                continue
            } catch DockerSocketError.socketIdentityChanged {
                throw DockerSocketError.socketIdentityChanged
            }
        }
    }

    public func serve(
        descriptor: Int32,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        defer {
            _ = shutdown(descriptor, SHUT_RDWR)
            _ = close(descriptor)
        }
        let request: DockerHTTPRequest
        do {
            request = try readRequest(descriptor: descriptor, isCancelled: isCancelled)
        } catch let error as DockerHTTPProtocolError {
            let responseError: DockerHTTPError
            switch error {
            case .cancelled: responseError = .cancelled
            case .unsupportedUpgrade: responseError = .unsupportedUpgrade
            case .bodyTooLarge: responseError = .badRequest
            default: responseError = .badRequest
            }
            try writeAll(
                DockerHTTPCodec.encodeResponse(
                    DockerHTTPCodec.errorResponse(responseError)
                ),
                descriptor: descriptor,
                isCancelled: isCancelled
            )
            return
        }
        let handled = server.handle(request, isCancelled: isCancelled)
        // The foreground daemon owns one request per accepted connection. Do
        // not advertise keep-alive when the exact connection is about to close.
        let response = DockerHTTPResponse(
            statusCode: handled.statusCode,
            reasonPhrase: handled.reasonPhrase,
            headers: handled.headers,
            body: handled.body,
            closeConnection: true
        )
        let encoded = try DockerHTTPCodec.encodeResponse(
            response,
            suppressBody: request.method == .head,
            isCancelled: isCancelled
        )
        try writeAll(encoded, descriptor: descriptor, isCancelled: isCancelled)
    }

    private func readRequest(
        descriptor: Int32,
        isCancelled: @Sendable () -> Bool
    ) throws -> DockerHTTPRequest {
        var data = Data()
        let maximum = DockerHTTPCodec.maximumHeaderBytes
            + DockerHTTPCodec.maximumBodyBytes
            + DockerHTTPCodec.maximumRequestLineBytes
        while true {
            if isCancelled() { throw DockerHTTPProtocolError.cancelled }
            do {
                return try DockerHTTPCodec.parseRequest(data, isCancelled: isCancelled)
            } catch DockerHTTPProtocolError.incompleteRequest {
                // Read the next bounded segment below.
            }
            guard data.count < maximum else { throw DockerHTTPProtocolError.bodyTooLarge }
            try wait(descriptor: descriptor, events: Int16(POLLIN), isCancelled: isCancelled)
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { throw DockerHTTPProtocolError.incompleteRequest }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw DockerSocketError.ioFailure
        }
    }

    private func writeAll(
        _ data: Data,
        descriptor: Int32,
        isCancelled: @Sendable () -> Bool
    ) throws {
        var offset = 0
        while offset < data.count {
            if isCancelled() { throw DockerSocketError.cancelled }
            try wait(descriptor: descriptor, events: Int16(POLLOUT), isCancelled: isCancelled)
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 { offset += count; continue }
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            }
            throw DockerSocketError.ioFailure
        }
    }

    private func wait(
        descriptor: Int32,
        events: Int16,
        isCancelled: @Sendable () -> Bool
    ) throws {
        while true {
            if isCancelled() { throw DockerSocketError.cancelled }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&entry, 1, 100)
            if result > 0 {
                guard entry.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                    throw DockerSocketError.ioFailure
                }
                return
            }
            if result == 0 { continue }
            if errno == EINTR { continue }
            throw DockerSocketError.ioFailure
        }
    }
}
