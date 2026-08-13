public enum HostwrightTunnelSessionPhase: String, Codable, Equatable, Sendable {
    case intended
    case connecting
    case active
    case draining
    case closed
    case faulted
}

public enum HostwrightTunnelFinalizer: String, Codable, Equatable, Sendable {
    case pending
    case active
    case releasing
    case released
    case quarantined
}

public struct HostwrightTunnelSessionIntent: Codable, Equatable, Sendable {
    public let route: HostwrightTunnelRoute
    public let phase: HostwrightTunnelSessionPhase
    public let finalizer: HostwrightTunnelFinalizer
    public let selectedTransport: HostwrightTunnelTransport?
    public let keyEpoch: Int64
    public let reconnectAttempt: Int
    public let observedSHA256: String?
    public let updatedAtUnixMilliseconds: Int64

    public init(
        route: HostwrightTunnelRoute,
        phase: HostwrightTunnelSessionPhase,
        finalizer: HostwrightTunnelFinalizer,
        selectedTransport: HostwrightTunnelTransport?,
        keyEpoch: Int64,
        reconnectAttempt: Int,
        observedSHA256: String?,
        updatedAtUnixMilliseconds: Int64
    ) {
        self.route = route
        self.phase = phase
        self.finalizer = finalizer
        self.selectedTransport = selectedTransport
        self.keyEpoch = keyEpoch
        self.reconnectAttempt = reconnectAttempt
        self.observedSHA256 = observedSHA256
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
    }
}

/// The state module implements this contract with the schema-v17 SQLite
/// repository. The network helper never creates a second journal.
public protocol HostwrightTunnelIntentPersisting: Sendable {
    func save(_ intent: HostwrightTunnelSessionIntent) throws
    func load(routeUUID: String) throws -> HostwrightTunnelSessionIntent?
    func remove(
        routeUUID: String,
        generation: Int64,
        fencingToken: String
    ) throws
}
