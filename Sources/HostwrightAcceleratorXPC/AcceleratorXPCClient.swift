import Dispatch
import Foundation
@preconcurrency import XPC

public enum AcceleratorXPCClientError: Error, Equatable, Sendable {
    case authenticationFailed
    case serviceUnavailable
    case invalidResponse
    case timeout
    case connectionInvalidated
}

public final class AcceleratorXPCClient: @unchecked Sendable {
    public let serviceName: String
    public let identityInspector: any AcceleratorXPCIdentityInspector
    private let queue: DispatchQueue

    public init(
        serviceName: String = AcceleratorXPCIdentityPolicy.serviceIdentifier,
        identityInspector: any AcceleratorXPCIdentityInspector = AcceleratorXPCLiveIdentityInspector()
    ) throws {
        guard (1...255).contains(serviceName.utf8.count),
              serviceName.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 95:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "serviceName")
        }
        self.serviceName = serviceName
        self.identityInspector = identityInspector
        self.queue = DispatchQueue(label: "dev.hostwright.phase10.accelerator.client")
    }

    public func send(
        _ request: AcceleratorXPCRequest
    ) async throws -> AcceleratorXPCResponse {
        do {
            try identityInspector.current().validate(as: .daemon)
        } catch {
            throw AcceleratorXPCClientError.authenticationFailed
        }
        let message = try AcceleratorXPCMessageCodec.encodeRequest(request)
        let connection = xpc_connection_create_mach_service(serviceName, queue, 0)
        guard xpc_connection_set_peer_code_signing_requirement(
            connection,
            AcceleratorXPCIdentityPolicy.serviceRequirement
        ) == 0 else {
            xpc_connection_set_event_handler(connection) { _ in }
            xpc_connection_activate(connection)
            xpc_connection_cancel(connection)
            throw AcceleratorXPCClientError.authenticationFailed
        }

        let pending = AcceleratorXPCClientPendingReply()
        xpc_connection_set_event_handler(connection) { event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            let error: AcceleratorXPCClientError = event === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT
                ? .authenticationFailed
                : .serviceUnavailable
            pending.finish(.failure(error))
        }
        xpc_connection_activate(connection)
        xpc_connection_send_message_with_reply(connection, message, queue) { reply in
            guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
                let error: AcceleratorXPCClientError = reply === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT
                    ? .authenticationFailed
                    : .serviceUnavailable
                pending.finish(.failure(error))
                return
            }
            do {
                let response = try AcceleratorXPCMessageCodec.decodeResponse(reply)
                // The public peer code-signing requirement is the transport
                // authorization boundary. PID/SecCode inspection is not used
                // here because the SDK exposes only a recyclable PID lookup.
                try response.serviceProof.validate(as: .service)
                try Self.validateTransportAuthenticated(
                    response: response,
                    for: request
                )
                pending.finish(.success(response))
            } catch let error as AcceleratorXPCClientError {
                pending.finish(.failure(error))
            } catch is AcceleratorXPCIdentityError {
                pending.finish(.failure(AcceleratorXPCClientError.authenticationFailed))
            } catch {
                pending.finish(.failure(AcceleratorXPCClientError.invalidResponse))
            }
        }

        let timeoutTask = Task { [pending, connection] in
            try? await Task.sleep(nanoseconds: UInt64(request.timeoutMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            pending.finish(.failure(AcceleratorXPCClientError.timeout))
            xpc_connection_cancel(connection)
        }
        defer {
            timeoutTask.cancel()
            xpc_connection_cancel(connection)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
            }
        } onCancel: {
            // Local connection loss is not a remote cancellation. Callers must send
            // an authenticated cancel request when they intend to stop execution.
            pending.finish(.failure(AcceleratorXPCClientError.connectionInvalidated))
            xpc_connection_cancel(connection)
        }
    }

    public static func validate(
        response: AcceleratorXPCResponse,
        for request: AcceleratorXPCRequest,
        liveServiceProof: AcceleratorXPCCodeIdentityProof
    ) throws {
        do {
            try liveServiceProof.validate(as: .service)
        } catch {
            throw AcceleratorXPCClientError.authenticationFailed
        }
        guard response.requestID == request.requestID,
              response.operation == request.operation,
              response.idempotencyDigest == request.idempotencyDigest,
              response.protocolVersion == request.protocolVersion,
              response.serviceProof == liveServiceProof else {
            throw AcceleratorXPCClientError.invalidResponse
        }
    }

    private static func validateTransportAuthenticated(
        response: AcceleratorXPCResponse,
        for request: AcceleratorXPCRequest
    ) throws {
        guard response.requestID == request.requestID,
              response.operation == request.operation,
              response.idempotencyDigest == request.idempotencyDigest,
              response.protocolVersion == request.protocolVersion else {
            throw AcceleratorXPCClientError.invalidResponse
        }
    }
}

private final class AcceleratorXPCClientPendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AcceleratorXPCResponse, Error>?
    private var result: Result<AcceleratorXPCResponse, Error>?

    func install(
        _ continuation: CheckedContinuation<AcceleratorXPCResponse, Error>
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<AcceleratorXPCResponse, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
