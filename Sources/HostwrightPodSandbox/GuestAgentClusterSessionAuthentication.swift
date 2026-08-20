import Foundation
import HostwrightCluster

/// Binds one credential-free Phase 11 handoff to the guest-agent request owner.
/// The authority revalidates the handoff immediately before guest dispatch.
public struct ClusterSessionGuestAgentAuthenticationBoundary:
    GuestAgentAuthenticationBoundary,
    Sendable
{
    private let authorizer: any ClusterSessionHandoffAuthorizing
    private let handoff: ClusterSessionHandoff
    private let nowMilliseconds: @Sendable () -> UInt64

    public init(
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
        self.authorizer = authorizer
        self.handoff = handoff
        self.nowMilliseconds = nowMilliseconds
    }

    public func authorize(_ request: GuestAgentEnvelope) throws {
        guard request.ownerID == handoff.subjectID else {
            throw ClusterSessionError.sessionIdentityMismatch
        }
        try authorizer.authorize(
            handoff,
            subjectID: request.ownerID,
            nowMilliseconds: nowMilliseconds()
        )
    }
}
