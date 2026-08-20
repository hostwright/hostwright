import Foundation
import HostwrightCluster

/// Produces guest-agent requests through an authenticated local node-agent.
/// The handoff is the only session value retained by this boundary; the node
/// transport reauthorizes it again immediately before launching its endpoint.
public final class GuestAgentNodeAgentTransport: @unchecked Sendable {
    public static let operation = "pod-sandbox-guest-agent-v1"

    private let nodeAgentTransport: ClusterNodeAgentLocalTransport
    private let authorizer: any ClusterSessionHandoffAuthorizing
    private let handoff: ClusterSessionHandoff
    private let nowMilliseconds: @Sendable () -> UInt64

    public init(
        nodeAgentTransport: ClusterNodeAgentLocalTransport,
        authorizer: any ClusterSessionHandoffAuthorizing,
        handoff: ClusterSessionHandoff,
        nowMilliseconds: @escaping @Sendable () -> UInt64 = {
            let milliseconds = Date().timeIntervalSince1970 * 1_000
            guard milliseconds >= 0, milliseconds <= Double(UInt64.max) else {
                return 0
            }
            return UInt64(milliseconds)
        }
    ) throws {
        try handoff.validate()
        self.nodeAgentTransport = nodeAgentTransport
        self.authorizer = authorizer
        self.handoff = handoff
        self.nowMilliseconds = nowMilliseconds
    }

    public func send(
        _ request: GuestAgentEnvelope,
        cancellation: GuestAgentCancellation? = nil
    ) async throws -> GuestAgentEnvelope {
        try request.validate()
        guard request.kind == .request else {
            throw GuestAgentProtocolError.invalidEnvelope("kind")
        }
        guard request.ownerID == handoff.subjectID else {
            throw ClusterNodeAgentTransportError.authorizationFailed(
                .sessionIdentityMismatch
            )
        }
        guard cancellation?.isCancelled != true else {
            throw ClusterNodeAgentTransportError.cancelled
        }

        let payload = try GuestAgentEnvelopeCodec.encode(request)
        let now = nowMilliseconds()
        do {
            try authorizer.authorize(
                handoff,
                subjectID: request.ownerID,
                nowMilliseconds: now
            )
        } catch let error as ClusterSessionError {
            throw ClusterNodeAgentTransportError.authorizationFailed(error)
        }
        guard cancellation?.isCancelled != true else {
            throw ClusterNodeAgentTransportError.cancelled
        }

        let responsePayload = try await nodeAgentTransport.send(
            handoff: handoff,
            subjectID: request.ownerID,
            operation: Self.operation,
            payload: payload,
            nowMilliseconds: now,
            timeoutMilliseconds: request.deadlineMilliseconds
        )
        guard cancellation?.isCancelled != true else {
            throw ClusterNodeAgentTransportError.cancelled
        }
        let response = try GuestAgentEnvelopeCodec.decode(
            responsePayload,
            expectedKind: .response
        )
        guard response.kind == .response,
              response.requestID == request.requestID,
              response.operation == request.operation,
              response.sandboxID == request.sandboxID,
              response.ownerID == request.ownerID,
              response.generation == request.generation else {
            throw GuestAgentProtocolError.requestIDMismatch
        }
        return response
    }
}
