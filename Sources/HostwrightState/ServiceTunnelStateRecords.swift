public enum ServiceTunnelLifecycleState: String, Codable, Equatable, Sendable {
    case intended
    case connecting
    case active
    case draining
    case closed
    case faulted
}

public enum ServiceTunnelFinalizerState: String, Codable, Equatable, Sendable {
    case pending
    case active
    case releasing
    case released
    case quarantined
}

public enum ServiceTunnelTransportState: String, Codable, Equatable, Sendable {
    case direct
    case relay
}

public struct ServiceTunnelExpectedVersion: Equatable, Sendable {
    public let generation: Int64
    public let fencingToken: String

    public init(generation: Int64, fencingToken: String) {
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct ServiceTunnelStateRecord: Equatable, Sendable {
    public let id: String
    public let projectUUID: String
    public let peerUUID: String
    public let generation: Int64
    public let providerID: String
    public let providerGeneration: Int64
    public let fencingToken: String
    public let operationGroupID: String
    public let desiredSHA256: String
    public let observedSHA256: String?
    public let routeJSON: String
    public let routeJSONSHA256: String
    public let lifecycleState: ServiceTunnelLifecycleState
    public let finalizerState: ServiceTunnelFinalizerState
    public let selectedTransport: ServiceTunnelTransportState?
    public let keyEpoch: Int64
    public let reconnectAttempt: Int
    public let createdAtUnixMilliseconds: Int64
    public let updatedAtUnixMilliseconds: Int64

    public init(
        id: String,
        projectUUID: String,
        peerUUID: String,
        generation: Int64,
        providerID: String,
        providerGeneration: Int64,
        fencingToken: String,
        operationGroupID: String,
        desiredSHA256: String,
        observedSHA256: String?,
        routeJSON: String,
        routeJSONSHA256: String,
        lifecycleState: ServiceTunnelLifecycleState,
        finalizerState: ServiceTunnelFinalizerState,
        selectedTransport: ServiceTunnelTransportState?,
        keyEpoch: Int64,
        reconnectAttempt: Int,
        createdAtUnixMilliseconds: Int64,
        updatedAtUnixMilliseconds: Int64
    ) {
        self.id = id
        self.projectUUID = projectUUID
        self.peerUUID = peerUUID
        self.generation = generation
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
        self.operationGroupID = operationGroupID
        self.desiredSHA256 = desiredSHA256
        self.observedSHA256 = observedSHA256
        self.routeJSON = routeJSON
        self.routeJSONSHA256 = routeJSONSHA256
        self.lifecycleState = lifecycleState
        self.finalizerState = finalizerState
        self.selectedTransport = selectedTransport
        self.keyEpoch = keyEpoch
        self.reconnectAttempt = reconnectAttempt
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
    }
}
