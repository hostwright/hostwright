import CryptoKit
import Foundation
import HostwrightCore

public enum StorageProviderContract {
    public static let apiVersion =
        HostwrightContractVersions.storageProviderAPI
    public static let protocolVersion = 1
    public static let maximumRequestBytes = 1 * 1_024 * 1_024
    public static let maximumResultBytes = 8 * 1_024 * 1_024
    public static let maximumDiagnosticBytes = 4_096
    public static let maximumGuidanceBytes = 1_024
    public static let maximumDeadlineWindowMilliseconds: Int64 = 15 * 60 * 1_000
    public static let maximumRememberedRequestIDs = 4_096
}

public enum StorageProviderOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case create
    case observe
    case attach
    case detach
    case snapshot
    case backup
    case restore
    case expand
    case delete
    case health
    case recovery

    public var mutatesProviderState: Bool {
        switch self {
        case .observe, .health:
            false
        case .create,
             .attach,
             .detach,
             .snapshot,
             .backup,
             .restore,
             .expand,
             .delete,
             .recovery:
            true
        }
    }
}

public enum StorageProviderCapabilityState: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case unavailable
    case degraded
    case blocked
}

public struct StorageProviderCapability: Codable, Equatable, Sendable {
    public let operation: StorageProviderOperation
    public let state: StorageProviderCapabilityState
    public let reason: String

    public init(
        operation: StorageProviderOperation,
        state: StorageProviderCapabilityState,
        reason: String
    ) {
        self.operation = operation
        self.state = state
        self.reason = reason
    }
}

public struct StorageProviderDescriptor: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let apiVersion: Int
    public let protocolVersion: Int
    public let providerID: String
    public let providerVersion: String
    public let capabilities: [StorageProviderCapability]
    public let maximumRequestBytes: Int
    public let maximumResultBytes: Int

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        apiVersion: Int = StorageProviderContract.apiVersion,
        protocolVersion: Int = StorageProviderContract.protocolVersion,
        providerID: String,
        providerVersion: String,
        capabilities: [StorageProviderCapability],
        maximumRequestBytes: Int = StorageProviderContract.maximumRequestBytes,
        maximumResultBytes: Int = StorageProviderContract.maximumResultBytes
    ) {
        self.schemaVersion = schemaVersion
        self.apiVersion = apiVersion
        self.protocolVersion = protocolVersion
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.capabilities = capabilities.sorted {
            if $0.operation.rawValue != $1.operation.rawValue {
                return $0.operation.rawValue < $1.operation.rawValue
            }
            if $0.state.rawValue != $1.state.rawValue {
                return $0.state.rawValue < $1.state.rawValue
            }
            return $0.reason < $1.reason
        }
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResultBytes = maximumResultBytes
    }

    public func canonicalSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func capability(for operation: StorageProviderOperation) -> StorageProviderCapability? {
        capabilities.first { $0.operation == operation }
    }
}

public enum StorageProviderCapabilityError: Error, Equatable, Sendable {
    case unadvertised(StorageProviderOperation)
    case unavailable(operation: StorageProviderOperation, reason: String)
    case degraded(operation: StorageProviderOperation, reason: String)
    case blocked(operation: StorageProviderOperation, reason: String)
}

public enum StorageProviderCapabilityNegotiator {
    public static func requireAvailable(
        _ operation: StorageProviderOperation,
        in descriptor: StorageProviderDescriptor
    ) throws {
        guard let capability = descriptor.capability(for: operation) else {
            throw StorageProviderCapabilityError.unadvertised(operation)
        }
        switch capability.state {
        case .available:
            return
        case .unavailable:
            throw StorageProviderCapabilityError.unavailable(
                operation: operation,
                reason: capability.reason
            )
        case .degraded:
            throw StorageProviderCapabilityError.degraded(
                operation: operation,
                reason: capability.reason
            )
        case .blocked:
            throw StorageProviderCapabilityError.blocked(
                operation: operation,
                reason: capability.reason
            )
        }
    }
}

public enum StorageProviderDescriptorError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedAPIVersion(Int)
    case unsupportedProtocolVersion(Int)
    case invalidProviderID
    case invalidProviderVersion
    case invalidRequestBound(Int)
    case invalidResultBound(Int)
    case duplicateCapability(StorageProviderOperation)
    case missingCapability(StorageProviderOperation)
    case invalidCapabilityReason(StorageProviderOperation)
}

public enum StorageProviderDescriptorValidator {
    public static func validate(_ descriptor: StorageProviderDescriptor) throws {
        guard descriptor.schemaVersion == StorageProviderDescriptor.currentSchemaVersion else {
            throw StorageProviderDescriptorError.unsupportedSchemaVersion(descriptor.schemaVersion)
        }
        guard descriptor.apiVersion == StorageProviderContract.apiVersion else {
            throw StorageProviderDescriptorError.unsupportedAPIVersion(descriptor.apiVersion)
        }
        guard descriptor.protocolVersion == StorageProviderContract.protocolVersion else {
            throw StorageProviderDescriptorError.unsupportedProtocolVersion(descriptor.protocolVersion)
        }
        guard validIdentifier(descriptor.providerID) else {
            throw StorageProviderDescriptorError.invalidProviderID
        }
        guard validVersion(descriptor.providerVersion) else {
            throw StorageProviderDescriptorError.invalidProviderVersion
        }
        guard descriptor.maximumRequestBytes > 0,
              descriptor.maximumRequestBytes <= StorageProviderContract.maximumRequestBytes else {
            throw StorageProviderDescriptorError.invalidRequestBound(descriptor.maximumRequestBytes)
        }
        guard descriptor.maximumResultBytes > 0,
              descriptor.maximumResultBytes <= StorageProviderContract.maximumResultBytes else {
            throw StorageProviderDescriptorError.invalidResultBound(descriptor.maximumResultBytes)
        }

        var seen = Set<StorageProviderOperation>()
        for capability in descriptor.capabilities {
            guard seen.insert(capability.operation).inserted else {
                throw StorageProviderDescriptorError.duplicateCapability(capability.operation)
            }
            guard validReason(capability.reason) else {
                throw StorageProviderDescriptorError.invalidCapabilityReason(capability.operation)
            }
        }
        for operation in StorageProviderOperation.allCases where !seen.contains(operation) {
            throw StorageProviderDescriptorError.missingCapability(operation)
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count >= 3 &&
            value.utf8.count <= 128 &&
            value.range(
                of: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$",
                options: .regularExpression
            ) != nil
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 128 &&
            value.unicodeScalars.allSatisfy {
                $0.isASCII && !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func validReason(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 512 &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public struct StorageProviderMutationContext: Codable, Equatable, Sendable {
    public let projectUUID: UUID
    public let projectGeneration: Int
    public let resourceUUID: UUID
    public let resourceGeneration: Int
    public let attachmentGeneration: Int?
    public let fencingToken: UUID

    public init(
        projectUUID: UUID,
        projectGeneration: Int,
        resourceUUID: UUID,
        resourceGeneration: Int,
        attachmentGeneration: Int? = nil,
        fencingToken: UUID
    ) {
        self.projectUUID = projectUUID
        self.projectGeneration = projectGeneration
        self.resourceUUID = resourceUUID
        self.resourceGeneration = resourceGeneration
        self.attachmentGeneration = attachmentGeneration
        self.fencingToken = fencingToken
    }

    public var isValid: Bool {
        projectGeneration > 0 &&
            resourceGeneration > 0 &&
            (attachmentGeneration == nil || attachmentGeneration! > 0)
    }

    private enum CodingKeys: String, CodingKey {
        case projectUUID
        case projectGeneration
        case resourceUUID
        case resourceGeneration
        case attachmentGeneration
        case fencingToken
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectUUID = try Self.decodeCanonicalUUID(from: values, forKey: .projectUUID)
        projectGeneration = try values.decode(Int.self, forKey: .projectGeneration)
        resourceUUID = try Self.decodeCanonicalUUID(from: values, forKey: .resourceUUID)
        resourceGeneration = try values.decode(Int.self, forKey: .resourceGeneration)
        attachmentGeneration = try values.decodeIfPresent(Int.self, forKey: .attachmentGeneration)
        fencingToken = try Self.decodeCanonicalUUID(from: values, forKey: .fencingToken)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(projectUUID.uuidString.lowercased(), forKey: .projectUUID)
        try values.encode(projectGeneration, forKey: .projectGeneration)
        try values.encode(resourceUUID.uuidString.lowercased(), forKey: .resourceUUID)
        try values.encode(resourceGeneration, forKey: .resourceGeneration)
        try values.encodeIfPresent(attachmentGeneration, forKey: .attachmentGeneration)
        try values.encode(fencingToken.uuidString.lowercased(), forKey: .fencingToken)
    }

    private static func decodeCanonicalUUID(
        from values: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID {
        let value = try values.decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw StorageProviderProtocolError.invalidMutationContext
        }
        return uuid
    }
}

public struct StorageProviderRequest<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: StorageProviderOperation
    public let deadlineUnixMilliseconds: Int64
    public let capabilitySHA256: String
    public let idempotencyKey: String
    public let mutationContext: StorageProviderMutationContext?
    public let payload: Payload

    public init(
        protocolVersion: Int = StorageProviderContract.protocolVersion,
        requestID: UUID = UUID(),
        operation: StorageProviderOperation,
        deadlineUnixMilliseconds: Int64,
        capabilitySHA256: String,
        idempotencyKey: String,
        mutationContext: StorageProviderMutationContext? = nil,
        payload: Payload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.capabilitySHA256 = capabilitySHA256
        self.idempotencyKey = idempotencyKey
        self.mutationContext = mutationContext
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
        case deadlineUnixMilliseconds = "deadline"
        case capabilitySHA256
        case idempotencyKey
        case mutationContext
        case payload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        requestID = try Self.decodeCanonicalUUID(from: values, forKey: .requestID)
        operation = try values.decode(StorageProviderOperation.self, forKey: .operation)
        deadlineUnixMilliseconds = try values.decode(Int64.self, forKey: .deadlineUnixMilliseconds)
        capabilitySHA256 = try values.decode(String.self, forKey: .capabilitySHA256)
        idempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
        mutationContext = try values.decodeIfPresent(
            StorageProviderMutationContext.self,
            forKey: .mutationContext
        )
        payload = try values.decode(Payload.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(operation, forKey: .operation)
        try values.encode(deadlineUnixMilliseconds, forKey: .deadlineUnixMilliseconds)
        try values.encode(capabilitySHA256, forKey: .capabilitySHA256)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encodeIfPresent(mutationContext, forKey: .mutationContext)
        try values.encode(payload, forKey: .payload)
    }

    private static func decodeCanonicalUUID(
        from values: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID {
        let value = try values.decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw StorageProviderProtocolError.invalidRequestID
        }
        return uuid
    }
}

extension StorageProviderRequest: Equatable where Payload: Equatable {}

public struct StorageProviderResultEnvelope<ResultPayload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: StorageProviderOperation
    public let result: ResultPayload

    public init(
        protocolVersion: Int = StorageProviderContract.protocolVersion,
        requestID: UUID,
        operation: StorageProviderOperation,
        result: ResultPayload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
        case result
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        requestID = try Self.decodeCanonicalUUID(from: values, forKey: .requestID)
        operation = try values.decode(StorageProviderOperation.self, forKey: .operation)
        result = try values.decode(ResultPayload.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(operation, forKey: .operation)
        try values.encode(result, forKey: .result)
    }

    private static func decodeCanonicalUUID(
        from values: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID {
        let value = try values.decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw StorageProviderProtocolError.invalidRequestID
        }
        return uuid
    }
}

extension StorageProviderResultEnvelope: Equatable where ResultPayload: Equatable {}

public enum StorageProviderFailureCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case invalidRequest = "invalid-request"
    case incompatible
    case unavailable
    case permissionDenied = "permission-denied"
    case rejected
    case timedOut = "timed-out"
    case cancelled
    case outputLimited = "output-limited"
    case crashed
    case staleGeneration = "stale-generation"
    case fencingConflict = "fencing-conflict"
    case replayedRequest = "replayed-request"
    case ambiguousEffect = "ambiguous-effect"
    case internalFailure = "internal-failure"
}

public enum StorageProviderRetryDisposition: String, Codable, Equatable, Sendable {
    case never
    case safeAfterObservation = "safe-after-observation"
    case resumeFromCheckpoint = "resume-from-checkpoint"
}

public enum StorageProviderRecoveryDisposition: String, Codable, Equatable, Sendable {
    case none
    case reobserve
    case resume
    case compensate
    case safeHold = "safe-hold"
}

public struct StorageProviderFailure: Codable, Equatable, Sendable {
    public let category: StorageProviderFailureCategory
    public let retryDisposition: StorageProviderRetryDisposition
    public let recoveryDisposition: StorageProviderRecoveryDisposition
    public let diagnostic: String
    public let guidance: String

    public init(
        category: StorageProviderFailureCategory,
        retryDisposition: StorageProviderRetryDisposition,
        recoveryDisposition: StorageProviderRecoveryDisposition,
        diagnostic: String,
        guidance: String,
        sensitiveValues: [String] = []
    ) {
        self.category = category
        self.retryDisposition = retryDisposition
        self.recoveryDisposition = recoveryDisposition
        self.diagnostic = Self.bounded(
            Self.redacted(diagnostic, exactValues: sensitiveValues),
            maximumBytes: StorageProviderContract.maximumDiagnosticBytes
        )
        self.guidance = Self.bounded(
            Self.redacted(guidance, exactValues: sensitiveValues),
            maximumBytes: StorageProviderContract.maximumGuidanceBytes
        )
    }

    public var requiresObservationBeforeRetry: Bool {
        retryDisposition == .safeAfterObservation ||
            category == .timedOut ||
            category == .cancelled ||
            category == .crashed ||
            category == .ambiguousEffect
    }

    private static func redacted(_ value: String, exactValues: [String]) -> String {
        exactValues
            .filter { !$0.isEmpty }
            .reduce(value) { partial, secret in
                partial.replacingOccurrences(of: secret, with: "<redacted>")
            }
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else {
            return value
        }

        var byteCount = 0
        var endIndex = value.startIndex
        while endIndex < value.endIndex {
            let nextIndex = value.index(after: endIndex)
            let characterBytes = value[endIndex..<nextIndex].utf8.count
            guard byteCount + characterBytes <= maximumBytes else {
                break
            }
            byteCount += characterBytes
            endIndex = nextIndex
        }
        return String(value[..<endIndex])
    }
}

public struct StorageProviderErrorEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: StorageProviderOperation
    public let failure: StorageProviderFailure

    public init(
        protocolVersion: Int = StorageProviderContract.protocolVersion,
        requestID: UUID,
        operation: StorageProviderOperation,
        failure: StorageProviderFailure
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
        case failure
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        let value = try values.decode(String.self, forKey: .requestID)
        guard let requestID = UUID(uuidString: value),
              requestID.uuidString.lowercased() == value else {
            throw StorageProviderProtocolError.invalidRequestID
        }
        self.requestID = requestID
        operation = try values.decode(StorageProviderOperation.self, forKey: .operation)
        failure = try values.decode(StorageProviderFailure.self, forKey: .failure)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(operation, forKey: .operation)
        try values.encode(failure, forKey: .failure)
    }
}
