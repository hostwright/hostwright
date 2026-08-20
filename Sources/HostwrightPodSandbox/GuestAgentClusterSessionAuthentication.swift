import Foundation
import HostwrightCluster

/// Binds one Phase 11 authenticated session to the guest-agent request owner.
/// Credentials and handshake messages stay outside the guest-agent lifecycle wire.
public struct ClusterSessionGuestAgentAuthenticationBoundary:
    GuestAgentAuthenticationBoundary,
    Sendable
{
    private let authorizer: any ClusterSessionAuthorizing
    private let session: ClusterAuthenticatedSession
    private let nowMilliseconds: @Sendable () -> UInt64

    public init(
        authorizer: any ClusterSessionAuthorizing,
        session: ClusterAuthenticatedSession,
        nowMilliseconds: @escaping @Sendable () -> UInt64 = {
            let milliseconds = Date().timeIntervalSince1970 * 1_000
            guard milliseconds >= 0, milliseconds <= Double(UInt64.max) else {
                return 0
            }
            return UInt64(milliseconds)
        }
    ) throws {
        try session.validate()
        self.authorizer = authorizer
        self.session = session
        self.nowMilliseconds = nowMilliseconds
    }

    public func authorize(_ request: GuestAgentEnvelope) throws {
        guard request.ownerID == session.subjectID else {
            throw ClusterSessionError.sessionIdentityMismatch
        }
        try authorizer.authorize(
            session,
            subjectID: request.ownerID,
            nowMilliseconds: nowMilliseconds()
        )
    }
}
