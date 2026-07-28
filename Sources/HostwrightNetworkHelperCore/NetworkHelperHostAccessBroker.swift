import CryptoKit
import Darwin
import Foundation
import HostwrightNetworking

final class NetworkHelperHostAccessBroker: @unchecked Sendable {
    private struct Group {
        let identity: NetworkHelperDNSIdentity
        let bindings: [ProjectDNSHostAccessBinding]
        let sha256: String
        let listeners: [NetworkHelperHostAccessListener]
    }

    private let lock = NSLock()
    private var groups: [String: Group] = [:]

    func apply(
        identity: NetworkHelperDNSIdentity,
        bindings: [ProjectDNSHostAccessBinding]
    ) throws -> String? {
        let identity = try identity.validated()
        let bindings =
            try NetworkHelperHostAccessValidation.validated(bindings)
        guard !bindings.isEmpty else {
            remove(identity: identity)
            return nil
        }
        for binding in bindings {
            guard NetworkHelperHostAccessValidation.isActiveLocalAddress(
                binding.listenAddress
            ) else {
                throw NetworkHelperError.bindingUnavailable
            }
            if binding.addressClass == .interface {
                guard NetworkHelperHostAccessValidation
                    .isActiveLocalAddress(binding.targetAddress) else {
                    throw NetworkHelperError.bindingUnavailable
                }
            }
        }
        let data = try NetworkHelperCanonicalJSON.encode(bindings)
        let digest = Self.sha256(data)
        let key = Self.groupKey(identity)

        lock.lock()
        defer { lock.unlock() }
        if let existing = groups[key],
           existing.identity == identity,
           existing.sha256 == digest {
            return digest
        }
        let requestedKeys = Set(bindings.map(Self.listenerKey))
        let occupied = Set(
            groups
                .filter { $0.key != key }
                .flatMap { $0.value.bindings.map(Self.listenerKey) }
        )
        guard requestedKeys.isDisjoint(with: occupied) else {
            throw NetworkHelperError.bindingUnavailable
        }

        let previous = groups.removeValue(forKey: key)
        previous?.listeners.forEach { $0.stop() }
        do {
            let listeners = try bindings.map {
                try NetworkHelperHostAccessListener(binding: $0)
            }
            listeners.forEach { $0.start() }
            groups[key] = Group(
                identity: identity,
                bindings: bindings,
                sha256: digest,
                listeners: listeners
            )
            return digest
        } catch {
            if let previous {
                let restored = try? previous.bindings.map {
                    try NetworkHelperHostAccessListener(binding: $0)
                }
                restored?.forEach { $0.start() }
                if let restored {
                    groups[key] = Group(
                        identity: previous.identity,
                        bindings: previous.bindings,
                        sha256: previous.sha256,
                        listeners: restored
                    )
                }
            }
            throw NetworkHelperError.bindingUnavailable
        }
    }

    func remove(identity: NetworkHelperDNSIdentity) {
        let key = Self.groupKey(identity)
        lock.lock()
        let group = groups.removeValue(forKey: key)
        lock.unlock()
        group?.listeners.forEach { $0.stop() }
    }

    func sha256(identity: NetworkHelperDNSIdentity) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let group = groups[Self.groupKey(identity)]
        guard group?.identity == identity else { return nil }
        return group?.sha256
    }

    var hasActiveBindings: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !groups.isEmpty
    }

    private static func groupKey(
        _ identity: NetworkHelperDNSIdentity
    ) -> String {
        "\(identity.projectUUID)/\(identity.dnsUUID)"
    }

    private static func listenerKey(
        _ binding: ProjectDNSHostAccessBinding
    ) -> String {
        [
            binding.protocolName.rawValue,
            binding.listenAddress,
            String(binding.port)
        ].joined(separator: "\u{1f}")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class NetworkHelperHostAccessListener:
    @unchecked Sendable
{
    private static let maximumTCPConnections = 128
    private static let maximumChunkBytes = 64 * 1_024
    private static let connectTimeoutMilliseconds: Int64 = 5_000
    private static let idleTimeoutMilliseconds: Int64 = 30_000

    let binding: ProjectDNSHostAccessBinding
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private var running = false
    private var activeConnections = 0

    init(binding: ProjectDNSHostAccessBinding) throws {
        self.binding = binding
        queue = DispatchQueue(
            label:
                "dev.hostwright.host-access.\(binding.protocolName.rawValue).\(binding.port)",
            qos: .userInitiated
        )
        let socketType = binding.protocolName == .tcp
            ? SOCK_STREAM
            : SOCK_DGRAM
        descriptor = Darwin.socket(AF_INET, socketType, 0)
        guard descriptor >= 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        var succeeded = false
        defer {
            if !succeeded {
                Darwin.close(descriptor)
            }
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        #if os(macOS)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        #endif
        var address = try Self.socketAddress(
            binding.listenAddress,
            port: binding.port
        )
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        if binding.protocolName == .tcp {
            guard Darwin.listen(descriptor, 128) == 0 else {
                throw NetworkHelperError.bindingUnavailable
            }
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(
                descriptor,
                F_SETFL,
                flags | O_NONBLOCK
              ) == 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        succeeded = true
    }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [self] in
            switch binding.protocolName {
            case .tcp:
                runTCP()
            case .udp:
                runUDP()
            }
            stopped.signal()
        }
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        lock.unlock()
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = stopped.wait(timeout: .now() + 2)
        Darwin.close(descriptor)
    }

    private func runTCP() {
        while isRunning {
            guard pollReadable(descriptor, milliseconds: 100) else {
                continue
            }
            var peer = sockaddr_in()
            var peerLength = socklen_t(
                MemoryLayout<sockaddr_in>.size
            )
            let client = withUnsafeMutablePointer(to: &peer) {
                pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.accept(descriptor, $0, &peerLength)
                }
            }
            if client < 0,
               errno == EAGAIN || errno == EWOULDBLOCK
                    || errno == EINTR {
                continue
            }
            guard client >= 0 else { continue }
            guard sourceIsAllowed(peer),
                  reserveConnection() else {
                Darwin.close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                [self] in
                defer {
                    Darwin.close(client)
                    releaseConnection()
                }
                guard configureConnectedSocket(client),
                      let target = try? connectTarget(
                        socketType: SOCK_STREAM
                      ) else {
                    return
                }
                defer { Darwin.close(target) }
                bridgeTCP(client, target)
            }
        }
    }

    private func runUDP() {
        var buffer = [UInt8](
            repeating: 0,
            count: Self.maximumChunkBytes
        )
        while isRunning {
            guard pollReadable(descriptor, milliseconds: 100) else {
                continue
            }
            var peer = sockaddr_in()
            var peerLength = socklen_t(
                MemoryLayout<sockaddr_in>.size
            )
            let count = withUnsafeMutablePointer(to: &peer) {
                peerPointer in
                peerPointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { peerAddress in
                    Darwin.recvfrom(
                        descriptor,
                        &buffer,
                        buffer.count,
                        0,
                        peerAddress,
                        &peerLength
                    )
                }
            }
            if count < 0,
               errno == EAGAIN || errno == EWOULDBLOCK
                    || errno == EINTR {
                continue
            }
            guard count > 0, sourceIsAllowed(peer) else {
                continue
            }
            forwardUDP(
                Data(buffer[0..<count]),
                peer: peer,
                peerLength: peerLength
            )
        }
    }

    private func bridgeTCP(_ first: Int32, _ second: Int32) {
        var firstOpen = true
        var secondOpen = true
        var lastActivity = Self.monotonicMilliseconds()
        while isRunning, firstOpen || secondOpen {
            if Self.monotonicMilliseconds() - lastActivity
                >= Self.idleTimeoutMilliseconds {
                return
            }
            var descriptors = [
                pollfd(
                    fd: first,
                    events: firstOpen ? Int16(POLLIN) : 0,
                    revents: 0
                ),
                pollfd(
                    fd: second,
                    events: secondOpen ? Int16(POLLIN) : 0,
                    revents: 0
                )
            ]
            let ready = Darwin.poll(&descriptors, 2, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { return }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                if transfer(from: first, to: second) {
                    lastActivity = Self.monotonicMilliseconds()
                } else {
                    firstOpen = false
                    _ = Darwin.shutdown(second, SHUT_WR)
                }
            }
            if descriptors[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                if transfer(from: second, to: first) {
                    lastActivity = Self.monotonicMilliseconds()
                } else {
                    secondOpen = false
                    _ = Darwin.shutdown(first, SHUT_WR)
                }
            }
            if descriptors.contains(where: {
                $0.revents & Int16(POLLERR | POLLNVAL) != 0
            }) {
                return
            }
        }
    }

    private func transfer(from source: Int32, to destination: Int32)
        -> Bool
    {
        var buffer = [UInt8](
            repeating: 0,
            count: Self.maximumChunkBytes
        )
        let count = Darwin.read(source, &buffer, buffer.count)
        if count < 0, errno == EINTR || errno == EAGAIN {
            return true
        }
        guard count > 0 else { return false }
        return writeAll(
            destination,
            data: Data(buffer[0..<count]),
            timeoutMilliseconds: 5_000
        )
    }

    private func forwardUDP(
        _ payload: Data,
        peer: sockaddr_in,
        peerLength: socklen_t
    ) {
        guard let target = try? connectTarget(
            socketType: SOCK_DGRAM
        ) else {
            return
        }
        defer { Darwin.close(target) }
        guard writeAll(
            target,
            data: payload,
            timeoutMilliseconds: 5_000
        ),
        pollReadable(target, milliseconds: 5_000) else {
            return
        }
        var response = [UInt8](
            repeating: 0,
            count: Self.maximumChunkBytes
        )
        let count = Darwin.recv(
            target,
            &response,
            response.count,
            0
        )
        guard count > 0 else { return }
        var mutablePeer = peer
        _ = withUnsafePointer(to: &mutablePeer) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.sendto(
                    descriptor,
                    response,
                    count,
                    0,
                    $0,
                    peerLength
                )
            }
        }
    }

    private func connectTarget(socketType: Int32) throws -> Int32 {
        let target = Darwin.socket(AF_INET, socketType, 0)
        guard target >= 0 else {
            throw NetworkHelperError.bindingUnavailable
        }
        var succeeded = false
        defer {
            if !succeeded { Darwin.close(target) }
        }
        guard configureConnectedSocket(target) else {
            throw NetworkHelperError.bindingUnavailable
        }
        var address = try Self.socketAddress(
            binding.targetAddress,
            port: binding.port
        )
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.connect(
                    target,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                throw NetworkHelperError.bindingUnavailable
            }
            var pollDescriptor = pollfd(
                fd: target,
                events: Int16(POLLOUT),
                revents: 0
            )
            let ready = Darwin.poll(
                &pollDescriptor,
                1,
                Int32(Self.connectTimeoutMilliseconds)
            )
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(
                MemoryLayout<Int32>.size
            )
            guard ready > 0,
                  getsockopt(
                    target,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &socketErrorLength
                  ) == 0,
                  socketError == 0 else {
                throw NetworkHelperError.bindingUnavailable
            }
        }
        succeeded = true
        return target
    }

    private func configureConnectedSocket(_ socket: Int32) -> Bool {
        let flags = fcntl(socket, F_GETFL)
        guard flags >= 0,
              fcntl(socket, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        #if os(macOS)
        var enabled: Int32 = 1
        guard setsockopt(
            socket,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return false
        }
        #endif
        return true
    }

    private func sourceIsAllowed(_ peer: sockaddr_in) -> Bool {
        var address = peer.sin_addr
        var buffer = [CChar](
            repeating: 0,
            count: Int(INET_ADDRSTRLEN)
        )
        guard inet_ntop(
            AF_INET,
            &address,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            return false
        }
        let value = buffer.withUnsafeBufferPointer { bytes in
            String(
                decoding: bytes
                    .prefix { $0 != 0 }
                    .map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        return NetworkHelperHostAccessValidation.ipv4(
            value,
            belongsTo: binding.clientCIDR
        )
    }

    private func reserveConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < Self.maximumTCPConnections else {
            return false
        }
        activeConnections += 1
        return true
    }

    private func releaseConnection() {
        lock.lock()
        activeConnections -= 1
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func pollReadable(
        _ socket: Int32,
        milliseconds: Int32
    ) -> Bool {
        var descriptor = pollfd(
            fd: socket,
            events: Int16(POLLIN),
            revents: 0
        )
        let result = Darwin.poll(&descriptor, 1, milliseconds)
        return result > 0
            && descriptor.revents & Int16(POLLIN | POLLHUP) != 0
    }

    private func writeAll(
        _ socket: Int32,
        data: Data,
        timeoutMilliseconds: Int64
    ) -> Bool {
        let deadline = Self.monotonicMilliseconds()
            + timeoutMilliseconds
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard Self.monotonicMilliseconds() < deadline else {
                    return false
                }
                var descriptor = pollfd(
                    fd: socket,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let ready = Darwin.poll(&descriptor, 1, 100)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { return false }
                guard ready > 0 else { continue }
                let count = Darwin.write(
                    socket,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0,
                   errno == EINTR || errno == EAGAIN
                    || errno == EWOULDBLOCK {
                    continue
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func socketAddress(
        _ value: String,
        port: Int
    ) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(
            MemoryLayout<sockaddr_in>.size
        )
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard value.withCString({
            inet_pton(AF_INET, $0, &address.sin_addr)
        }) == 1 else {
            throw NetworkHelperError.invalidRequest
        }
        return address
    }

    private static func monotonicMilliseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000
            + Int64(time.tv_nsec) / 1_000_000
    }
}
