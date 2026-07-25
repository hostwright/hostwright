import CryptoKit
import Foundation

public enum RuntimeImageLifecycleOperation: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pull
    case build
    case push
    case tag
    case load
    case save
    case inspect
    case delete
    case prune
}

public enum RuntimeImageLifecycleContractError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unknownField(String)
    case invalidOperationID
    case invalidIdempotencyKey
    case invalidCapabilitySHA256
    case missingField(operation: RuntimeImageLifecycleOperation, field: String)
    case unexpectedField(operation: RuntimeImageLifecycleOperation, field: String)
    case invalidReference(String)
    case invalidPath(String)
    case invalidPlatform
    case invalidOutputLimit
    case invalidPruneCutoff
    case requestTooLarge
    case invalidCapabilityContract
    case unavailable(operation: RuntimeImageLifecycleOperation, reason: RuntimeImageOperationCapabilityReason)
    case invalidDigest(String)
    case invalidImageRecord
    case invalidResult
    case invalidProgress
}

public struct RuntimeImageReferenceDigest: Codable, Equatable, Sendable {
    public let reference: String
    public let digest: String

    public init(reference: String, digest: String) throws {
        self.reference = try RuntimeImageLifecycleContract.validatedReference(
            reference
        )
        self.digest = try RuntimeImageLifecycleContract.validatedDigest(digest)
    }
}

public struct RuntimeImagePartialEffectError: Error, Equatable, Sendable {
    public let operation: RuntimeImageLifecycleOperation
    public let createdReferences: [RuntimeImageReferenceDigest]
    public let unrestorableChange: Bool

    public init(
        operation: RuntimeImageLifecycleOperation,
        createdReferences: [RuntimeImageReferenceDigest],
        unrestorableChange: Bool = false
    ) throws {
        let sorted = createdReferences.sorted {
            ($0.reference, $0.digest) < ($1.reference, $1.digest)
        }
        guard (!sorted.isEmpty || unrestorableChange),
              Set(sorted.map(\.reference)).count == sorted.count,
              sorted.count <=
                RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest
        else {
            throw RuntimeImageLifecycleContractError.invalidResult
        }
        self.operation = operation
        self.createdReferences = sorted
        self.unrestorableChange = unrestorableChange
    }
}

public enum RuntimeImageLifecycleLimits {
    public static let maximumRequestBytes = 64 * 1_024
    public static let maximumReferenceBytes = 4_096
    public static let maximumPathBytes = 4_096
    public static let maximumProviderValueBytes = 256
    public static let maximumOutputBytes = 8 * 1_024 * 1_024
    public static let defaultOutputBytes = 1 * 1_024 * 1_024
    public static let maximumSourceReferencesPerRequest = 256
    public static let maximumReferencesPerImage = 256
    public static let maximumVariantsPerImage = 64
    public static let maximumLayersPerImage = 512
    public static let maximumImagesPerResult = 10_000
    public static let maximumDeletedDigestsPerResult = 10_000
    public static let maximumProgressEvents = 100_000
}

public enum RuntimeImageLifecycleContract {
    public static func validatedReference(_ value: String) throws -> String {
        guard RuntimeImageLifecycleValidation.validReference(value) else {
            throw RuntimeImageLifecycleContractError.invalidReference(value)
        }
        return value
    }

    public static func validatedAbsolutePath(_ value: String) throws -> String {
        guard RuntimeImageLifecycleValidation.validAbsoluteNormalizedPath(value) else {
            throw RuntimeImageLifecycleContractError.invalidPath(value)
        }
        return value
    }

    public static func validatedDigest(_ value: String) throws -> String {
        guard RuntimeImageLifecycleValidation.validOCIDigest(value) else {
            throw RuntimeImageLifecycleContractError.invalidDigest(value)
        }
        return value
    }

    public static func parsedPlatform(
        _ value: String?
    ) throws -> (operatingSystem: String?, architecture: String?) {
        guard let value else {
            return (nil, nil)
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw RuntimeImageLifecycleContractError.invalidPlatform
        }
        let operatingSystem = String(parts[0])
        let architecture = String(parts[1])
        try RuntimeImageLifecycleValidation.validatePlatform(
            operatingSystem: operatingSystem,
            architecture: architecture
        )
        return (operatingSystem, architecture)
    }
}

public struct RuntimeImageLifecycleRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operation: RuntimeImageLifecycleOperation
    public let operationID: String
    public let idempotencyKey: String
    public let capabilitySHA256: String
    public let sourceReferences: [String]
    public let expectedSourceDigests: [String: String]
    public let targetReference: String?
    public let contextPath: String?
    public let dockerfilePath: String?
    public let archivePath: String?
    public let platformOS: String?
    public let platformArchitecture: String?
    public let offline: Bool
    public let noCache: Bool
    public let maximumOutputBytes: Int

    public init(
        schemaVersion: Int = RuntimeImageLifecycleRequest.currentSchemaVersion,
        operation: RuntimeImageLifecycleOperation,
        operationID: String,
        idempotencyKey: String,
        capabilitySHA256: String,
        sourceReferences: [String] = [],
        expectedSourceDigests: [String: String] = [:],
        targetReference: String? = nil,
        contextPath: String? = nil,
        dockerfilePath: String? = nil,
        archivePath: String? = nil,
        platformOS: String? = nil,
        platformArchitecture: String? = nil,
        offline: Bool = false,
        noCache: Bool = false,
        maximumOutputBytes: Int = RuntimeImageLifecycleLimits.defaultOutputBytes
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RuntimeImageLifecycleContractError.unsupportedSchemaVersion(schemaVersion)
        }
        guard RuntimeImageLifecycleValidation.validOperationID(operationID) else {
            throw RuntimeImageLifecycleContractError.invalidOperationID
        }
        guard RuntimeImageLifecycleValidation.validSHA256(idempotencyKey) else {
            throw RuntimeImageLifecycleContractError.invalidIdempotencyKey
        }
        guard RuntimeImageLifecycleValidation.validSHA256(capabilitySHA256) else {
            throw RuntimeImageLifecycleContractError.invalidCapabilitySHA256
        }
        guard (1...RuntimeImageLifecycleLimits.maximumOutputBytes).contains(maximumOutputBytes) else {
            throw RuntimeImageLifecycleContractError.invalidOutputLimit
        }

        let normalizedSourceReferences = Array(Set(sourceReferences)).sorted()
        guard sourceReferences.count == normalizedSourceReferences.count,
              normalizedSourceReferences.count <=
                RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest else {
            throw RuntimeImageLifecycleContractError.invalidReference(
                sourceReferences.first ?? ""
            )
        }
        for value in normalizedSourceReferences + [targetReference].compactMap({ $0 }) {
            guard RuntimeImageLifecycleValidation.validReference(value) else {
                throw RuntimeImageLifecycleContractError.invalidReference(value)
            }
        }
        guard expectedSourceDigests.keys.allSatisfy({
            RuntimeImageLifecycleValidation.validReference($0)
        }),
        expectedSourceDigests.values.allSatisfy(
            RuntimeImageLifecycleValidation.validOCIDigest
        ) else {
            throw RuntimeImageLifecycleContractError.invalidResult
        }
        for value in [contextPath, dockerfilePath, archivePath].compactMap({ $0 }) {
            guard RuntimeImageLifecycleValidation.validAbsoluteNormalizedPath(value) else {
                throw RuntimeImageLifecycleContractError.invalidPath(value)
            }
        }
        if let contextPath, let dockerfilePath {
            let prefix = contextPath == "/" ? "/" : contextPath + "/"
            guard dockerfilePath.hasPrefix(prefix) else {
                throw RuntimeImageLifecycleContractError.invalidPath(dockerfilePath)
            }
        }
        try RuntimeImageLifecycleValidation.validatePlatform(
            operatingSystem: platformOS,
            architecture: platformArchitecture
        )

        self.schemaVersion = schemaVersion
        self.operation = operation
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.capabilitySHA256 = capabilitySHA256
        self.sourceReferences = normalizedSourceReferences
        self.expectedSourceDigests = expectedSourceDigests
        self.targetReference = targetReference
        self.contextPath = contextPath
        self.dockerfilePath = dockerfilePath
        self.archivePath = archivePath
        self.platformOS = platformOS
        self.platformArchitecture = platformArchitecture
        self.offline = offline
        self.noCache = noCache
        self.maximumOutputBytes = maximumOutputBytes

        try validateOperationFields()
        guard try canonicalJSONData().count <= RuntimeImageLifecycleLimits.maximumRequestBytes else {
            throw RuntimeImageLifecycleContractError.requestTooLarge
        }
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func planSHA256() throws -> String {
        RuntimeImageLifecycleValidation.sha256(try canonicalJSONData())
    }

    private func validateOperationFields() throws {
        let present: [String: Bool] = [
            "sourceReferences": !sourceReferences.isEmpty,
            "expectedSourceDigests": !expectedSourceDigests.isEmpty,
            "targetReference": targetReference != nil,
            "contextPath": contextPath != nil,
            "dockerfilePath": dockerfilePath != nil,
            "archivePath": archivePath != nil,
            "platform": platformOS != nil || platformArchitecture != nil,
            "offline": offline,
            "noCache": noCache
        ]

        func require(_ field: String) throws {
            guard present[field] == true else {
                throw RuntimeImageLifecycleContractError.missingField(
                    operation: operation,
                    field: field
                )
            }
        }

        func permit(_ permitted: Set<String>) throws {
            for field in present.keys.sorted() where present[field] == true && !permitted.contains(field) {
                throw RuntimeImageLifecycleContractError.unexpectedField(
                    operation: operation,
                    field: field
                )
            }
        }

        switch operation {
        case .pull:
            try requireSourceCardinality(1...1)
            try permit(["sourceReferences", "platform", "offline"])
        case .build:
            try requireSourceCardinality(0...0)
            try require("targetReference")
            try require("contextPath")
            try permit([
                "targetReference",
                "contextPath",
                "dockerfilePath",
                "platform",
                "offline",
                "noCache"
            ])
        case .push:
            try requireSourceCardinality(1...1)
            try require("targetReference")
            try requireExpectedSourceDigests()
            try permit([
                "sourceReferences",
                "expectedSourceDigests",
                "targetReference",
                "platform",
                "offline"
            ])
            guard targetReference == sourceReferences[0] else {
                throw RuntimeImageLifecycleContractError.invalidReference(
                    targetReference ?? ""
                )
            }
        case .tag:
            try requireSourceCardinality(1...1)
            try require("targetReference")
            try requireExpectedSourceDigests()
            try permit([
                "sourceReferences",
                "expectedSourceDigests",
                "targetReference"
            ])
        case .load:
            try requireSourceCardinality(
                1...RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest
            )
            try require("archivePath")
            try permit(["sourceReferences", "archivePath"])
        case .save:
            try requireSourceCardinality(
                1...RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest
            )
            try require("archivePath")
            try requireExpectedSourceDigests()
            try permit([
                "sourceReferences",
                "expectedSourceDigests",
                "archivePath",
                "platform"
            ])
        case .inspect:
            try requireSourceCardinality(
                1...RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest
            )
            try permit(["sourceReferences"])
        case .delete:
            try requireSourceCardinality(
                0...RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest
            )
            try requireExpectedSourceDigests()
            try permit(["sourceReferences", "expectedSourceDigests"])
        case .prune:
            try requireSourceCardinality(
                0...RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest
            )
            try requireExpectedSourceDigests()
            try permit(["sourceReferences", "expectedSourceDigests"])
        }

        func requireSourceCardinality(_ accepted: ClosedRange<Int>) throws {
            guard accepted.contains(sourceReferences.count) else {
                let field = "sourceReferences[\(accepted.lowerBound)...\(accepted.upperBound)]"
                if sourceReferences.isEmpty {
                    throw RuntimeImageLifecycleContractError.missingField(
                        operation: operation,
                        field: field
                    )
                }
                throw RuntimeImageLifecycleContractError.unexpectedField(
                    operation: operation,
                    field: field
                )
            }
        }

        func requireExpectedSourceDigests() throws {
            guard Set(expectedSourceDigests.keys) ==
                    Set(sourceReferences) else {
                let field = "expectedSourceDigests"
                if expectedSourceDigests.isEmpty {
                    throw RuntimeImageLifecycleContractError.missingField(
                        operation: operation,
                        field: field
                    )
                }
                throw RuntimeImageLifecycleContractError.unexpectedField(
                    operation: operation,
                    field: field
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case operation
        case operationID
        case idempotencyKey
        case capabilitySHA256
        case sourceReferences
        case expectedSourceDigests
        case targetReference
        case contextPath
        case dockerfilePath
        case archivePath
        case platformOS
        case platformArchitecture
        case offline
        case noCache
        case maximumOutputBytes
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: RuntimeImageDynamicCodingKey.self)
        let accepted = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = raw.allKeys.map(\.stringValue).filter({ !accepted.contains($0) }).sorted().first {
            throw RuntimeImageLifecycleContractError.unknownField(unknown)
        }

        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            operation: try values.decode(RuntimeImageLifecycleOperation.self, forKey: .operation),
            operationID: try values.decode(String.self, forKey: .operationID),
            idempotencyKey: try values.decode(String.self, forKey: .idempotencyKey),
            capabilitySHA256: try values.decode(String.self, forKey: .capabilitySHA256),
            sourceReferences: try values.decode([String].self, forKey: .sourceReferences),
            expectedSourceDigests: try values.decode(
                [String: String].self,
                forKey: .expectedSourceDigests
            ),
            targetReference: try values.decodeIfPresent(String.self, forKey: .targetReference),
            contextPath: try values.decodeIfPresent(String.self, forKey: .contextPath),
            dockerfilePath: try values.decodeIfPresent(String.self, forKey: .dockerfilePath),
            archivePath: try values.decodeIfPresent(String.self, forKey: .archivePath),
            platformOS: try values.decodeIfPresent(String.self, forKey: .platformOS),
            platformArchitecture: try values.decodeIfPresent(
                String.self,
                forKey: .platformArchitecture
            ),
            offline: try values.decode(Bool.self, forKey: .offline),
            noCache: try values.decode(Bool.self, forKey: .noCache),
            maximumOutputBytes: try values.decode(Int.self, forKey: .maximumOutputBytes)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(operation, forKey: .operation)
        try values.encode(operationID, forKey: .operationID)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encode(capabilitySHA256, forKey: .capabilitySHA256)
        try values.encode(sourceReferences, forKey: .sourceReferences)
        try values.encode(
            expectedSourceDigests,
            forKey: .expectedSourceDigests
        )
        try values.encodeIfPresent(targetReference, forKey: .targetReference)
        try values.encodeIfPresent(contextPath, forKey: .contextPath)
        try values.encodeIfPresent(dockerfilePath, forKey: .dockerfilePath)
        try values.encodeIfPresent(archivePath, forKey: .archivePath)
        try values.encodeIfPresent(platformOS, forKey: .platformOS)
        try values.encodeIfPresent(platformArchitecture, forKey: .platformArchitecture)
        try values.encode(offline, forKey: .offline)
        try values.encode(noCache, forKey: .noCache)
        try values.encode(maximumOutputBytes, forKey: .maximumOutputBytes)
    }
}

public enum RuntimeImageOperationCapabilityReason: String, Codable, CaseIterable, Equatable, Sendable {
    case implemented
    case qualificationIncomplete = "qualification-incomplete"
    case providerUnavailable = "provider-unavailable"
    case providerUnsupported = "provider-unsupported"
    case platformUnsupported = "platform-unsupported"
    case policyBlocked = "policy-blocked"
}

public struct RuntimeImageOperationCapability: Codable, Equatable, Sendable {
    public let operation: RuntimeImageLifecycleOperation
    public let state: RuntimeProviderCapabilityState
    public let reason: RuntimeImageOperationCapabilityReason

    public init(
        operation: RuntimeImageLifecycleOperation,
        state: RuntimeProviderCapabilityState,
        reason: RuntimeImageOperationCapabilityReason
    ) {
        self.operation = operation
        self.state = state
        self.reason = reason
    }
}

public struct RuntimeImageOperationCapabilityContract: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let providerID: RuntimeProviderID
    public let capabilitySHA256: String
    public let operations: [RuntimeImageOperationCapability]

    public init(
        schemaVersion: Int = RuntimeImageOperationCapabilityContract.currentSchemaVersion,
        providerID: RuntimeProviderID,
        capabilitySHA256: String,
        operations: [RuntimeImageOperationCapability]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              RuntimeImageLifecycleValidation.validProviderID(providerID),
              RuntimeImageLifecycleValidation.validSHA256(capabilitySHA256),
              operations.count == RuntimeImageLifecycleOperation.allCases.count,
              Set(operations.map(\.operation)).count == operations.count,
              Set(operations.map(\.operation)) == Set(RuntimeImageLifecycleOperation.allCases),
              operations.allSatisfy(Self.validStatus) else {
            throw RuntimeImageLifecycleContractError.invalidCapabilityContract
        }
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.capabilitySHA256 = capabilitySHA256
        self.operations = operations.sorted { $0.operation.rawValue < $1.operation.rawValue }
    }

    public func status(
        for operation: RuntimeImageLifecycleOperation
    ) -> RuntimeImageOperationCapability {
        operations.first(where: { $0.operation == operation })!
    }

    public func requireAvailable(_ operation: RuntimeImageLifecycleOperation) throws {
        let status = status(for: operation)
        guard status.state == .available, status.reason == .implemented else {
            throw RuntimeImageLifecycleContractError.unavailable(
                operation: operation,
                reason: status.reason
            )
        }
    }

    private static func validStatus(_ status: RuntimeImageOperationCapability) -> Bool {
        if status.state == .available {
            return status.reason == .implemented
        }
        return status.reason != .implemented
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case providerID
        case capabilitySHA256
        case operations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            providerID: try values.decode(RuntimeProviderID.self, forKey: .providerID),
            capabilitySHA256: try values.decode(String.self, forKey: .capabilitySHA256),
            operations: try values.decode(
                [RuntimeImageOperationCapability].self,
                forKey: .operations
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(capabilitySHA256, forKey: .capabilitySHA256)
        try values.encode(operations, forKey: .operations)
    }
}

public struct RuntimeImageVariantRecord: Codable, Equatable, Sendable {
    public let digest: String
    public let operatingSystem: String
    public let architecture: String
    public let sizeBytes: Int64
    public let layerDigests: [String]

    public init(
        digest: String,
        operatingSystem: String,
        architecture: String,
        sizeBytes: Int64,
        layerDigests: [String] = []
    ) throws {
        let normalizedLayers = Array(Set(layerDigests)).sorted()
        guard RuntimeImageLifecycleValidation.validOCIDigest(digest),
              sizeBytes >= 0,
              layerDigests.count == normalizedLayers.count,
              normalizedLayers.count <= RuntimeImageLifecycleLimits.maximumLayersPerImage,
              normalizedLayers.allSatisfy(RuntimeImageLifecycleValidation.validOCIDigest) else {
            throw RuntimeImageLifecycleContractError.invalidImageRecord
        }
        try RuntimeImageLifecycleValidation.validatePlatform(
            operatingSystem: operatingSystem,
            architecture: architecture
        )
        self.digest = digest
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.sizeBytes = sizeBytes
        self.layerDigests = normalizedLayers
    }

    private enum CodingKeys: String, CodingKey {
        case digest
        case operatingSystem
        case architecture
        case sizeBytes
        case layerDigests
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            digest: try values.decode(String.self, forKey: .digest),
            operatingSystem: try values.decode(String.self, forKey: .operatingSystem),
            architecture: try values.decode(String.self, forKey: .architecture),
            sizeBytes: try values.decode(Int64.self, forKey: .sizeBytes),
            layerDigests: try values.decode([String].self, forKey: .layerDigests)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(digest, forKey: .digest)
        try values.encode(operatingSystem, forKey: .operatingSystem)
        try values.encode(architecture, forKey: .architecture)
        try values.encode(sizeBytes, forKey: .sizeBytes)
        try values.encode(layerDigests, forKey: .layerDigests)
    }
}

public struct RuntimeImageRecord: Codable, Equatable, Sendable {
    public let digest: String
    public let references: [String]
    public let mediaType: String
    public let sizeBytes: Int64
    public let variants: [RuntimeImageVariantRecord]
    public let createdAtUnixSeconds: Int64?

    public init(
        digest: String,
        references: [String],
        mediaType: String,
        sizeBytes: Int64,
        variants: [RuntimeImageVariantRecord],
        createdAtUnixSeconds: Int64? = nil
    ) throws {
        let normalizedReferences = Array(Set(references)).sorted()
        let sortedVariants = variants.sorted(by: Self.variantOrder)
        let platformKeys = Set(variants.map { "\($0.operatingSystem)/\($0.architecture)" })
        guard RuntimeImageLifecycleValidation.validOCIDigest(digest),
              !mediaType.isEmpty,
              mediaType.utf8.count <= RuntimeImageLifecycleLimits.maximumProviderValueBytes,
              !RuntimeImageLifecycleValidation.hasControlCharacter(mediaType),
              sizeBytes >= 0,
              references.count == normalizedReferences.count,
              normalizedReferences.count <= RuntimeImageLifecycleLimits.maximumReferencesPerImage,
              normalizedReferences.allSatisfy(RuntimeImageLifecycleValidation.validReference),
              !variants.isEmpty,
              variants.count <= RuntimeImageLifecycleLimits.maximumVariantsPerImage,
              Set(variants.map(\.digest)).count == variants.count,
              platformKeys.count == variants.count,
              createdAtUnixSeconds.map({ $0 >= 0 }) ?? true else {
            throw RuntimeImageLifecycleContractError.invalidImageRecord
        }
        self.digest = digest
        self.references = normalizedReferences
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.variants = sortedVariants
        self.createdAtUnixSeconds = createdAtUnixSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case digest
        case references
        case mediaType
        case sizeBytes
        case variants
        case createdAtUnixSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            digest: try values.decode(String.self, forKey: .digest),
            references: try values.decode([String].self, forKey: .references),
            mediaType: try values.decode(String.self, forKey: .mediaType),
            sizeBytes: try values.decode(Int64.self, forKey: .sizeBytes),
            variants: try values.decode([RuntimeImageVariantRecord].self, forKey: .variants),
            createdAtUnixSeconds: try values.decodeIfPresent(
                Int64.self,
                forKey: .createdAtUnixSeconds
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(digest, forKey: .digest)
        try values.encode(references, forKey: .references)
        try values.encode(mediaType, forKey: .mediaType)
        try values.encode(sizeBytes, forKey: .sizeBytes)
        try values.encode(variants, forKey: .variants)
        try values.encodeIfPresent(createdAtUnixSeconds, forKey: .createdAtUnixSeconds)
    }

    private static func variantOrder(
        _ lhs: RuntimeImageVariantRecord,
        _ rhs: RuntimeImageVariantRecord
    ) -> Bool {
        (lhs.operatingSystem, lhs.architecture, lhs.digest) <
            (rhs.operatingSystem, rhs.architecture, rhs.digest)
    }
}

public enum RuntimeImageOperationDisposition: String, Codable, Equatable, Sendable {
    case succeeded
    case unchanged
}

public struct RuntimeImageOperationResult: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operation: RuntimeImageLifecycleOperation
    public let operationID: String
    public let idempotencyKey: String
    public let planSHA256: String
    public let providerID: RuntimeProviderID
    public let providerVersion: String
    public let disposition: RuntimeImageOperationDisposition
    public let images: [RuntimeImageRecord]
    public let deletedDigests: [String]
    public let reclaimedBytes: Int64

    public init(
        schemaVersion: Int = RuntimeImageOperationResult.currentSchemaVersion,
        operation: RuntimeImageLifecycleOperation,
        operationID: String,
        idempotencyKey: String,
        planSHA256: String,
        providerID: RuntimeProviderID,
        providerVersion: String,
        disposition: RuntimeImageOperationDisposition,
        images: [RuntimeImageRecord] = [],
        deletedDigests: [String] = [],
        reclaimedBytes: Int64 = 0
    ) throws {
        let sortedImages = images.sorted {
            ($0.digest, $0.references.joined(separator: "\u{0}")) <
                ($1.digest, $1.references.joined(separator: "\u{0}"))
        }
        let sortedDeleted = Array(Set(deletedDigests)).sorted()
        guard schemaVersion == Self.currentSchemaVersion,
              RuntimeImageLifecycleValidation.validOperationID(operationID),
              RuntimeImageLifecycleValidation.validSHA256(idempotencyKey),
              RuntimeImageLifecycleValidation.validSHA256(planSHA256),
              RuntimeImageLifecycleValidation.validProviderID(providerID),
              !providerVersion.isEmpty,
              providerVersion.utf8.count <= RuntimeImageLifecycleLimits.maximumProviderValueBytes,
              !RuntimeImageLifecycleValidation.hasControlCharacter(providerVersion),
              images.count <= RuntimeImageLifecycleLimits.maximumImagesPerResult,
              Set(images.map(\.digest)).count == images.count,
              deletedDigests.count == sortedDeleted.count,
              sortedDeleted.count <= RuntimeImageLifecycleLimits.maximumDeletedDigestsPerResult,
              sortedDeleted.allSatisfy(RuntimeImageLifecycleValidation.validOCIDigest),
              reclaimedBytes >= 0 else {
            throw RuntimeImageLifecycleContractError.invalidResult
        }
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.planSHA256 = planSHA256
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.disposition = disposition
        self.images = sortedImages
        self.deletedDigests = sortedDeleted
        self.reclaimedBytes = reclaimedBytes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operation
        case operationID
        case idempotencyKey
        case planSHA256
        case providerID
        case providerVersion
        case disposition
        case images
        case deletedDigests
        case reclaimedBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            operation: try values.decode(RuntimeImageLifecycleOperation.self, forKey: .operation),
            operationID: try values.decode(String.self, forKey: .operationID),
            idempotencyKey: try values.decode(String.self, forKey: .idempotencyKey),
            planSHA256: try values.decode(String.self, forKey: .planSHA256),
            providerID: try values.decode(RuntimeProviderID.self, forKey: .providerID),
            providerVersion: try values.decode(String.self, forKey: .providerVersion),
            disposition: try values.decode(
                RuntimeImageOperationDisposition.self,
                forKey: .disposition
            ),
            images: try values.decode([RuntimeImageRecord].self, forKey: .images),
            deletedDigests: try values.decode([String].self, forKey: .deletedDigests),
            reclaimedBytes: try values.decode(Int64.self, forKey: .reclaimedBytes)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(operation, forKey: .operation)
        try values.encode(operationID, forKey: .operationID)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encode(planSHA256, forKey: .planSHA256)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(providerVersion, forKey: .providerVersion)
        try values.encode(disposition, forKey: .disposition)
        try values.encode(images, forKey: .images)
        try values.encode(deletedDigests, forKey: .deletedDigests)
        try values.encode(reclaimedBytes, forKey: .reclaimedBytes)
    }
}

public enum RuntimeImageProgressStage: String, Codable, CaseIterable, Equatable, Sendable {
    case resolving
    case downloading
    case verifying
    case unpacking
    case building
    case uploading
    case writing
    case deleting
    case complete
}

public struct RuntimeImageProgressEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operation: RuntimeImageLifecycleOperation
    public let operationID: String
    public let idempotencyKey: String
    public let sequence: UInt64
    public let stage: RuntimeImageProgressStage
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let itemDigest: String?
    public let itemReference: String?

    public init(
        schemaVersion: Int = RuntimeImageProgressEvent.currentSchemaVersion,
        operation: RuntimeImageLifecycleOperation,
        operationID: String,
        idempotencyKey: String,
        sequence: UInt64,
        stage: RuntimeImageProgressStage,
        completedBytes: Int64,
        totalBytes: Int64? = nil,
        itemDigest: String? = nil,
        itemReference: String? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              RuntimeImageLifecycleValidation.validOperationID(operationID),
              RuntimeImageLifecycleValidation.validSHA256(idempotencyKey),
              sequence < UInt64(RuntimeImageLifecycleLimits.maximumProgressEvents),
              completedBytes >= 0,
              totalBytes.map({ $0 >= completedBytes }) ?? true,
              itemDigest.map(RuntimeImageLifecycleValidation.validOCIDigest) ?? true,
              itemReference.map(RuntimeImageLifecycleValidation.validReference) ?? true else {
            throw RuntimeImageLifecycleContractError.invalidProgress
        }
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.sequence = sequence
        self.stage = stage
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.itemDigest = itemDigest
        self.itemReference = itemReference
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operation
        case operationID
        case idempotencyKey
        case sequence
        case stage
        case completedBytes
        case totalBytes
        case itemDigest
        case itemReference
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            operation: try values.decode(RuntimeImageLifecycleOperation.self, forKey: .operation),
            operationID: try values.decode(String.self, forKey: .operationID),
            idempotencyKey: try values.decode(String.self, forKey: .idempotencyKey),
            sequence: try values.decode(UInt64.self, forKey: .sequence),
            stage: try values.decode(RuntimeImageProgressStage.self, forKey: .stage),
            completedBytes: try values.decode(Int64.self, forKey: .completedBytes),
            totalBytes: try values.decodeIfPresent(Int64.self, forKey: .totalBytes),
            itemDigest: try values.decodeIfPresent(String.self, forKey: .itemDigest),
            itemReference: try values.decodeIfPresent(String.self, forKey: .itemReference)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(operation, forKey: .operation)
        try values.encode(operationID, forKey: .operationID)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(stage, forKey: .stage)
        try values.encode(completedBytes, forKey: .completedBytes)
        try values.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try values.encodeIfPresent(itemDigest, forKey: .itemDigest)
        try values.encodeIfPresent(itemReference, forKey: .itemReference)
    }
}

public protocol RuntimeImageLifecycleProviding: RuntimeAdapter {
    func imageOperationCapabilities() async throws -> RuntimeImageOperationCapabilityContract
    func performImageOperation(
        _ request: RuntimeImageLifecycleRequest,
        confirmation: RuntimeMutationConfirmation?,
        progress: @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) async throws -> RuntimeImageOperationResult
}

private struct RuntimeImageDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum RuntimeImageLifecycleValidation {
    static func validOperationID(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              value == value.lowercased(),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func validOCIDigest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else {
            return false
        }
        return validSHA256(String(value.dropFirst("sha256:".count)))
    }

    static func validProviderID(_ value: RuntimeProviderID) -> Bool {
        !value.rawValue.isEmpty &&
            value.rawValue.utf8.count <= RuntimeImageLifecycleLimits.maximumProviderValueBytes &&
            !hasControlCharacter(value.rawValue) &&
            value.rawValue == value.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validReference(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= RuntimeImageLifecycleLimits.maximumReferenceBytes,
              !value.hasPrefix("-"),
              !value.contains("://"),
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }),
              !value.contains("//") else {
            return false
        }
        let pathComponent = #"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"#
        let domainLabel = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
        let registry = #"\#(domainLabel)(?:\.\#(domainLabel))*(?::[0-9]{1,5})?"#
        let name = #"(?:\#(registry)/)?\#(pathComponent)(?:/\#(pathComponent))*"#
        let tag = #"(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})"#
        let digest = #"sha256:[a-f0-9]{64}"#
        let pattern = #"^\#(name)(?::\#(tag))?(?:@\#(digest))?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return false
        }
        if let slash = value.firstIndex(of: "/") {
            let registryCandidate = value[..<slash]
            if let colon = registryCandidate.lastIndex(of: ":"),
               registryCandidate[registryCandidate.index(after: colon)...].allSatisfy(\.isNumber),
               (Int(registryCandidate[registryCandidate.index(after: colon)...]) ?? 0) > 65_535 {
                return false
            }
        }
        return true
    }

    static func validAbsoluteNormalizedPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= RuntimeImageLifecycleLimits.maximumPathBytes,
              value.hasPrefix("/"),
              !hasControlCharacter(value),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return false
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    static func validatePlatform(
        operatingSystem: String?,
        architecture: String?
    ) throws {
        guard (operatingSystem == nil) == (architecture == nil) else {
            throw RuntimeImageLifecycleContractError.invalidPlatform
        }
        guard let operatingSystem, let architecture else {
            return
        }
        guard operatingSystem == "linux",
              architecture == "arm64" || architecture == "amd64" else {
            throw RuntimeImageLifecycleContractError.invalidPlatform
        }
    }

    static func hasControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
