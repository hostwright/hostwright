import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class RuntimeProviderConformanceTests: XCTestCase {
    func testExecutableScriptedSubjectPassesCompleteSuiteAndCleansExactly() async throws {
        let subject = ExecutableScriptedConformanceSubject(
            advertisedFeatures: mappedFeatures
        )

        let report = await RuntimeProviderConformanceSuite.run(subject)

        XCTAssertTrue(report.passed)
        XCTAssertFalse(report.containsLiveRuntimeEvidence)
        XCTAssertEqual(
            report.cases.map(\.caseIdentifier),
            RuntimeProviderConformanceCaseID.allCases
        )
        XCTAssertTrue(report.cases.allSatisfy { $0.status == .passed })
        XCTAssertEqual(
            report.qualifiedFeatures,
            mappedFeatures.sorted { $0.rawValue < $1.rawValue }
        )

        let snapshot = await subject.snapshot()
        XCTAssertEqual(snapshot.remainingResources, [ExecutableScriptedConformanceSubject.sentinelID])
        XCTAssertTrue(snapshot.remainingManagedResources.isEmpty)
        XCTAssertEqual(snapshot.providerRestarts, 1)
        XCTAssertEqual(snapshot.managedRestarts, 1)
        XCTAssertEqual(snapshot.failureInjections, 1)
        XCTAssertEqual(
            snapshot.exerciseCounts,
            Dictionary(
                uniqueKeysWithValues: RuntimeProviderConformanceCaseID.allCases.map { ($0, 1) }
            )
        )

        let encoded = try JSONEncoder().encode(report)
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeProviderConformanceReport.self, from: encoded),
            report
        )
        XCTAssertEqual(try report.evidenceSHA256().count, 64)
    }

    func testFailedCasesRejectOnlyCapabilitiesMappedToThoseCases() async {
        let subject = ExecutableScriptedConformanceSubject(
            advertisedFeatures: mappedFeatures,
            forcedFailures: [.localImageRefusal, .exactCleanup]
        )

        let report = await RuntimeProviderConformanceSuite.run(subject)
        let capabilities = Dictionary(
            uniqueKeysWithValues: report.capabilities.map { ($0.feature, $0) }
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(capabilities[.observation]?.status, .qualified)
        XCTAssertEqual(capabilities[.processControl]?.status, .qualified)
        XCTAssertEqual(capabilities[.streaming]?.status, .qualified)
        XCTAssertEqual(capabilities[.cancellation]?.status, .qualified)
        XCTAssertEqual(capabilities[.timeouts]?.status, .qualified)

        XCTAssertEqual(capabilities[.images]?.status, .rejected)
        XCTAssertEqual(capabilities[.images]?.failedCases, [.localImageRefusal])
        XCTAssertEqual(capabilities[.cleanup]?.status, .rejected)
        XCTAssertEqual(capabilities[.cleanup]?.failedCases, [.exactCleanup])
        XCTAssertEqual(capabilities[.lifecycle]?.status, .rejected)
        XCTAssertEqual(
            capabilities[.lifecycle]?.failedCases,
            [.localImageRefusal, .exactCleanup]
        )
        XCTAssertEqual(capabilities[.errors]?.status, .rejected)
        XCTAssertEqual(capabilities[.errors]?.failedCases, [.localImageRefusal])
    }

    func testDuplicateUnknownAndUnmappedAdvertisementsFailClosed() async {
        let futureFeature = RuntimeProviderFeature(rawValue: "future-feature")
        let subject = ExecutableScriptedConformanceSubject(
            advertisedFeatures: [.observation, .observation, .networks, futureFeature]
        )

        let report = await RuntimeProviderConformanceSuite.run(subject)
        let capabilities = Dictionary(
            uniqueKeysWithValues: report.capabilities.map { ($0.feature, $0) }
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.qualifiedFeatures.isEmpty)
        XCTAssertEqual(capabilities[.observation]?.reason, .advertisedMoreThanOnce)
        XCTAssertEqual(capabilities[.networks]?.reason, .noMappedCases)
        XCTAssertEqual(capabilities[futureFeature]?.reason, .featureUnknown)
        XCTAssertTrue(
            RuntimeProviderConformanceSuite.mappedCaseIdentifiers(for: .networks).isEmpty
        )
        XCTAssertTrue(
            RuntimeProviderConformanceSuite.mappedCaseIdentifiers(for: .storage).isEmpty
        )
    }

    func testCaseIdentityCategoryAndSubjectErrorsRejectMappedCapabilities() async {
        let subject = ExecutableScriptedConformanceSubject(
            advertisedFeatures: [.observation, .timeouts, .errors],
            wrongCaseIdentifiers: [.observation],
            wrongFailureCategories: [.timeout],
            thrownCases: [.crash]
        )

        let report = await RuntimeProviderConformanceSuite.run(subject)
        let results = Dictionary(
            uniqueKeysWithValues: report.cases.map { ($0.caseIdentifier, $0) }
        )

        XCTAssertEqual(results[.observation]?.failure, .caseIdentityMismatch)
        XCTAssertEqual(results[.timeout]?.failure, .failureCategoryMismatch)
        XCTAssertEqual(results[.crash]?.failure, .subjectError)
        XCTAssertTrue(report.capabilities.allSatisfy { $0.status == .rejected })
    }

    func testReportOrderingIsDeterministicAcrossAdvertisementOrder() async {
        let first = ExecutableScriptedConformanceSubject(
            advertisedFeatures: mappedFeatures
        )
        let second = ExecutableScriptedConformanceSubject(
            advertisedFeatures: mappedFeatures.reversed()
        )

        let firstReport = await RuntimeProviderConformanceSuite.run(first)
        let secondReport = await RuntimeProviderConformanceSuite.run(second)

        XCTAssertEqual(firstReport, secondReport)
        for testCase in RuntimeProviderConformanceSuite.cases {
            XCTAssertEqual(
                testCase.mappedFeatures,
                testCase.mappedFeatures.sorted { $0.rawValue < $1.rawValue }
            )
        }
    }

    func testInvalidSubjectIdentityFailsNegotiationBeforeCapabilityQualification() async {
        let subject = ExecutableScriptedConformanceSubject(
            advertisedFeatures: [.observation],
            providerID: RuntimeProviderID(rawValue: "unknown-provider"),
            providerVersion: "1.1"
        )

        let report = await RuntimeProviderConformanceSuite.run(subject)
        let negotiation = report.cases.first {
            $0.caseIdentifier == .capabilityNegotiation
        }

        XCTAssertEqual(negotiation?.failure, .subjectIdentityInvalid)
        XCTAssertEqual(report.capabilities.first?.status, .rejected)
        XCTAssertEqual(report.capabilities.first?.failedCases, [.capabilityNegotiation])
    }

    func testRetryAndRecoveryMismatchesFailClosed() async {
        let retryMismatch = ExecutableScriptedConformanceSubject(
            advertisedFeatures: [.timeouts],
            wrongRetryDispositions: [.timeout]
        )
        let recoveryMismatch = ExecutableScriptedConformanceSubject(
            advertisedFeatures: [.errors],
            wrongRecoveryDispositions: [.failureInjection]
        )

        let retryReport = await RuntimeProviderConformanceSuite.run(retryMismatch)
        let recoveryReport = await RuntimeProviderConformanceSuite.run(recoveryMismatch)

        XCTAssertEqual(
            retryReport.cases.first { $0.caseIdentifier == .timeout }?.failure,
            .failureRetryMismatch
        )
        XCTAssertEqual(
            recoveryReport.cases.first { $0.caseIdentifier == .failureInjection }?.failure,
            .failureRecoveryMismatch
        )
        XCTAssertFalse(retryReport.passed)
        XCTAssertFalse(recoveryReport.passed)
    }

    func testEmptyAdvertisementCannotPassVacuously() async {
        let subject = ExecutableScriptedConformanceSubject(
            advertisedFeatures: [] as [RuntimeProviderFeature]
        )

        let report = await RuntimeProviderConformanceSuite.run(subject)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.capabilities.isEmpty)
    }

    func testMatrixRequiresEveryExactSubjectAndLiveEvidenceBeforeQualification() async throws {
        let required = matrixSubjects
        let reports = await conformanceReports(for: required)

        let matrix = RuntimeProviderConformanceMatrix.evaluate(
            requiredSubjects: required,
            reports: reports
        )

        XCTAssertTrue(matrix.passed)
        XCTAssertTrue(matrix.findings.isEmpty)
        XCTAssertEqual(
            matrix.providers.map(\.providerID),
            [.appleContainerCLI, .appleContainerization]
        )
        XCTAssertTrue(matrix.providers.allSatisfy { $0.status == .qualified })
        XCTAssertTrue(matrix.providers.allSatisfy { $0.qualifiedFeatures == mappedFeatures.sorted { $0.rawValue < $1.rawValue } })

        let reordered = RuntimeProviderConformanceMatrix.evaluate(
            requiredSubjects: required.reversed(),
            reports: reports.reversed()
        )
        XCTAssertEqual(reordered, matrix)
        XCTAssertEqual(try reordered.evidenceSHA256(), try matrix.evidenceSHA256())
    }

    func testMatrixFailsClosedForMissingDuplicateUnexpectedAndFixtureOnlyEvidence() async {
        let scriptedCLI = RuntimeProviderConformanceSubjectIdentity(
            providerID: .appleContainerCLI,
            providerVersion: "1.1.0",
            evidenceClass: .scriptedFixture
        )
        let liveCLI = RuntimeProviderConformanceSubjectIdentity(
            providerID: .appleContainerCLI,
            providerVersion: "1.1.0",
            evidenceClass: .liveRuntime
        )
        let unexpected = RuntimeProviderConformanceSubjectIdentity(
            providerID: .appleContainerization,
            providerVersion: "0.35.0",
            evidenceClass: .liveRuntime
        )
        let scriptedReport = await conformanceReport(for: scriptedCLI)
        let unexpectedReport = await conformanceReport(for: unexpected)

        let matrix = RuntimeProviderConformanceMatrix.evaluate(
            requiredSubjects: [scriptedCLI, scriptedCLI, liveCLI],
            reports: [scriptedReport, scriptedReport, unexpectedReport]
        )
        let reasons = Set(matrix.findings.map(\.reason))

        XCTAssertFalse(matrix.passed)
        XCTAssertTrue(reasons.contains(.duplicateRequirement))
        XCTAssertTrue(reasons.contains(.duplicateSubjectReport))
        XCTAssertTrue(reasons.contains(.missingRequiredSubject))
        XCTAssertTrue(reasons.contains(.unexpectedSubjectReport))
        XCTAssertTrue(matrix.providers.allSatisfy { $0.status == .rejected })

        let fixtureOnly = RuntimeProviderConformanceMatrix.evaluate(
            requiredSubjects: [scriptedCLI],
            reports: [scriptedReport]
        )
        XCTAssertEqual(fixtureOnly.findings.map(\.reason), [.liveEvidenceMissing])
        XCTAssertFalse(fixtureOnly.passed)
    }

    private var mappedFeatures: [RuntimeProviderFeature] {
        [
            .observation,
            .lifecycle,
            .processControl,
            .streaming,
            .images,
            .cancellation,
            .timeouts,
            .errors,
            .cleanup
        ]
    }

    private var matrixSubjects: [RuntimeProviderConformanceSubjectIdentity] {
        [
            RuntimeProviderConformanceSubjectIdentity(
                providerID: .appleContainerCLI,
                providerVersion: "1.0.0",
                evidenceClass: .scriptedFixture
            ),
            RuntimeProviderConformanceSubjectIdentity(
                providerID: .appleContainerCLI,
                providerVersion: "1.0.0",
                evidenceClass: .liveRuntime
            ),
            RuntimeProviderConformanceSubjectIdentity(
                providerID: .appleContainerCLI,
                providerVersion: "1.1.0",
                evidenceClass: .scriptedFixture
            ),
            RuntimeProviderConformanceSubjectIdentity(
                providerID: .appleContainerCLI,
                providerVersion: "1.1.0",
                evidenceClass: .liveRuntime
            ),
            RuntimeProviderConformanceSubjectIdentity(
                providerID: .appleContainerization,
                providerVersion: "0.35.0",
                evidenceClass: .scriptedFixture
            ),
            RuntimeProviderConformanceSubjectIdentity(
                providerID: .appleContainerization,
                providerVersion: "0.35.0",
                evidenceClass: .liveRuntime
            )
        ]
    }

    private func conformanceReports(
        for identities: [RuntimeProviderConformanceSubjectIdentity]
    ) async -> [RuntimeProviderConformanceReport] {
        var reports: [RuntimeProviderConformanceReport] = []
        for identity in identities {
            reports.append(await conformanceReport(for: identity))
        }
        return reports
    }

    private func conformanceReport(
        for identity: RuntimeProviderConformanceSubjectIdentity
    ) async -> RuntimeProviderConformanceReport {
        let subject = ExecutableScriptedConformanceSubject(
            advertisedFeatures: mappedFeatures,
            providerID: identity.providerID,
            providerVersion: identity.providerVersion,
            evidenceClass: identity.evidenceClass
        )
        return await RuntimeProviderConformanceSuite.run(subject)
    }
}

private actor ExecutableScriptedConformanceSubject: RuntimeProviderConformanceSubject {
    static let sentinelID = "unmanaged-sentinel"

    nonisolated let conformanceIdentity: RuntimeProviderConformanceSubjectIdentity
    nonisolated let advertisedFeatures: [RuntimeProviderFeature]

    private let forcedFailures: Set<RuntimeProviderConformanceCaseID>
    private let wrongCaseIdentifiers: Set<RuntimeProviderConformanceCaseID>
    private let wrongFailureCategories: Set<RuntimeProviderConformanceCaseID>
    private let wrongRetryDispositions: Set<RuntimeProviderConformanceCaseID>
    private let wrongRecoveryDispositions: Set<RuntimeProviderConformanceCaseID>
    private let thrownCases: Set<RuntimeProviderConformanceCaseID>

    private let resourceUUID = "018f2ad8-6f80-7c11-91db-9f4a9a4dc441"
    private let managedID = "hostwright-v2-demo-api-scripted"
    private let restartPersistenceID = "hostwright-v2-demo-persist-scripted"
    private let partialEffectID = "hostwright-v2-demo-partial-scripted"
    private let availableImage = "ghcr.io/example/api:fixture"

    private var resources: [String: Lifecycle] = [sentinelID: .running]
    private var managedResources = Set<String>()
    private var localImages: Set<String>
    private var exerciseCounts: [RuntimeProviderConformanceCaseID: Int] = [:]
    private var providerRestarts = 0
    private var managedRestarts = 0
    private var failureInjections = 0

    init<S: Sequence>(
        advertisedFeatures: S,
        providerID: RuntimeProviderID = .appleContainerCLI,
        providerVersion: String = "1.1.0",
        evidenceClass: RuntimeProviderConformanceEvidenceClass = .scriptedFixture,
        forcedFailures: Set<RuntimeProviderConformanceCaseID> = [],
        wrongCaseIdentifiers: Set<RuntimeProviderConformanceCaseID> = [],
        wrongFailureCategories: Set<RuntimeProviderConformanceCaseID> = [],
        wrongRetryDispositions: Set<RuntimeProviderConformanceCaseID> = [],
        wrongRecoveryDispositions: Set<RuntimeProviderConformanceCaseID> = [],
        thrownCases: Set<RuntimeProviderConformanceCaseID> = []
    ) where S.Element == RuntimeProviderFeature {
        self.conformanceIdentity = RuntimeProviderConformanceSubjectIdentity(
            providerID: providerID,
            providerVersion: providerVersion,
            evidenceClass: evidenceClass
        )
        self.advertisedFeatures = Array(advertisedFeatures)
        self.forcedFailures = forcedFailures
        self.wrongCaseIdentifiers = wrongCaseIdentifiers
        self.wrongFailureCategories = wrongFailureCategories
        self.wrongRetryDispositions = wrongRetryDispositions
        self.wrongRecoveryDispositions = wrongRecoveryDispositions
        self.thrownCases = thrownCases
        self.localImages = [availableImage]
    }

    func exercise(
        _ testCase: RuntimeProviderConformanceCase
    ) async throws -> RuntimeProviderConformanceCaseEvidence {
        exerciseCounts[testCase.identifier, default: 0] += 1

        if thrownCases.contains(testCase.identifier) {
            throw FixtureError.injected
        }
        if wrongCaseIdentifiers.contains(testCase.identifier) {
            return RuntimeProviderConformanceCaseEvidence(
                caseIdentifier: alternateIdentifier(for: testCase.identifier),
                status: .passed,
                normalizedFailureSemantics: expectedSemantics(for: testCase.identifier)
            )
        }
        if forcedFailures.contains(testCase.identifier) {
            return evidence(
                for: testCase.identifier,
                passed: false,
                category: expectedCategory(for: testCase.identifier)
            )
        }

        let result: RuntimeProviderConformanceCaseEvidence
        switch testCase.identifier {
        case .capabilityNegotiation:
            let uniqueFeatures = Set(advertisedFeatures)
            result = evidence(
                for: testCase.identifier,
                passed: !advertisedFeatures.isEmpty &&
                    uniqueFeatures.count == advertisedFeatures.count
            )
        case .observation:
            result = evidence(
                for: testCase.identifier,
                passed: resources[Self.sentinelID] == .running && managedResources.isEmpty
            )
        case .uuidIdentity:
            result = evidence(
                for: testCase.identifier,
                passed: HostwrightResourceUUID.isValid(resourceUUID)
            )
        case .localImageRefusal:
            let before = resources
            let missingImage = "ghcr.io/example/missing:fixture"
            let refused = !localImages.contains(missingImage)
            result = evidence(
                for: testCase.identifier,
                passed: refused && resources == before,
                category: .rejected
            )
        case .create:
            guard localImages.contains(availableImage), resources[managedID] == nil else {
                result = evidence(for: testCase.identifier, passed: false)
                break
            }
            resources[managedID] = .created
            managedResources.insert(managedID)
            result = evidence(
                for: testCase.identifier,
                passed: resources[managedID] == .created
            )
        case .start:
            guard resources[managedID] == .created else {
                result = evidence(for: testCase.identifier, passed: false)
                break
            }
            resources[managedID] = .running
            result = evidence(
                for: testCase.identifier,
                passed: resources[managedID] == .running
            )
        case .managedRestart:
            guard resources[managedID] == .running else {
                result = evidence(for: testCase.identifier, passed: false)
                break
            }
            resources[managedID] = .stopped
            resources[managedID] = .running
            managedRestarts += 1
            result = evidence(
                for: testCase.identifier,
                passed: resources[managedID] == .running && managedRestarts == 1
            )
        case .delete:
            guard managedResources.contains(managedID) else {
                result = evidence(for: testCase.identifier, passed: false)
                break
            }
            resources.removeValue(forKey: managedID)
            managedResources.remove(managedID)
            result = evidence(
                for: testCase.identifier,
                passed: resources[managedID] == nil && resources[Self.sentinelID] == .running
            )
        case .boundedLogs:
            let log = String(repeating: "log-line\n", count: 100)
            result = evidence(
                for: testCase.identifier,
                passed: log.utf8.count <= RuntimeProviderConformanceLimits.maximumLogBytes &&
                    log.split(separator: "\n").count <= RuntimeProviderConformanceLimits.maximumLogLines
            )
        case .boundedStats:
            let statsPayload = "{\"id\":\"\(managedID)\",\"cpu\":100,\"memory\":2048}"
            result = evidence(
                for: testCase.identifier,
                passed: statsPayload.utf8.count <= RuntimeProviderConformanceLimits.maximumStatsBytes &&
                    statsPayload.contains(managedID)
            )
        case .timeout:
            let before = resources
            result = evidence(
                for: testCase.identifier,
                passed: resources == before,
                category: .timedOut
            )
        case .cancellation:
            let before = resources
            result = evidence(
                for: testCase.identifier,
                passed: resources == before,
                category: .cancelled
            )
        case .crash:
            let before = resources
            result = evidence(
                for: testCase.identifier,
                passed: resources == before,
                category: .crashed
            )
        case .providerRestart:
            resources[restartPersistenceID] = .running
            managedResources.insert(restartPersistenceID)
            let persistedResources = resources
            let persistedManagedResources = managedResources
            providerRestarts += 1
            resources = persistedResources
            managedResources = persistedManagedResources
            result = evidence(
                for: testCase.identifier,
                passed: resources[restartPersistenceID] == .running && providerRestarts == 1
            )
        case .failureInjection:
            resources[partialEffectID] = .created
            managedResources.insert(partialEffectID)
            failureInjections += 1
            resources.removeValue(forKey: partialEffectID)
            managedResources.remove(partialEffectID)
            result = evidence(
                for: testCase.identifier,
                passed: resources[partialEffectID] == nil &&
                    resources[Self.sentinelID] == .running &&
                    failureInjections == 1,
                category: .partialEffect
            )
        case .unmanagedSentinelPreservation:
            result = evidence(
                for: testCase.identifier,
                passed: resources[Self.sentinelID] == .running &&
                    !managedResources.contains(Self.sentinelID)
            )
        case .exactCleanup:
            for identifier in managedResources {
                resources.removeValue(forKey: identifier)
            }
            managedResources.removeAll()
            result = evidence(
                for: testCase.identifier,
                passed: resources == [Self.sentinelID: .running] && managedResources.isEmpty
            )
        }

        if wrongFailureCategories.contains(testCase.identifier) {
            return RuntimeProviderConformanceCaseEvidence(
                caseIdentifier: testCase.identifier,
                status: result.status,
                normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics(
                    category: .cancelled,
                    retryDisposition: .safeAfterObservation,
                    recoveryDisposition: .reobserve
                )
            )
        }
        if wrongRetryDispositions.contains(testCase.identifier),
           let semantics = result.normalizedFailureSemantics {
            return RuntimeProviderConformanceCaseEvidence(
                caseIdentifier: testCase.identifier,
                status: result.status,
                normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics(
                    category: semantics.category,
                    retryDisposition: semantics.retryDisposition == .never
                        ? .safeAfterObservation
                        : .never,
                    recoveryDisposition: semantics.recoveryDisposition
                )
            )
        }
        if wrongRecoveryDispositions.contains(testCase.identifier),
           let semantics = result.normalizedFailureSemantics {
            return RuntimeProviderConformanceCaseEvidence(
                caseIdentifier: testCase.identifier,
                status: result.status,
                normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics(
                    category: semantics.category,
                    retryDisposition: semantics.retryDisposition,
                    recoveryDisposition: semantics.recoveryDisposition == .none
                        ? .reobserve
                        : .none
                )
            )
        }
        return result
    }

    func snapshot() -> Snapshot {
        Snapshot(
            remainingResources: resources.keys.sorted(),
            remainingManagedResources: managedResources.sorted(),
            exerciseCounts: exerciseCounts,
            providerRestarts: providerRestarts,
            managedRestarts: managedRestarts,
            failureInjections: failureInjections
        )
    }

    private func evidence(
        for identifier: RuntimeProviderConformanceCaseID,
        passed: Bool,
        category: RuntimeFailureCategory? = nil
    ) -> RuntimeProviderConformanceCaseEvidence {
        RuntimeProviderConformanceCaseEvidence(
            caseIdentifier: identifier,
            status: passed ? .passed : .failed,
            normalizedFailureSemantics: semantics(for: category)
        )
    }

    private func expectedSemantics(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderConformanceFailureSemantics? {
        semantics(for: expectedCategory(for: identifier))
    }

    private func semantics(
        for category: RuntimeFailureCategory?
    ) -> RuntimeProviderConformanceFailureSemantics? {
        guard let category else {
            return nil
        }
        switch category {
        case .rejected:
            return RuntimeProviderConformanceFailureSemantics(
                category: .rejected,
                retryDisposition: .never,
                recoveryDisposition: .none
            )
        case .timedOut:
            return RuntimeProviderConformanceFailureSemantics(
                category: .timedOut,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .cancelled:
            return RuntimeProviderConformanceFailureSemantics(
                category: .cancelled,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .crashed:
            return RuntimeProviderConformanceFailureSemantics(
                category: .crashed,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .partialEffect:
            return RuntimeProviderConformanceFailureSemantics(
                category: .partialEffect,
                retryDisposition: .resumeFromCheckpoint,
                recoveryDisposition: .resume
            )
        default:
            return RuntimeProviderConformanceFailureSemantics(
                category: category,
                retryDisposition: .never,
                recoveryDisposition: .none
            )
        }
    }

    private func expectedCategory(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeFailureCategory? {
        switch identifier {
        case .localImageRefusal:
            .rejected
        case .timeout:
            .timedOut
        case .cancellation:
            .cancelled
        case .crash:
            .crashed
        case .failureInjection:
            .partialEffect
        default:
            nil
        }
    }

    private func alternateIdentifier(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderConformanceCaseID {
        identifier == .observation ? .uuidIdentity : .observation
    }

    private enum Lifecycle: Equatable, Sendable {
        case created
        case running
        case stopped
    }

    private enum FixtureError: Error {
        case injected
    }

    struct Snapshot: Equatable, Sendable {
        let remainingResources: [String]
        let remainingManagedResources: [String]
        let exerciseCounts: [RuntimeProviderConformanceCaseID: Int]
        let providerRestarts: Int
        let managedRestarts: Int
        let failureInjections: Int
    }
}
