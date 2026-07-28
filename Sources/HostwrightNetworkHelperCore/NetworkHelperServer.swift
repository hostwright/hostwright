import Darwin
import Foundation
import HostwrightNetworking
import HostwrightRuntime

struct NetworkHelperDispatcher: @unchecked Sendable {
    let store: NetworkHelperStateStore
    let hostAccessBroker: NetworkHelperHostAccessBroker

    init(
        store: NetworkHelperStateStore,
        hostAccessBroker: NetworkHelperHostAccessBroker =
            NetworkHelperHostAccessBroker()
    ) {
        self.store = store
        self.hostAccessBroker = hostAccessBroker
    }

    var hasActiveHostAccessBindings: Bool {
        hostAccessBroker.hasActiveBindings
    }

    func dispatch(frame: Data) throws -> Data {
        let request = try NetworkHelperCanonicalJSON.decodeFrame(
            NetworkHelperRequest.self,
            from: frame
        )
        do {
            _ = try request.validated()
            let status: NetworkHelperStatus
            switch request.operation {
            case .apply:
                let persisted = try store.apply(
                    identity: request.identity,
                    corefile: request.corefile!,
                    hostAccessBindings:
                        request.hostAccessBindings ?? [],
                    predecessorFencingToken:
                        request.predecessorFencingToken
                )
                status = try activatingStatus(
                    persisted,
                    identity: request.identity,
                    bindings: request.hostAccessBindings ?? []
                )
            case .status:
                let persisted = try store.status(
                    identity: request.identity
                )
                if persisted.disposition == .active {
                    let bindings = try store
                        .activeHostAccessConfigurations()
                        .first(where: {
                            $0.identity == request.identity
                        })?.bindings ?? []
                    status = try activatingStatus(
                        persisted,
                        identity: request.identity,
                        bindings: bindings
                    )
                } else {
                    status = withHostAccessActivity(
                        persisted,
                        active: false
                    )
                }
            case .remove:
                let removed = try store.remove(identity: request.identity)
                hostAccessBroker.remove(identity: request.identity)
                status = withHostAccessActivity(
                    removed,
                    active: false
                )
            }
            return try NetworkHelperCanonicalJSON.frame(
                NetworkHelperResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    status: status
                )
            )
        } catch let error as NetworkHelperError {
            return try NetworkHelperCanonicalJSON.frame(
                NetworkHelperResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    error: error.failure
                )
            )
        }
    }

    private func activatingStatus(
        _ persisted: NetworkHelperStatus,
        identity: NetworkHelperDNSIdentity,
        bindings: [ProjectDNSHostAccessBinding]
    ) throws -> NetworkHelperStatus {
        guard persisted.disposition == .active else {
            return withHostAccessActivity(
                persisted,
                active: false
            )
        }
        guard let expected = persisted.hostAccessSHA256 else {
            hostAccessBroker.remove(identity: identity)
            return withHostAccessActivity(
                persisted,
                active: true
            )
        }
        if hostAccessBroker.sha256(identity: identity) == expected {
            return withHostAccessActivity(
                persisted,
                active: true
            )
        }
        do {
            let applied = try hostAccessBroker.apply(
                identity: identity,
                bindings: bindings
            )
            return withHostAccessActivity(
                persisted,
                active: applied == expected
            )
        } catch NetworkHelperError.bindingUnavailable {
            return withHostAccessActivity(
                persisted,
                active: false
            )
        }
    }

    private func withHostAccessActivity(
        _ status: NetworkHelperStatus,
        active: Bool
    ) -> NetworkHelperStatus {
        NetworkHelperStatus(
            disposition: status.disposition,
            identity: status.identity,
            corefileSHA256: status.corefileSHA256,
            hostAccessSHA256: status.hostAccessSHA256,
            hostAccessActive: active,
            reason: status.reason
        )
    }
}

enum NetworkHelperConnectionHandler {
    static func handle(
        descriptor: Int32,
        dispatcher: NetworkHelperDispatcher,
        timeoutMilliseconds: Int64 = 5_000
    ) throws {
        precondition(timeoutMilliseconds > 0)
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        let header = try readExact(
            descriptor: descriptor,
            byteCount: ContainerizationHelperProtocolV1.frameHeaderBytes,
            deadlineMilliseconds: deadline
        )
        let payloadLength = header.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard payloadLength > 0,
              payloadLength <= UInt32(
                NetworkHelperProtocolV1.maximumFrameBytes
              ) else {
            throw NetworkHelperError.invalidFrame
        }
        let payload = try readExact(
            descriptor: descriptor,
            byteCount: Int(payloadLength),
            deadlineMilliseconds: deadline
        )
        let response = try dispatcher.dispatch(frame: header + payload)
        try writeAll(
            descriptor: descriptor,
            data: response,
            deadlineMilliseconds: deadline
        )
    }

    static func readFrame(
        descriptor: Int32,
        timeoutMilliseconds: Int64 = 5_000
    ) throws -> Data {
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        let header = try readExact(
            descriptor: descriptor,
            byteCount: ContainerizationHelperProtocolV1.frameHeaderBytes,
            deadlineMilliseconds: deadline
        )
        let payloadLength = header.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard payloadLength > 0,
              payloadLength <= UInt32(
                NetworkHelperProtocolV1.maximumFrameBytes
              ) else {
            throw NetworkHelperError.invalidFrame
        }
        return header + (try readExact(
            descriptor: descriptor,
            byteCount: Int(payloadLength),
            deadlineMilliseconds: deadline
        ))
    }

    private static func readExact(
        descriptor: Int32,
        byteCount: Int,
        deadlineMilliseconds: Int64
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(byteCount)
        var buffer = [UInt8](
            repeating: 0,
            count: min(max(byteCount, 1), 64 * 1_024)
        )
        while result.count < byteCount {
            guard monotonicMilliseconds() < deadlineMilliseconds else {
                throw NetworkHelperError.ioFailure
            }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let ready = Darwin.poll(&pollDescriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            guard ready > 0 else { continue }
            let requested = min(buffer.count, byteCount - result.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0, errno == EINTR || errno == EAGAIN
                || errno == EWOULDBLOCK {
                continue
            }
            guard count > 0 else {
                throw NetworkHelperError.invalidFrame
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
                guard monotonicMilliseconds() < deadlineMilliseconds else {
                    throw NetworkHelperError.ioFailure
                }
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let ready = Darwin.poll(&pollDescriptor, 1, 100)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else {
                    throw NetworkHelperError.ioFailure
                }
                guard ready > 0 else { continue }
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR || errno == EAGAIN
                    || errno == EWOULDBLOCK {
                    continue
                }
                guard count > 0 else {
                    throw NetworkHelperError.ioFailure
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

struct NetworkHelperUnixServer: Sendable {
    let runtimeDirectory: ContainerizationHelperRuntimeDirectory
    let dispatcher: NetworkHelperDispatcher
    let authenticator: NetworkHelperPeerAuthenticator
    let idleTimeoutMilliseconds: Int64

    init(
        runtimeDirectory: ContainerizationHelperRuntimeDirectory,
        dispatcher: NetworkHelperDispatcher,
        authenticator: NetworkHelperPeerAuthenticator,
        idleTimeoutMilliseconds: Int64 = 30_000
    ) {
        precondition(idleTimeoutMilliseconds > 0)
        self.runtimeDirectory = runtimeDirectory
        self.dispatcher = dispatcher
        self.authenticator = authenticator
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
    }

    func run() throws {
        let lease = try runtimeDirectory.makeListeningSocket()
        defer { try? lease.closeAndRemove() }
        var lastActivity = monotonicMilliseconds()

        while dispatcher.hasActiveHostAccessBindings
            || monotonicMilliseconds() - lastActivity
                < idleTimeoutMilliseconds {
            var pollDescriptor = pollfd(
                fd: lease.descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let ready = Darwin.poll(&pollDescriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            guard ready > 0,
                  pollDescriptor.revents & Int16(POLLIN) != 0 else {
                continue
            }

            let connection = Darwin.accept(lease.descriptor, nil, nil)
            if connection < 0, errno == EINTR || errno == EAGAIN {
                continue
            }
            guard connection >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            defer { Darwin.close(connection) }

            let flags = fcntl(connection, F_GETFL)
            guard flags >= 0,
                  fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(connection, F_SETFL, flags | O_NONBLOCK) == 0 else {
                continue
            }
            do {
                try authenticator.validate(
                    connectionDescriptor: connection
                )
                try NetworkHelperConnectionHandler.handle(
                    descriptor: connection,
                    dispatcher: dispatcher
                )
                lastActivity = monotonicMilliseconds()
            } catch {
                continue
            }
        }
    }

    private func monotonicMilliseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000
            + Int64(time.tv_nsec) / 1_000_000
    }
}
