import Foundation

public enum PodSandboxValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidField(String)
    case missingField(String)
    case outOfBounds(String)
    case invalidIdentifier(String)

    public var description: String {
        switch self {
        case .invalidField(let field): "Invalid pod-sandbox field: \(field)."
        case .missingField(let field): "Missing pod-sandbox field: \(field)."
        case .outOfBounds(let field): "Pod-sandbox field is out of bounds: \(field)."
        case .invalidIdentifier(let field): "Pod-sandbox identifier is invalid: \(field)."
        }
    }
}

public enum PodSandboxLifecycleError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidTransition(PodSandboxTransition, PodSandboxState)
    case ownershipMismatch
    case generationMismatch
    case generationConflict
    case requestIDConflict
    case replayMismatch
    case sandboxNotFound
    case recoveryEvidenceInvalid
    case cleanupIncomplete

    public var description: String {
        switch self {
        case .invalidTransition(let transition, let state):
            "Transition \(transition.rawValue) is invalid from state \(state.rawValue)."
        case .ownershipMismatch: "The request does not own this pod sandbox."
        case .generationMismatch: "The request generation does not match the fenced sandbox generation."
        case .generationConflict: "The requested generation conflicts with a newer fenced generation."
        case .requestIDConflict: "The request ID is already bound to a different operation."
        case .replayMismatch: "The replayed request ID has different operation inputs."
        case .sandboxNotFound: "The pod sandbox does not exist."
        case .recoveryEvidenceInvalid: "Recovery evidence does not describe a valid partial sandbox."
        case .cleanupIncomplete: "Exact pod-sandbox cleanup did not remove every owned resource."
        }
    }
}

enum PodSandboxValidation {
    static func safeIdentifier(
        _ value: String,
        maximumLength: Int,
        field: String
    ) throws {
        guard !value.isEmpty, value.utf8.count <= maximumLength else {
            throw PodSandboxValidationError.outOfBounds(field)
        }
        guard value.range(
            of: "^[a-z0-9][a-z0-9._:-]*$",
            options: .regularExpression
        ) != nil else {
            throw PodSandboxValidationError.invalidIdentifier(field)
        }
    }

    static func boundedText(
        _ value: String,
        maximumLength: Int,
        field: String
    ) throws {
        guard !value.isEmpty, value.utf8.count <= maximumLength else {
            throw PodSandboxValidationError.outOfBounds(field)
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PodSandboxValidationError.invalidField(field)
        }
    }

    static func generation(_ value: UInt64, field: String = "generation") throws {
        guard value > 0, value <= UInt64(Int64.max) else {
            throw PodSandboxValidationError.outOfBounds(field)
        }
    }
}

public struct PodSandboxID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try PodSandboxValidation.safeIdentifier(
            rawValue,
            maximumLength: 128,
            field: "sandboxID"
        )
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PodSandboxSpec: Codable, Equatable, Sendable {
    public static let minimumMemoryMiB: UInt32 = 128
    public static let maximumMemoryMiB: UInt32 = 1_048_576
    public static let maximumCPUCount: UInt16 = 128

    public let id: PodSandboxID
    public let ownerID: String
    public let generation: UInt64
    public let cpuCount: UInt16
    public let memoryMiB: UInt32

    public init(
        id: PodSandboxID,
        ownerID: String,
        generation: UInt64,
        cpuCount: UInt16 = 1,
        memoryMiB: UInt32 = 256
    ) throws {
        try PodSandboxValidation.safeIdentifier(ownerID, maximumLength: 128, field: "ownerID")
        try PodSandboxValidation.generation(generation)
        guard (1...Self.maximumCPUCount).contains(cpuCount) else {
            throw PodSandboxValidationError.outOfBounds("cpuCount")
        }
        guard (Self.minimumMemoryMiB...Self.maximumMemoryMiB).contains(memoryMiB) else {
            throw PodSandboxValidationError.outOfBounds("memoryMiB")
        }
        self.id = id
        self.ownerID = ownerID
        self.generation = generation
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(PodSandboxID.self, forKey: .id),
            ownerID: container.decode(String.self, forKey: .ownerID),
            generation: container.decode(UInt64.self, forKey: .generation),
            cpuCount: container.decode(UInt16.self, forKey: .cpuCount),
            memoryMiB: container.decode(UInt32.self, forKey: .memoryMiB)
        )
    }
}

public enum PodSandboxState: String, Codable, CaseIterable, Sendable {
    case absent
    case created
    case prepared
    case running
    case stopped
    case recovering
    case cancelling
    case tearingDown
}

public enum PodSandboxTransition: String, Codable, CaseIterable, Sendable {
    case create
    case prepare
    case start
    case stop
    case restart
    case recover
    case cancel
    case teardown
}

public struct PodSandboxRecoveryEvidence: Codable, Equatable, Sendable {
    public let id: PodSandboxID
    public let ownerID: String
    public let generation: UInt64
    public let resourcePresent: Bool
    public let prepared: Bool
    public let running: Bool

    public init(
        id: PodSandboxID,
        ownerID: String,
        generation: UInt64,
        resourcePresent: Bool,
        prepared: Bool,
        running: Bool
    ) throws {
        try PodSandboxValidation.safeIdentifier(ownerID, maximumLength: 128, field: "ownerID")
        try PodSandboxValidation.generation(generation)
        guard resourcePresent || (!prepared && !running) else {
            throw PodSandboxValidationError.invalidField("resourcePresent")
        }
        guard !running || prepared else {
            throw PodSandboxValidationError.invalidField("running")
        }
        self.id = id
        self.ownerID = ownerID
        self.generation = generation
        self.resourcePresent = resourcePresent
        self.prepared = prepared
        self.running = running
    }
}

public struct PodSandboxSnapshot: Codable, Equatable, Sendable {
    public let id: PodSandboxID
    public let ownerID: String
    public let generation: UInt64
    public let state: PodSandboxState
    public let resourcePresent: Bool
    public let prepared: Bool
    public let running: Bool
    public let cleanupComplete: Bool
    public let cleanupResourceCount: Int
    public let lastTransition: PodSandboxTransition?

    init(
        id: PodSandboxID,
        ownerID: String,
        generation: UInt64,
        state: PodSandboxState,
        resourcePresent: Bool,
        prepared: Bool,
        running: Bool,
        cleanupComplete: Bool,
        cleanupResourceCount: Int,
        lastTransition: PodSandboxTransition?
    ) {
        self.id = id
        self.ownerID = ownerID
        self.generation = generation
        self.state = state
        self.resourcePresent = resourcePresent
        self.prepared = prepared
        self.running = running
        self.cleanupComplete = cleanupComplete
        self.cleanupResourceCount = cleanupResourceCount
        self.lastTransition = lastTransition
    }
}

public struct PodSandboxLifecycleResult: Equatable, Sendable {
    public let transition: PodSandboxTransition
    public let snapshot: PodSandboxSnapshot
    public let replayed: Bool
    public let cleanupPerformed: Bool

    init(
        transition: PodSandboxTransition,
        snapshot: PodSandboxSnapshot,
        replayed: Bool,
        cleanupPerformed: Bool
    ) {
        self.transition = transition
        self.snapshot = snapshot
        self.replayed = replayed
        self.cleanupPerformed = cleanupPerformed
    }
}
