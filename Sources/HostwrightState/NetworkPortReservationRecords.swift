import Foundation

public enum NetworkPortReservationProtocol:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case tcp
    case udp
}

public enum NetworkPortAllocationKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case fixed
    case dynamic
}

public enum NetworkPortReservationLifecycle:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case reserved
    case active
    case releasing
    case released
    case faulted
}

public struct NetworkPortReservationRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let projectUUID: String
    public let resourceUUID: String
    public let serviceName: String
    public let generation: Int64
    public let providerID: String
    public let providerGeneration: Int64
    public let fencingToken: String
    public let bindAddress: String
    public let hostPort: Int
    public let containerPort: Int
    public let protocolName: NetworkPortReservationProtocol
    public let allocationKind: NetworkPortAllocationKind
    public let desiredSHA256: String
    public let observedSHA256: String?
    public let lifecycleState: NetworkPortReservationLifecycle
    public let finalizerState: NetworkStateFinalizer
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        projectUUID: String,
        resourceUUID: String,
        serviceName: String,
        generation: Int64,
        providerID: String,
        providerGeneration: Int64,
        fencingToken: String,
        bindAddress: String,
        hostPort: Int,
        containerPort: Int,
        protocolName: NetworkPortReservationProtocol,
        allocationKind: NetworkPortAllocationKind,
        desiredSHA256: String,
        observedSHA256: String?,
        lifecycleState: NetworkPortReservationLifecycle,
        finalizerState: NetworkStateFinalizer,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.projectUUID = projectUUID
        self.resourceUUID = resourceUUID
        self.serviceName = serviceName
        self.generation = generation
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
        self.bindAddress = bindAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
        self.allocationKind = allocationKind
        self.desiredSHA256 = desiredSHA256
        self.observedSHA256 = observedSHA256
        self.lifecycleState = lifecycleState
        self.finalizerState = finalizerState
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var expectedVersion: NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: generation,
            fencingToken: fencingToken
        )
    }
}
