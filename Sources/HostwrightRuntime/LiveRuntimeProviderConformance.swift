import CryptoKit
import Foundation
import HostwrightCore

/// A canonical, semantic runtime snapshot used only by maintainer live qualification.
/// Implementations must exclude volatile timestamps and other non-semantic values.
public struct RuntimeProviderLiveQualificationSnapshot: Codable, Equatable, Sendable {
    public let inventorySHA256: String
    public let unmanagedSentinelSHA256: String

    public init(inventorySHA256: String, unmanagedSentinelSHA256: String) {
        self.inventorySHA256 = inventorySHA256
        self.unmanagedSentinelSHA256 = unmanagedSentinelSHA256
    }
}

public struct RuntimeProviderLiveQualificationDriverResult: Equatable, Sendable {
    public let status: RuntimeProviderConformanceEvidenceStatus
    public let normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics?
    public let resourceTransition: RuntimeProviderLiveQualificationResourceTransition?
    public let faultControl: RuntimeProviderLiveQualificationFaultControlEvidence?

    public init(
        status: RuntimeProviderConformanceEvidenceStatus,
        normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics? = nil,
        resourceTransition: RuntimeProviderLiveQualificationResourceTransition? = nil,
        faultControl: RuntimeProviderLiveQualificationFaultControlEvidence? = nil
    ) {
        self.status = status
        self.normalizedFailureSemantics = normalizedFailureSemantics
        self.resourceTransition = resourceTransition
        self.faultControl = faultControl
    }

    public static func passed(
        semantics: RuntimeProviderConformanceFailureSemantics? = nil,
        resourceTransition: RuntimeProviderLiveQualificationResourceTransition? = nil,
        faultControl: RuntimeProviderLiveQualificationFaultControlEvidence? = nil
    ) -> RuntimeProviderLiveQualificationDriverResult {
        RuntimeProviderLiveQualificationDriverResult(
            status: .passed,
            normalizedFailureSemantics: semantics,
            resourceTransition: resourceTransition,
            faultControl: faultControl
        )
    }
}

public struct RuntimeProviderLiveQualificationResourceTransition: Codable, Equatable, Sendable {
    public let resourceUUID: String
    public let projectUUID: String
    public let beforeLifecycle: RuntimeInventoryLifecycleState
    public let afterLifecycle: RuntimeInventoryLifecycleState
    public let beforeRuntimeInstanceSHA256: String?
    public let afterRuntimeInstanceSHA256: String?
    public let beforeObservationSHA256: String
    public let afterObservationSHA256: String
    public let beforeObservationGeneration: Int
    public let afterObservationGeneration: Int

    public init(
        resourceUUID: String,
        projectUUID: String,
        beforeLifecycle: RuntimeInventoryLifecycleState,
        afterLifecycle: RuntimeInventoryLifecycleState,
        beforeRuntimeInstanceSHA256: String?,
        afterRuntimeInstanceSHA256: String?,
        beforeObservationSHA256: String,
        afterObservationSHA256: String,
        beforeObservationGeneration: Int,
        afterObservationGeneration: Int
    ) {
        self.resourceUUID = resourceUUID
        self.projectUUID = projectUUID
        self.beforeLifecycle = beforeLifecycle
        self.afterLifecycle = afterLifecycle
        self.beforeRuntimeInstanceSHA256 = beforeRuntimeInstanceSHA256
        self.afterRuntimeInstanceSHA256 = afterRuntimeInstanceSHA256
        self.beforeObservationSHA256 = beforeObservationSHA256
        self.afterObservationSHA256 = afterObservationSHA256
        self.beforeObservationGeneration = beforeObservationGeneration
        self.afterObservationGeneration = afterObservationGeneration
    }
}

public struct RuntimeProviderLiveQualificationFaultControlEvidence: Codable, Equatable, Sendable {
    public let deadlineEnforced: Bool
    public let faultControllerActivated: Bool
    public let processTreeTerminated: Bool
    public let recoveryObservationSHA256: String

    public init(
        deadlineEnforced: Bool,
        faultControllerActivated: Bool,
        processTreeTerminated: Bool,
        recoveryObservationSHA256: String
    ) {
        self.deadlineEnforced = deadlineEnforced
        self.faultControllerActivated = faultControllerActivated
        self.processTreeTerminated = processTreeTerminated
        self.recoveryObservationSHA256 = recoveryObservationSHA256
    }
}

/// The production boundary implemented by the maintainer-only live qualification executable.
/// Each operation must use the real provider and return only after structured re-observation.
public protocol RuntimeProviderLiveQualificationDriver: Sendable {
    var providerID: RuntimeProviderID { get }
    var providerVersion: String { get }
    var advertisedFeatures: [RuntimeProviderFeature] { get }

    func captureCanonicalInventory() async throws -> RuntimeProviderLiveQualificationSnapshot
    func negotiateCapabilities() async throws -> RuntimeProviderLiveQualificationDriverResult
    func observeRuntime() async throws -> RuntimeProviderLiveQualificationDriverResult
    func verifyUUIDIdentity() async throws -> RuntimeProviderLiveQualificationDriverResult
    func refuseMissingLocalImage() async throws -> RuntimeProviderLiveQualificationDriverResult
    func createManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult
    func startManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult
    func restartManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult
    func deleteManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult
    func readBoundedLogs(
        maximumBytes: Int,
        maximumLines: Int
    ) async throws -> RuntimeProviderLiveQualificationDriverResult
    func readBoundedStats(
        maximumBytes: Int
    ) async throws -> RuntimeProviderLiveQualificationDriverResult
    func exerciseTimeoutRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult
    func exerciseCancellationRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult
    func exerciseCrashRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult
    func restartProvider() async throws -> RuntimeProviderLiveQualificationDriverResult
    func injectRecoverablePartialEffect() async throws -> RuntimeProviderLiveQualificationDriverResult
    func verifyUnmanagedSentinel() async throws -> RuntimeProviderLiveQualificationDriverResult
    func cleanupManagedResources() async throws -> RuntimeProviderLiveQualificationDriverResult
}

public enum RuntimeProviderLiveQualificationRecordStatus: String, Codable, Equatable, Sendable {
    case passed
    case driverAssertionFailed = "driver-assertion-failed"
    case driverError = "driver-error"
    case invalidSnapshot = "invalid-snapshot"
    case invalidResourceTransition = "invalid-resource-transition"
    case invalidFaultControlEvidence = "invalid-fault-control-evidence"
    case unmanagedSentinelChanged = "unmanaged-sentinel-changed"
    case unexpectedInventoryChange = "unexpected-inventory-change"
    case exactCleanupMismatch = "exact-cleanup-mismatch"
    case unsafePriorFailure = "unsafe-prior-failure"
}

public struct RuntimeProviderLiveQualificationRecord: Codable, Equatable, Sendable {
    public let caseIdentifier: RuntimeProviderConformanceCaseID
    public let status: RuntimeProviderLiveQualificationRecordStatus
    public let beforeInventorySHA256: String?
    public let afterInventorySHA256: String?
    public let beforeUnmanagedSentinelSHA256: String?
    public let afterUnmanagedSentinelSHA256: String?
    public let normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics?
    public let resourceTransition: RuntimeProviderLiveQualificationResourceTransition?
    public let faultControl: RuntimeProviderLiveQualificationFaultControlEvidence?
}

public enum RuntimeProviderLiveQualificationEvidenceError: Error, Equatable, Sendable {
    case encodedEvidenceTooLarge
}

/// Deterministic evidence emitted by the maintainer-only live conformance runner.
public struct RuntimeProviderLiveQualificationEvidence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumEncodedBytes = 512 * 1_024

    public let schemaVersion: Int
    public let report: RuntimeProviderConformanceReport
    public let baselineInventorySHA256: String?
    public let finalInventorySHA256: String?
    public let records: [RuntimeProviderLiveQualificationRecord]

    init(
        report: RuntimeProviderConformanceReport,
        baselineInventorySHA256: String?,
        finalInventorySHA256: String?,
        records: [RuntimeProviderLiveQualificationRecord]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.report = report
        self.baselineInventorySHA256 = baselineInventorySHA256
        self.finalInventorySHA256 = finalInventorySHA256
        self.records = records
    }

    public var passed: Bool {
        report.passed &&
            report.containsLiveRuntimeEvidence &&
            records.map(\.caseIdentifier) == RuntimeProviderConformanceCaseID.allCases &&
            records.allSatisfy { $0.status == .passed } &&
            baselineInventorySHA256 != nil &&
            baselineInventorySHA256 == finalInventorySHA256
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw RuntimeProviderLiveQualificationEvidenceError.encodedEvidenceTooLarge
        }
        return data
    }

    public func evidenceSHA256() throws -> String {
        SHA256.hash(data: try canonicalJSONData())
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum RuntimeProviderLiveQualificationRunner {
    public static func run(
        driver: any RuntimeProviderLiveQualificationDriver
    ) async -> RuntimeProviderLiveQualificationEvidence {
        let subject = RuntimeProviderLiveQualificationSubject(driver: driver)
        let report = await RuntimeProviderConformanceSuite.run(subject)
        await subject.ensureCleanupFinalized()
        return await subject.evidence(report: report)
    }
}

private actor RuntimeProviderLiveQualificationSubject: RuntimeProviderConformanceSubject {
    nonisolated let conformanceIdentity: RuntimeProviderConformanceSubjectIdentity
    nonisolated let advertisedFeatures: [RuntimeProviderFeature]

    private let driver: any RuntimeProviderLiveQualificationDriver
    private var baseline: RuntimeProviderLiveQualificationSnapshot?
    private var finalInventorySHA256: String?
    private var records: [RuntimeProviderLiveQualificationRecord] = []
    private var lastResourceTransition: RuntimeProviderLiveQualificationResourceTransition?
    private var cleanupFinalized = false
    private var unsafeForFurtherMutation = false

    init(driver: any RuntimeProviderLiveQualificationDriver) {
        self.driver = driver
        self.conformanceIdentity = RuntimeProviderConformanceSubjectIdentity(
            providerID: Self.boundedProviderID(driver.providerID),
            providerVersion: Self.boundedProviderVersion(driver.providerVersion),
            evidenceClass: .liveRuntime
        )
        self.advertisedFeatures = Self.boundedFeatures(driver.advertisedFeatures)
    }

    func exercise(
        _ testCase: RuntimeProviderConformanceCase
    ) async throws -> RuntimeProviderConformanceCaseEvidence {
        if testCase.identifier == .exactCleanup {
            return await finalizeExactCleanup(testCase)
        }
        if unsafeForFurtherMutation {
            return recordFailure(testCase, status: .unsafePriorFailure)
        }
        let before: RuntimeProviderLiveQualificationSnapshot
        do {
            before = try await driver.captureCanonicalInventory()
        } catch {
            return recordFailure(testCase, status: .driverError)
        }
        guard Self.valid(before) else {
            return recordFailure(testCase, status: .invalidSnapshot)
        }
        if baseline == nil {
            baseline = before
        }

        let driverResult: RuntimeProviderLiveQualificationDriverResult
        do {
            driverResult = try await execute(testCase.identifier)
        } catch {
            let after = try? await validSnapshot()
            unsafeForFurtherMutation = Self.mayMutateRuntime(testCase.identifier) || after == nil ||
                after?.inventorySHA256 != before.inventorySHA256 ||
                after?.unmanagedSentinelSHA256 != before.unmanagedSentinelSHA256
            return recordFailure(
                testCase,
                status: .driverError,
                before: before,
                after: after
            )
        }

        let after: RuntimeProviderLiveQualificationSnapshot
        do {
            after = try await driver.captureCanonicalInventory()
        } catch {
            unsafeForFurtherMutation = true
            return recordFailure(
                testCase,
                status: .driverError,
                before: before,
                semantics: driverResult.normalizedFailureSemantics
            )
        }
        guard Self.valid(after) else {
            unsafeForFurtherMutation = true
            return recordFailure(
                testCase,
                status: .invalidSnapshot,
                before: before,
                semantics: driverResult.normalizedFailureSemantics
            )
        }

        let status = qualificationStatus(
            for: testCase.identifier,
            before: before,
            after: after,
            driverResult: driverResult
        )
        records.append(
            RuntimeProviderLiveQualificationRecord(
                caseIdentifier: testCase.identifier,
                status: status,
                beforeInventorySHA256: before.inventorySHA256,
                afterInventorySHA256: after.inventorySHA256,
                beforeUnmanagedSentinelSHA256: before.unmanagedSentinelSHA256,
                afterUnmanagedSentinelSHA256: after.unmanagedSentinelSHA256,
                normalizedFailureSemantics: driverResult.normalizedFailureSemantics,
                resourceTransition: driverResult.resourceTransition,
                faultControl: driverResult.faultControl
            )
        )
        if status != .passed &&
            (Self.mayMutateRuntime(testCase.identifier) ||
                status == .unmanagedSentinelChanged ||
                status == .unexpectedInventoryChange ||
                status == .invalidSnapshot) {
            unsafeForFurtherMutation = true
        }
        return RuntimeProviderConformanceCaseEvidence(
            caseIdentifier: testCase.identifier,
            status: status == .passed ? .passed : .failed,
            normalizedFailureSemantics: driverResult.normalizedFailureSemantics
        )
    }

    func evidence(
        report: RuntimeProviderConformanceReport
    ) -> RuntimeProviderLiveQualificationEvidence {
        RuntimeProviderLiveQualificationEvidence(
            report: report,
            baselineInventorySHA256: baseline?.inventorySHA256,
            finalInventorySHA256: finalInventorySHA256,
            records: records
        )
    }

    func ensureCleanupFinalized() async {
        guard !cleanupFinalized,
              let cleanupCase = RuntimeProviderConformanceSuite.cases.first(where: {
                  $0.identifier == .exactCleanup
              }) else {
            return
        }
        _ = await finalizeExactCleanup(cleanupCase)
    }

    private func execute(
        _ identifier: RuntimeProviderConformanceCaseID
    ) async throws -> RuntimeProviderLiveQualificationDriverResult {
        switch identifier {
        case .capabilityNegotiation:
            try await driver.negotiateCapabilities()
        case .observation:
            try await driver.observeRuntime()
        case .uuidIdentity:
            try await driver.verifyUUIDIdentity()
        case .localImageRefusal:
            try await driver.refuseMissingLocalImage()
        case .create:
            try await driver.createManagedResource()
        case .start:
            try await driver.startManagedResource()
        case .managedRestart:
            try await driver.restartManagedResource()
        case .delete:
            try await driver.deleteManagedResource()
        case .boundedLogs:
            try await driver.readBoundedLogs(
                maximumBytes: RuntimeProviderConformanceLimits.maximumLogBytes,
                maximumLines: RuntimeProviderConformanceLimits.maximumLogLines
            )
        case .boundedStats:
            try await driver.readBoundedStats(
                maximumBytes: RuntimeProviderConformanceLimits.maximumStatsBytes
            )
        case .timeout:
            try await driver.exerciseTimeoutRecovery()
        case .cancellation:
            try await driver.exerciseCancellationRecovery()
        case .crash:
            try await driver.exerciseCrashRecovery()
        case .providerRestart:
            try await driver.restartProvider()
        case .failureInjection:
            try await driver.injectRecoverablePartialEffect()
        case .unmanagedSentinelPreservation:
            try await driver.verifyUnmanagedSentinel()
        case .exactCleanup:
            try await driver.cleanupManagedResources()
        }
    }

    private func qualificationStatus(
        for identifier: RuntimeProviderConformanceCaseID,
        before: RuntimeProviderLiveQualificationSnapshot,
        after: RuntimeProviderLiveQualificationSnapshot,
        driverResult: RuntimeProviderLiveQualificationDriverResult
    ) -> RuntimeProviderLiveQualificationRecordStatus {
        guard driverResult.status == .passed else {
            return .driverAssertionFailed
        }
        guard let baseline,
              before.unmanagedSentinelSHA256 == baseline.unmanagedSentinelSHA256,
              after.unmanagedSentinelSHA256 == baseline.unmanagedSentinelSHA256 else {
            return .unmanagedSentinelChanged
        }
        if Self.requiresNoNetInventoryChange(identifier),
           before.inventorySHA256 != after.inventorySHA256 {
            return .unexpectedInventoryChange
        }
        if identifier == .exactCleanup,
           after.inventorySHA256 != baseline.inventorySHA256 {
            return .exactCleanupMismatch
        }
        if let expectedTransition = Self.expectedTransition(for: identifier) {
            guard let transition = driverResult.resourceTransition,
                  validTransition(
                      transition,
                      expected: expectedTransition,
                      before: before,
                      after: after
                  ) else {
                return .invalidResourceTransition
            }
            lastResourceTransition = transition
        } else if driverResult.resourceTransition != nil {
            return .invalidResourceTransition
        }
        if Self.requiresFaultControl(identifier),
           !Self.validFaultControl(
               driverResult.faultControl,
               for: identifier,
               afterInventorySHA256: after.inventorySHA256
           ) {
            return .invalidFaultControlEvidence
        }
        return .passed
    }

    private func finalizeExactCleanup(
        _ testCase: RuntimeProviderConformanceCase
    ) async -> RuntimeProviderConformanceCaseEvidence {
        guard !cleanupFinalized else {
            return RuntimeProviderConformanceCaseEvidence(
                caseIdentifier: testCase.identifier,
                status: records.last(where: { $0.caseIdentifier == .exactCleanup })?.status == .passed
                    ? .passed
                    : .failed
            )
        }
        cleanupFinalized = true
        let before = try? await validSnapshot()
        let driverResult: RuntimeProviderLiveQualificationDriverResult?
        do {
            driverResult = try await driver.cleanupManagedResources()
        } catch {
            driverResult = nil
        }
        let after = try? await validSnapshot()
        finalInventorySHA256 = after?.inventorySHA256

        let status: RuntimeProviderLiveQualificationRecordStatus
        if driverResult == nil || after == nil {
            status = .driverError
        } else if driverResult?.status != .passed {
            status = .driverAssertionFailed
        } else if let baseline,
                  after?.unmanagedSentinelSHA256 != baseline.unmanagedSentinelSHA256 {
            status = .unmanagedSentinelChanged
        } else if let baseline,
                  after?.inventorySHA256 != baseline.inventorySHA256 {
            status = .exactCleanupMismatch
        } else if let after,
                  !Self.validFaultControl(
                      driverResult?.faultControl,
                      for: .exactCleanup,
                      afterInventorySHA256: after.inventorySHA256
                  ) {
            status = .invalidFaultControlEvidence
        } else if baseline == nil {
            status = .invalidSnapshot
        } else {
            status = .passed
        }
        records.append(
            RuntimeProviderLiveQualificationRecord(
                caseIdentifier: testCase.identifier,
                status: status,
                beforeInventorySHA256: before?.inventorySHA256,
                afterInventorySHA256: after?.inventorySHA256,
                beforeUnmanagedSentinelSHA256: before?.unmanagedSentinelSHA256,
                afterUnmanagedSentinelSHA256: after?.unmanagedSentinelSHA256,
                normalizedFailureSemantics: driverResult?.normalizedFailureSemantics,
                resourceTransition: driverResult?.resourceTransition,
                faultControl: driverResult?.faultControl
            )
        )
        return RuntimeProviderConformanceCaseEvidence(
            caseIdentifier: testCase.identifier,
            status: status == .passed ? .passed : .failed,
            normalizedFailureSemantics: driverResult?.normalizedFailureSemantics
        )
    }

    private func validSnapshot() async throws -> RuntimeProviderLiveQualificationSnapshot? {
        let snapshot = try await driver.captureCanonicalInventory()
        return Self.valid(snapshot) ? snapshot : nil
    }

    private func recordFailure(
        _ testCase: RuntimeProviderConformanceCase,
        status: RuntimeProviderLiveQualificationRecordStatus,
        before: RuntimeProviderLiveQualificationSnapshot? = nil,
        after: RuntimeProviderLiveQualificationSnapshot? = nil,
        semantics: RuntimeProviderConformanceFailureSemantics? = nil
    ) -> RuntimeProviderConformanceCaseEvidence {
        records.append(
            RuntimeProviderLiveQualificationRecord(
                caseIdentifier: testCase.identifier,
                status: status,
                beforeInventorySHA256: before?.inventorySHA256,
                afterInventorySHA256: after?.inventorySHA256,
                beforeUnmanagedSentinelSHA256: before?.unmanagedSentinelSHA256,
                afterUnmanagedSentinelSHA256: after?.unmanagedSentinelSHA256,
                normalizedFailureSemantics: semantics,
                resourceTransition: nil,
                faultControl: nil
            )
        )
        return RuntimeProviderConformanceCaseEvidence(
            caseIdentifier: testCase.identifier,
            status: .failed,
            normalizedFailureSemantics: semantics
        )
    }

    private static func valid(_ snapshot: RuntimeProviderLiveQualificationSnapshot) -> Bool {
        validSHA256(snapshot.inventorySHA256) && validSHA256(snapshot.unmanagedSentinelSHA256)
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }

    private static func requiresNoNetInventoryChange(
        _ identifier: RuntimeProviderConformanceCaseID
    ) -> Bool {
        switch identifier {
        case .create, .start, .managedRestart, .delete, .exactCleanup:
            false
        default:
            true
        }
    }

    private func validTransition(
        _ transition: RuntimeProviderLiveQualificationResourceTransition,
        expected: (RuntimeInventoryLifecycleState, RuntimeInventoryLifecycleState),
        before: RuntimeProviderLiveQualificationSnapshot,
        after: RuntimeProviderLiveQualificationSnapshot
    ) -> Bool {
        guard HostwrightResourceUUID.isValid(transition.resourceUUID),
              HostwrightResourceUUID.isValid(transition.projectUUID),
              transition.beforeLifecycle == expected.0,
              transition.afterLifecycle == expected.1,
              transition.beforeObservationSHA256 == before.inventorySHA256,
              transition.afterObservationSHA256 == after.inventorySHA256,
              transition.beforeObservationGeneration >= 0,
              transition.afterObservationGeneration == transition.beforeObservationGeneration + 1,
              Self.validOptionalSHA256(transition.beforeRuntimeInstanceSHA256),
              Self.validOptionalSHA256(transition.afterRuntimeInstanceSHA256) else {
            return false
        }
        switch (transition.beforeLifecycle, transition.afterLifecycle) {
        case (.missing, .stopped):
            guard transition.beforeRuntimeInstanceSHA256 == nil,
                  transition.afterRuntimeInstanceSHA256 != nil,
                  before.inventorySHA256 != after.inventorySHA256 else {
                return false
            }
        case (.stopped, .running):
            guard transition.beforeRuntimeInstanceSHA256 != nil,
                  transition.beforeRuntimeInstanceSHA256 == transition.afterRuntimeInstanceSHA256,
                  before.inventorySHA256 != after.inventorySHA256 else {
                return false
            }
        case (.running, .running):
            guard transition.beforeRuntimeInstanceSHA256 != nil,
                  transition.afterRuntimeInstanceSHA256 != nil,
                  before.inventorySHA256 != after.inventorySHA256 else {
                return false
            }
        case (.running, .missing):
            guard transition.beforeRuntimeInstanceSHA256 != nil,
                  transition.afterRuntimeInstanceSHA256 == nil,
                  before.inventorySHA256 != after.inventorySHA256 else {
                return false
            }
        default:
            return false
        }
        guard let previous = lastResourceTransition else {
            return transition.beforeLifecycle == .missing
        }
        return previous.resourceUUID == transition.resourceUUID &&
            previous.projectUUID == transition.projectUUID &&
            previous.afterLifecycle == transition.beforeLifecycle &&
            previous.afterRuntimeInstanceSHA256 == transition.beforeRuntimeInstanceSHA256 &&
            previous.afterObservationGeneration == transition.beforeObservationGeneration
    }

    private static func expectedTransition(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> (RuntimeInventoryLifecycleState, RuntimeInventoryLifecycleState)? {
        switch identifier {
        case .create:
            (.missing, .stopped)
        case .start:
            (.stopped, .running)
        case .managedRestart:
            (.running, .running)
        case .delete:
            (.running, .missing)
        default:
            nil
        }
    }

    private static func requiresFaultControl(
        _ identifier: RuntimeProviderConformanceCaseID
    ) -> Bool {
        switch identifier {
        case .timeout, .cancellation, .crash, .failureInjection, .exactCleanup:
            true
        default:
            false
        }
    }

    private static func validFaultControl(
        _ evidence: RuntimeProviderLiveQualificationFaultControlEvidence?,
        for identifier: RuntimeProviderConformanceCaseID,
        afterInventorySHA256: String
    ) -> Bool {
        guard let evidence,
              validSHA256(evidence.recoveryObservationSHA256),
              evidence.recoveryObservationSHA256 == afterInventorySHA256 else {
            return false
        }
        switch identifier {
        case .exactCleanup:
            return evidence.deadlineEnforced
        case .timeout:
            return evidence.deadlineEnforced &&
                evidence.faultControllerActivated &&
                evidence.processTreeTerminated
        case .cancellation, .crash:
            return evidence.faultControllerActivated && evidence.processTreeTerminated
        case .failureInjection:
            return evidence.faultControllerActivated
        default:
            return false
        }
    }

    private static func validOptionalSHA256(_ value: String?) -> Bool {
        value == nil || validSHA256(value!)
    }

    private static func mayMutateRuntime(
        _ identifier: RuntimeProviderConformanceCaseID
    ) -> Bool {
        switch identifier {
        case .create, .start, .managedRestart, .delete, .timeout, .cancellation,
             .crash, .providerRestart, .failureInjection:
            true
        default:
            false
        }
    }

    private static func boundedProviderID(_ value: RuntimeProviderID) -> RuntimeProviderID {
        guard value.rawValue.utf8.count <= 64,
              RuntimeProviderID.knownValues.contains(value) else {
            return RuntimeProviderID(rawValue: "invalid")
        }
        return value
    }

    private static func boundedProviderVersion(_ value: String) -> String {
        value.utf8.count <= 64 ? value : "invalid"
    }

    private static func boundedFeatures(
        _ values: [RuntimeProviderFeature]
    ) -> [RuntimeProviderFeature] {
        guard values.count <= 64,
              values.allSatisfy({ $0.rawValue.utf8.count <= 64 }) else {
            return [.observation, .observation]
        }
        return values
    }
}
