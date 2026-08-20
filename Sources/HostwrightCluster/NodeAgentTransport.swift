import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore

public enum ClusterNodeAgentTransportError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case invalidResponse(String)
    case authorizationFailed(ClusterSessionError)
    case requestTooLarge
    case responseTooLarge
    case socketFailed(Int32)
    case connectionFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case peerClosed
    case processLaunchFailed
    case processExited(Int32)
    case timedOut
    case cancelled
    case responseRequestMismatch
    case remoteRejected(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let field): "Node-agent transport configuration is invalid: \(field)."
        case .invalidRequest(let field): "Node-agent request is invalid: \(field)."
        case .invalidResponse(let field): "Node-agent response is invalid: \(field)."
        case .authorizationFailed: "Node-agent handoff authorization was rejected."
        case .requestTooLarge: "Node-agent request exceeds the local transport bound."
        case .responseTooLarge: "Node-agent response exceeds the local transport bound."
        case .socketFailed: "Node-agent local socket creation failed."
        case .connectionFailed: "Node-agent local socket connection failed."
        case .writeFailed: "Node-agent local socket write failed."
        case .readFailed: "Node-agent local socket read failed."
        case .peerClosed: "Node-agent local socket peer closed the connection."
        case .processLaunchFailed: "Node-agent subprocess could not be launched."
        case .processExited(let status): "Node-agent subprocess exited before completing the request: \(status)."
        case .timedOut: "Node-agent local transport timed out."
        case .cancelled: "Node-agent local transport was cancelled."
        case .responseRequestMismatch: "Node-agent response does not match the request."
        case .remoteRejected(let code): "Node-agent rejected the request: \(code)."
        }
    }
}

public enum ClusterNodeAgentTransportContract {
    public static let apiVersion = 1
    public static let protocolLabel = "hostwright-cluster-node-agent-v1"
    public static let socketArgument = "--socket-path"
    public static let maximumOperationBytes = 128
    public static let maximumPayloadBytes = 45 * 1_024
    public static let maximumTimeoutMilliseconds = 300_000
    public static let maximumSocketPathBytes = 103
}

public struct ClusterNodeAgentRequest: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let protocolLabel: String
    public let requestID: String
    public let handoff: ClusterSessionHandoff
    public let operation: String
    public let payloadBase64: String

    public init(
        requestID: String = UUID().uuidString.lowercased(),
        handoff: ClusterSessionHandoff,
        operation: String,
        payload: Data
    ) throws {
        self.apiVersion = ClusterNodeAgentTransportContract.apiVersion
        self.protocolLabel = ClusterNodeAgentTransportContract.protocolLabel
        self.requestID = requestID
        self.handoff = handoff
        self.operation = operation
        self.payloadBase64 = payload.base64EncodedString()
        try validate()
    }

    public func validate() throws {
        guard apiVersion == ClusterNodeAgentTransportContract.apiVersion,
              protocolLabel == ClusterNodeAgentTransportContract.protocolLabel else {
            throw ClusterNodeAgentTransportError.invalidRequest("protocol")
        }
        try NodeAgentTransportValidation.uuid(requestID, field: "requestID")
        try handoff.validate()
        try NodeAgentTransportValidation.identifier(
            operation,
            field: "operation",
            maximumBytes: ClusterNodeAgentTransportContract.maximumOperationBytes
        )
        guard let payload = Data(base64Encoded: payloadBase64),
              payload.count <= ClusterNodeAgentTransportContract.maximumPayloadBytes,
              payload.base64EncodedString() == payloadBase64 else {
            throw ClusterNodeAgentTransportError.invalidRequest("payload")
        }
    }

    public func canonicalData() throws -> Data {
        try validate()
        return try ControlPlaneCanonicalJSON.encode(self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        let protocolLabel = try container.decode(String.self, forKey: .protocolLabel)
        guard apiVersion == ClusterNodeAgentTransportContract.apiVersion,
              protocolLabel == ClusterNodeAgentTransportContract.protocolLabel else {
            throw ClusterNodeAgentTransportError.invalidRequest("protocol")
        }
        try self.init(
            requestID: container.decode(String.self, forKey: .requestID),
            handoff: container.decode(ClusterSessionHandoff.self, forKey: .handoff),
            operation: container.decode(String.self, forKey: .operation),
            payload: try Self.decodePayload(
                container.decode(String.self, forKey: .payloadBase64)
            )
        )
    }

    private static func decodePayload(_ value: String) throws -> Data {
        guard let payload = Data(base64Encoded: value) else {
            throw ClusterNodeAgentTransportError.invalidRequest("payload")
        }
        return payload
    }

    private enum CodingKeys: String, CodingKey {
        case apiVersion
        case protocolLabel
        case requestID
        case handoff
        case operation
        case payloadBase64
    }
}

public enum ClusterNodeAgentResponseStatus: String, Codable, Equatable, Sendable {
    case completed
    case rejected
}

public struct ClusterNodeAgentResponse: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let protocolLabel: String
    public let requestID: String
    public let status: ClusterNodeAgentResponseStatus
    public let payloadBase64: String
    public let errorCode: String

    public init(
        requestID: String,
        status: ClusterNodeAgentResponseStatus,
        payload: Data = Data(),
        errorCode: String = ""
    ) throws {
        self.apiVersion = ClusterNodeAgentTransportContract.apiVersion
        self.protocolLabel = ClusterNodeAgentTransportContract.protocolLabel
        self.requestID = requestID
        self.status = status
        self.payloadBase64 = payload.base64EncodedString()
        self.errorCode = errorCode
        try validate()
    }

    public func validate() throws {
        guard apiVersion == ClusterNodeAgentTransportContract.apiVersion,
              protocolLabel == ClusterNodeAgentTransportContract.protocolLabel else {
            throw ClusterNodeAgentTransportError.invalidResponse("protocol")
        }
        try NodeAgentTransportValidation.uuid(requestID, field: "requestID")
        guard let payload = Data(base64Encoded: payloadBase64),
              payload.count <= ClusterNodeAgentTransportContract.maximumPayloadBytes,
              payload.base64EncodedString() == payloadBase64 else {
            throw ClusterNodeAgentTransportError.invalidResponse("payload")
        }
        switch status {
        case .completed:
            guard errorCode.isEmpty else {
                throw ClusterNodeAgentTransportError.invalidResponse("completed error")
            }
        case .rejected:
            guard payload.isEmpty else {
                throw ClusterNodeAgentTransportError.invalidResponse("rejected payload")
            }
            try NodeAgentTransportValidation.identifier(
                errorCode,
                field: "errorCode",
                maximumBytes: ClusterNodeAgentTransportContract.maximumOperationBytes
            )
        }
    }

    public func payload() throws -> Data {
        try validate()
        return Data(base64Encoded: payloadBase64) ?? Data()
    }

    public func canonicalData() throws -> Data {
        try validate()
        return try ControlPlaneCanonicalJSON.encode(self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        let protocolLabel = try container.decode(String.self, forKey: .protocolLabel)
        guard apiVersion == ClusterNodeAgentTransportContract.apiVersion,
              protocolLabel == ClusterNodeAgentTransportContract.protocolLabel else {
            throw ClusterNodeAgentTransportError.invalidResponse("protocol")
        }
        try self.init(
            requestID: container.decode(String.self, forKey: .requestID),
            status: container.decode(ClusterNodeAgentResponseStatus.self, forKey: .status),
            payload: try Self.decodePayload(container.decode(String.self, forKey: .payloadBase64)),
            errorCode: container.decode(String.self, forKey: .errorCode)
        )
    }

    private static func decodePayload(_ value: String) throws -> Data {
        guard let payload = Data(base64Encoded: value) else {
            throw ClusterNodeAgentTransportError.invalidResponse("payload")
        }
        return payload
    }

    private enum CodingKeys: String, CodingKey {
        case apiVersion
        case protocolLabel
        case requestID
        case status
        case payloadBase64
        case errorCode
    }
}

public enum ClusterNodeAgentWireContract {
    public static let requestAllowedKeys: Set<String> = [
        "apiVersion", "protocolLabel", "requestID", "handoff", "operation", "payloadBase64",
    ]
    public static let responseAllowedKeys: Set<String> = [
        "apiVersion", "protocolLabel", "requestID", "status", "payloadBase64", "errorCode",
    ]

    public static func decodeRequest(_ data: Data) throws -> ClusterNodeAgentRequest {
        do {
            let value = try Phase09StrictDecoder.decode(
                ClusterNodeAgentRequest.self,
                from: data,
                allowedKeys: requestAllowedKeys,
                requiredKeys: requestAllowedKeys
            )
            try value.validate()
            return value
        } catch let error as ClusterNodeAgentTransportError {
            throw error
        } catch {
            throw ClusterNodeAgentTransportError.invalidRequest("wire")
        }
    }

    public static func decodeResponse(_ data: Data) throws -> ClusterNodeAgentResponse {
        do {
            let value = try Phase09StrictDecoder.decode(
                ClusterNodeAgentResponse.self,
                from: data,
                allowedKeys: responseAllowedKeys,
                requiredKeys: responseAllowedKeys
            )
            try value.validate()
            return value
        } catch let error as ClusterNodeAgentTransportError {
            throw error
        } catch {
            throw ClusterNodeAgentTransportError.invalidResponse("wire")
        }
    }
}

public struct ClusterNodeAgentSubprocessConfiguration: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let socketPath: String

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = SecureSubprocessEnvironment.minimal,
        workingDirectory: String = "/",
        socketPath: String
    ) throws {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.socketPath = socketPath
        try validate()
    }

    public func validate() throws {
        do {
            _ = try SecureExecutableResolver.verify(
                path: executablePath,
                ownershipPolicy: .rootOrCurrentUser
            )
            _ = try SecureExecutableResolver.verifyWorkingDirectory(path: workingDirectory)
        } catch {
            throw ClusterNodeAgentTransportError.invalidConfiguration("executable")
        }
        guard arguments.count <= 4_096,
              arguments.allSatisfy({ !$0.contains("\0") }),
              !arguments.contains(ClusterNodeAgentTransportContract.socketArgument) else {
            throw ClusterNodeAgentTransportError.invalidConfiguration("arguments")
        }
        guard environment == SecureSubprocessEnvironment.minimal else {
            throw ClusterNodeAgentTransportError.invalidConfiguration("environment")
        }
        try NodeAgentTransportValidation.socketPath(socketPath)
    }

    fileprivate var launchArguments: [String] {
        arguments + [ClusterNodeAgentTransportContract.socketArgument, socketPath]
    }
}

/// A one-request, background local transport for an authenticated node agent.
/// The subprocess receives the handoff over a framed Unix socket; credentials,
/// challenge material, and proof material are never placed in its arguments or
/// environment. The concrete authority requirement prevents an unauthenticated
/// transport from being constructed.
public final class ClusterNodeAgentLocalTransport: @unchecked Sendable {
    private let authority: ClusterSessionAuthority
    private let authorizer: any ClusterSessionHandoffAuthorizing
    private let configuration: ClusterNodeAgentSubprocessConfiguration

    public init(
        authority: ClusterSessionAuthority,
        configuration: ClusterNodeAgentSubprocessConfiguration
    ) throws {
        try configuration.validate()
        self.authority = authority
        self.authorizer = authority
        self.configuration = configuration
    }

    public func send(
        session: ClusterAuthenticatedSession,
        subjectID: String,
        operation: String,
        payload: Data,
        nowMilliseconds: UInt64,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> Data {
        guard !Task.isCancelled else { throw ClusterNodeAgentTransportError.cancelled }
        let handoff: ClusterSessionHandoff
        do {
            handoff = try authority.bootstrapConsumer(
                from: session,
                subjectID: subjectID,
                nowMilliseconds: nowMilliseconds
            )
        } catch let error as ClusterSessionError {
            throw ClusterNodeAgentTransportError.authorizationFailed(error)
        }
        return try await send(
            handoff: handoff,
            subjectID: subjectID,
            operation: operation,
            payload: payload,
            nowMilliseconds: nowMilliseconds,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public func send(
        handoff: ClusterSessionHandoff,
        subjectID: String,
        operation: String,
        payload: Data,
        nowMilliseconds: UInt64,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> Data {
        guard (1...ClusterNodeAgentTransportContract.maximumTimeoutMilliseconds)
            .contains(timeoutMilliseconds) else {
            throw ClusterNodeAgentTransportError.invalidConfiguration("timeout")
        }
        let request: ClusterNodeAgentRequest
        do {
            try authorizer.authorize(
                handoff,
                subjectID: subjectID,
                nowMilliseconds: nowMilliseconds
            )
            request = try ClusterNodeAgentRequest(
                handoff: handoff,
                operation: operation,
                payload: payload
            )
        } catch let error as ClusterSessionError {
            throw ClusterNodeAgentTransportError.authorizationFailed(error)
        }

        let cancellation = SecureSubprocessCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try self.execute(
                            request: request,
                            timeoutMilliseconds: timeoutMilliseconds,
                            cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func execute(
        request: ClusterNodeAgentRequest,
        timeoutMilliseconds: Int,
        cancellation: SecureSubprocessCancellation
    ) throws -> Data {
        guard !cancellation.isCancelled else { throw ClusterNodeAgentTransportError.cancelled }
        let requestData = try request.canonicalData()
        guard requestData.count <= ControlPlaneContract.maximumRequestBytes else {
            throw ClusterNodeAgentTransportError.requestTooLarge
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.launchArguments
        process.environment = configuration.environment
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ClusterNodeAgentTransportError.processLaunchFailed
        }
        defer { terminate(process) }
        guard process.isRunning else {
            throw ClusterNodeAgentTransportError.processExited(process.terminationStatus)
        }

        let deadline = SocketDeadline(timeoutMilliseconds: timeoutMilliseconds)
        let descriptor = try connect(
            process: process,
            deadline: deadline,
            cancellation: cancellation
        )
        defer { _ = Darwin.close(descriptor) }

        do {
            try writeFrame(
                requestData,
                to: descriptor,
                deadline: deadline,
                cancellation: cancellation
            )
            let responseData = try readFrame(
                from: descriptor,
                deadline: deadline,
                cancellation: cancellation
            )
            guard responseData.count <= ControlPlaneContract.maximumResponseOrFrameBytes else {
                throw ClusterNodeAgentTransportError.responseTooLarge
            }
            let response = try ClusterNodeAgentWireContract.decodeResponse(responseData)
            guard response.requestID == request.requestID else {
                throw ClusterNodeAgentTransportError.responseRequestMismatch
            }
            switch response.status {
            case .completed:
                return try response.payload()
            case .rejected:
                throw ClusterNodeAgentTransportError.remoteRejected(response.errorCode)
            }
        } catch let error as ClusterNodeAgentTransportError {
            throw error
        } catch {
            throw ClusterNodeAgentTransportError.readFailed(EIO)
        }
    }

    private func connect(
        process: Process,
        deadline: SocketDeadline,
        cancellation: SecureSubprocessCancellation
    ) throws -> Int32 {
        var lastError = ENOENT
        while !deadline.expired {
            guard !cancellation.isCancelled else { throw ClusterNodeAgentTransportError.cancelled }
            guard process.isRunning else {
                throw ClusterNodeAgentTransportError.processExited(process.terminationStatus)
            }
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw ClusterNodeAgentTransportError.socketFailed(errno)
            }
            do {
                try makeNonBlocking(descriptor)
                var address = try NodeAgentSocketAddress(path: configuration.socketPath)
                let result = withUnsafePointer(to: &address.value) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, address.length)
                    }
                }
                if result == 0 {
                    try NodeAgentSocketIdentity.validate(path: configuration.socketPath)
                    return descriptor
                }
                lastError = errno
                if errno == EINPROGRESS {
                    try waitFor(
                        descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        cancellation: cancellation
                    )
                    let socketError = try socketError(descriptor)
                    if socketError == 0 {
                        try NodeAgentSocketIdentity.validate(path: configuration.socketPath)
                        return descriptor
                    }
                    lastError = socketError
                }
                _ = Darwin.close(descriptor)
                guard lastError == ENOENT || lastError == ECONNREFUSED || lastError == EAGAIN else {
                    throw ClusterNodeAgentTransportError.connectionFailed(lastError)
                }
                try waitBriefly(deadline: deadline, cancellation: cancellation)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        throw lastError == ENOENT || lastError == ECONNREFUSED
            ? ClusterNodeAgentTransportError.timedOut
            : ClusterNodeAgentTransportError.connectionFailed(lastError)
    }

    private func writeFrame(
        _ payload: Data,
        to descriptor: Int32,
        deadline: SocketDeadline,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard !payload.isEmpty,
              payload.count <= ControlPlaneContract.maximumRequestBytes else {
            throw ClusterNodeAgentTransportError.requestTooLarge
        }
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        frame.append(payload)
        var offset = 0
        while offset < frame.count {
            try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            let written = frame.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    frame.count - offset
                )
            }
            if written > 0 {
                offset += written
            } else if written == 0 {
                throw ClusterNodeAgentTransportError.peerClosed
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw ClusterNodeAgentTransportError.writeFailed(errno)
            }
        }
    }

    private func readFrame(
        from descriptor: Int32,
        deadline: SocketDeadline,
        cancellation: SecureSubprocessCancellation
    ) throws -> Data {
        let header = try readExact(
            4,
            from: descriptor,
            deadline: deadline,
            cancellation: cancellation
        )
        let length = (UInt32(header[0]) << 24)
            | (UInt32(header[1]) << 16)
            | (UInt32(header[2]) << 8)
            | UInt32(header[3])
        guard length > 0 else { throw ClusterNodeAgentTransportError.invalidResponse("empty frame") }
        do {
            try ControlFramingContract.validateDeclaredLength(length, kind: .response)
        } catch {
            throw ClusterNodeAgentTransportError.responseTooLarge
        }
        return try readExact(
            Int(length),
            from: descriptor,
            deadline: deadline,
            cancellation: cancellation
        )
    }

    private func readExact(
        _ count: Int,
        from descriptor: Int32,
        deadline: SocketDeadline,
        cancellation: SecureSubprocessCancellation
    ) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try waitFor(descriptor, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            let readCount = result.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
            }
            if readCount > 0 {
                offset += readCount
            } else if readCount == 0 {
                throw ClusterNodeAgentTransportError.peerClosed
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw ClusterNodeAgentTransportError.readFailed(errno)
            }
        }
        return result
    }

    private func waitFor(
        _ descriptor: Int32,
        events: Int16,
        deadline: SocketDeadline,
        cancellation: SecureSubprocessCancellation
    ) throws {
        while !deadline.expired {
            guard !cancellation.isCancelled else { throw ClusterNodeAgentTransportError.cancelled }
            var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptorState, 1, deadline.pollMilliseconds)
            if result > 0 {
                if descriptorState.revents & Int16(POLLNVAL) != 0 {
                    throw ClusterNodeAgentTransportError.readFailed(EBADF)
                }
                if descriptorState.revents & Int16(POLLHUP) != 0,
                   descriptorState.revents & (Int16(POLLIN) | Int16(POLLOUT)) == 0 {
                    throw ClusterNodeAgentTransportError.peerClosed
                }
                if descriptorState.revents & Int16(POLLERR) != 0 {
                    throw ClusterNodeAgentTransportError.readFailed(try socketError(descriptor))
                }
                return
            }
            if result < 0, errno != EINTR {
                throw ClusterNodeAgentTransportError.readFailed(errno)
            }
        }
        throw ClusterNodeAgentTransportError.timedOut
    }

    private func waitBriefly(
        deadline: SocketDeadline,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard !cancellation.isCancelled else { throw ClusterNodeAgentTransportError.cancelled }
        let nanoseconds = min(deadline.remainingNanoseconds, 5_000_000)
        if nanoseconds > 0 {
            usleep(useconds_t(nanoseconds / 1_000))
        }
    }

    private func makeNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ClusterNodeAgentTransportError.socketFailed(errno)
        }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ClusterNodeAgentTransportError.socketFailed(errno)
        }
    }

    private func socketError(_ descriptor: Int32) throws -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &value, &length) == 0 else {
            throw ClusterNodeAgentTransportError.socketFailed(errno)
        }
        return value
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private struct SocketDeadline: Sendable {
    private let deadlineNanoseconds: UInt64

    init(timeoutMilliseconds: Int) {
        deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
    }

    var expired: Bool {
        DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds
    }

    var remainingNanoseconds: UInt64 {
        deadlineNanoseconds > DispatchTime.now().uptimeNanoseconds
            ? deadlineNanoseconds - DispatchTime.now().uptimeNanoseconds
            : 0
    }

    var pollMilliseconds: Int32 {
        Int32(min(max(1, remainingNanoseconds / 1_000_000), 50))
    }
}

private struct NodeAgentSocketAddress {
    var value: sockaddr_un
    let length: socklen_t

    init(path: String) throws {
        try NodeAgentTransportValidation.socketPath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathData = Data(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: pathData)
            bytes[pathData.count] = 0
        }
        self.value = address
        self.length = socklen_t(MemoryLayout<sockaddr_un>.size)
    }
}

private enum NodeAgentSocketIdentity {
    static func validate(path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw ClusterNodeAgentTransportError.invalidConfiguration("socket identity")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ClusterNodeAgentTransportError.invalidConfiguration("socket identity")
        }
    }
}

private enum NodeAgentTransportValidation {
    static func uuid(_ value: String, field: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw ClusterNodeAgentTransportError.invalidRequest(field)
        }
    }

    static func identifier(_ value: String, field: String, maximumBytes: Int) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.range(of: "^[a-z0-9][a-z0-9._:-]*$", options: .regularExpression) != nil else {
            throw ClusterNodeAgentTransportError.invalidRequest(field)
        }
    }

    static func socketPath(_ value: String) throws {
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              !value.hasSuffix("/"),
              value.utf8.count <= ClusterNodeAgentTransportContract.maximumSocketPathBytes,
              value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ClusterNodeAgentTransportError.invalidConfiguration("socketPath")
        }
    }
}
