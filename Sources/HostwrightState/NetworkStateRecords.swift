import Foundation

public enum NetworkStateDriver:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case nat
    case hostOnly = "host-only"
}

public enum NetworkStateAddressRequest: Codable, Equatable, Sendable {
    case auto
    case disabled
    case cidr(String)

    var storedValue: String {
        switch self {
        case .auto:
            return "auto"
        case .disabled:
            return "disabled"
        case .cidr(let value):
            return value
        }
    }

    init(storedValue: String) {
        switch storedValue {
        case "auto":
            self = .auto
        case "disabled":
            self = .disabled
        default:
            self = .cidr(storedValue)
        }
    }
}

public enum NetworkStateResourceLifecycle:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case creating
    case available
    case deleting
    case deleted
    case faulted
}

public enum NetworkStateAttachmentLifecycle:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case attaching
    case attached
    case detaching
    case detached
    case faulted
}

public enum NetworkStateFinalizer:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case pending
    case active
    case releasing
    case released
    case quarantined
}

public struct NetworkStateExpectedVersion:
    Codable,
    Equatable,
    Sendable
{
    public let generation: Int64
    public let fencingToken: String

    public init(generation: Int64, fencingToken: String) {
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct NetworkStateMutationAuthority:
    Equatable,
    Sendable
{
    public let providerID: String
    public let providerGeneration: Int64
    public let operationGroupID: String
    public let fencingToken: String
    public let plannedCapabilitySHA256: String
    public let currentCapabilitySHA256: String

    public init(
        providerID: String,
        providerGeneration: Int64,
        operationGroupID: String,
        fencingToken: String,
        plannedCapabilitySHA256: String,
        currentCapabilitySHA256: String
    ) {
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.operationGroupID = operationGroupID
        self.fencingToken = fencingToken
        self.plannedCapabilitySHA256 = plannedCapabilitySHA256
        self.currentCapabilitySHA256 = currentCapabilitySHA256
    }
}

public enum NetworkStateRecoveryTrigger:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case postMutation = "post-mutation"
    case timedOut = "timed-out"
    case cancelled
    case partialEffect = "partial-effect"
    case processTerminated = "process-terminated"
}

public enum NetworkStateRecoveryObservation:
    Equatable,
    Sendable
{
    case absent
    case exactOwned(observedSHA256: String)
    case conflictingOwner(observedSHA256: String?)
    case indeterminate
}

public enum NetworkStateRecoveryAction:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case retryMutation = "retry-mutation"
    case verifyAndAdvance = "verify-and-advance"
    case stable
    case resumeDeletion = "resume-deletion"
    case finalizeDeletion = "finalize-deletion"
    case purgeTerminalRecord = "purge-terminal-record"
    case quarantine
}

public struct NetworkStateRecoveryDecision:
    Equatable,
    Sendable
{
    public let trigger: NetworkStateRecoveryTrigger
    public let action: NetworkStateRecoveryAction
    public let requiresObservationBeforeMutation: Bool

    public init(
        trigger: NetworkStateRecoveryTrigger,
        action: NetworkStateRecoveryAction,
        requiresObservationBeforeMutation: Bool = true
    ) {
        self.trigger = trigger
        self.action = action
        self.requiresObservationBeforeMutation =
            requiresObservationBeforeMutation
    }
}

public enum NetworkStateTeardownKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case attachment
    case network
}

public struct NetworkStateTeardownTarget:
    Equatable,
    Sendable
{
    public let kind: NetworkStateTeardownKind
    public let id: String
    public let networkUUID: String
    public let generation: Int64
    public let fencingToken: String

    public init(
        kind: NetworkStateTeardownKind,
        id: String,
        networkUUID: String,
        generation: Int64,
        fencingToken: String
    ) {
        self.kind = kind
        self.id = id
        self.networkUUID = networkUUID
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct NetworkStateResourceRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let projectUUID: String
    public let name: String
    public let runtimeName: String
    public let generation: Int64
    public let providerID: String
    public let providerGeneration: Int64
    public let fencingToken: String
    public let driver: NetworkStateDriver
    public let requestedIPv4: NetworkStateAddressRequest
    public let requestedIPv6: NetworkStateAddressRequest
    public let observedIPv4: [String]
    public let observedIPv6: [String]
    public let desiredSHA256: String
    public let observedSHA256: String?
    public let lifecycleState: NetworkStateResourceLifecycle
    public let finalizerState: NetworkStateFinalizer
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        projectUUID: String,
        name: String,
        runtimeName: String,
        generation: Int64,
        providerID: String,
        providerGeneration: Int64,
        fencingToken: String,
        driver: NetworkStateDriver,
        requestedIPv4: NetworkStateAddressRequest,
        requestedIPv6: NetworkStateAddressRequest,
        observedIPv4: [String],
        observedIPv6: [String],
        desiredSHA256: String,
        observedSHA256: String?,
        lifecycleState: NetworkStateResourceLifecycle,
        finalizerState: NetworkStateFinalizer,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.projectUUID = projectUUID
        self.name = name
        self.runtimeName = runtimeName
        self.generation = generation
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
        self.driver = driver
        self.requestedIPv4 = requestedIPv4
        self.requestedIPv6 = requestedIPv6
        self.observedIPv4 = observedIPv4
        self.observedIPv6 = observedIPv6
        self.desiredSHA256 = desiredSHA256
        self.observedSHA256 = observedSHA256
        self.lifecycleState = lifecycleState
        self.finalizerState = finalizerState
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NetworkStateAttachmentRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let networkUUID: String
    public let projectUUID: String
    public let resourceUUID: String
    public let generation: Int64
    public let providerID: String
    public let providerGeneration: Int64
    public let fencingToken: String
    public let desiredSHA256: String
    public let observedSHA256: String?
    public let lifecycleState: NetworkStateAttachmentLifecycle
    public let finalizerState: NetworkStateFinalizer
    public let operationGroupID: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        networkUUID: String,
        projectUUID: String,
        resourceUUID: String,
        generation: Int64,
        providerID: String,
        providerGeneration: Int64,
        fencingToken: String,
        desiredSHA256: String,
        observedSHA256: String?,
        lifecycleState: NetworkStateAttachmentLifecycle,
        finalizerState: NetworkStateFinalizer,
        operationGroupID: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.networkUUID = networkUUID
        self.projectUUID = projectUUID
        self.resourceUUID = resourceUUID
        self.generation = generation
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
        self.desiredSHA256 = desiredSHA256
        self.observedSHA256 = observedSHA256
        self.lifecycleState = lifecycleState
        self.finalizerState = finalizerState
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
