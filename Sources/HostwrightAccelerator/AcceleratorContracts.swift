import CryptoKit
import Foundation

public enum AcceleratorContract {
    public static let currentVersion = 1
}

public enum AcceleratorLimits {
    public static let maxIdentifierBytes = 128
    public static let maxSourceBytes = 128
    public static let maxReasonBytes = 512
    public static let maxInputBytes = 16 * 1024 * 1024
    public static let maxOutputBytes = 16 * 1024 * 1024
    public static let maxTimeoutMilliseconds = 300_000
    public static let maxConcurrency = 256
    public static let maxModeEvidenceCount = 16
    public static let maxBudgetCount = 128
    public static let maxAllowedModeCount = 3
    public static let maxBudgetAmount: UInt64 = 1 << 50
}

public enum AcceleratorErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case unsupportedVersion = "unsupported-version"
    case invalidIdentifier = "invalid-identifier"
    case invalidDigest = "invalid-digest"
    case invalidTimestamp = "invalid-timestamp"
    case invalidOrdering = "invalid-ordering"
    case invalidBudget = "invalid-budget"
    case invalidMode = "invalid-mode"
    case linuxGuestPassthroughBlocked = "linux-guest-passthrough-blocked"
    case invalidScope = "invalid-scope"
    case scopeMismatch = "scope-mismatch"
    case invalidAuthentication = "invalid-authentication"
    case authenticationExpired = "authentication-expired"
    case invalidQuota = "invalid-quota"
    case invalidClaim = "invalid-claim"
    case invalidReservation = "invalid-reservation"
    case staleNodeEpoch = "stale-node-epoch"
    case staleReservationSequence = "stale-reservation-sequence"
    case outOfOrderObservation = "out-of-order-observation"
    case invalidTransition = "invalid-transition"
    case terminalState = "terminal-state"
    case expired = "expired"
    case invalidGrant = "invalid-grant"
    case grantMismatch = "grant-mismatch"
    case requestMismatch = "request-mismatch"
    case invalidRequest = "invalid-request"
    case inputLimitExceeded = "input-limit-exceeded"
    case outputLimitExceeded = "output-limit-exceeded"
    case timeoutLimitExceeded = "timeout-limit-exceeded"
    case concurrencyLimitExceeded = "concurrency-limit-exceeded"
    case inventoryMismatch = "inventory-mismatch"
    case modeUnavailable = "mode-unavailable"
    case budgetExceeded = "budget-exceeded"
    case invalidUsage = "invalid-usage"
    case invalidProvenance = "invalid-provenance"
    case invalidCancellation = "invalid-cancellation"
    case invalidRevocation = "invalid-revocation"
}

public struct AcceleratorValidationError:
    Error,
    Codable,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    public let code: AcceleratorErrorCode
    public let field: String

    public init(
        code: AcceleratorErrorCode,
        field: String = "contract"
    ) {
        self.code = code
        self.field = field
    }

    public var description: String {
        "\(code.rawValue):\(field)"
    }
}

internal enum AcceleratorValidation {
    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    static func fail(
        _ code: AcceleratorErrorCode,
        _ field: String
    ) -> AcceleratorValidationError {
        AcceleratorValidationError(code: code, field: field)
    }

    static func version(_ value: Int) throws {
        guard value == AcceleratorContract.currentVersion else {
            throw fail(.unsupportedVersion, "contractVersion")
        }
    }

    static func uuid(_ value: UUID, field: String) throws {
        guard value != zeroUUID else {
            throw fail(.invalidIdentifier, field)
        }
    }

    static func scope(_ value: AcceleratorScope) throws {
        try uuid(value.projectID, field: "scope.projectID")
        if let workloadID = value.workloadID {
            try uuid(workloadID, field: "scope.workloadID")
        }
    }

    static func identifier(
        _ value: String,
        field: String,
        maxBytes: Int = AcceleratorLimits.maxIdentifierBytes
    ) throws {
        guard (1...maxBytes).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 58, 95:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw fail(.invalidIdentifier, field)
        }
    }

    static func source(_ value: AcceleratorEvidenceSource) throws {
        guard !value.rawValue.isEmpty,
              value.rawValue.utf8.count <= AcceleratorLimits.maxSourceBytes else {
            throw fail(.invalidIdentifier, "source")
        }
    }

    static func reason(_ value: String) throws {
        guard (1...AcceleratorLimits.maxReasonBytes).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value <= 0x7E
              }) else {
            throw fail(.invalidIdentifier, "reason")
        }
    }

    static func date(_ value: Date, field: String) throws {
        guard value.timeIntervalSince1970.isFinite else {
            throw fail(.invalidTimestamp, field)
        }
    }

    static func dateRange(
        start: Date,
        end: Date,
        startField: String,
        endField: String
    ) throws {
        try date(start, field: startField)
        try date(end, field: endField)
        guard end > start else {
            throw fail(.invalidTimestamp, "\(startField)-\(endField)-order")
        }
    }

    static func positiveGeneration(_ value: Int64, field: String) throws {
        guard value >= 1 else {
            throw fail(.invalidOrdering, field)
        }
    }

    static func positiveBudget(_ value: UInt64, field: String) throws {
        guard value > 0, value <= AcceleratorLimits.maxBudgetAmount else {
            throw fail(.invalidBudget, field)
        }
    }

    static func canonical<T: Equatable>(
        _ values: [T],
        sortedBy areInIncreasingOrder: (T, T) -> Bool,
        field: String
    ) throws {
        guard values == values.sorted(by: areInIncreasingOrder) else {
            throw fail(.invalidOrdering, field)
        }
        for index in values.indices.dropFirst() {
            guard values[index] != values[index - 1] else {
                throw fail(.invalidOrdering, field)
            }
        }
    }
}

public struct AcceleratorDigest:
    Codable,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let value: String

    public init(_ value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              }) else {
            throw AcceleratorValidationError(code: .invalidDigest, field: "digest")
        }
        self.value = value
    }

    public var description: String {
        value
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum AcceleratorScope: Codable, Equatable, Hashable, Sendable {
    case project(projectID: UUID)
    case workload(projectID: UUID, workloadID: UUID)

    public var projectID: UUID {
        switch self {
        case .project(let projectID), .workload(let projectID, _):
            return projectID
        }
    }

    public var workloadID: UUID? {
        switch self {
        case .project:
            return nil
        case .workload(_, let workloadID):
            return workloadID
        }
    }

    public var stableKey: String {
        switch self {
        case .project(let projectID):
            return "project:\(projectID.uuidString.lowercased())"
        case .workload(let projectID, let workloadID):
            return "project:\(projectID.uuidString.lowercased())/workload:\(workloadID.uuidString.lowercased())"
        }
    }

    public func contains(_ other: AcceleratorScope) -> Bool {
        guard projectID == other.projectID else { return false }
        switch (self, other) {
        case (.project, _):
            return true
        case (.workload(_, let lhsWorkload), .workload(_, let rhsWorkload)):
            return lhsWorkload == rhsWorkload
        case (.workload, .project):
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case projectID
        case workloadID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let projectID = try container.decode(UUID.self, forKey: .projectID)
        try AcceleratorValidation.uuid(projectID, field: "projectID")
        switch kind {
        case "project":
            self = .project(projectID: projectID)
        case "workload":
            let workloadID = try container.decode(UUID.self, forKey: .workloadID)
            try AcceleratorValidation.uuid(workloadID, field: "workloadID")
            self = .workload(projectID: projectID, workloadID: workloadID)
        default:
            throw AcceleratorValidation.fail(.invalidScope, "kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project(let projectID):
            try container.encode("project", forKey: .kind)
            try container.encode(projectID, forKey: .projectID)
        case .workload(let projectID, let workloadID):
            try container.encode("workload", forKey: .kind)
            try container.encode(projectID, forKey: .projectID)
            try container.encode(workloadID, forKey: .workloadID)
        }
    }
}

public enum AcceleratorEvidenceSource: String, Codable, CaseIterable, Equatable, Sendable {
    case callerObservedEvidence = "caller-observed-evidence"
    case callerMeasuredBudget = "caller-measured-budget"
    case hostNativeExecutionSelfTest = "host-native-execution-self-test"
    case hostNativeModeMeasurement = "host-native-mode-measurement"
    case callerMeasuredUsage = "caller-measured-usage"
    case contractBoundary = "contract-boundary"
    case metalRegistryIdentity = "metal-registry-identity"
    case metalCurrentAllocatedSize = "metal-current-allocated-size"
    case metalWorkingSetApproximation = "metal-working-set-approximation"
    case coreMLComputeUnitsPolicy = "core-ml-compute-units-policy"
    case coreMLEligibility = "core-ml-eligibility"
    case mlxPublicDevice = "mlx-public-device"
    case mlxProcessLocalMemory = "mlx-process-local-memory"
}

public struct AcceleratorAuthenticationContext:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let subjectID: String
    public let sessionID: String
    public let credentialID: String?
    public let authenticationDigest: AcceleratorDigest
    public let authenticatedAt: Date
    public let expiresAt: Date

    public init(
        subjectID: String,
        sessionID: String,
        credentialID: String? = nil,
        authenticationDigest: AcceleratorDigest,
        authenticatedAt: Date,
        expiresAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.identifier(subjectID, field: "subjectID")
        try AcceleratorValidation.identifier(sessionID, field: "sessionID")
        if let credentialID {
            try AcceleratorValidation.identifier(credentialID, field: "credentialID")
        }
        try AcceleratorValidation.dateRange(
            start: authenticatedAt,
            end: expiresAt,
            startField: "authenticatedAt",
            endField: "expiresAt"
        )
        self.contractVersion = contractVersion
        self.subjectID = subjectID
        self.sessionID = sessionID
        self.credentialID = credentialID
        self.authenticationDigest = authenticationDigest
        self.authenticatedAt = authenticatedAt
        self.expiresAt = expiresAt
    }

    public func isActive(at observationTime: Date) -> Bool {
        observationTime.timeIntervalSince1970.isFinite
            && observationTime >= authenticatedAt
            && observationTime <= expiresAt
    }

    public func validateActive(at observationTime: Date) throws {
        guard isActive(at: observationTime) else {
            throw AcceleratorValidationError(
                code: .authenticationExpired,
                field: "authentication"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case subjectID
        case sessionID
        case credentialID
        case authenticationDigest
        case authenticatedAt
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            subjectID: container.decode(String.self, forKey: .subjectID),
            sessionID: container.decode(String.self, forKey: .sessionID),
            credentialID: container.decodeIfPresent(String.self, forKey: .credentialID),
            authenticationDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .authenticationDigest
            ),
            authenticatedAt: container.decode(Date.self, forKey: .authenticatedAt),
            expiresAt: container.decode(Date.self, forKey: .expiresAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorExecutionMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case metal
    case coreML = "core-ml"
    case mlxSwift = "mlx-swift"
    case linuxGuestGPUPassthrough = "linux-guest-gpu-passthrough"
    case linuxGuestANEPassthrough = "linux-guest-ane-passthrough"

    public var isLinuxGuestPassthrough: Bool {
        switch self {
        case .linuxGuestGPUPassthrough, .linuxGuestANEPassthrough:
            return true
        case .metal, .coreML, .mlxSwift:
            return false
        }
    }
}

public enum AcceleratorModeStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case blocked
    case unavailable
}

public enum AcceleratorModeEvidenceReason: String, Codable, CaseIterable, Equatable, Sendable {
    case linuxGuestPassthroughBlocked = "linux-guest-passthrough-blocked"
    case evidenceUnavailable = "evidence-unavailable"
    case policyUnavailable = "policy-unavailable"
}

public enum AcceleratorExecutionEvidenceOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case succeeded
    case failed
}

public struct AcceleratorHostNativeExecutionEvidence:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let mode: AcceleratorExecutionMode
    public let backendIdentifier: String
    public let frameworkIdentifier: String
    public let operatingSystem: String
    public let executionDigest: AcceleratorDigest
    public let provenanceDigest: AcceleratorDigest
    public let outcome: AcceleratorExecutionEvidenceOutcome
    public let observedGeneration: Int64
    public let observedAt: Date
    public let completedAt: Date

    public init(
        mode: AcceleratorExecutionMode,
        backendIdentifier: String,
        frameworkIdentifier: String,
        operatingSystem: String,
        executionDigest: AcceleratorDigest,
        provenanceDigest: AcceleratorDigest,
        outcome: AcceleratorExecutionEvidenceOutcome = .succeeded,
        observedGeneration: Int64,
        observedAt: Date,
        completedAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        guard !mode.isLinuxGuestPassthrough else {
            throw AcceleratorValidation.fail(.linuxGuestPassthroughBlocked, "mode")
        }
        try AcceleratorValidation.identifier(backendIdentifier, field: "backendIdentifier")
        try AcceleratorValidation.identifier(frameworkIdentifier, field: "frameworkIdentifier")
        try AcceleratorValidation.identifier(operatingSystem, field: "operatingSystem")
        try AcceleratorValidation.positiveGeneration(observedGeneration, field: "observedGeneration")
        try AcceleratorValidation.dateRange(
            start: observedAt,
            end: completedAt,
            startField: "observedAt",
            endField: "completedAt"
        )
        guard outcome == .succeeded else {
            throw AcceleratorValidation.fail(.invalidMode, "outcome")
        }
        self.contractVersion = contractVersion
        self.mode = mode
        self.backendIdentifier = backendIdentifier
        self.frameworkIdentifier = frameworkIdentifier
        self.operatingSystem = operatingSystem
        self.executionDigest = executionDigest
        self.provenanceDigest = provenanceDigest
        self.outcome = outcome
        self.observedGeneration = observedGeneration
        self.observedAt = observedAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case mode
        case backendIdentifier
        case frameworkIdentifier
        case operatingSystem
        case executionDigest
        case provenanceDigest
        case outcome
        case observedGeneration
        case observedAt
        case completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(AcceleratorExecutionMode.self, forKey: .mode),
            backendIdentifier: container.decode(String.self, forKey: .backendIdentifier),
            frameworkIdentifier: container.decode(String.self, forKey: .frameworkIdentifier),
            operatingSystem: container.decode(String.self, forKey: .operatingSystem),
            executionDigest: container.decode(AcceleratorDigest.self, forKey: .executionDigest),
            provenanceDigest: container.decode(AcceleratorDigest.self, forKey: .provenanceDigest),
            outcome: container.decode(AcceleratorExecutionEvidenceOutcome.self, forKey: .outcome),
            observedGeneration: container.decode(Int64.self, forKey: .observedGeneration),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            completedAt: container.decode(Date.self, forKey: .completedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorModeEvidence:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let mode: AcceleratorExecutionMode
    public let status: AcceleratorModeStatus
    public let evidenceDigest: AcceleratorDigest
    public let source: AcceleratorEvidenceSource
    public let observedGeneration: Int64
    public let reasonCode: AcceleratorModeEvidenceReason?
    public let executionEvidence: AcceleratorHostNativeExecutionEvidence?

    public init(
        mode: AcceleratorExecutionMode,
        status: AcceleratorModeStatus,
        evidenceDigest: AcceleratorDigest,
        source: AcceleratorEvidenceSource,
        observedGeneration: Int64,
        reasonCode: AcceleratorModeEvidenceReason? = nil,
        executionEvidence: AcceleratorHostNativeExecutionEvidence? = nil,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.positiveGeneration(
            observedGeneration,
            field: "observedGeneration"
        )
        if mode.isLinuxGuestPassthrough {
            guard status == .blocked,
                  reasonCode == .linuxGuestPassthroughBlocked else {
                throw AcceleratorValidation.fail(
                    .linuxGuestPassthroughBlocked,
                    "mode"
                )
            }
        } else if status == .available {
            guard reasonCode == nil,
                  source == .hostNativeExecutionSelfTest,
                  let executionEvidence,
                  executionEvidence.mode == mode,
                  executionEvidence.observedGeneration == observedGeneration,
                  executionEvidence.provenanceDigest == evidenceDigest else {
                throw AcceleratorValidation.fail(.invalidMode, "reasonCode")
            }
        } else {
            guard reasonCode != nil, executionEvidence == nil else {
                throw AcceleratorValidation.fail(.invalidMode, "reasonCode")
            }
        }
        try AcceleratorValidation.source(source)
        self.contractVersion = contractVersion
        self.mode = mode
        self.status = status
        self.evidenceDigest = evidenceDigest
        self.source = source
        self.observedGeneration = observedGeneration
        self.reasonCode = reasonCode
        self.executionEvidence = executionEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case mode
        case status
        case evidenceDigest
        case source
        case observedGeneration
        case reasonCode
        case executionEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(AcceleratorExecutionMode.self, forKey: .mode),
            status: container.decode(AcceleratorModeStatus.self, forKey: .status),
            evidenceDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .evidenceDigest
            ),
            source: container.decode(
                AcceleratorEvidenceSource.self,
                forKey: .source
            ),
            observedGeneration: container.decode(
                Int64.self,
                forKey: .observedGeneration
            ),
            reasonCode: container.decodeIfPresent(
                AcceleratorModeEvidenceReason.self,
                forKey: .reasonCode
            ),
            executionEvidence: container.decodeIfPresent(
                AcceleratorHostNativeExecutionEvidence.self,
                forKey: .executionEvidence
            ),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorBudgetKind: String, Codable, CaseIterable, Equatable, Sendable {
    case memory
    case compute
    case concurrency
}

public enum AcceleratorBudgetUnit: String, Codable, CaseIterable, Equatable, Sendable {
    case bytes
    case computeUnits = "compute-units"
    case concurrentExecutions = "concurrent-executions"
}

public struct AcceleratorBudgetMeasurementEvidence:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let executionDigest: AcceleratorDigest
    public let provenanceDigest: AcceleratorDigest
    public let observedGeneration: Int64

    public init(
        executionDigest: AcceleratorDigest,
        provenanceDigest: AcceleratorDigest,
        observedGeneration: Int64
    ) throws {
        try AcceleratorValidation.positiveGeneration(
            observedGeneration,
            field: "measurementEvidence.observedGeneration"
        )
        self.executionDigest = executionDigest
        self.provenanceDigest = provenanceDigest
        self.observedGeneration = observedGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case executionDigest
        case provenanceDigest
        case observedGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual == Set(["executionDigest", "provenanceDigest", "observedGeneration"]) else {
            throw AcceleratorValidation.fail(.invalidBudget, "measurementEvidence")
        }
        try self.init(
            executionDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .executionDigest
            ),
            provenanceDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .provenanceDigest
            ),
            observedGeneration: container.decode(
                Int64.self,
                forKey: .observedGeneration
            )
        )
    }
}

public struct AcceleratorMeasuredBudget:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let mode: AcceleratorExecutionMode?
    public let kind: AcceleratorBudgetKind
    public let amount: UInt64
    public let unit: AcceleratorBudgetUnit
    public let source: AcceleratorEvidenceSource
    public let observedGeneration: Int64
    public let measurementEvidence: AcceleratorBudgetMeasurementEvidence
    public let measurementEvidenceDigest: AcceleratorDigest

    public var orderingKey: String {
        "\(mode?.rawValue ?? "global"):\(kind.rawValue)"
    }

    public init(
        mode: AcceleratorExecutionMode?,
        kind: AcceleratorBudgetKind,
        amount: UInt64,
        unit: AcceleratorBudgetUnit,
        source: AcceleratorEvidenceSource,
        observedGeneration: Int64,
        measurementEvidence: AcceleratorBudgetMeasurementEvidence,
        measurementEvidenceDigest: AcceleratorDigest,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        guard let mode else {
            throw AcceleratorValidation.fail(.invalidBudget, "mode")
        }
        if mode.isLinuxGuestPassthrough {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "mode"
            )
        }
        try AcceleratorValidation.positiveBudget(amount, field: "amount")
        try AcceleratorValidation.positiveGeneration(
            observedGeneration,
            field: "observedGeneration"
        )
        guard source == .hostNativeModeMeasurement else {
            throw AcceleratorValidation.fail(.invalidBudget, "source")
        }
        guard measurementEvidence.observedGeneration == observedGeneration else {
            throw AcceleratorValidation.fail(.invalidOrdering, "measurementEvidence.observedGeneration")
        }
        guard measurementEvidenceDigest == (try Self.measurementEvidenceDigest(
            mode: mode,
            kind: kind,
            amount: amount,
            unit: unit,
            observedGeneration: observedGeneration,
            measurementEvidence: measurementEvidence
        )) else {
            throw AcceleratorValidation.fail(.invalidBudget, "measurementEvidenceDigest")
        }
        let expectedUnit: AcceleratorBudgetUnit
        switch kind {
        case .memory:
            expectedUnit = .bytes
        case .compute:
            expectedUnit = .computeUnits
        case .concurrency:
            expectedUnit = .concurrentExecutions
        }
        guard unit == expectedUnit else {
            throw AcceleratorValidation.fail(.invalidBudget, "unit")
        }
        if kind == .concurrency {
            guard amount <= UInt64(AcceleratorLimits.maxConcurrency) else {
                throw AcceleratorValidation.fail(
                    .concurrencyLimitExceeded,
                    "amount"
                )
            }
        }
        self.contractVersion = contractVersion
        self.mode = mode
        self.kind = kind
        self.amount = amount
        self.unit = unit
        self.source = source
        self.observedGeneration = observedGeneration
        self.measurementEvidence = measurementEvidence
        self.measurementEvidenceDigest = measurementEvidenceDigest
    }

    public static func measurementEvidenceDigest(
        mode: AcceleratorExecutionMode,
        kind: AcceleratorBudgetKind,
        amount: UInt64,
        unit: AcceleratorBudgetUnit,
        observedGeneration: Int64,
        measurementEvidence: AcceleratorBudgetMeasurementEvidence
    ) throws -> AcceleratorDigest {
        let canonical = [
            "mode=\(mode.rawValue)",
            "kind=\(kind.rawValue)",
            "amount=\(amount)",
            "unit=\(unit.rawValue)",
            "source=\(AcceleratorEvidenceSource.hostNativeModeMeasurement.rawValue)",
            "observedGeneration=\(observedGeneration)",
            "measurement.executionDigest=\(measurementEvidence.executionDigest.value)",
            "measurement.provenanceDigest=\(measurementEvidence.provenanceDigest.value)",
            "measurement.observedGeneration=\(measurementEvidence.observedGeneration)"
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try AcceleratorDigest(digest)
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case mode
        case kind
        case amount
        case unit
        case source
        case observedGeneration
        case measurementEvidence
        case measurementEvidenceDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(AcceleratorExecutionMode.self, forKey: .mode),
            kind: container.decode(AcceleratorBudgetKind.self, forKey: .kind),
            amount: container.decode(UInt64.self, forKey: .amount),
            unit: container.decode(AcceleratorBudgetUnit.self, forKey: .unit),
            source: container.decode(
                AcceleratorEvidenceSource.self,
                forKey: .source
            ),
            observedGeneration: container.decode(
                Int64.self,
                forKey: .observedGeneration
            ),
            measurementEvidence: container.decode(
                AcceleratorBudgetMeasurementEvidence.self,
                forKey: .measurementEvidence
            ),
            measurementEvidenceDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .measurementEvidenceDigest
            ),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

private extension AcceleratorMeasuredBudget {
    func modeEvidenceDigestMatches(
        modeEvidence: [AcceleratorModeEvidence]
    ) -> Bool {
        guard let mode = mode,
              let evidence = modeEvidence.first(where: { $0.mode == mode }),
              let executionEvidence = evidence.executionEvidence else {
            return false
        }
        return evidence.status == .available
            && evidence.source == .hostNativeExecutionSelfTest
            && evidence.evidenceDigest == executionEvidence.provenanceDigest
            && measurementEvidence.executionDigest == executionEvidence.executionDigest
            && measurementEvidence.provenanceDigest == executionEvidence.provenanceDigest
            && measurementEvidence.observedGeneration == executionEvidence.observedGeneration
            && (try? Self.measurementEvidenceDigest(
                mode: mode,
                kind: kind,
                amount: amount,
                unit: unit,
                observedGeneration: observedGeneration,
                measurementEvidence: measurementEvidence
            )) == measurementEvidenceDigest
    }
}

public struct AcceleratorBudgetVector:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let memoryBytes: UInt64
    public let computeUnits: UInt64
    public let concurrencyUnits: UInt64

    private enum CodingKeys: String, CodingKey {
        case memoryBytes
        case computeUnits
        case concurrencyUnits
    }

    public init(
        memoryBytes: UInt64,
        computeUnits: UInt64,
        concurrencyUnits: UInt64
    ) throws {
        guard memoryBytes <= AcceleratorLimits.maxBudgetAmount,
              computeUnits <= AcceleratorLimits.maxBudgetAmount,
              concurrencyUnits > 0,
              concurrencyUnits <= UInt64(AcceleratorLimits.maxConcurrency),
              memoryBytes > 0 || computeUnits > 0 else {
            throw AcceleratorValidation.fail(.invalidBudget, "budget")
        }
        self.memoryBytes = memoryBytes
        self.computeUnits = computeUnits
        self.concurrencyUnits = concurrencyUnits
    }

    public func fits(in other: AcceleratorBudgetVector) -> Bool {
        memoryBytes <= other.memoryBytes
            && computeUnits <= other.computeUnits
            && concurrencyUnits <= other.concurrencyUnits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            memoryBytes: container.decode(UInt64.self, forKey: .memoryBytes),
            computeUnits: container.decode(UInt64.self, forKey: .computeUnits),
            concurrencyUnits: container.decode(
                UInt64.self,
                forKey: .concurrencyUnits
            )
        )
    }
}

public struct AcceleratorInventorySnapshot:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let snapshotID: UUID
    public let hostID: UUID
    public let observedAt: Date
    public let observedGeneration: Int64
    public let modeEvidence: [AcceleratorModeEvidence]
    public let budgets: [AcceleratorMeasuredBudget]

    public init(
        snapshotID: UUID,
        hostID: UUID,
        observedAt: Date,
        observedGeneration: Int64,
        modeEvidence: [AcceleratorModeEvidence],
        budgets: [AcceleratorMeasuredBudget],
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(snapshotID, field: "snapshotID")
        try AcceleratorValidation.uuid(hostID, field: "hostID")
        try AcceleratorValidation.date(observedAt, field: "observedAt")
        try AcceleratorValidation.positiveGeneration(
            observedGeneration,
            field: "observedGeneration"
        )
        guard (1...AcceleratorLimits.maxModeEvidenceCount).contains(
            modeEvidence.count
        ) else {
            throw AcceleratorValidation.fail(.invalidMode, "modeEvidence")
        }
        let orderedModes = modeEvidence.sorted {
            $0.mode.rawValue < $1.mode.rawValue
        }
        try AcceleratorValidation.canonical(
            modeEvidence,
            sortedBy: { $0.mode.rawValue < $1.mode.rawValue },
            field: "modeEvidence"
        )
        guard orderedModes.contains(where: {
            $0.mode == .linuxGuestGPUPassthrough
                && $0.status == .blocked
                && $0.reasonCode == .linuxGuestPassthroughBlocked
        }), orderedModes.contains(where: {
            $0.mode == .linuxGuestANEPassthrough
                && $0.status == .blocked
                && $0.reasonCode == .linuxGuestPassthroughBlocked
        }) else {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "modeEvidence"
            )
        }
        guard (0...AcceleratorLimits.maxBudgetCount).contains(budgets.count) else {
            throw AcceleratorValidation.fail(.invalidBudget, "budgets")
        }
        try AcceleratorValidation.canonical(
            budgets,
            sortedBy: { $0.orderingKey < $1.orderingKey },
            field: "budgets"
        )
        guard budgets.allSatisfy({
            $0.observedGeneration == observedGeneration
                && $0.modeEvidenceDigestMatches(modeEvidence: orderedModes)
        }) else {
            throw AcceleratorValidation.fail(.invalidOrdering, "budgetGeneration")
        }
        self.contractVersion = contractVersion
        self.snapshotID = snapshotID
        self.hostID = hostID
        self.observedAt = observedAt
        self.observedGeneration = observedGeneration
        self.modeEvidence = modeEvidence
        self.budgets = budgets
    }

    public func evidence(for mode: AcceleratorExecutionMode) -> AcceleratorModeEvidence? {
        modeEvidence.first { $0.mode == mode }
    }

    public func budget(
        for mode: AcceleratorExecutionMode,
        kind: AcceleratorBudgetKind
    ) -> AcceleratorMeasuredBudget? {
        budgets.first { $0.mode == mode && $0.kind == kind }
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case snapshotID
        case hostID
        case observedAt
        case observedGeneration
        case modeEvidence
        case budgets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            snapshotID: container.decode(UUID.self, forKey: .snapshotID),
            hostID: container.decode(UUID.self, forKey: .hostID),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            observedGeneration: container.decode(
                Int64.self,
                forKey: .observedGeneration
            ),
            modeEvidence: container.decode(
                [AcceleratorModeEvidence].self,
                forKey: .modeEvidence
            ),
            budgets: container.decode(
                [AcceleratorMeasuredBudget].self,
                forKey: .budgets
            ),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorQuota: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let budget: AcceleratorBudgetVector
    public let maxInputBytes: Int
    public let maxOutputBytes: Int
    public let maxTimeoutMilliseconds: Int

    public init(
        budget: AcceleratorBudgetVector,
        maxInputBytes: Int,
        maxOutputBytes: Int,
        maxTimeoutMilliseconds: Int,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        guard (1...AcceleratorLimits.maxInputBytes).contains(maxInputBytes) else {
            throw AcceleratorValidation.fail(.inputLimitExceeded, "maxInputBytes")
        }
        guard (1...AcceleratorLimits.maxOutputBytes).contains(maxOutputBytes) else {
            throw AcceleratorValidation.fail(.outputLimitExceeded, "maxOutputBytes")
        }
        guard (1...AcceleratorLimits.maxTimeoutMilliseconds).contains(
            maxTimeoutMilliseconds
        ) else {
            throw AcceleratorValidation.fail(
                .timeoutLimitExceeded,
                "maxTimeoutMilliseconds"
            )
        }
        self.contractVersion = contractVersion
        self.budget = budget
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
        self.maxTimeoutMilliseconds = maxTimeoutMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case budget
        case maxInputBytes
        case maxOutputBytes
        case maxTimeoutMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            budget: container.decode(
                AcceleratorBudgetVector.self,
                forKey: .budget
            ),
            maxInputBytes: container.decode(Int.self, forKey: .maxInputBytes),
            maxOutputBytes: container.decode(Int.self, forKey: .maxOutputBytes),
            maxTimeoutMilliseconds: container.decode(
                Int.self,
                forKey: .maxTimeoutMilliseconds
            ),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorClaim: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let claimID: UUID
    public let scope: AcceleratorScope
    public let allowedModes: [AcceleratorExecutionMode]
    public let modelHash: AcceleratorDigest?
    public let quota: AcceleratorQuota
    public let inventorySnapshotID: UUID
    public let inventoryGeneration: Int64
    public let issuer: AcceleratorAuthenticationContext
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        claimID: UUID,
        scope: AcceleratorScope,
        allowedModes: [AcceleratorExecutionMode],
        modelHash: AcceleratorDigest?,
        quota: AcceleratorQuota,
        inventorySnapshotID: UUID,
        inventoryGeneration: Int64,
        issuer: AcceleratorAuthenticationContext,
        issuedAt: Date,
        expiresAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(claimID, field: "claimID")
        try AcceleratorValidation.scope(scope)
        try AcceleratorValidation.uuid(inventorySnapshotID, field: "inventorySnapshotID")
        try AcceleratorValidation.positiveGeneration(
            inventoryGeneration,
            field: "inventoryGeneration"
        )
        guard (1...AcceleratorLimits.maxAllowedModeCount).contains(
            allowedModes.count
        ),
              allowedModes.allSatisfy({ !$0.isLinuxGuestPassthrough }) else {
            throw AcceleratorValidation.fail(.linuxGuestPassthroughBlocked, "allowedModes")
        }
        try AcceleratorValidation.canonical(
            allowedModes,
            sortedBy: { $0.rawValue < $1.rawValue },
            field: "allowedModes"
        )
        try AcceleratorValidation.dateRange(
            start: issuedAt,
            end: expiresAt,
            startField: "issuedAt",
            endField: "expiresAt"
        )
        try issuer.validateActive(at: issuedAt)
        self.contractVersion = contractVersion
        self.claimID = claimID
        self.scope = scope
        self.allowedModes = allowedModes
        self.modelHash = modelHash
        self.quota = quota
        self.inventorySnapshotID = inventorySnapshotID
        self.inventoryGeneration = inventoryGeneration
        self.issuer = issuer
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case claimID
        case scope
        case allowedModes
        case modelHash
        case quota
        case inventorySnapshotID
        case inventoryGeneration
        case issuer
        case issuedAt
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            claimID: container.decode(UUID.self, forKey: .claimID),
            scope: container.decode(AcceleratorScope.self, forKey: .scope),
            allowedModes: container.decode(
                [AcceleratorExecutionMode].self,
                forKey: .allowedModes
            ),
            modelHash: container.decodeIfPresent(
                AcceleratorDigest.self,
                forKey: .modelHash
            ),
            quota: container.decode(AcceleratorQuota.self, forKey: .quota),
            inventorySnapshotID: container.decode(
                UUID.self,
                forKey: .inventorySnapshotID
            ),
            inventoryGeneration: container.decode(
                Int64.self,
                forKey: .inventoryGeneration
            ),
            issuer: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .issuer
            ),
            issuedAt: container.decode(Date.self, forKey: .issuedAt),
            expiresAt: container.decode(Date.self, forKey: .expiresAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorFence: Codable, Equatable, Hashable, Sendable {
    public let nodeEpoch: Int64
    public let reservationSequence: Int64

    private enum CodingKeys: String, CodingKey {
        case nodeEpoch
        case reservationSequence
    }

    public init(nodeEpoch: Int64, reservationSequence: Int64) throws {
        try AcceleratorValidation.positiveGeneration(nodeEpoch, field: "nodeEpoch")
        try AcceleratorValidation.positiveGeneration(
            reservationSequence,
            field: "reservationSequence"
        )
        self.nodeEpoch = nodeEpoch
        self.reservationSequence = reservationSequence
    }

    public var stableKey: String {
        "\(nodeEpoch):\(reservationSequence)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeEpoch: container.decode(Int64.self, forKey: .nodeEpoch),
            reservationSequence: container.decode(
                Int64.self,
                forKey: .reservationSequence
            )
        )
    }
}
