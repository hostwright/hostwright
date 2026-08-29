import CryptoKit
import Foundation

public enum AcceleratorPlatformAdapterLimits {
    public static let maxDeviceNameBytes = 256
    public static let maxDetailBytes = AcceleratorLimits.maxReasonBytes
    public static let maxInputBytes = AcceleratorLimits.maxInputBytes
    public static let maxOutputBytes = AcceleratorLimits.maxOutputBytes
}

public enum AcceleratorPlatformAdapterError: Error, Codable, Equatable, Sendable {
    case unavailable(String)
    case unsupported(String)
    case invalidObservation(String)
    case invalidValue(String)
    case payloadTooLarge(String)
    case inputDigestMismatch(String)
    case outputLimitExceeded(String)
    case invalidMode(String)
    case linuxGuestPassthroughBlocked

    private enum CodingKeys: String, CodingKey {
        case kind
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try AcceleratorPlatformCodec.strictContainer(
            decoder,
            required: ["kind", "detail"],
            optional: [],
            field: "adapterError"
        )
        let kind = try container.decode(
            String.self,
            forKey: AcceleratorPlatformCodec.key("kind")
        )
        let detail = try container.decode(
            String.self,
            forKey: AcceleratorPlatformCodec.key("detail")
        )
        try AcceleratorPlatformValidation.detail(detail, field: "adapterError.detail")
        switch kind {
        case "unavailable": self = .unavailable(detail)
        case "unsupported": self = .unsupported(detail)
        case "invalid-observation": self = .invalidObservation(detail)
        case "invalid-value": self = .invalidValue(detail)
        case "payload-too-large": self = .payloadTooLarge(detail)
        case "input-digest-mismatch": self = .inputDigestMismatch(detail)
        case "output-limit-exceeded": self = .outputLimitExceeded(detail)
        case "invalid-mode": self = .invalidMode(detail)
        case "linux-guest-passthrough-blocked":
            guard detail == "guest-passthrough" else {
                throw AcceleratorValidationError(code: .invalidIdentifier, field: "adapterError.detail")
            }
            self = .linuxGuestPassthroughBlocked
        default:
            throw AcceleratorValidationError(code: .invalidIdentifier, field: "adapterError.kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable(let detail):
            try container.encode("unavailable", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .unsupported(let detail):
            try container.encode("unsupported", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .invalidObservation(let detail):
            try container.encode("invalid-observation", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .invalidValue(let detail):
            try container.encode("invalid-value", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .payloadTooLarge(let detail):
            try container.encode("payload-too-large", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .inputDigestMismatch(let detail):
            try container.encode("input-digest-mismatch", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .outputLimitExceeded(let detail):
            try container.encode("output-limit-exceeded", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .invalidMode(let detail):
            try container.encode("invalid-mode", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .linuxGuestPassthroughBlocked:
            try container.encode("linux-guest-passthrough-blocked", forKey: .kind)
            try container.encode("guest-passthrough", forKey: .detail)
        }
    }

    public func validate() throws {
        switch self {
        case .unavailable(let detail), .unsupported(let detail),
             .invalidObservation(let detail), .invalidValue(let detail),
             .payloadTooLarge(let detail), .inputDigestMismatch(let detail),
             .outputLimitExceeded(let detail), .invalidMode(let detail):
            try AcceleratorPlatformValidation.detail(detail, field: "adapterError.detail")
        case .linuxGuestPassthroughBlocked:
            break
        }
    }
}

private struct AcceleratorPlatformCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum AcceleratorPlatformCodec {
    static func key(_ value: String) -> AcceleratorPlatformCodingKey {
        AcceleratorPlatformCodingKey(stringValue: value)!
    }

    static func strictContainer(
        _ decoder: Decoder,
        required: Set<String>,
        optional: Set<String>,
        field: String
    ) throws -> KeyedDecodingContainer<AcceleratorPlatformCodingKey> {
        let container = try decoder.container(
            keyedBy: AcceleratorPlatformCodingKey.self
        )
        let actual = Set(container.allKeys.map { $0.stringValue })
        let allowed = required.union(optional)
        guard actual.isSuperset(of: required), actual.isSubset(of: allowed) else {
            throw AcceleratorPlatformAdapterError.invalidValue(field)
        }
        return container
    }
}

private enum AcceleratorPlatformValidation {
    static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    static func date(_ value: Date, field: String) throws {
        guard value.timeIntervalSince1970.isFinite else {
            throw AcceleratorPlatformAdapterError.invalidObservation(field)
        }
    }

    static func generation(_ value: Int64, field: String) throws {
        guard value > 0 else {
            throw AcceleratorPlatformAdapterError.invalidObservation(field)
        }
    }

    static func identifier(_ value: String, field: String, maxBytes: Int) throws {
        guard !value.isEmpty,
              value.utf8.count <= maxBytes,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw AcceleratorPlatformAdapterError.invalidObservation(field)
        }
    }

    static func detail(_ value: String, field: String) throws {
        guard value.utf8.count <= AcceleratorPlatformAdapterLimits.maxDetailBytes else {
            throw AcceleratorPlatformAdapterError.payloadTooLarge(field)
        }
        guard value.utf8.count >= 1,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw AcceleratorPlatformAdapterError.invalidObservation(field)
        }
    }

    static func digest(_ value: AcceleratorDigest, field: String) throws {
        guard value.value.utf8.count == 64 else {
            throw AcceleratorPlatformAdapterError.invalidValue(field)
        }
    }

    static func uuid(_ value: UUID, field: String) throws {
        guard value != zeroUUID else {
            throw AcceleratorPlatformAdapterError.invalidValue(field)
        }
    }

    static func sha256(_ data: Data) throws -> AcceleratorDigest {
        try AcceleratorDigest(
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }
}

public struct AcceleratorMetalAllocationObservation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let deviceName: String
    public let registryID: UInt64
    public let isRemovable: Bool
    public let hasUnifiedMemory: Bool
    /// Current Metal resource allocation evidence, never free capacity or quota.
    public let currentAllocatedBytes: UInt64
    /// A performance approximation, never reservable capacity.
    public let recommendedMaxWorkingSetBytes: UInt64?
    public let observedGeneration: Int64
    public let observedAt: Date
    public let source: AcceleratorEvidenceSource

    public init(
        deviceName: String,
        registryID: UInt64,
        currentAllocatedBytes: UInt64,
        recommendedMaxWorkingSetBytes: UInt64?,
        observedGeneration: Int64,
        observedAt: Date,
        isRemovable: Bool = false,
        hasUnifiedMemory: Bool = false,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorPlatformValidation.identifier(
            deviceName,
            field: "deviceName",
            maxBytes: AcceleratorPlatformAdapterLimits.maxDeviceNameBytes
        )
        guard registryID > 0,
              currentAllocatedBytes <= AcceleratorLimits.maxBudgetAmount,
              recommendedMaxWorkingSetBytes.map({
                  $0 > 0 && $0 <= AcceleratorLimits.maxBudgetAmount
              }) ?? true else {
            throw AcceleratorPlatformAdapterError.invalidObservation("metal.allocation")
        }
        try AcceleratorPlatformValidation.generation(
            observedGeneration,
            field: "observedGeneration"
        )
        try AcceleratorPlatformValidation.date(observedAt, field: "observedAt")
        self.contractVersion = contractVersion
        self.deviceName = deviceName
        self.registryID = registryID
        self.isRemovable = isRemovable
        self.hasUnifiedMemory = hasUnifiedMemory
        self.currentAllocatedBytes = currentAllocatedBytes
        self.recommendedMaxWorkingSetBytes = recommendedMaxWorkingSetBytes
        self.observedGeneration = observedGeneration
        self.observedAt = observedAt
        self.source = .metalCurrentAllocatedSize
    }

    public init(from decoder: Decoder) throws {
        let container = try AcceleratorPlatformCodec.strictContainer(
            decoder,
            required: [
                "contractVersion", "deviceName", "registryID", "isRemovable", "hasUnifiedMemory",
                "currentAllocatedBytes", "observedGeneration", "observedAt", "source"
            ],
            optional: ["recommendedMaxWorkingSetBytes"],
            field: "metal.observation"
        )
        let source = try container.decode(
            AcceleratorEvidenceSource.self,
            forKey: AcceleratorPlatformCodec.key("source")
        )
        guard source == .metalCurrentAllocatedSize else {
            throw AcceleratorPlatformAdapterError.invalidValue("source")
        }
        try self.init(
            deviceName: container.decode(
                String.self,
                forKey: AcceleratorPlatformCodec.key("deviceName")
            ),
            registryID: container.decode(
                UInt64.self,
                forKey: AcceleratorPlatformCodec.key("registryID")
            ),
            currentAllocatedBytes: container.decode(
                UInt64.self,
                forKey: AcceleratorPlatformCodec.key("currentAllocatedBytes")
            ),
            recommendedMaxWorkingSetBytes: container.decodeIfPresent(
                UInt64.self,
                forKey: AcceleratorPlatformCodec.key("recommendedMaxWorkingSetBytes")
            ),
            observedGeneration: container.decode(
                Int64.self,
                forKey: AcceleratorPlatformCodec.key("observedGeneration")
            ),
            observedAt: container.decode(
                Date.self,
                forKey: AcceleratorPlatformCodec.key("observedAt")
            ),
            isRemovable: container.decode(
                Bool.self,
                forKey: AcceleratorPlatformCodec.key("isRemovable")
            ),
            hasUnifiedMemory: container.decode(
                Bool.self,
                forKey: AcceleratorPlatformCodec.key("hasUnifiedMemory")
            ),
            contractVersion: container.decode(
                Int.self,
                forKey: AcceleratorPlatformCodec.key("contractVersion")
            )
        )
    }
}

public protocol AcceleratorMetalAllocationReader: Sendable {
    func readMetalAllocation(
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorMetalAllocationObservation
}

public struct AcceleratorMetalAllocationAdapter: Sendable {
    private let reader: any AcceleratorMetalAllocationReader

    public init(reader: any AcceleratorMetalAllocationReader) {
        self.reader = reader
    }

    public func read(
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorMetalAllocationObservation {
        try reader.readMetalAllocation(
            observedAt: observedAt,
            observedGeneration: observedGeneration
        )
    }
}

public enum AcceleratorCoreMLPolicyStatus:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    /// The Core ML configuration API accepted a policy value; this is not hardware proof.
    case policyAccepted = "policy-accepted"
    case unavailable
    case unsupported
}

public enum AcceleratorCoreMLExplanationCode:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case computeUnitsArePolicyOnly = "compute-units-are-policy-only"
    case coreMLFrameworkUnavailable = "core-ml-framework-unavailable"
    case computeUnitPolicyUnsupported = "compute-unit-policy-unsupported"
}

public struct AcceleratorCoreMLEligibilityObservation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let requestedComputeUnits: String
    public let modelHash: AcceleratorDigest?
    public let status: AcceleratorCoreMLPolicyStatus
    public let explanation: AcceleratorCoreMLExplanationCode
    public let source: AcceleratorEvidenceSource
    public let observedGeneration: Int64
    public let observedAt: Date

    public init(
        requestedComputeUnits: String,
        modelHash: AcceleratorDigest? = nil,
        status: AcceleratorCoreMLPolicyStatus,
        explanation: AcceleratorCoreMLExplanationCode,
        source: AcceleratorEvidenceSource,
        observedGeneration: Int64,
        observedAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorPlatformValidation.identifier(
            requestedComputeUnits,
            field: "requestedComputeUnits",
            maxBytes: AcceleratorLimits.maxIdentifierBytes
        )
        if let modelHash {
            try AcceleratorPlatformValidation.digest(modelHash, field: "modelHash")
        }
        guard source == .coreMLComputeUnitsPolicy || source == .contractBoundary else {
            throw AcceleratorPlatformAdapterError.invalidValue("source")
        }
        switch status {
        case .policyAccepted:
            guard source == .coreMLComputeUnitsPolicy,
                  explanation == .computeUnitsArePolicyOnly else {
                throw AcceleratorPlatformAdapterError.invalidValue("policyEvidence")
            }
        case .unavailable:
            guard source == .contractBoundary,
                  explanation == .coreMLFrameworkUnavailable else {
                throw AcceleratorPlatformAdapterError.invalidValue("unavailableEvidence")
            }
        case .unsupported:
            guard source == .contractBoundary,
                  explanation == .computeUnitPolicyUnsupported else {
                throw AcceleratorPlatformAdapterError.invalidValue("unsupportedEvidence")
            }
        }
        try AcceleratorPlatformValidation.generation(
            observedGeneration,
            field: "observedGeneration"
        )
        try AcceleratorPlatformValidation.date(observedAt, field: "observedAt")
        self.contractVersion = contractVersion
        self.requestedComputeUnits = requestedComputeUnits
        self.modelHash = modelHash
        self.status = status
        self.explanation = explanation
        self.source = source
        self.observedGeneration = observedGeneration
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try AcceleratorPlatformCodec.strictContainer(
            decoder,
            required: [
                "contractVersion", "requestedComputeUnits", "status", "explanation", "source",
                "observedGeneration", "observedAt"
            ],
            optional: ["modelHash"],
            field: "coreML.observation"
        )
        try self.init(
            requestedComputeUnits: container.decode(
                String.self,
                forKey: AcceleratorPlatformCodec.key("requestedComputeUnits")
            ),
            modelHash: container.decodeIfPresent(
                AcceleratorDigest.self,
                forKey: AcceleratorPlatformCodec.key("modelHash")
            ),
            status: container.decode(
                AcceleratorCoreMLPolicyStatus.self,
                forKey: AcceleratorPlatformCodec.key("status")
            ),
            explanation: container.decode(
                AcceleratorCoreMLExplanationCode.self,
                forKey: AcceleratorPlatformCodec.key("explanation")
            ),
            source: container.decode(
                AcceleratorEvidenceSource.self,
                forKey: AcceleratorPlatformCodec.key("source")
            ),
            observedGeneration: container.decode(
                Int64.self,
                forKey: AcceleratorPlatformCodec.key("observedGeneration")
            ),
            observedAt: container.decode(
                Date.self,
                forKey: AcceleratorPlatformCodec.key("observedAt")
            ),
            contractVersion: container.decode(
                Int.self,
                forKey: AcceleratorPlatformCodec.key("contractVersion")
            )
        )
    }
}

public protocol AcceleratorCoreMLEligibilityReader: Sendable {
    func readCoreMLEligibility(
        requestedComputeUnits: String,
        modelHash: AcceleratorDigest?,
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorCoreMLEligibilityObservation
}

public struct AcceleratorCoreMLEligibilityAdapter: Sendable {
    private let reader: any AcceleratorCoreMLEligibilityReader

    public init(reader: any AcceleratorCoreMLEligibilityReader) {
        self.reader = reader
    }

    public func read(
        requestedComputeUnits: String,
        modelHash: AcceleratorDigest?,
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorCoreMLEligibilityObservation {
        let observation = try reader.readCoreMLEligibility(
            requestedComputeUnits: requestedComputeUnits,
            modelHash: modelHash,
            observedAt: observedAt,
            observedGeneration: observedGeneration
        )
        guard observation.requestedComputeUnits == requestedComputeUnits,
              observation.modelHash == modelHash,
              observation.observedAt == observedAt,
              observation.observedGeneration == observedGeneration else {
            throw AcceleratorPlatformAdapterError.invalidObservation("core-ml")
        }
        return observation
    }
}

public struct AcceleratorMLXExecutionRequest:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let executionRequest: AcceleratorExecutionRequest
    public let input: Data

    public init(
        executionRequest: AcceleratorExecutionRequest,
        input: Data,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        guard executionRequest.contractVersion == contractVersion else {
            throw AcceleratorPlatformAdapterError.invalidValue(
                "executionRequest.contractVersion"
            )
        }
        guard executionRequest.mode == .mlxSwift else {
            throw executionRequest.mode.isLinuxGuestPassthrough
                ? AcceleratorPlatformAdapterError.linuxGuestPassthroughBlocked
                : AcceleratorPlatformAdapterError.invalidMode("executionRequest.mode")
        }
        guard input.count <= AcceleratorPlatformAdapterLimits.maxInputBytes else {
            throw AcceleratorPlatformAdapterError.payloadTooLarge("input")
        }
        guard input.count == executionRequest.inputBytes else {
            throw AcceleratorPlatformAdapterError.invalidObservation("inputBytes")
        }
        guard try AcceleratorPlatformValidation.sha256(input)
            == executionRequest.inputDigest else {
            throw AcceleratorPlatformAdapterError.inputDigestMismatch("input")
        }
        self.contractVersion = contractVersion
        self.executionRequest = executionRequest
        self.input = input
    }

    public init(from decoder: Decoder) throws {
        let container = try AcceleratorPlatformCodec.strictContainer(
            decoder,
            required: ["contractVersion", "executionRequest", "input"],
            optional: [],
            field: "mlx.request"
        )
        try self.init(
            executionRequest: container.decode(
                AcceleratorExecutionRequest.self,
                forKey: AcceleratorPlatformCodec.key("executionRequest")
            ),
            input: container.decode(
                Data.self,
                forKey: AcceleratorPlatformCodec.key("input")
            ),
            contractVersion: container.decode(
                Int.self,
                forKey: AcceleratorPlatformCodec.key("contractVersion")
            )
        )
    }
}

public enum AcceleratorMLXExecutionResult:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case unavailable(String)
    case unsupported(String)

    private enum CodingKeys: String, CodingKey { case kind, detail }

    public init(from decoder: Decoder) throws {
        let container = try AcceleratorPlatformCodec.strictContainer(
            decoder,
            required: ["kind", "detail"],
            optional: [],
            field: "mlx.result"
        )
        let kind = try container.decode(
            String.self,
            forKey: AcceleratorPlatformCodec.key("kind")
        )
        let detail = try container.decode(
            String.self,
            forKey: AcceleratorPlatformCodec.key("detail")
        )
        try AcceleratorPlatformValidation.detail(detail, field: "mlx.result.detail")
        switch kind {
        case "unavailable": self = .unavailable(detail)
        case "unsupported": self = .unsupported(detail)
        default: throw AcceleratorValidationError(code: .invalidIdentifier, field: "mlx.result.kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        let detail: String
        switch self {
        case .unavailable(let value), .unsupported(let value):
            detail = value
        }
        guard (1...AcceleratorPlatformAdapterLimits.maxDetailBytes).contains(
            detail.utf8.count
        ) else {
            throw AcceleratorPlatformAdapterError.payloadTooLarge("mlx.result.detail")
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable(let detail):
            try container.encode("unavailable", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .unsupported(let detail):
            try container.encode("unsupported", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        }
    }

    public func validate() throws {
        let detail: String
        switch self {
        case .unavailable(let value), .unsupported(let value):
            detail = value
        }
        try AcceleratorPlatformValidation.detail(detail, field: "mlx.result.detail")
    }
}

public protocol AcceleratorMLXExecutor: Sendable {
    func execute(_ request: AcceleratorMLXExecutionRequest) async throws -> AcceleratorMLXExecutionResult
}

public struct AcceleratorUnavailableMLXExecutor: AcceleratorMLXExecutor, Sendable {
    public init() {}

    public func execute(_ request: AcceleratorMLXExecutionRequest) async throws -> AcceleratorMLXExecutionResult {
        _ = request
        return .unavailable("mlx-swift-backend-not-configured")
    }
}

public struct AcceleratorMLXExecutionAdapter: Sendable {
    private let executor: any AcceleratorMLXExecutor

    public init() {
        self.executor = AcceleratorUnavailableMLXExecutor()
    }

    internal init(executor: any AcceleratorMLXExecutor) {
        self.executor = executor
    }

    public func execute(
        _ request: AcceleratorMLXExecutionRequest,
        observedAt: Date
    ) async throws -> AcceleratorMLXExecutionResult {
        try AcceleratorPlatformValidation.date(observedAt, field: "observedAt")
        guard observedAt >= request.executionRequest.requestedAt else {
            throw AcceleratorPlatformAdapterError.invalidObservation("observedAt")
        }
        let result = try await executor.execute(request)
        try result.validate()
        return result
    }
}

public enum AcceleratorGuestExecutionGuard {
    public static func validate(_ mode: AcceleratorExecutionMode, isGuest: Bool) throws {
        _ = isGuest
        guard !mode.isLinuxGuestPassthrough else {
            throw AcceleratorPlatformAdapterError.linuxGuestPassthroughBlocked
        }
    }
}

#if canImport(Metal)
import Metal

public struct AcceleratorSystemMetalAllocationReader: AcceleratorMetalAllocationReader, Sendable {
    public init() {}

    public func readMetalAllocation(
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorMetalAllocationObservation {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw AcceleratorPlatformAdapterError.unavailable("metal-device")
        }
        return try AcceleratorMetalAllocationObservation(
            deviceName: device.name,
            registryID: device.registryID,
            currentAllocatedBytes: UInt64(device.currentAllocatedSize),
            recommendedMaxWorkingSetBytes: device.recommendedMaxWorkingSetSize == 0
                ? nil
                : device.recommendedMaxWorkingSetSize,
            observedGeneration: observedGeneration,
            observedAt: observedAt,
            isRemovable: device.isRemovable,
            hasUnifiedMemory: device.hasUnifiedMemory
        )
    }
}
#else
public struct AcceleratorSystemMetalAllocationReader: AcceleratorMetalAllocationReader, Sendable {
    public init() {}

    public func readMetalAllocation(
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorMetalAllocationObservation {
        _ = observedAt
        _ = observedGeneration
        throw AcceleratorPlatformAdapterError.unavailable("metal-framework")
    }
}
#endif

#if canImport(CoreML)
import CoreML

public struct AcceleratorSystemCoreMLEligibilityReader: AcceleratorCoreMLEligibilityReader, Sendable {
    public init() {}

    public func readCoreMLEligibility(
        requestedComputeUnits: String,
        modelHash: AcceleratorDigest?,
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorCoreMLEligibilityObservation {
        let configuration = MLModelConfiguration()
        guard !requestedComputeUnits.isEmpty else {
            throw AcceleratorPlatformAdapterError.invalidObservation(
                "requestedComputeUnits"
            )
        }
        switch requestedComputeUnits {
        case "cpu-only":
            configuration.computeUnits = .cpuOnly
        case "cpu-and-gpu":
            configuration.computeUnits = .cpuAndGPU
        case "cpu-and-neural-engine":
            configuration.computeUnits = .cpuAndNeuralEngine
        case "all":
            configuration.computeUnits = .all
        default:
            throw AcceleratorPlatformAdapterError.unsupported(
                "core-ml-compute-units"
            )
        }
        return try AcceleratorCoreMLEligibilityObservation(
            requestedComputeUnits: requestedComputeUnits,
            modelHash: modelHash,
            status: .policyAccepted,
            explanation: .computeUnitsArePolicyOnly,
            source: .coreMLComputeUnitsPolicy,
            observedGeneration: observedGeneration,
            observedAt: observedAt
        )
    }
}
#else
public struct AcceleratorSystemCoreMLEligibilityReader: AcceleratorCoreMLEligibilityReader, Sendable {
    public init() {}

    public func readCoreMLEligibility(
        requestedComputeUnits: String,
        modelHash: AcceleratorDigest?,
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorCoreMLEligibilityObservation {
        _ = requestedComputeUnits
        _ = modelHash
        _ = observedAt
        _ = observedGeneration
        throw AcceleratorPlatformAdapterError.unavailable("core-ml-framework")
    }
}
#endif
