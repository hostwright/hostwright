import Foundation
import XCTest
@testable import HostwrightRuntime

final class LiveRuntimeProviderConformanceTests: XCTestCase {
    func testRunnerExecutesEveryCaseAndEmitsDeterministicBoundedLiveEvidence() async throws {
        let firstDriver = RecordingLiveQualificationDriver()
        let first = await RuntimeProviderLiveQualificationRunner.run(driver: firstDriver)

        XCTAssertTrue(first.passed)
        XCTAssertTrue(first.report.passed)
        XCTAssertTrue(first.report.containsLiveRuntimeEvidence)
        XCTAssertEqual(
            first.records.map(\.caseIdentifier),
            RuntimeProviderConformanceCaseID.allCases
        )
        XCTAssertTrue(first.records.allSatisfy { $0.status == .passed })
        XCTAssertEqual(first.baselineInventorySHA256, RecordingLiveQualificationDriver.baselineDigest)
        XCTAssertEqual(first.finalInventorySHA256, RecordingLiveQualificationDriver.baselineDigest)
        XCTAssertTrue(first.records.allSatisfy {
            $0.beforeUnmanagedSentinelSHA256 == RecordingLiveQualificationDriver.sentinelDigest &&
                $0.afterUnmanagedSentinelSHA256 == RecordingLiveQualificationDriver.sentinelDigest
        })

        let audit = await firstDriver.audit()
        XCTAssertEqual(audit.caseCalls, RuntimeProviderConformanceCaseID.allCases)
        XCTAssertEqual(audit.snapshotCalls, RuntimeProviderConformanceCaseID.allCases.count * 2)
        XCTAssertEqual(
            audit.logLimit,
            RecordingLiveQualificationDriver.LogLimit(
                bytes: RuntimeProviderConformanceLimits.maximumLogBytes,
                lines: RuntimeProviderConformanceLimits.maximumLogLines
            )
        )
        XCTAssertEqual(audit.statsLimit, RuntimeProviderConformanceLimits.maximumStatsBytes)

        let second = await RuntimeProviderLiveQualificationRunner.run(
            driver: RecordingLiveQualificationDriver()
        )
        let firstJSON = try first.canonicalJSONData()
        XCTAssertEqual(firstJSON, try second.canonicalJSONData())
        XCTAssertEqual(try first.evidenceSHA256(), try second.evidenceSHA256())
        XCTAssertLessThanOrEqual(
            firstJSON.count,
            RuntimeProviderLiveQualificationEvidence.maximumEncodedBytes
        )
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                RuntimeProviderLiveQualificationEvidence.self,
                from: firstJSON
            )
        )
    }

    func testRunnerFailsClosedWhenUnmanagedSentinelChanges() async {
        let evidence = await RuntimeProviderLiveQualificationRunner.run(
            driver: RecordingLiveQualificationDriver(
                fault: .mutateSentinel(.failureInjection)
            )
        )

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(
            evidence.record(for: .failureInjection)?.status,
            .unmanagedSentinelChanged
        )
        XCTAssertEqual(
            evidence.report.result(for: .failureInjection)?.failure,
            .assertionFailed
        )
    }

    func testRunnerRequiresExactFinalInventoryCleanup() async {
        let evidence = await RuntimeProviderLiveQualificationRunner.run(
            driver: RecordingLiveQualificationDriver(fault: .cleanupMismatch)
        )

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(
            evidence.record(for: .exactCleanup)?.status,
            .exactCleanupMismatch
        )
        XCTAssertNotEqual(evidence.baselineInventorySHA256, evidence.finalInventorySHA256)
        XCTAssertEqual(
            evidence.report.result(for: .exactCleanup)?.failure,
            .assertionFailed
        )
    }

    func testRunnerRejectsNetMutationFromReadOnlyCase() async {
        let evidence = await RuntimeProviderLiveQualificationRunner.run(
            driver: RecordingLiveQualificationDriver(
                fault: .mutateInventory(.observation)
            )
        )

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(
            evidence.record(for: .observation)?.status,
            .unexpectedInventoryChange
        )
    }

    func testRunnerRecordsDriverErrorsWithoutRetainingDiagnostics() async throws {
        let driver = RecordingLiveQualificationDriver(fault: .throwError(.timeout))
        let evidence = await RuntimeProviderLiveQualificationRunner.run(
            driver: driver
        )

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(evidence.record(for: .timeout)?.status, .driverError)
        XCTAssertEqual(evidence.report.result(for: .timeout)?.failure, .assertionFailed)
        let audit = await driver.audit()
        XCTAssertEqual(audit.caseCalls.last, .exactCleanup)
        let encoded = try XCTUnwrap(String(data: evidence.canonicalJSONData(), encoding: .utf8))
        XCTAssertFalse(encoded.contains(RecordingLiveQualificationDriver.sensitiveErrorText))
    }

    func testRunnerFailsClosedOnDriverAssertionAndStillCleansUp() async {
        let driver = RecordingLiveQualificationDriver(fault: .failAssertion(.boundedStats))
        let evidence = await RuntimeProviderLiveQualificationRunner.run(driver: driver)

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(
            evidence.record(for: .boundedStats)?.status,
            .driverAssertionFailed
        )
        let audit = await driver.audit()
        XCTAssertEqual(audit.caseCalls.last, .exactCleanup)
        XCTAssertEqual(evidence.baselineInventorySHA256, evidence.finalInventorySHA256)
    }

    func testRunnerRejectsInvalidSnapshotAndBoundsUntrustedIdentityMetadata() async throws {
        let oversized = String(repeating: "x", count: 1_000_000)
        let evidence = await RuntimeProviderLiveQualificationRunner.run(
            driver: RecordingLiveQualificationDriver(
                providerVersion: oversized,
                advertisedFeatures: [RuntimeProviderFeature(rawValue: oversized)],
                fault: .invalidFirstSnapshot
            )
        )

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(evidence.record(for: .capabilityNegotiation)?.status, .invalidSnapshot)
        XCTAssertEqual(evidence.report.subject.providerVersion, "invalid")
        XCTAssertLessThanOrEqual(
            try evidence.canonicalJSONData().count,
            RuntimeProviderLiveQualificationEvidence.maximumEncodedBytes
        )
        XCTAssertFalse(
            String(data: try evidence.canonicalJSONData(), encoding: .utf8)?.contains(oversized) ?? true
        )
    }

    func testExpectedFailureSemanticsFlowThroughLiveDriverAndSuite() async {
        let evidence = await RuntimeProviderLiveQualificationRunner.run(
            driver: RecordingLiveQualificationDriver()
        )

        let expected: [RuntimeProviderConformanceCaseID: RuntimeProviderConformanceFailureSemantics] = [
            .localImageRefusal: .init(
                category: .rejected,
                retryDisposition: .never,
                recoveryDisposition: .none
            ),
            .timeout: .init(
                category: .timedOut,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            ),
            .cancellation: .init(
                category: .cancelled,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            ),
            .crash: .init(
                category: .crashed,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            ),
            .failureInjection: .init(
                category: .partialEffect,
                retryDisposition: .resumeFromCheckpoint,
                recoveryDisposition: .resume
            )
        ]
        for (identifier, semantics) in expected {
            XCTAssertEqual(
                evidence.report.result(for: identifier)?.normalizedFailureSemantics,
                semantics
            )
            XCTAssertEqual(
                evidence.record(for: identifier)?.normalizedFailureSemantics,
                semantics
            )
        }
    }

    func testRunnerRejectsConstantInventoryNoOpLifecycleDriver() async {
        let driver = RecordingLiveQualificationDriver(fault: .noOpLifecycle)
        let evidence = await RuntimeProviderLiveQualificationRunner.run(driver: driver)

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(
            evidence.record(for: .create)?.status,
            .invalidResourceTransition
        )
        XCTAssertEqual(
            evidence.record(for: .start)?.status,
            .unsafePriorFailure
        )
        XCTAssertEqual(evidence.record(for: .exactCleanup)?.status, .passed)
        XCTAssertEqual(evidence.baselineInventorySHA256, evidence.finalInventorySHA256)
        let audit = await driver.audit()
        XCTAssertEqual(audit.caseCalls, [.capabilityNegotiation, .observation, .uuidIdentity,
                                         .localImageRefusal, .create, .exactCleanup])
    }

    func testCleanupDoesNotDependOnPreCleanupSnapshot() async {
        let driver = RecordingLiveQualificationDriver(fault: .invalidPreCleanupSnapshot)
        let evidence = await RuntimeProviderLiveQualificationRunner.run(driver: driver)

        XCTAssertTrue(evidence.passed)
        XCTAssertEqual(evidence.record(for: .exactCleanup)?.status, .passed)
        XCTAssertNil(evidence.record(for: .exactCleanup)?.beforeInventorySHA256)
        XCTAssertEqual(evidence.finalInventorySHA256, RecordingLiveQualificationDriver.baselineDigest)
        let audit = await driver.audit()
        XCTAssertEqual(audit.caseCalls.last, .exactCleanup)
    }

    func testDriverFailureAfterMutationSkipsUnsafeCasesAndStillCleansExactly() async {
        let driver = RecordingLiveQualificationDriver(fault: .throwAfterMutation(.create))
        let evidence = await RuntimeProviderLiveQualificationRunner.run(driver: driver)

        XCTAssertFalse(evidence.passed)
        XCTAssertEqual(evidence.record(for: .create)?.status, .driverError)
        XCTAssertEqual(evidence.record(for: .start)?.status, .unsafePriorFailure)
        XCTAssertEqual(evidence.record(for: .exactCleanup)?.status, .passed)
        XCTAssertEqual(evidence.baselineInventorySHA256, evidence.finalInventorySHA256)
        let audit = await driver.audit()
        XCTAssertEqual(audit.caseCalls.last, .exactCleanup)
    }
}

private extension RuntimeProviderLiveQualificationEvidence {
    func record(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderLiveQualificationRecord? {
        records.first { $0.caseIdentifier == identifier }
    }
}

private extension RuntimeProviderConformanceReport {
    func result(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderConformanceCaseResult? {
        cases.first { $0.caseIdentifier == identifier }
    }
}

private actor RecordingLiveQualificationDriver: RuntimeProviderLiveQualificationDriver {
    static let baselineDigest = String(repeating: "a", count: 64)
    static let createdDigest = String(repeating: "c", count: 64)
    static let runningDigest = String(repeating: "d", count: 64)
    static let changedDigest = String(repeating: "e", count: 64)
    static let sentinelDigest = String(repeating: "b", count: 64)
    static let changedSentinelDigest = String(repeating: "f", count: 64)
    static let sensitiveErrorText = "token-that-must-not-enter-evidence"

    nonisolated let providerID: RuntimeProviderID
    nonisolated let providerVersion: String
    nonisolated let advertisedFeatures: [RuntimeProviderFeature]

    private let fault: Fault?
    private var inventoryDigest = baselineDigest
    private var sentinelDigest = sentinelDigest
    private var caseCalls: [RuntimeProviderConformanceCaseID] = []
    private var snapshotCalls = 0
    private var logLimit: LogLimit?
    private var statsLimit: Int?
    private var lifecycle: RuntimeInventoryLifecycleState = .missing
    private var runtimeInstanceSHA256: String?
    private var observationGeneration = 0

    init(
        providerID: RuntimeProviderID = .appleContainerCLI,
        providerVersion: String = "1.1.0",
        advertisedFeatures: [RuntimeProviderFeature] = [
            .observation,
            .lifecycle,
            .processControl,
            .streaming,
            .images,
            .cancellation,
            .timeouts,
            .errors,
            .cleanup
        ],
        fault: Fault? = nil
    ) {
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.advertisedFeatures = advertisedFeatures
        self.fault = fault
    }

    func captureCanonicalInventory() async throws -> RuntimeProviderLiveQualificationSnapshot {
        defer { snapshotCalls += 1 }
        if fault == .invalidFirstSnapshot && snapshotCalls == 0 {
            return RuntimeProviderLiveQualificationSnapshot(
                inventorySHA256: "INVALID",
                unmanagedSentinelSHA256: sentinelDigest
            )
        }
        if fault == .invalidPreCleanupSnapshot && snapshotCalls == 32 {
            throw DriverError.injected(Self.sensitiveErrorText)
        }
        return RuntimeProviderLiveQualificationSnapshot(
            inventorySHA256: inventoryDigest,
            unmanagedSentinelSHA256: sentinelDigest
        )
    }

    func negotiateCapabilities() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.capabilityNegotiation)
    }

    func observeRuntime() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.observation)
    }

    func verifyUUIDIdentity() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.uuidIdentity)
    }

    func refuseMissingLocalImage() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.localImageRefusal)
    }

    func createManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.create)
    }

    func startManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.start)
    }

    func restartManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.managedRestart)
    }

    func deleteManagedResource() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.delete)
    }

    func readBoundedLogs(
        maximumBytes: Int,
        maximumLines: Int
    ) async throws -> RuntimeProviderLiveQualificationDriverResult {
        logLimit = LogLimit(bytes: maximumBytes, lines: maximumLines)
        return try exercise(.boundedLogs)
    }

    func readBoundedStats(
        maximumBytes: Int
    ) async throws -> RuntimeProviderLiveQualificationDriverResult {
        statsLimit = maximumBytes
        return try exercise(.boundedStats)
    }

    func exerciseTimeoutRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.timeout)
    }

    func exerciseCancellationRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.cancellation)
    }

    func exerciseCrashRecovery() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.crash)
    }

    func restartProvider() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.providerRestart)
    }

    func injectRecoverablePartialEffect() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.failureInjection)
    }

    func verifyUnmanagedSentinel() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.unmanagedSentinelPreservation)
    }

    func cleanupManagedResources() async throws -> RuntimeProviderLiveQualificationDriverResult {
        try exercise(.exactCleanup)
    }

    func audit() -> Audit {
        Audit(
            caseCalls: caseCalls,
            snapshotCalls: snapshotCalls,
            logLimit: logLimit,
            statsLimit: statsLimit
        )
    }

    private func exercise(
        _ identifier: RuntimeProviderConformanceCaseID
    ) throws -> RuntimeProviderLiveQualificationDriverResult {
        caseCalls.append(identifier)
        if fault == .throwError(identifier) {
            throw DriverError.injected(Self.sensitiveErrorText)
        }
        if fault == .failAssertion(identifier) {
            return RuntimeProviderLiveQualificationDriverResult(status: .failed)
        }

        let transition = applyLifecycleTransition(identifier)
        if fault == .throwAfterMutation(identifier) {
            throw DriverError.injected(Self.sensitiveErrorText)
        }
        switch identifier {
        case .exactCleanup:
            inventoryDigest = fault == .cleanupMismatch
                ? Self.changedDigest
                : Self.baselineDigest
            lifecycle = .missing
            runtimeInstanceSHA256 = nil
        default:
            break
        }
        if fault == .mutateInventory(identifier) {
            inventoryDigest = Self.changedDigest
        }
        if fault == .mutateSentinel(identifier) {
            sentinelDigest = Self.changedSentinelDigest
        }

        return .passed(
            semantics: Self.expectedSemantics(for: identifier),
            resourceTransition: transition,
            faultControl: faultControlEvidence(for: identifier)
        )
    }

    private func applyLifecycleTransition(
        _ identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderLiveQualificationResourceTransition? {
        guard fault != .noOpLifecycle else { return nil }
        let beforeDigest = inventoryDigest
        let beforeLifecycle = lifecycle
        let beforeInstance = runtimeInstanceSHA256
        let beforeGeneration = observationGeneration
        switch identifier {
        case .create:
            inventoryDigest = Self.createdDigest
            lifecycle = .created
            runtimeInstanceSHA256 = Self.createdDigest
        case .start:
            inventoryDigest = Self.runningDigest
            lifecycle = .running
        case .managedRestart:
            break
        case .delete:
            inventoryDigest = Self.baselineDigest
            lifecycle = .missing
            runtimeInstanceSHA256 = nil
        default:
            return nil
        }
        observationGeneration += 1
        return RuntimeProviderLiveQualificationResourceTransition(
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            projectUUID: "22222222-2222-4222-8222-222222222222",
            beforeLifecycle: beforeLifecycle,
            afterLifecycle: lifecycle,
            beforeRuntimeInstanceSHA256: beforeInstance,
            afterRuntimeInstanceSHA256: runtimeInstanceSHA256,
            beforeObservationSHA256: beforeDigest,
            afterObservationSHA256: inventoryDigest,
            beforeObservationGeneration: beforeGeneration,
            afterObservationGeneration: observationGeneration
        )
    }

    private func faultControlEvidence(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderLiveQualificationFaultControlEvidence? {
        switch identifier {
        case .exactCleanup:
            RuntimeProviderLiveQualificationFaultControlEvidence(
                deadlineEnforced: true,
                faultControllerActivated: false,
                processTreeTerminated: false,
                recoveryObservationSHA256: inventoryDigest
            )
        case .timeout:
            RuntimeProviderLiveQualificationFaultControlEvidence(
                deadlineEnforced: true,
                faultControllerActivated: true,
                processTreeTerminated: true,
                recoveryObservationSHA256: inventoryDigest
            )
        case .cancellation, .crash:
            RuntimeProviderLiveQualificationFaultControlEvidence(
                deadlineEnforced: false,
                faultControllerActivated: true,
                processTreeTerminated: true,
                recoveryObservationSHA256: inventoryDigest
            )
        case .failureInjection:
            RuntimeProviderLiveQualificationFaultControlEvidence(
                deadlineEnforced: false,
                faultControllerActivated: true,
                processTreeTerminated: false,
                recoveryObservationSHA256: inventoryDigest
            )
        default:
            nil
        }
    }

    private static func expectedSemantics(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderConformanceFailureSemantics? {
        switch identifier {
        case .localImageRefusal:
            .init(category: .rejected, retryDisposition: .never, recoveryDisposition: .none)
        case .timeout:
            .init(
                category: .timedOut,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .cancellation:
            .init(
                category: .cancelled,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .crash:
            .init(
                category: .crashed,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .failureInjection:
            .init(
                category: .partialEffect,
                retryDisposition: .resumeFromCheckpoint,
                recoveryDisposition: .resume
            )
        default:
            nil
        }
    }

    enum Fault: Equatable, Sendable {
        case mutateSentinel(RuntimeProviderConformanceCaseID)
        case mutateInventory(RuntimeProviderConformanceCaseID)
        case cleanupMismatch
        case throwError(RuntimeProviderConformanceCaseID)
        case throwAfterMutation(RuntimeProviderConformanceCaseID)
        case failAssertion(RuntimeProviderConformanceCaseID)
        case invalidFirstSnapshot
        case invalidPreCleanupSnapshot
        case noOpLifecycle
    }

    enum DriverError: Error {
        case injected(String)
    }

    struct LogLimit: Equatable, Sendable {
        let bytes: Int
        let lines: Int
    }

    struct Audit: Equatable, Sendable {
        let caseCalls: [RuntimeProviderConformanceCaseID]
        let snapshotCalls: Int
        let logLimit: LogLimit?
        let statsLimit: Int?
    }
}
