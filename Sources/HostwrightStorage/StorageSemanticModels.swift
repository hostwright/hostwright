import Foundation

public enum StorageSemanticOperation: String, Codable, CaseIterable, Sendable {
    case create
    case delete
    case stage
    case unstage
    case publish
    case unpublish
    case expand
    case snapshot
    case restore
    case capacity
    case health
}

public enum StorageSemanticRetryClass: String, Codable, CaseIterable, Sendable {
    case never
    case safeAfterObservation = "safe-after-observation"
    case resumeFromCheckpoint = "resume-from-checkpoint"
}

public enum StorageSemanticErrorCode: String, Codable, CaseIterable, Sendable {
    case invalidArgument = "invalid-argument"
    case alreadyExists = "already-exists"
    case notFound = "not-found"
    case failedPrecondition = "failed-precondition"
    case capacityExhausted = "capacity-exhausted"
    case staleGeneration = "stale-generation"
    case fencingConflict = "fencing-conflict"
    case unsupportedTopology = "unsupported-topology"
    case unhealthy
    case cancelled
    case timedOut = "timed-out"
    case ambiguousEffect = "ambiguous-effect"
}

public struct StorageSemanticError:
    Error,
    Codable,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public let operation: StorageSemanticOperation
    public let code: StorageSemanticErrorCode
    public let retryClass: StorageSemanticRetryClass
    public let message: String

    public init(
        operation: StorageSemanticOperation,
        code: StorageSemanticErrorCode,
        retryClass: StorageSemanticRetryClass,
        message: String
    ) {
        self.operation = operation
        self.code = code
        self.retryClass = retryClass
        self.message = String(message.prefix(512))
    }

    public var description: String {
        "\(operation.rawValue): \(code.rawValue) (\(retryClass.rawValue)): \(message)"
    }
}

public enum StorageSemanticInterruption: String, Codable, Sendable {
    case none
    case cancelled
    case timedOut = "timed-out"
    case ambiguousEffect = "ambiguous-effect"
}

public enum StorageSemanticDisposition: String, Codable, Sendable {
    case performed
    case alreadySatisfied = "already-satisfied"
    case observed
}

public enum StorageSemanticAccessMode: String, Codable, Sendable {
    case readWriteOnce = "read-write-once"
    case readOnlyMany = "read-only-many"
}

public enum StorageSemanticHealth: String, Codable, Sendable {
    case healthy
    case degraded
    case unhealthy
}

public enum StorageSemanticAttachmentKind: String, Codable, Sendable {
    case stage
    case publish
}

public enum StorageSemanticLimits {
    public static let maximumCapacityBytes: Int64 =
        1_125_899_906_842_624
    public static let maximumNameBytes = 128
    public static let maximumProviderIDBytes = 256
    public static let maximumPathBytes = 4_096
    public static let maximumResources = 10_000
}

public struct StorageLocalTopology: Codable, Equatable, Hashable, Sendable {
    public static let segmentKey = "hostwright.apple/local-node"

    public let nodeID: String
    public let operatingSystem: String
    public let architecture: String

    public init(
        nodeID: String,
        operatingSystem: String = "darwin",
        architecture: String = "arm64"
    ) throws {
        guard StorageSemanticValidation.validIdentifier(
            nodeID,
            maximumBytes: StorageSemanticLimits.maximumNameBytes
        ),
        operatingSystem == "darwin",
        architecture == "arm64" else {
            throw StorageSemanticError(
                operation: .capacity,
                code: .unsupportedTopology,
                retryClass: .never,
                message: "Storage topology must identify one bounded local Apple-silicon node."
            )
        }
        self.nodeID = nodeID
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public var segments: [String: String] {
        [Self.segmentKey: nodeID]
    }

    public func isAccessible(from candidate: StorageLocalTopology) -> Bool {
        self == candidate
    }

    func validate(operation: StorageSemanticOperation) throws {
        guard StorageSemanticValidation.validIdentifier(
            nodeID,
            maximumBytes: StorageSemanticLimits.maximumNameBytes
        ),
        operatingSystem == "darwin",
        architecture == "arm64" else {
            throw StorageSemanticError(
                operation: operation,
                code: .unsupportedTopology,
                retryClass: .never,
                message: "Storage topology must identify one bounded local Apple-silicon node."
            )
        }
    }
}

public struct StorageSemanticContext: Codable, Equatable, Sendable {
    public let operationID: String
    public let idempotencyKey: String
    public let providerID: String
    public let generation: Int64
    public let fencingToken: String
    public let interruption: StorageSemanticInterruption

    public init(
        operationID: String,
        idempotencyKey: String,
        providerID: String,
        generation: Int64,
        fencingToken: String,
        interruption: StorageSemanticInterruption = .none
    ) throws {
        guard StorageSemanticValidation.validUUID(operationID),
              StorageSemanticValidation.validSHA256(idempotencyKey),
              StorageSemanticValidation.validIdentifier(
                providerID,
                maximumBytes:
                    StorageSemanticLimits.maximumProviderIDBytes
              ),
              generation > 0,
              StorageSemanticValidation.validUUID(fencingToken) else {
            throw StorageSemanticError(
                operation: .health,
                code: .invalidArgument,
                retryClass: .never,
                message:
                    "Storage context requires canonical operation, idempotency, provider, generation, and fencing identities."
            )
        }
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.providerID = providerID
        self.generation = generation
        self.fencingToken = fencingToken
        self.interruption = interruption
    }

    func validate(operation: StorageSemanticOperation) throws {
        guard StorageSemanticValidation.validUUID(operationID),
              StorageSemanticValidation.validSHA256(idempotencyKey),
              StorageSemanticValidation.validIdentifier(
                  providerID,
                  maximumBytes:
                      StorageSemanticLimits.maximumProviderIDBytes
              ),
              generation > 0,
              StorageSemanticValidation.validUUID(fencingToken) else {
            throw StorageSemanticError(
                operation: operation,
                code: .invalidArgument,
                retryClass: .never,
                message:
                    "Storage context requires canonical operation, idempotency, provider, generation, and fencing identities."
            )
        }
    }
}

public struct StorageSemanticRequest: Codable, Equatable, Sendable {
    public let operation: StorageSemanticOperation
    public let context: StorageSemanticContext
    public let volumeID: String?
    public let volumeName: String?
    public let snapshotID: String?
    public let snapshotName: String?
    public let capacityBytes: Int64?
    public let topology: StorageLocalTopology?
    public let stagingPath: String?
    public let targetPath: String?
    public let readOnly: Bool?
    public let accessMode: StorageSemanticAccessMode?

    public init(
        operation: StorageSemanticOperation,
        context: StorageSemanticContext,
        volumeID: String? = nil,
        volumeName: String? = nil,
        snapshotID: String? = nil,
        snapshotName: String? = nil,
        capacityBytes: Int64? = nil,
        topology: StorageLocalTopology? = nil,
        stagingPath: String? = nil,
        targetPath: String? = nil,
        readOnly: Bool? = nil,
        accessMode: StorageSemanticAccessMode? = nil
    ) throws {
        self.operation = operation
        self.context = context
        self.volumeID = volumeID
        self.volumeName = volumeName
        self.snapshotID = snapshotID
        self.snapshotName = snapshotName
        self.capacityBytes = capacityBytes
        self.topology = topology
        self.stagingPath = stagingPath
        self.targetPath = targetPath
        self.readOnly = readOnly
        self.accessMode = accessMode
        try validate()
    }

    func validate() throws {
        try context.validate(operation: operation)
        if let topology {
            try topology.validate(operation: operation)
        }
        if let volumeID,
           !StorageSemanticValidation.validUUID(volumeID) {
            throw invalid("volumeID must be a canonical UUID.")
        }
        if let snapshotID,
           !StorageSemanticValidation.validUUID(snapshotID) {
            throw invalid("snapshotID must be a canonical UUID.")
        }
        for (label, value) in [
            ("volumeName", volumeName),
            ("snapshotName", snapshotName)
        ] where value != nil {
            guard StorageSemanticValidation.validIdentifier(
                value!,
                maximumBytes: StorageSemanticLimits.maximumNameBytes
            ) else {
                throw invalid("\(label) is not a bounded stable name.")
            }
        }
        for (label, value) in [
            ("stagingPath", stagingPath),
            ("targetPath", targetPath)
        ] where value != nil {
            guard StorageSemanticValidation.validPath(value!) else {
                throw invalid("\(label) must be an absolute normalized path.")
            }
        }
        if let capacityBytes,
           !(1...StorageSemanticLimits.maximumCapacityBytes)
            .contains(capacityBytes) {
            throw invalid("capacityBytes is outside the supported range.")
        }

        let present: Set<String> = Set([
            volumeID == nil ? nil : "volumeID",
            volumeName == nil ? nil : "volumeName",
            snapshotID == nil ? nil : "snapshotID",
            snapshotName == nil ? nil : "snapshotName",
            capacityBytes == nil ? nil : "capacityBytes",
            topology == nil ? nil : "topology",
            stagingPath == nil ? nil : "stagingPath",
            targetPath == nil ? nil : "targetPath",
            readOnly == nil ? nil : "readOnly",
            accessMode == nil ? nil : "accessMode"
        ].compactMap { $0 })

        func require(_ required: Set<String>, permit: Set<String>) throws {
            guard required.isSubset(of: present) else {
                throw invalid(
                    "Missing fields: \(required.subtracting(present).sorted().joined(separator: ", "))."
                )
            }
            guard present.isSubset(of: permit) else {
                throw invalid(
                    "Unexpected fields: \(present.subtracting(permit).sorted().joined(separator: ", "))."
                )
            }
        }

        switch operation {
        case .create:
            try require(
                ["volumeID", "volumeName", "capacityBytes", "topology", "accessMode"],
                permit: ["volumeID", "volumeName", "capacityBytes", "topology", "accessMode"]
            )
        case .delete:
            try require(["volumeID"], permit: ["volumeID"])
        case .stage:
            try require(
                ["volumeID", "topology", "stagingPath"],
                permit: ["volumeID", "topology", "stagingPath"]
            )
        case .unstage:
            try require(
                ["volumeID", "topology", "stagingPath"],
                permit: ["volumeID", "topology", "stagingPath"]
            )
        case .publish:
            try require(
                ["volumeID", "topology", "stagingPath", "targetPath", "readOnly"],
                permit: ["volumeID", "topology", "stagingPath", "targetPath", "readOnly"]
            )
        case .unpublish:
            try require(
                ["volumeID", "topology", "targetPath"],
                permit: ["volumeID", "topology", "targetPath"]
            )
        case .expand:
            try require(
                ["volumeID", "capacityBytes"],
                permit: ["volumeID", "capacityBytes"]
            )
        case .snapshot:
            try require(
                ["volumeID", "snapshotID", "snapshotName"],
                permit: ["volumeID", "snapshotID", "snapshotName"]
            )
        case .restore:
            try require(
                [
                    "volumeID", "volumeName", "snapshotID",
                    "capacityBytes", "topology", "accessMode"
                ],
                permit: [
                    "volumeID", "volumeName", "snapshotID",
                    "capacityBytes", "topology", "accessMode"
                ]
            )
        case .capacity:
            try require(["topology"], permit: ["topology"])
        case .health:
            try require([], permit: ["volumeID"])
        }
    }

    private func invalid(_ message: String) -> StorageSemanticError {
        StorageSemanticError(
            operation: operation,
            code: .invalidArgument,
            retryClass: .never,
            message: message
        )
    }
}

public struct StorageSemanticVolume: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let providerID: String
    public let generation: Int64
    public let fencingToken: String
    public let capacityBytes: Int64
    public let topology: StorageLocalTopology
    public let accessMode: StorageSemanticAccessMode
    public let health: StorageSemanticHealth
    public let sourceSnapshotID: String?

    public init(
        id: String,
        name: String,
        providerID: String,
        generation: Int64,
        fencingToken: String,
        capacityBytes: Int64,
        topology: StorageLocalTopology,
        accessMode: StorageSemanticAccessMode,
        health: StorageSemanticHealth = .healthy,
        sourceSnapshotID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.generation = generation
        self.fencingToken = fencingToken
        self.capacityBytes = capacityBytes
        self.topology = topology
        self.accessMode = accessMode
        self.health = health
        self.sourceSnapshotID = sourceSnapshotID
    }
}

public struct StorageSemanticAttachment:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let volumeID: String
    public let nodeID: String
    public let kind: StorageSemanticAttachmentKind
    public let path: String
    public let stagingPath: String?
    public let readOnly: Bool

    public init(
        volumeID: String,
        nodeID: String,
        kind: StorageSemanticAttachmentKind,
        path: String,
        stagingPath: String?,
        readOnly: Bool
    ) {
        self.volumeID = volumeID
        self.nodeID = nodeID
        self.kind = kind
        self.path = path
        self.stagingPath = stagingPath
        self.readOnly = readOnly
    }
}

public struct StorageSemanticSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sourceVolumeID: String
    public let sourceGeneration: Int64
    public let capacityBytes: Int64
    public let ready: Bool

    public init(
        id: String,
        name: String,
        sourceVolumeID: String,
        sourceGeneration: Int64,
        capacityBytes: Int64,
        ready: Bool
    ) {
        self.id = id
        self.name = name
        self.sourceVolumeID = sourceVolumeID
        self.sourceGeneration = sourceGeneration
        self.capacityBytes = capacityBytes
        self.ready = ready
    }
}

public struct StorageSemanticState: Codable, Equatable, Sendable {
    public let topology: StorageLocalTopology
    public let totalCapacityBytes: Int64
    public let providerHealth: StorageSemanticHealth
    public let volumes: [StorageSemanticVolume]
    public let attachments: [StorageSemanticAttachment]
    public let snapshots: [StorageSemanticSnapshot]

    public init(
        topology: StorageLocalTopology,
        totalCapacityBytes: Int64,
        providerHealth: StorageSemanticHealth = .healthy,
        volumes: [StorageSemanticVolume] = [],
        attachments: [StorageSemanticAttachment] = [],
        snapshots: [StorageSemanticSnapshot] = []
    ) throws {
        self.topology = topology
        self.totalCapacityBytes = totalCapacityBytes
        self.providerHealth = providerHealth
        self.volumes = volumes.sorted { $0.id < $1.id }
        self.attachments = attachments.sorted {
            ($0.volumeID, $0.nodeID, $0.kind.rawValue, $0.path) <
                ($1.volumeID, $1.nodeID, $1.kind.rawValue, $1.path)
        }
        self.snapshots = snapshots.sorted { $0.id < $1.id }
        try validate()
    }

    public var allocatedCapacityBytes: Int64 {
        volumes.reduce(0) { partial, volume in
            let (sum, overflow) = partial.addingReportingOverflow(
                volume.capacityBytes
            )
            return overflow ? Int64.max : sum
        }
    }

    public var availableCapacityBytes: Int64 {
        let (remaining, overflow) = totalCapacityBytes
            .subtractingReportingOverflow(allocatedCapacityBytes)
        return overflow ? 0 : max(0, remaining)
    }

    func validate() throws {
        func invalid() -> StorageSemanticError {
            StorageSemanticError(
                operation: .health,
                code: .invalidArgument,
                retryClass: .never,
                message: "Storage semantic state contains an invalid identity, topology, capacity, or relationship."
            )
        }

        try topology.validate(operation: .health)
        guard (1...StorageSemanticLimits.maximumCapacityBytes)
            .contains(totalCapacityBytes),
              volumes.count <= StorageSemanticLimits.maximumResources,
              attachments.count <= StorageSemanticLimits.maximumResources,
              snapshots.count <= StorageSemanticLimits.maximumResources,
              Set(volumes.map(\.id)).count == volumes.count,
              Set(volumes.map(\.name)).count == volumes.count,
              Set(snapshots.map(\.id)).count == snapshots.count,
              Set(snapshots.map(\.name)).count == snapshots.count,
              Set(attachments).count == attachments.count else {
            throw invalid()
        }

        var allocated: Int64 = 0
        for volume in volumes {
            guard StorageSemanticValidation.validUUID(volume.id),
                  StorageSemanticValidation.validIdentifier(
                      volume.name,
                      maximumBytes:
                          StorageSemanticLimits.maximumNameBytes
                  ),
                  StorageSemanticValidation.validIdentifier(
                      volume.providerID,
                      maximumBytes:
                          StorageSemanticLimits.maximumProviderIDBytes
                  ),
                  volume.generation > 0,
                  StorageSemanticValidation.validUUID(
                      volume.fencingToken
                  ),
                  (1...StorageSemanticLimits.maximumCapacityBytes)
                    .contains(volume.capacityBytes),
                  volume.topology == topology,
                  volume.capacityBytes <= totalCapacityBytes - allocated,
                  volume.sourceSnapshotID == nil ||
                    StorageSemanticValidation.validUUID(
                        volume.sourceSnapshotID!
                    ) else {
                throw invalid()
            }
            allocated += volume.capacityBytes
        }

        let volumeIDs = Set(volumes.map(\.id))
        for attachment in attachments {
            guard volumeIDs.contains(attachment.volumeID),
                  attachment.nodeID == topology.nodeID,
                  StorageSemanticValidation.validPath(
                      attachment.path
                  ) else {
                throw invalid()
            }
            switch attachment.kind {
            case .stage:
                guard attachment.stagingPath == nil,
                      !attachment.readOnly else {
                    throw invalid()
                }
            case .publish:
                guard let stagingPath = attachment.stagingPath,
                      StorageSemanticValidation.validPath(
                          stagingPath
                      ) else {
                    throw invalid()
                }
            }
        }

        for snapshot in snapshots {
            guard StorageSemanticValidation.validUUID(snapshot.id),
                  StorageSemanticValidation.validIdentifier(
                      snapshot.name,
                      maximumBytes:
                          StorageSemanticLimits.maximumNameBytes
                  ),
                  StorageSemanticValidation.validUUID(
                      snapshot.sourceVolumeID
                  ),
                  snapshot.sourceGeneration > 0,
                  (1...StorageSemanticLimits.maximumCapacityBytes)
                    .contains(snapshot.capacityBytes) else {
                throw invalid()
            }
        }
    }
}

public struct StorageSemanticResult: Codable, Equatable, Sendable {
    public let operation: StorageSemanticOperation
    public let operationID: String
    public let idempotencyKey: String
    public let disposition: StorageSemanticDisposition
    public let retryClass: StorageSemanticRetryClass
    public let volumeID: String?
    public let snapshotID: String?
    public let availableCapacityBytes: Int64?
    public let health: StorageSemanticHealth?

    public init(
        operation: StorageSemanticOperation,
        operationID: String,
        idempotencyKey: String,
        disposition: StorageSemanticDisposition,
        retryClass: StorageSemanticRetryClass,
        volumeID: String? = nil,
        snapshotID: String? = nil,
        availableCapacityBytes: Int64? = nil,
        health: StorageSemanticHealth? = nil
    ) {
        self.operation = operation
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.disposition = disposition
        self.retryClass = retryClass
        self.volumeID = volumeID
        self.snapshotID = snapshotID
        self.availableCapacityBytes = availableCapacityBytes
        self.health = health
    }
}

public struct StorageSemanticTransition: Equatable, Sendable {
    public let result: StorageSemanticResult
    public let state: StorageSemanticState

    public init(
        result: StorageSemanticResult,
        state: StorageSemanticState
    ) {
        self.result = result
        self.state = state
    }
}

enum StorageSemanticValidation {
    static func validUUID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.allSatisfy {
                ("0"..."9").contains($0) || ("a"..."f").contains($0)
            }
    }

    static func validIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.range(
                of: "^[A-Za-z0-9](?:[A-Za-z0-9._:/-]*[A-Za-z0-9])?$",
                options: .regularExpression
            ) != nil
    }

    static func validPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= StorageSemanticLimits.maximumPathBytes,
              value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !value.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).contains("..") else {
            return false
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path == value
    }
}
