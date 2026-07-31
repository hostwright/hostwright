public struct ProjectDNSStateRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let projectUUID: String
    public let generation: Int64
    public let providerID: String
    public let providerGeneration: Int64
    public let fencingToken: String
    public let desiredSHA256: String
    public let observedSHA256: String?
    public let lifecycleState: NetworkStateResourceLifecycle
    public let finalizerState: NetworkStateFinalizer
    public let lastReadyRecordSHA256: String?
    public let operationGroupID: String

    public init(
        id: String,
        projectUUID: String,
        generation: Int64,
        providerID: String,
        providerGeneration: Int64,
        fencingToken: String,
        desiredSHA256: String,
        observedSHA256: String?,
        lifecycleState: NetworkStateResourceLifecycle,
        finalizerState: NetworkStateFinalizer,
        lastReadyRecordSHA256: String?,
        operationGroupID: String
    ) {
        self.id = id
        self.projectUUID = projectUUID
        self.generation = generation
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
        self.desiredSHA256 = desiredSHA256
        self.observedSHA256 = observedSHA256
        self.lifecycleState = lifecycleState
        self.finalizerState = finalizerState
        self.lastReadyRecordSHA256 = lastReadyRecordSHA256
        self.operationGroupID = operationGroupID
    }
}
