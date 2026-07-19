import CryptoKit
import Foundation

public enum RuntimeProviderConformanceEvidenceClass: String, Codable, Equatable, Hashable, Sendable {
    case scriptedFixture = "scripted-fixture"
    case liveRuntime = "live-runtime"
}

public struct RuntimeProviderConformanceSubjectIdentity: Codable, Equatable, Hashable, Sendable {
    public let providerID: RuntimeProviderID
    public let providerVersion: String
    public let evidenceClass: RuntimeProviderConformanceEvidenceClass

    public init(
        providerID: RuntimeProviderID,
        providerVersion: String,
        evidenceClass: RuntimeProviderConformanceEvidenceClass
    ) {
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.evidenceClass = evidenceClass
    }
}

public enum RuntimeProviderConformanceLimits {
    public static let maximumLogBytes = 1 * 1_024 * 1_024
    public static let maximumLogLines = 1_000
    public static let maximumStatsBytes = 256 * 1_024
}

public struct RuntimeProviderConformanceFailureSemantics: Codable, Equatable, Sendable {
    public let category: RuntimeFailureCategory
    public let retryDisposition: RuntimeRetryDisposition
    public let recoveryDisposition: RuntimeRecoveryDisposition

    public init(
        category: RuntimeFailureCategory,
        retryDisposition: RuntimeRetryDisposition,
        recoveryDisposition: RuntimeRecoveryDisposition
    ) {
        self.category = category
        self.retryDisposition = retryDisposition
        self.recoveryDisposition = recoveryDisposition
    }
}

public enum RuntimeProviderConformanceCaseID: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case capabilityNegotiation = "capability-negotiation"
    case observation
    case uuidIdentity = "uuid-identity"
    case localImageRefusal = "local-image-refusal"
    case create
    case start
    case managedRestart = "managed-restart"
    case delete
    case boundedLogs = "bounded-logs"
    case boundedStats = "bounded-stats"
    case timeout
    case cancellation
    case crash
    case providerRestart = "provider-restart"
    case failureInjection = "failure-injection"
    case unmanagedSentinelPreservation = "unmanaged-sentinel-preservation"
    case exactCleanup = "exact-cleanup"
}

public struct RuntimeProviderConformanceCase: Codable, Equatable, Sendable {
    public let identifier: RuntimeProviderConformanceCaseID
    public let mappedFeatures: [RuntimeProviderFeature]
    public let expectedFailureSemantics: RuntimeProviderConformanceFailureSemantics?

    public init(
        identifier: RuntimeProviderConformanceCaseID,
        mappedFeatures: [RuntimeProviderFeature],
        expectedFailureSemantics: RuntimeProviderConformanceFailureSemantics? = nil
    ) {
        self.identifier = identifier
        self.mappedFeatures = mappedFeatures.sorted { $0.rawValue < $1.rawValue }
        self.expectedFailureSemantics = expectedFailureSemantics
    }

    public var expectedFailureCategory: RuntimeFailureCategory? {
        expectedFailureSemantics?.category
    }
}

public enum RuntimeProviderConformanceEvidenceStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

public struct RuntimeProviderConformanceCaseEvidence: Codable, Equatable, Sendable {
    public let caseIdentifier: RuntimeProviderConformanceCaseID
    public let status: RuntimeProviderConformanceEvidenceStatus
    public let normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics?

    public init(
        caseIdentifier: RuntimeProviderConformanceCaseID,
        status: RuntimeProviderConformanceEvidenceStatus,
        normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics? = nil
    ) {
        self.caseIdentifier = caseIdentifier
        self.status = status
        self.normalizedFailureSemantics = normalizedFailureSemantics
    }

    public var normalizedFailureCategory: RuntimeFailureCategory? {
        normalizedFailureSemantics?.category
    }
}

public protocol RuntimeProviderConformanceSubject: Sendable {
    var conformanceIdentity: RuntimeProviderConformanceSubjectIdentity { get }
    var advertisedFeatures: [RuntimeProviderFeature] { get }

    func exercise(
        _ testCase: RuntimeProviderConformanceCase
    ) async throws -> RuntimeProviderConformanceCaseEvidence
}

public enum RuntimeProviderConformanceCaseFailure: String, Codable, Equatable, Sendable {
    case assertionFailed = "assertion-failed"
    case subjectError = "subject-error"
    case caseIdentityMismatch = "case-identity-mismatch"
    case failureCategoryMismatch = "failure-category-mismatch"
    case failureRetryMismatch = "failure-retry-mismatch"
    case failureRecoveryMismatch = "failure-recovery-mismatch"
    case subjectIdentityInvalid = "subject-identity-invalid"
}

public enum RuntimeProviderConformanceCaseStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

public struct RuntimeProviderConformanceCaseResult: Codable, Equatable, Sendable {
    public let caseIdentifier: RuntimeProviderConformanceCaseID
    public let status: RuntimeProviderConformanceCaseStatus
    public let failure: RuntimeProviderConformanceCaseFailure?
    public let normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics?

    public init(
        caseIdentifier: RuntimeProviderConformanceCaseID,
        status: RuntimeProviderConformanceCaseStatus,
        failure: RuntimeProviderConformanceCaseFailure? = nil,
        normalizedFailureSemantics: RuntimeProviderConformanceFailureSemantics? = nil
    ) {
        self.caseIdentifier = caseIdentifier
        self.status = status
        self.failure = failure
        self.normalizedFailureSemantics = normalizedFailureSemantics
    }

    public var normalizedFailureCategory: RuntimeFailureCategory? {
        normalizedFailureSemantics?.category
    }
}

public enum RuntimeProviderConformanceCapabilityStatus: String, Codable, Equatable, Sendable {
    case qualified
    case rejected
}

public enum RuntimeProviderConformanceCapabilityReason: String, Codable, Equatable, Sendable {
    case allMappedCasesPassed = "all-mapped-cases-passed"
    case advertisedMoreThanOnce = "advertised-more-than-once"
    case featureUnknown = "feature-unknown"
    case noMappedCases = "no-mapped-cases"
    case mappedCaseFailed = "mapped-case-failed"
}

public struct RuntimeProviderConformanceCapabilityResult: Codable, Equatable, Sendable {
    public let feature: RuntimeProviderFeature
    public let status: RuntimeProviderConformanceCapabilityStatus
    public let reason: RuntimeProviderConformanceCapabilityReason
    public let mappedCases: [RuntimeProviderConformanceCaseID]
    public let failedCases: [RuntimeProviderConformanceCaseID]

    public init(
        feature: RuntimeProviderFeature,
        status: RuntimeProviderConformanceCapabilityStatus,
        reason: RuntimeProviderConformanceCapabilityReason,
        mappedCases: [RuntimeProviderConformanceCaseID],
        failedCases: [RuntimeProviderConformanceCaseID]
    ) {
        self.feature = feature
        self.status = status
        self.reason = reason
        self.mappedCases = mappedCases.sorted(by: RuntimeProviderConformanceSuite.caseOrder)
        self.failedCases = failedCases.sorted(by: RuntimeProviderConformanceSuite.caseOrder)
    }
}

public struct RuntimeProviderConformanceReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let subject: RuntimeProviderConformanceSubjectIdentity
    public let cases: [RuntimeProviderConformanceCaseResult]
    public let capabilities: [RuntimeProviderConformanceCapabilityResult]

    public init(
        schemaVersion: Int = RuntimeProviderConformanceReport.currentSchemaVersion,
        subject: RuntimeProviderConformanceSubjectIdentity,
        cases: [RuntimeProviderConformanceCaseResult],
        capabilities: [RuntimeProviderConformanceCapabilityResult]
    ) {
        self.schemaVersion = schemaVersion
        self.subject = subject
        self.cases = cases.sorted {
            RuntimeProviderConformanceSuite.caseOrder($0.caseIdentifier, $1.caseIdentifier)
        }
        self.capabilities = capabilities.sorted { $0.feature.rawValue < $1.feature.rawValue }
    }

    public var qualifiedFeatures: [RuntimeProviderFeature] {
        capabilities
            .filter { $0.status == .qualified }
            .map(\.feature)
    }

    public var passed: Bool {
        cases.map(\.caseIdentifier) == RuntimeProviderConformanceCaseID.allCases &&
            !capabilities.isEmpty &&
            Set(capabilities.map(\.feature)).count == capabilities.count &&
            cases.allSatisfy { $0.status == .passed } &&
            capabilities.allSatisfy { $0.status == .qualified }
    }

    public var containsLiveRuntimeEvidence: Bool {
        subject.evidenceClass == .liveRuntime
    }

    public func evidenceSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum RuntimeProviderConformanceMatrixFindingReason: String, Codable, Equatable, Sendable {
    case emptyRequirementSet = "empty-requirement-set"
    case duplicateRequirement = "duplicate-requirement"
    case missingRequiredSubject = "missing-required-subject"
    case duplicateSubjectReport = "duplicate-subject-report"
    case unexpectedSubjectReport = "unexpected-subject-report"
    case requiredReportFailed = "required-report-failed"
    case liveEvidenceMissing = "live-evidence-missing"
    case normalizedSemanticsMismatch = "normalized-semantics-mismatch"
    case noQualifiedFeatures = "no-qualified-features"
}

public struct RuntimeProviderConformanceMatrixFinding: Codable, Equatable, Sendable {
    public let reason: RuntimeProviderConformanceMatrixFindingReason
    public let subject: RuntimeProviderConformanceSubjectIdentity?
    public let providerID: RuntimeProviderID?
    public let caseIdentifier: RuntimeProviderConformanceCaseID?

    public init(
        reason: RuntimeProviderConformanceMatrixFindingReason,
        subject: RuntimeProviderConformanceSubjectIdentity? = nil,
        providerID: RuntimeProviderID? = nil,
        caseIdentifier: RuntimeProviderConformanceCaseID? = nil
    ) {
        self.reason = reason
        self.subject = subject
        self.providerID = providerID
        self.caseIdentifier = caseIdentifier
    }
}

public enum RuntimeProviderConformanceProviderStatus: String, Codable, Equatable, Sendable {
    case qualified
    case rejected
}

public struct RuntimeProviderConformanceProviderResult: Codable, Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let status: RuntimeProviderConformanceProviderStatus
    public let qualifiedFeatures: [RuntimeProviderFeature]

    public init(
        providerID: RuntimeProviderID,
        status: RuntimeProviderConformanceProviderStatus,
        qualifiedFeatures: [RuntimeProviderFeature]
    ) {
        self.providerID = providerID
        self.status = status
        self.qualifiedFeatures = qualifiedFeatures.sorted { $0.rawValue < $1.rawValue }
    }
}

public struct RuntimeProviderConformanceMatrixReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let requiredSubjects: [RuntimeProviderConformanceSubjectIdentity]
    public let reports: [RuntimeProviderConformanceReport]
    public let providers: [RuntimeProviderConformanceProviderResult]
    public let findings: [RuntimeProviderConformanceMatrixFinding]

    public init(
        schemaVersion: Int = RuntimeProviderConformanceMatrixReport.currentSchemaVersion,
        requiredSubjects: [RuntimeProviderConformanceSubjectIdentity],
        reports: [RuntimeProviderConformanceReport],
        providers: [RuntimeProviderConformanceProviderResult],
        findings: [RuntimeProviderConformanceMatrixFinding]
    ) {
        self.schemaVersion = schemaVersion
        self.requiredSubjects = requiredSubjects.sorted(by: RuntimeProviderConformanceMatrix.subjectOrder)
        self.reports = reports.sorted {
            RuntimeProviderConformanceMatrix.subjectOrder($0.subject, $1.subject)
        }
        self.providers = providers.sorted { $0.providerID.rawValue < $1.providerID.rawValue }
        self.findings = findings.sorted(by: RuntimeProviderConformanceMatrix.findingOrder)
    }

    public var passed: Bool {
        !requiredSubjects.isEmpty &&
            findings.isEmpty &&
            !providers.isEmpty &&
            providers.allSatisfy { $0.status == .qualified }
    }

    public func evidenceSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum RuntimeProviderConformanceMatrix {
    public static func evaluate(
        requiredSubjects: [RuntimeProviderConformanceSubjectIdentity],
        reports: [RuntimeProviderConformanceReport]
    ) -> RuntimeProviderConformanceMatrixReport {
        var findings: [RuntimeProviderConformanceMatrixFinding] = []
        let requirementCounts = Dictionary(grouping: requiredSubjects, by: { $0 }).mapValues(\.count)
        let reportCounts = Dictionary(grouping: reports, by: \.subject).mapValues(\.count)
        let requiredSet = Set(requiredSubjects)

        if requiredSubjects.isEmpty {
            findings.append(RuntimeProviderConformanceMatrixFinding(reason: .emptyRequirementSet))
        }
        for subject in requirementCounts.keys.sorted(by: subjectOrder)
            where requirementCounts[subject, default: 0] != 1 {
            findings.append(
                RuntimeProviderConformanceMatrixFinding(
                    reason: .duplicateRequirement,
                    subject: subject,
                    providerID: subject.providerID
                )
            )
        }
        for subject in requiredSet.sorted(by: subjectOrder) {
            switch reportCounts[subject, default: 0] {
            case 0:
                findings.append(
                    RuntimeProviderConformanceMatrixFinding(
                        reason: .missingRequiredSubject,
                        subject: subject,
                        providerID: subject.providerID
                    )
                )
            case 1:
                break
            default:
                findings.append(
                    RuntimeProviderConformanceMatrixFinding(
                        reason: .duplicateSubjectReport,
                        subject: subject,
                        providerID: subject.providerID
                    )
                )
            }
        }
        for subject in reportCounts.keys.sorted(by: subjectOrder) where !requiredSet.contains(subject) {
            findings.append(
                RuntimeProviderConformanceMatrixFinding(
                    reason: .unexpectedSubjectReport,
                    subject: subject,
                    providerID: subject.providerID
                )
            )
        }

        let exactReports = reports.filter {
            requiredSet.contains($0.subject) && reportCounts[$0.subject] == 1
        }
        for report in exactReports where !report.passed {
            findings.append(
                RuntimeProviderConformanceMatrixFinding(
                    reason: .requiredReportFailed,
                    subject: report.subject,
                    providerID: report.subject.providerID
                )
            )
        }

        for identifier in RuntimeProviderConformanceCaseID.allCases {
            let values = exactReports.compactMap { report in
                report.cases.first { $0.caseIdentifier == identifier }?.normalizedFailureSemantics
            }
            let unique = values.reduce(into: [RuntimeProviderConformanceFailureSemantics]()) {
                if !$0.contains($1) {
                    $0.append($1)
                }
            }
            if unique.count > 1 {
                findings.append(
                    RuntimeProviderConformanceMatrixFinding(
                        reason: .normalizedSemanticsMismatch,
                        caseIdentifier: identifier
                    )
                )
            }
        }

        let requiredProviders = Set(requiredSubjects.map(\.providerID))
        for providerID in requiredProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
            let providerRequirements = requiredSubjects.filter { $0.providerID == providerID }
            if !providerRequirements.contains(where: { $0.evidenceClass == .liveRuntime }) {
                findings.append(
                    RuntimeProviderConformanceMatrixFinding(
                        reason: .liveEvidenceMissing,
                        providerID: providerID
                    )
                )
            }
        }

        var providers: [RuntimeProviderConformanceProviderResult] = []
        for providerID in requiredProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
            let providerRequirements = requiredSubjects.filter { $0.providerID == providerID }
            let providerReports = exactReports.filter { $0.subject.providerID == providerID }
            let providerHasFinding = findings.contains { finding in
                finding.providerID == providerID ||
                    (finding.providerID == nil && finding.reason == .normalizedSemanticsMismatch)
            }
            let allRequiredReportsPresent = providerRequirements.count == providerReports.count &&
                providerRequirements.allSatisfy { requirement in
                    providerReports.contains { $0.subject == requirement }
                }
            let allReportsPassed = providerReports.allSatisfy(\.passed)
            let hasLiveReport = providerReports.contains { $0.containsLiveRuntimeEvidence }

            var commonFeatures = Set(RuntimeProviderFeature.knownValues)
            for report in providerReports {
                commonFeatures.formIntersection(report.qualifiedFeatures)
            }
            if providerReports.isEmpty {
                commonFeatures.removeAll()
            }

            if commonFeatures.isEmpty && allRequiredReportsPresent && allReportsPassed && hasLiveReport {
                findings.append(
                    RuntimeProviderConformanceMatrixFinding(
                        reason: .noQualifiedFeatures,
                        providerID: providerID
                    )
                )
            }
            let qualified = allRequiredReportsPresent &&
                allReportsPassed &&
                hasLiveReport &&
                !providerHasFinding &&
                !commonFeatures.isEmpty
            providers.append(
                RuntimeProviderConformanceProviderResult(
                    providerID: providerID,
                    status: qualified ? .qualified : .rejected,
                    qualifiedFeatures: qualified ? Array(commonFeatures) : []
                )
            )
        }

        return RuntimeProviderConformanceMatrixReport(
            requiredSubjects: requiredSubjects,
            reports: reports,
            providers: providers,
            findings: findings
        )
    }

    static func subjectOrder(
        _ lhs: RuntimeProviderConformanceSubjectIdentity,
        _ rhs: RuntimeProviderConformanceSubjectIdentity
    ) -> Bool {
        (lhs.providerID.rawValue, lhs.providerVersion, lhs.evidenceClass.rawValue) <
            (rhs.providerID.rawValue, rhs.providerVersion, rhs.evidenceClass.rawValue)
    }

    static func findingOrder(
        _ lhs: RuntimeProviderConformanceMatrixFinding,
        _ rhs: RuntimeProviderConformanceMatrixFinding
    ) -> Bool {
        findingSortKey(lhs) < findingSortKey(rhs)
    }

    private static func findingSortKey(
        _ finding: RuntimeProviderConformanceMatrixFinding
    ) -> (String, String, String, String, String) {
        (
            finding.reason.rawValue,
            finding.providerID?.rawValue ?? "",
            finding.subject?.providerVersion ?? "",
            finding.subject?.evidenceClass.rawValue ?? "",
            finding.caseIdentifier?.rawValue ?? ""
        )
    }
}

public enum RuntimeProviderConformanceSuite {
    public static var cases: [RuntimeProviderConformanceCase] {
        RuntimeProviderConformanceCaseID.allCases.map { identifier in
            RuntimeProviderConformanceCase(
                identifier: identifier,
                mappedFeatures: mappedFeatures(for: identifier),
                expectedFailureSemantics: expectedFailureSemantics(for: identifier)
            )
        }
    }

    public static func mappedCaseIdentifiers(
        for feature: RuntimeProviderFeature
    ) -> [RuntimeProviderConformanceCaseID] {
        guard mappedFeatureSet.contains(feature) else {
            return []
        }
        return cases
            .filter { $0.mappedFeatures.contains(feature) }
            .map(\.identifier)
    }

    public static func run(
        _ subject: any RuntimeProviderConformanceSubject
    ) async -> RuntimeProviderConformanceReport {
        var results: [RuntimeProviderConformanceCaseResult] = []
        for testCase in cases {
            results.append(await exercise(testCase, using: subject))
        }

        return RuntimeProviderConformanceReport(
            subject: subject.conformanceIdentity,
            cases: results,
            capabilities: capabilityResults(
                advertisedFeatures: subject.advertisedFeatures,
                caseResults: results
            )
        )
    }

    static func caseOrder(
        _ lhs: RuntimeProviderConformanceCaseID,
        _ rhs: RuntimeProviderConformanceCaseID
    ) -> Bool {
        caseIndex(lhs) < caseIndex(rhs)
    }

    private static let mappedFeatureSet = Set([
        RuntimeProviderFeature.observation,
        .lifecycle,
        .processControl,
        .streaming,
        .images,
        .cancellation,
        .timeouts,
        .errors,
        .cleanup
    ])

    private static func exercise(
        _ testCase: RuntimeProviderConformanceCase,
        using subject: any RuntimeProviderConformanceSubject
    ) async -> RuntimeProviderConformanceCaseResult {
        do {
            let evidence = try await subject.exercise(testCase)
            guard evidence.caseIdentifier == testCase.identifier else {
                return failedResult(
                    testCase,
                    failure: .caseIdentityMismatch,
                    semantics: evidence.normalizedFailureSemantics
                )
            }
            guard evidence.status == .passed else {
                return failedResult(
                    testCase,
                    failure: .assertionFailed,
                    semantics: evidence.normalizedFailureSemantics
                )
            }
            guard evidence.normalizedFailureCategory == testCase.expectedFailureCategory else {
                return failedResult(
                    testCase,
                    failure: .failureCategoryMismatch,
                    semantics: evidence.normalizedFailureSemantics
                )
            }
            guard evidence.normalizedFailureSemantics?.retryDisposition ==
                testCase.expectedFailureSemantics?.retryDisposition else {
                return failedResult(
                    testCase,
                    failure: .failureRetryMismatch,
                    semantics: evidence.normalizedFailureSemantics
                )
            }
            guard evidence.normalizedFailureSemantics?.recoveryDisposition ==
                testCase.expectedFailureSemantics?.recoveryDisposition else {
                return failedResult(
                    testCase,
                    failure: .failureRecoveryMismatch,
                    semantics: evidence.normalizedFailureSemantics
                )
            }
            if testCase.identifier == .capabilityNegotiation,
               !valid(identity: subject.conformanceIdentity) {
                return failedResult(testCase, failure: .subjectIdentityInvalid)
            }
            return RuntimeProviderConformanceCaseResult(
                caseIdentifier: testCase.identifier,
                status: .passed,
                normalizedFailureSemantics: evidence.normalizedFailureSemantics
            )
        } catch {
            return failedResult(testCase, failure: .subjectError)
        }
    }

    private static func failedResult(
        _ testCase: RuntimeProviderConformanceCase,
        failure: RuntimeProviderConformanceCaseFailure,
        semantics: RuntimeProviderConformanceFailureSemantics? = nil
    ) -> RuntimeProviderConformanceCaseResult {
        RuntimeProviderConformanceCaseResult(
            caseIdentifier: testCase.identifier,
            status: .failed,
            failure: failure,
            normalizedFailureSemantics: semantics
        )
    }

    private static func capabilityResults(
        advertisedFeatures: [RuntimeProviderFeature],
        caseResults: [RuntimeProviderConformanceCaseResult]
    ) -> [RuntimeProviderConformanceCapabilityResult] {
        let counts = Dictionary(grouping: advertisedFeatures, by: { $0 }).mapValues(\.count)
        let knownFeatures = Set(RuntimeProviderFeature.knownValues)
        let caseResultByIdentifier = Dictionary(
            uniqueKeysWithValues: caseResults.map { ($0.caseIdentifier, $0) }
        )

        return counts.keys.sorted { $0.rawValue < $1.rawValue }.map { feature in
            let mappedCases = mappedCaseIdentifiers(for: feature)
            if !knownFeatures.contains(feature) {
                return rejectedCapability(feature, reason: .featureUnknown)
            }
            if counts[feature, default: 0] != 1 {
                return rejectedCapability(
                    feature,
                    reason: .advertisedMoreThanOnce,
                    mappedCases: mappedCases
                )
            }
            guard !mappedCases.isEmpty else {
                return rejectedCapability(feature, reason: .noMappedCases)
            }

            let failedCases = mappedCases.filter {
                caseResultByIdentifier[$0]?.status != .passed
            }
            guard failedCases.isEmpty else {
                return rejectedCapability(
                    feature,
                    reason: .mappedCaseFailed,
                    mappedCases: mappedCases,
                    failedCases: failedCases
                )
            }
            return RuntimeProviderConformanceCapabilityResult(
                feature: feature,
                status: .qualified,
                reason: .allMappedCasesPassed,
                mappedCases: mappedCases,
                failedCases: []
            )
        }
    }

    private static func rejectedCapability(
        _ feature: RuntimeProviderFeature,
        reason: RuntimeProviderConformanceCapabilityReason,
        mappedCases: [RuntimeProviderConformanceCaseID] = [],
        failedCases: [RuntimeProviderConformanceCaseID] = []
    ) -> RuntimeProviderConformanceCapabilityResult {
        RuntimeProviderConformanceCapabilityResult(
            feature: feature,
            status: .rejected,
            reason: reason,
            mappedCases: mappedCases,
            failedCases: failedCases
        )
    }

    private static func expectedFailureSemantics(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> RuntimeProviderConformanceFailureSemantics? {
        switch identifier {
        case .localImageRefusal:
            RuntimeProviderConformanceFailureSemantics(
                category: .rejected,
                retryDisposition: .never,
                recoveryDisposition: .none
            )
        case .timeout:
            RuntimeProviderConformanceFailureSemantics(
                category: .timedOut,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .cancellation:
            RuntimeProviderConformanceFailureSemantics(
                category: .cancelled,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .crash:
            RuntimeProviderConformanceFailureSemantics(
                category: .crashed,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve
            )
        case .failureInjection:
            RuntimeProviderConformanceFailureSemantics(
                category: .partialEffect,
                retryDisposition: .resumeFromCheckpoint,
                recoveryDisposition: .resume
            )
        default:
            nil
        }
    }

    private static func valid(
        identity: RuntimeProviderConformanceSubjectIdentity
    ) -> Bool {
        RuntimeProviderID.knownValues.contains(identity.providerID) &&
            identity.providerVersion.utf8.count <= 64 &&
            identity.providerVersion.range(
                of: #"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?\z"#,
                options: .regularExpression
            ) != nil
    }

    private static func mappedFeatures(
        for identifier: RuntimeProviderConformanceCaseID
    ) -> [RuntimeProviderFeature] {
        switch identifier {
        case .capabilityNegotiation:
            Array(mappedFeatureSet)
        case .observation, .boundedStats:
            [.observation]
        case .uuidIdentity:
            [.observation, .lifecycle, .processControl, .cleanup]
        case .localImageRefusal:
            [.lifecycle, .images, .errors]
        case .create:
            [.lifecycle]
        case .start, .managedRestart:
            [.lifecycle, .processControl]
        case .delete:
            [.lifecycle, .cleanup]
        case .boundedLogs:
            [.streaming]
        case .timeout:
            [.lifecycle, .processControl, .timeouts, .errors]
        case .cancellation:
            [.lifecycle, .processControl, .cancellation, .errors]
        case .crash, .providerRestart:
            [.lifecycle, .processControl, .errors]
        case .failureInjection:
            [.lifecycle, .errors, .cleanup]
        case .unmanagedSentinelPreservation, .exactCleanup:
            [.lifecycle, .cleanup]
        }
    }

    private static func caseIndex(_ identifier: RuntimeProviderConformanceCaseID) -> Int {
        RuntimeProviderConformanceCaseID.allCases.firstIndex(of: identifier) ?? .max
    }
}
