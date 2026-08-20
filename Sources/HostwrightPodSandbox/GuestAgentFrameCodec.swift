import Darwin
import Foundation

public enum GuestAgentFramePayloadKind: Sendable {
    case request
    case response
    case frame
}

public struct GuestAgentDeadline: Sendable {
    private let endUptimeNanoseconds: UInt64
    private let monotonicNow: @Sendable () -> UInt64

    public init(
        timeoutMilliseconds: Int,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws {
        guard (1...GuestAgentProtocolV1.maximumDeadlineMilliseconds).contains(timeoutMilliseconds) else {
            throw GuestAgentProtocolError.invalidDeadline
        }
        let now = monotonicNow()
        let duration = UInt64(timeoutMilliseconds) * 1_000_000
        guard UInt64.max - now >= duration else {
            throw GuestAgentProtocolError.invalidDeadline
        }
        self.endUptimeNanoseconds = now + duration
        self.monotonicNow = monotonicNow
    }

    public func assertActive() throws {
        guard monotonicNow() < endUptimeNanoseconds else {
            throw GuestAgentProtocolError.deadlineExceeded
        }
    }

    fileprivate func remainingPollMilliseconds() throws -> Int32 {
        let now = monotonicNow()
        guard now < endUptimeNanoseconds else {
            throw GuestAgentProtocolError.deadlineExceeded
        }
        let remaining = endUptimeNanoseconds - now
        let rounded = (remaining + 999_999) / 1_000_000
        return Int32(min(rounded, UInt64(Int32.max)))
    }
}

public final class GuestAgentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

public struct GuestAgentCreditWindow: Equatable, Sendable {
    public private(set) var available: Int

    public init(initialCredit: Int = 0) throws {
        guard (0...GuestAgentProtocolV1.maximumCredit).contains(initialCredit) else {
            throw GuestAgentProtocolError.invalidEnvelope("credit")
        }
        self.available = initialCredit
    }

    public mutating func grant(_ credit: Int) throws {
        guard (0...GuestAgentProtocolV1.maximumCredit).contains(credit) else {
            throw GuestAgentProtocolError.invalidEnvelope("credit")
        }
        guard available + credit <= GuestAgentProtocolV1.maximumCredit else {
            throw GuestAgentProtocolError.invalidEnvelope("credit window")
        }
        available += credit
    }

    public mutating func consume() throws {
        guard available > 0 else {
            throw GuestAgentProtocolError.creditExhausted
        }
        available -= 1
    }
}

public final class GuestAgentCreditLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [String: GuestAgentCreditWindow] = [:]

    public init() {}

    @discardableResult
    public func grant(streamID: String, credit: Int) throws -> Int {
        try validateStreamID(streamID)
        return try lock.withLock {
            var window: GuestAgentCreditWindow
            if let existing = windows[streamID] {
                window = existing
            } else {
                window = try GuestAgentCreditWindow()
            }
            try window.grant(credit)
            windows[streamID] = window
            return window.available
        }
    }

    @discardableResult
    public func consume(streamID: String) throws -> Int {
        try validateStreamID(streamID)
        return try lock.withLock {
            guard var window = windows[streamID] else {
                throw GuestAgentProtocolError.creditExhausted
            }
            try window.consume()
            windows[streamID] = window
            return window.available
        }
    }

    public func available(streamID: String) throws -> Int {
        try validateStreamID(streamID)
        return lock.withLock { windows[streamID]?.available ?? 0 }
    }

    public func clear(streamID: String) throws {
        try validateStreamID(streamID)
        _ = lock.withLock { windows.removeValue(forKey: streamID) }
    }

    private func validateStreamID(_ streamID: String) throws {
        try PodSandboxValidation.safeIdentifier(
            streamID,
            maximumLength: GuestAgentProtocolV1.maximumRequestIDBytes,
            field: "streamID"
        )
    }
}

public enum GuestAgentFrameCodec {
    public static let prefixBytes = GuestAgentProtocolV1.lengthPrefixBytes
    public static let maximumRequestBytes = GuestAgentProtocolV1.maximumRequestBytes
    public static let maximumResponseOrFrameBytes = GuestAgentProtocolV1.maximumResponseOrFrameBytes

    public static func configureConnectedSocket(descriptor: Int32) throws {
        guard descriptor >= 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
        var noSigPipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
    }

    public static func encodedFrame(
        payload: Data,
        kind: GuestAgentFramePayloadKind
    ) throws -> Data {
        guard payload.count > 0, payload.count <= Int(UInt32.max) else {
            throw GuestAgentProtocolError.invalidFrameLength
        }
        let maximum = maximumBytes(for: kind)
        guard payload.count <= maximum else {
            throw GuestAgentProtocolError.frameTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func write(
        _ payload: Data,
        kind: GuestAgentFramePayloadKind,
        descriptor: Int32,
        deadline: GuestAgentDeadline,
        cancellation: GuestAgentCancellation? = nil
    ) throws {
        let frame = try encodedFrame(payload: payload, kind: kind)
        try writeAll(
            frame,
            descriptor: descriptor,
            deadline: deadline,
            cancellation: cancellation
        )
    }

    public static func read(
        kind: GuestAgentFramePayloadKind,
        descriptor: Int32,
        deadline: GuestAgentDeadline,
        cancellation: GuestAgentCancellation? = nil
    ) throws -> Data {
        let prefix = try readExactly(
            prefixBytes,
            descriptor: descriptor,
            deadline: deadline,
            cancellation: cancellation
        )
        let networkLength = prefix.withUnsafeBytes { source -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: source)
            }
            return value
        }
        let length = UInt32(bigEndian: networkLength)
        guard length > 0 else {
            throw GuestAgentProtocolError.invalidFrameLength
        }
        guard length <= UInt32(maximumBytes(for: kind)) else {
            throw GuestAgentProtocolError.frameTooLarge
        }
        return try readExactly(
            Int(length),
            descriptor: descriptor,
            deadline: deadline,
            cancellation: cancellation
        )
    }

    private static func maximumBytes(for kind: GuestAgentFramePayloadKind) -> Int {
        switch kind {
        case .request: maximumRequestBytes
        case .response, .frame: maximumResponseOrFrameBytes
        }
    }

    private static func readExactly(
        _ length: Int,
        descriptor: Int32,
        deadline: GuestAgentDeadline,
        cancellation: GuestAgentCancellation?
    ) throws -> Data {
        guard descriptor >= 0, length > 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
        var result = Data(count: length)
        var offset = 0
        try result.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else {
                throw GuestAgentProtocolError.transportFailure
            }
            while offset < length {
                try wait(
                    descriptor: descriptor,
                    events: Int16(POLLIN),
                    deadline: deadline,
                    cancellation: cancellation
                )
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    length - offset
                )
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    throw GuestAgentProtocolError.peerClosed
                } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else {
                    throw GuestAgentProtocolError.transportFailure
                }
            }
        }
        return result
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        deadline: GuestAgentDeadline,
        cancellation: GuestAgentCancellation?
    ) throws {
        guard descriptor >= 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
        try data.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else {
                throw GuestAgentProtocolError.transportFailure
            }
            var offset = 0
            while offset < source.count {
                try wait(
                    descriptor: descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    cancellation: cancellation
                )
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    source.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    throw GuestAgentProtocolError.writeClosed
                } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else if errno == EPIPE || errno == ECONNRESET || errno == ENOTCONN {
                    throw GuestAgentProtocolError.writeClosed
                } else {
                    throw GuestAgentProtocolError.transportFailure
                }
            }
        }
    }

    private static func wait(
        descriptor: Int32,
        events: Int16,
        deadline: GuestAgentDeadline,
        cancellation: GuestAgentCancellation?
    ) throws {
        guard descriptor >= 0 else {
            throw GuestAgentProtocolError.transportFailure
        }
        while true {
            if cancellation?.isCancelled == true {
                throw GuestAgentProtocolError.cancelled
            }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            var timeout = try deadline.remainingPollMilliseconds()
            if cancellation != nil {
                timeout = min(timeout, 50)
            }
            let result = Darwin.poll(&entry, 1, timeout)
            if result > 0 {
                guard entry.revents & Int16(POLLNVAL) == 0 else {
                    throw GuestAgentProtocolError.transportFailure
                }
                if entry.revents & events != 0 {
                    return
                }
                if entry.revents & Int16(POLLHUP | POLLERR) != 0 {
                    if events == Int16(POLLIN) && entry.revents & Int16(POLLIN) != 0 {
                        return
                    }
                    throw events == Int16(POLLOUT)
                        ? GuestAgentProtocolError.writeClosed
                        : GuestAgentProtocolError.peerClosed
                }
                continue
            }
            if result == 0 {
                try deadline.assertActive()
                continue
            }
            if errno == EINTR {
                continue
            }
            throw GuestAgentProtocolError.transportFailure
        }
    }
}
