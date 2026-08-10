import Dispatch
import Foundation
import CryptoKit
import XCTest
import HostwrightScheduler

#if canImport(Darwin)
import Darwin
#endif

enum Phase10SchedulerQualification {
    static let defaultSeed: UInt64 = 0x10_209_214

    struct Configuration {
        static let generatedCountEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_GENERATED_COUNT"
        static let exactCountEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_EXACT_COUNT"
        static let seedEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_SEED"
        static let performanceEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_PERFORMANCE"
        static let performanceRepeatsEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_PERFORMANCE_REPEATS"
        static let referenceMacEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_REFERENCE_MAC"
        static let referenceMacIDEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_REFERENCE_MAC_ID"
        static let outputRootEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_OUTPUT_ROOT"

        let seed: UInt64
        let generatedCount: Int
        let exactCount: Int
        let performanceEnabled: Bool
        let performanceRepeats: Int
        let referenceMacGateEnabled: Bool
        let referenceMacID: String?
        let explicitOutputRoot: URL?

        init(
            seed: UInt64 = Phase10SchedulerQualification.defaultSeed,
            generatedCount: Int = 48,
            exactCount: Int = 24,
            performanceEnabled: Bool = false,
            performanceRepeats: Int = 7,
            referenceMacGateEnabled: Bool = false,
            referenceMacID: String? = nil,
            explicitOutputRoot: URL? = nil
        ) throws {
            guard generatedCount > 0, generatedCount <= 1_000_000 else {
                throw ConfigurationError.invalidCount(
                    name: Self.generatedCountEnvironment,
                    value: generatedCount,
                    maximum: 1_000_000
                )
            }
            guard exactCount > 0, exactCount <= 10_000 else {
                throw ConfigurationError.invalidCount(
                    name: Self.exactCountEnvironment,
                    value: exactCount,
                    maximum: 10_000
                )
            }
            guard performanceRepeats >= 5, performanceRepeats <= 1_000 else {
                throw ConfigurationError.invalidCount(
                    name: Self.performanceRepeatsEnvironment,
                    value: performanceRepeats,
                    maximum: 1_000
                )
            }
            if let explicitOutputRoot {
                try Self.validateExplicitOutputRoot(explicitOutputRoot)
            }
            let normalizedReferenceMacID = referenceMacID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if referenceMacGateEnabled {
                guard performanceEnabled else {
                    throw ConfigurationError.referenceMacGateRequiresPerformance
                }
                guard explicitOutputRoot != nil else {
                    throw ConfigurationError.referenceMacGateRequiresExplicitOutputRoot
                }
                guard !(normalizedReferenceMacID?.isEmpty ?? true) else {
                    throw ConfigurationError.referenceMacGateRequiresIdentifier
                }
                guard performanceRepeats == 7 else {
                    throw ConfigurationError.referenceMacGateRequiresSevenSamples
                }
            } else {
                guard normalizedReferenceMacID == nil else {
                    throw ConfigurationError.referenceMacGateForbidsIdentifier
                }
            }
            self.seed = seed
            self.generatedCount = generatedCount
            self.exactCount = exactCount
            self.performanceEnabled = performanceEnabled
            self.performanceRepeats = performanceRepeats
            self.referenceMacGateEnabled = referenceMacGateEnabled
            self.referenceMacID = normalizedReferenceMacID
            self.explicitOutputRoot = explicitOutputRoot
        }

        static func current(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> Configuration {
            let seed = try unsigned(
                environment[seedEnvironment],
                name: seedEnvironment,
                defaultValue: Phase10SchedulerQualification.defaultSeed
            )
            let generatedCount = try count(
                environment[generatedCountEnvironment],
                name: generatedCountEnvironment,
                defaultValue: 48,
                maximum: 1_000_000
            )
            let exactCount = try count(
                environment[exactCountEnvironment],
                name: exactCountEnvironment,
                defaultValue: 24,
                maximum: 10_000
            )
            let performanceRepeats = try count(
                environment[performanceRepeatsEnvironment],
                name: performanceRepeatsEnvironment,
                defaultValue: 7,
                maximum: 1_000
            )
            let outputRoot = environment[outputRootEnvironment].flatMap { raw -> URL? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
            }
            return try Configuration(
                seed: seed,
                generatedCount: generatedCount,
                exactCount: exactCount,
                performanceEnabled: enabled(environment[performanceEnvironment]),
                performanceRepeats: performanceRepeats,
                referenceMacGateEnabled: enabled(environment[referenceMacEnvironment]),
                referenceMacID: environment[referenceMacIDEnvironment],
                explicitOutputRoot: outputRoot
            )
        }

        var hasQualifiedReferenceMacGate: Bool {
            referenceMacGateEnabled
        }

        private static func count(
            _ raw: String?,
            name: String,
            defaultValue: Int,
            maximum: Int
        ) throws -> Int {
            guard let raw, !raw.isEmpty else {
                return defaultValue
            }
            guard let value = Int(raw), value > 0, value <= maximum else {
                throw ConfigurationError.invalidEnvironment(name: name, value: raw)
            }
            return value
        }

        private static func unsigned(
            _ raw: String?,
            name: String,
            defaultValue: UInt64
        ) throws -> UInt64 {
            guard let raw, !raw.isEmpty else {
                return defaultValue
            }
            let value: UInt64?
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
                value = UInt64(raw.dropFirst(2), radix: 16)
            } else {
                value = UInt64(raw)
            }
            guard let value else {
                throw ConfigurationError.invalidEnvironment(name: name, value: raw)
            }
            return value
        }

        private static func enabled(_ raw: String?) -> Bool {
            ["1", "true", "yes"].contains(raw?.lowercased())
        }

        static func validateExplicitOutputRoot(_ root: URL) throws {
            let standardizedRoot = root.standardizedFileURL
            guard standardizedRoot.isFileURL,
                  !standardizedRoot.path.isEmpty,
                  standardizedRoot.path != "/" else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            guard FileManager.default.fileExists(atPath: standardizedRoot.path),
                  !hasSymlinkComponent(standardizedRoot),
                  let resolvedRoot = resolvedRealPath(standardizedRoot) else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            if standardizedRoot.path == ownedDurableOutputRoot.standardizedFileURL.path {
                guard resolvedRoot == resolvedRealPath(ownedDurableOutputRoot.standardizedFileURL) else {
                    throw ConfigurationError.disallowedOutputRoot(root.path)
                }
                try validateExistingOrNearestParent(
                    standardizedRoot,
                    requirePrivateExistingDirectory: true
                )
                return
            }
            let pathComponents = standardizedRoot.pathComponents.map { $0.lowercased() }
            guard !pathComponents.contains("evidence"),
                  !pathComponents.contains(where: { $0.contains("phase08") || $0.contains("phase09") }) else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
            let isTemporaryRoot = isWithin(standardizedRoot, root: temporaryRoot)
            guard isTemporaryRoot,
                  let resolvedTemporaryRoot = resolvedRealPath(temporaryRoot),
                  resolvedRoot == resolvedTemporaryRoot || resolvedRoot.hasPrefix(resolvedTemporaryRoot + "/") else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            try validateExistingOrNearestParent(
                standardizedRoot,
                requirePrivateExistingDirectory: true
            )
        }

        static func isWithin(_ child: URL, root: URL) -> Bool {
            let childPath = child.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            guard childPath != rootPath else { return true }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return childPath.hasPrefix(prefix)
        }

        static func hasSymlinkComponent(_ url: URL) -> Bool {
            var current = URL(fileURLWithPath: "/", isDirectory: true)
            for component in url.standardizedFileURL.pathComponents {
                if component == "/" { continue }
                current.appendPathComponent(component, isDirectory: true)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
                      let type = attributes[.type] as? FileAttributeType else {
                    continue
                }
                if type == .typeSymbolicLink {
                    // Only the documented macOS compatibility links are
                    // accepted, and only when they resolve to their exact
                    // system targets.  Caller-owned links are rejected.
                    let resolved = try? FileManager.default.destinationOfSymbolicLink(
                        atPath: current.path
                    )
                    if (current.path == "/var" && resolved == "private/var")
                        || (current.path == "/tmp" && resolved == "private/tmp") {
                        continue
                    }
                    return true
                }
            }
            return false
        }

        static func resolvedRealPath(_ url: URL) -> String? {
#if canImport(Darwin)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard Darwin.realpath(url.path, &buffer) != nil else { return nil }
            return String(cString: buffer)
#else
            return url.resolvingSymlinksInPath().standardizedFileURL.path
#endif
        }

        private static func validateExistingOrNearestParent(
            _ url: URL,
            requirePrivateExistingDirectory: Bool
        ) throws {
            let current = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: current.path) else {
                throw ConfigurationError.disallowedOutputRoot(url.path)
            }
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
            let boundary = isWithin(current, root: temporaryRoot) ? temporaryRoot : current
            var ancestor = current
            while true {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
                      (attributes[.type] as? FileAttributeType) == .typeDirectory,
                      let owner = attributes[.ownerAccountName] as? String,
                      owner == NSUserName(),
                      let permissions = attributes[.posixPermissions] as? NSNumber,
                      (!requirePrivateExistingDirectory || permissions.intValue & 0o077 == 0) else {
                    throw ConfigurationError.disallowedOutputRoot(url.path)
                }
                if ancestor.path == boundary.path { break }
                let parent = ancestor.deletingLastPathComponent()
                guard parent.path != ancestor.path else {
                    throw ConfigurationError.disallowedOutputRoot(url.path)
                }
                ancestor = parent
            }
        }

        static var ownedDurableOutputRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".codex/evidence/phase10-scheduler-closure-2026-08-06",
                    isDirectory: true
                )
        }

        var outputRootIdentity: String {
            explicitOutputRoot?.standardizedFileURL.path ?? "temporary-phase10-owned"
        }
    }

    enum ConfigurationError: Error, LocalizedError {
        case invalidCount(name: String, value: Int, maximum: Int)
        case invalidEnvironment(name: String, value: String)
        case disallowedOutputRoot(String)
        case referenceMacGateRequiresExplicitOutputRoot
        case referenceMacGateRequiresIdentifier
        case referenceMacGateRequiresPerformance
        case referenceMacGateForbidsIdentifier
        case referenceMacGateRequiresSevenSamples

        var errorDescription: String? {
            switch self {
            case let .invalidCount(name, value, maximum):
                "\(name) must be in 1...\(maximum); received \(value)."
            case let .invalidEnvironment(name, value):
                "\(name) has an invalid value: \(value)."
            case let .disallowedOutputRoot(path):
                "Phase 10 qualification output may not use an evidence or Phase 08/09 root: \(path)."
            case .referenceMacGateRequiresExplicitOutputRoot:
                "A reference-Mac threshold gate requires an explicit retained Phase 10 output root."
            case .referenceMacGateRequiresIdentifier:
                "A reference-Mac threshold gate requires an explicit reference-Mac identifier."
            case .referenceMacGateRequiresPerformance:
                "A reference-Mac threshold gate requires the performance cell to be enabled."
            case .referenceMacGateForbidsIdentifier:
                "A disabled reference-Mac threshold gate may not carry a reference-Mac identifier."
            case .referenceMacGateRequiresSevenSamples:
                "A reference-Mac threshold gate requires exactly seven performance samples."
            }
        }
    }

    enum OracleMode: String, Codable {
        case none
        case feasibility
        case lockedTieBreak
    }

    struct Scenario: Codable, Equatable {
        let label: String
        let seed: UInt64
        let input: SchedulerEngineInput
        let oracleMode: OracleMode
    }

    struct StatefulTrace {
        let label: String
        let epochs: [Scenario]
        let protectedWorkloadID: UUID
        let expectedNodeID: UUID
        let protectedWorkMustBeFirst: Bool
        let maxMoves: Int
    }

    struct HardSelectorTopologyCase: Codable, Equatable {
        let workload: WorkloadPlacementRequirements
        let nodes: [SchedulerNode]
        let context: HardTopologySpreadContext
        let passingNodeID: UUID
        let absentNotInNodeID: UUID
        let skewedTopologyNodeID: UUID
    }

    enum IssueSeverity: String, Codable {
        case failure
        case diagnostic
    }

    enum IssueKind: String, Codable, Hashable {
        case engineError
        case decisionIdentity
        case hardPolicy
        case capacity
        case quota
        case preemption
        case determinism
        case starvationBound
        case churnBound
        case exactSafetyMismatch
        case exactTieBreakMismatch
        case intentionalOptimizationGap
        case hostileExpectation
        case harnessError
    }

    struct Issue: Codable, Equatable {
        let kind: IssueKind
        let severity: IssueSeverity
        let message: String
    }

    struct Evaluation {
        let decision: SchedulerDecision?
        let inputDigest: String
        let issues: [Issue]
        let oracle: Phase10SchedulerQualificationExactOracle.Result?
        private let provenance: Phase10SchedulerQualificationEvaluationProvenance?

        fileprivate init(
            decision: SchedulerDecision?,
            inputDigest: String,
            issues: [Issue],
            oracle: Phase10SchedulerQualificationExactOracle.Result?
        ) {
            self.decision = decision
            self.inputDigest = inputDigest
            self.issues = issues
            self.oracle = oracle
            provenance = Phase10SchedulerQualificationEvaluationProvenance()
        }

        var isVerifierProduced: Bool { provenance != nil }

        var failures: [Issue] {
            issues.filter { $0.severity == .failure }
        }

        func addingIssue(_ issue: Issue) -> Evaluation {
            Evaluation(
                decision: decision,
                inputDigest: inputDigest,
                issues: issues + [issue],
                oracle: oracle
            )
        }
    }
}

private final class Phase10SchedulerQualificationEvaluationProvenance {}

enum Phase10SchedulerQualificationRunCell: String, Codable {
    case generatedInvariant = "generated-invariant"
    case exactOracle = "exact-oracle"
}

struct Phase10SchedulerQualificationReceiptConfiguration: Codable, Equatable {
    let seed: UInt64
    let generatedCount: Int
    let exactCount: Int
    let performanceEnabled: Bool
    let performanceRepeats: Int
    let referenceMacGateEnabled: Bool
    let referenceMacID: String?
    let outputRootIdentity: String

    init(_ configuration: Phase10SchedulerQualification.Configuration) {
        seed = configuration.seed
        generatedCount = configuration.generatedCount
        exactCount = configuration.exactCount
        performanceEnabled = configuration.performanceEnabled
        performanceRepeats = configuration.performanceRepeats
        referenceMacGateEnabled = configuration.referenceMacGateEnabled
        referenceMacID = configuration.referenceMacID
        outputRootIdentity = configuration.outputRootIdentity
    }

    func validate() throws {
        guard performanceRepeats >= 5, performanceRepeats <= 1_000 else {
            throw Phase10SchedulerQualificationReceiptError.invalidCounts
        }
        if referenceMacGateEnabled {
            guard performanceEnabled,
                  performanceRepeats == 7,
                  !(referenceMacID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                    "reference-Mac gate requires the performance cell, seven samples, and a nonempty identifier"
                )
            }
        } else {
            guard referenceMacID == nil else {
                throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                    "reference-Mac identifier cannot be present without the gate"
                )
            }
        }
    }
}

struct Phase10SchedulerQualificationDirectTestOutcome: Codable, Equatable {
    let status: String
    let testCount: Int
    let failedTestCount: Int
    let assertionFailureCount: Int
    let skippedTestCount: Int
    let elapsedSeconds: Double
}

struct Phase10SchedulerQualificationReplayEntry: Codable, Equatable {
    let relativePath: String
    let sha256: String
    let byteCount: Int
    let issueKind: String
    let severity: String
    let scenarioSeed: UInt64
    let inputFingerprint: String
    let caseIndex: Int
    let oracleDomain: String?

    init(
        relativePath: String,
        sha256: String,
        byteCount: Int,
        issueKind: String,
        severity: String,
        scenarioSeed: UInt64,
        inputFingerprint: String,
        caseIndex: Int = -1,
        oracleDomain: String? = nil
    ) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.issueKind = issueKind
        self.severity = severity
        self.scenarioSeed = scenarioSeed
        self.inputFingerprint = inputFingerprint
        self.caseIndex = caseIndex
        self.oracleDomain = oracleDomain
    }
}

private struct Phase10SchedulerQualificationReplayBinding: Hashable {
    let caseIndex: Int
    let inputFingerprint: String
    let issueKind: String
    let severity: String
    let scenarioSeed: UInt64
    let sha256: String
    let byteCount: Int
    let oracleDomain: String?
}

private struct Phase10SchedulerQualificationExecutionTranscriptMaterial: Codable {
    let caseInputFingerprints: [String]
    let replayFixtures: [Phase10SchedulerQualificationReplayEntry]
    let directTest: Phase10SchedulerQualificationDirectTestOutcome
    let safetyMismatchCount: Int
    let optimizationGapCount: Int
}

enum Phase10SchedulerQualificationReceiptError: Error, LocalizedError {
    case invalidSchema(String)
    case invalidCell(String)
    case invalidFingerprint(field: String, value: String)
    case invalidCounts
    case invalidOutcome
    case invalidReplayEntry
    case invalidCrossField(String)
    case invalidInputSequence(String)
    case fingerprintMismatch(field: String, expected: String, actual: String)
    case outputRootMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .invalidSchema(schema):
            return "Unsupported Phase 10 scheduler qualification receipt schema: \(schema)."
        case let .invalidCell(cell):
            return "Unsupported Phase 10 scheduler qualification receipt cell: \(cell)."
        case let .invalidFingerprint(field, value):
            return "Phase 10 scheduler qualification \(field) fingerprint is invalid: \(value)."
        case .invalidCounts:
            return "Phase 10 scheduler qualification receipt counts are invalid."
        case .invalidOutcome:
            return "Phase 10 scheduler qualification receipt test outcome is invalid."
        case .invalidReplayEntry:
            return "Phase 10 scheduler qualification replay manifest entry is invalid."
        case let .invalidCrossField(detail):
            return "Phase 10 scheduler qualification receipt cross-field invariant failed: \(detail)."
        case let .invalidInputSequence(detail):
            return "Phase 10 scheduler qualification input sequence is invalid: \(detail)."
        case let .fingerprintMismatch(field, expected, actual):
            return "Phase 10 scheduler qualification \(field) fingerprint mismatch: expected \(expected), received \(actual)."
        case let .outputRootMismatch(expected, actual):
            return "Phase 10 scheduler qualification receipt output root mismatch: expected \(expected), received \(actual)."
        }
    }
}

struct Phase10SchedulerQualificationPathIdentity: Codable, Equatable {
    let textualPath: String
    let resolvedPath: String
    let device: UInt64
    let inode: UInt64

    static func placeholder(path: String) -> Self {
        Self(
            textualPath: path,
            resolvedPath: path,
            device: 1,
            inode: 1
        )
    }

    static func capture(_ url: URL) throws -> Self {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL,
              !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(standardized),
              let resolved = Phase10SchedulerQualification.Configuration.resolvedRealPath(standardized),
              let attributes = try? FileManager.default.attributesOfItem(atPath: standardized.path),
              (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        return Self(
            textualPath: standardized.path,
            resolvedPath: resolved,
            device: device.uint64Value,
            inode: inode.uint64Value
        )
    }

    func verify(at url: URL) throws {
        guard self == (try Self.capture(url)) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
    }
}

struct Phase10SchedulerQualificationRunReceipt: Codable, Equatable {
    static let schema = "hostwright.phase10.scheduler.qualification.run.v1"

    let schema: String
    let cell: Phase10SchedulerQualificationRunCell
    let testName: String
    let seed: UInt64
    let caseCount: Int
    let oracleDomain: String?
    let configuration: Phase10SchedulerQualificationReceiptConfiguration
    let directTest: Phase10SchedulerQualificationDirectTestOutcome
    let sourceFingerprint: String
    let inputFingerprint: String
    let buildFingerprint: String
    let executionTranscriptFingerprint: String
    let safetyMismatchCount: Int
    let optimizationGapCount: Int
    let caseInputFingerprints: [String]
    let replayFixtures: [Phase10SchedulerQualificationReplayEntry]
    let outputRootIdentity: String
    let runDirectoryIdentity: String
    let outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity?
    let runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity?
    let cleanupScopeVerified: Bool

    init(
        schema: String,
        cell: Phase10SchedulerQualificationRunCell,
        testName: String,
        seed: UInt64,
        caseCount: Int,
        oracleDomain: String?,
        configuration: Phase10SchedulerQualificationReceiptConfiguration,
        directTest: Phase10SchedulerQualificationDirectTestOutcome,
        sourceFingerprint: String,
        inputFingerprint: String,
        buildFingerprint: String,
        executionTranscriptFingerprint: String = "",
        safetyMismatchCount: Int,
        optimizationGapCount: Int,
        caseInputFingerprints: [String] = [],
        replayFixtures: [Phase10SchedulerQualificationReplayEntry],
        outputRootIdentity: String,
        runDirectoryIdentity: String,
        outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity? = nil,
        runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity? = nil,
        cleanupScopeVerified: Bool
    ) {
        self.schema = schema
        self.cell = cell
        self.testName = testName
        self.seed = seed
        self.caseCount = caseCount
        self.oracleDomain = oracleDomain
        self.configuration = configuration
        self.directTest = directTest
        self.sourceFingerprint = sourceFingerprint
        self.inputFingerprint = inputFingerprint
        self.buildFingerprint = buildFingerprint
        self.executionTranscriptFingerprint = executionTranscriptFingerprint.isEmpty
            ? Self.computeExecutionTranscriptFingerprint(
                caseInputFingerprints: caseInputFingerprints,
                replayFixtures: replayFixtures,
                directTest: directTest,
                safetyMismatchCount: safetyMismatchCount,
                optimizationGapCount: optimizationGapCount
            )
            : executionTranscriptFingerprint
        self.safetyMismatchCount = safetyMismatchCount
        self.optimizationGapCount = optimizationGapCount
        self.caseInputFingerprints = caseInputFingerprints
        self.replayFixtures = replayFixtures
        self.outputRootIdentity = outputRootIdentity
        self.runDirectoryIdentity = runDirectoryIdentity
        self.outputRootPathIdentity = outputRootPathIdentity
        self.runDirectoryPathIdentity = runDirectoryPathIdentity
        self.cleanupScopeVerified = cleanupScopeVerified
    }

    fileprivate static func computeExecutionTranscriptFingerprint(
        caseInputFingerprints: [String],
        replayFixtures: [Phase10SchedulerQualificationReplayEntry],
        directTest: Phase10SchedulerQualificationDirectTestOutcome,
        safetyMismatchCount: Int,
        optimizationGapCount: Int
    ) -> String {
        let material = Phase10SchedulerQualificationExecutionTranscriptMaterial(
            caseInputFingerprints: caseInputFingerprints,
            replayFixtures: replayFixtures.sorted { lhs, rhs in
                if lhs.relativePath != rhs.relativePath {
                    return lhs.relativePath < rhs.relativePath
                }
                if lhs.caseIndex != rhs.caseIndex {
                    return lhs.caseIndex < rhs.caseIndex
                }
                return lhs.inputFingerprint < rhs.inputFingerprint
            },
            directTest: directTest,
            safetyMismatchCount: safetyMismatchCount,
            optimizationGapCount: optimizationGapCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(material) else {
            return ""
        }
        return Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data)
    }

    func validate(
        allowPreCommitReplayPaths: Bool = false,
        requirePathIdentities: Bool = true
    ) throws {
        try configuration.validate()
        guard schema == Self.schema else {
            throw Phase10SchedulerQualificationReceiptError.invalidSchema(schema)
        }
        guard cell == .generatedInvariant || cell == .exactOracle else {
            throw Phase10SchedulerQualificationReceiptError.invalidCell(cell.rawValue)
        }
        let expectedTestName: String
        let expectedCaseCount: Int
        switch cell {
        case .generatedInvariant:
            expectedTestName = "testPhase10SchedulerQualificationSeededInvariantSmoke"
            expectedCaseCount = configuration.generatedCount
        case .exactOracle:
            expectedTestName = "testPhase10SchedulerQualificationExactMultiResourceFeasibilityOracleSmoke"
            expectedCaseCount = configuration.exactCount
        }
        guard testName == expectedTestName,
              caseCount == expectedCaseCount,
              seed == configuration.seed,
              caseCount > 0,
              safetyMismatchCount >= 0,
              optimizationGapCount >= 0 else {
            throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                "cell, test name, seed, and configured case count disagree"
            )
        }
        if cell == .generatedInvariant {
            guard oracleDomain == nil else {
                throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                    "generated invariant cell must not claim an oracle domain"
                )
            }
        } else {
            guard oracleDomain == "multi-resource(cpu,memory,disk)-hard-capacity-feasibility" else {
                throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                    "exact oracle cell must declare the multi-resource hard-capacity domain"
                )
            }
        }
        guard configuration.outputRootIdentity == outputRootIdentity,
              configuration.outputRootIdentity != "temporary-phase10-owned",
              !outputRootIdentity.isEmpty,
              Self.isSafeRunDirectoryIdentity(runDirectoryIdentity),
              cleanupScopeVerified else {
            throw Phase10SchedulerQualificationReceiptError.invalidOutcome
        }
        if requirePathIdentities {
            guard outputRootPathIdentity != nil,
                  runDirectoryPathIdentity != nil else {
                throw Phase10SchedulerQualificationReceiptError.invalidOutcome
            }
        }
        guard configuration.generatedCount > 0,
              configuration.generatedCount <= 1_000_000,
              configuration.exactCount > 0,
              configuration.exactCount <= 10_000,
              configuration.performanceRepeats >= 5,
              configuration.performanceRepeats <= 1_000,
              !configuration.referenceMacGateEnabled || configuration.performanceRepeats == 7 else {
            throw Phase10SchedulerQualificationReceiptError.invalidCounts
        }
        guard directTest.testCount == 1,
              directTest.failedTestCount == (safetyMismatchCount == 0 ? 0 : 1),
              directTest.assertionFailureCount == safetyMismatchCount,
              directTest.skippedTestCount == 0,
              directTest.elapsedSeconds.isFinite,
              directTest.elapsedSeconds >= 0,
              directTest.status == (safetyMismatchCount == 0 ? "passed" : "failed") else {
            throw Phase10SchedulerQualificationReceiptError.invalidOutcome
        }
        guard caseInputFingerprints.count == caseCount,
              caseInputFingerprints.allSatisfy({ $0.count == 64 }) else {
            throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                "receipt is missing a canonical input digest for one or more cases"
            )
        }
        for fingerprint in caseInputFingerprints {
            try Self.validateFingerprint(fingerprint, field: "case-input")
        }
        guard replayFixtures.filter({ $0.severity == "failure" }).count == safetyMismatchCount,
              replayFixtures.filter({ $0.issueKind == Phase10SchedulerQualification.IssueKind.intentionalOptimizationGap.rawValue }).count == optimizationGapCount else {
            throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                "mismatch and optimization-gap counts disagree with replay manifest"
            )
        }
        guard caseCount > 0 else {
            throw Phase10SchedulerQualificationReceiptError.invalidCounts
        }
        try Self.validateFingerprint(sourceFingerprint, field: "source")
        try Self.validateFingerprint(inputFingerprint, field: "input")
        try Self.validateFingerprint(buildFingerprint, field: "build")
        try Self.validateFingerprint(
            executionTranscriptFingerprint,
            field: "execution-transcript"
        )
        guard executionTranscriptFingerprint == Self.computeExecutionTranscriptFingerprint(
            caseInputFingerprints: caseInputFingerprints,
            replayFixtures: replayFixtures,
            directTest: directTest,
            safetyMismatchCount: safetyMismatchCount,
            optimizationGapCount: optimizationGapCount
        ) else {
            throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                "execution outcome transcript is not bound to the receipt counters and replay manifest"
            )
        }
        let sortedFixtures = replayFixtures.sorted { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.inputFingerprint < rhs.inputFingerprint
        }
        guard sortedFixtures == replayFixtures else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        var seenPaths = Set<String>()
        var seenReplayBindings = Set<Phase10SchedulerQualificationReplayBinding>()
        for fixture in replayFixtures {
            let validOracleDomain = cell == .exactOracle
                ? fixture.oracleDomain == Phase10SchedulerQualificationExactOracle.domain
                : fixture.oracleDomain == nil
                    || fixture.oracleDomain == Phase10SchedulerQualificationExactOracle.domain
            guard Self.isSafeRelativePath(fixture.relativePath),
                  seenPaths.insert(fixture.relativePath).inserted,
                  fixture.byteCount > 0,
                  fixture.caseIndex >= 0,
                  fixture.caseIndex < caseInputFingerprints.count,
                  fixture.inputFingerprint == caseInputFingerprints[fixture.caseIndex],
                  fixture.scenarioSeed == seed &+ UInt64(fixture.caseIndex),
                  validOracleDomain,
                  fixture.severity == "failure" || fixture.severity == "diagnostic" else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            if !allowPreCommitReplayPaths,
               !fixture.relativePath.hasPrefix(runDirectoryIdentity + "/") {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            guard seenReplayBindings.insert(
                Phase10SchedulerQualificationReplayBinding(
                    caseIndex: fixture.caseIndex,
                    inputFingerprint: fixture.inputFingerprint,
                    issueKind: fixture.issueKind,
                    severity: fixture.severity,
                    scenarioSeed: fixture.scenarioSeed,
                    sha256: fixture.sha256,
                    byteCount: fixture.byteCount,
                    oracleDomain: fixture.oracleDomain
                )
            ).inserted else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            guard Phase10SchedulerQualification.IssueKind(rawValue: fixture.issueKind) != nil,
                  fixture.issueKind != Phase10SchedulerQualification.IssueKind.intentionalOptimizationGap.rawValue
                    || fixture.severity == "diagnostic" else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            try Self.validateFingerprint(fixture.sha256, field: "replay")
            try Self.validateFingerprint(fixture.inputFingerprint, field: "replay-input")
        }
    }

    func verifyBinding(
        expectedSourceFingerprint: String,
        expectedInputFingerprint: String,
        expectedBuildFingerprint: String,
        expectedOutputRootIdentity: String
    ) throws {
        try validate()
        guard sourceFingerprint == expectedSourceFingerprint else {
            throw Phase10SchedulerQualificationReceiptError.fingerprintMismatch(
                field: "source",
                expected: expectedSourceFingerprint,
                actual: sourceFingerprint
            )
        }
        guard inputFingerprint == expectedInputFingerprint else {
            throw Phase10SchedulerQualificationReceiptError.fingerprintMismatch(
                field: "input",
                expected: expectedInputFingerprint,
                actual: inputFingerprint
            )
        }
        guard buildFingerprint == expectedBuildFingerprint else {
            throw Phase10SchedulerQualificationReceiptError.fingerprintMismatch(
                field: "build",
                expected: expectedBuildFingerprint,
                actual: buildFingerprint
            )
        }
        guard outputRootIdentity == expectedOutputRootIdentity else {
            throw Phase10SchedulerQualificationReceiptError.outputRootMismatch(
                expected: expectedOutputRootIdentity,
                actual: outputRootIdentity
            )
        }
    }

    func verifyReplayFiles(at root: URL) throws {
        try Phase10SchedulerQualification.Configuration.validateExplicitOutputRoot(root)
        guard outputRootIdentity == root.standardizedFileURL.path else {
            throw Phase10SchedulerQualificationReceiptError.outputRootMismatch(
                expected: outputRootIdentity,
                actual: root.standardizedFileURL.path
            )
        }
        try verifyCurrentBindings()
        guard let outputRootPathIdentity,
              let runDirectoryPathIdentity else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        try outputRootPathIdentity.verify(at: root.standardizedFileURL)
        guard !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(root) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let standardizedRoot = root.standardizedFileURL
        guard Self.isSafeRunDirectoryIdentity(runDirectoryIdentity) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let runDirectory = standardizedRoot.appendingPathComponent(
            runDirectoryIdentity,
            isDirectory: true
        ).standardizedFileURL
        guard Phase10SchedulerQualification.Configuration.isWithin(
            runDirectory,
            root: standardizedRoot
        ),
        !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(runDirectory),
        let runAttributes = try? FileManager.default.attributesOfItem(atPath: runDirectory.path),
            (runAttributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        try runDirectoryPathIdentity.verify(at: runDirectory)
        var seenSemanticReplayBindings = Set<String>()
        for fixture in replayFixtures {
            let validOracleDomain = cell == .exactOracle
                ? fixture.oracleDomain == Phase10SchedulerQualificationExactOracle.domain
                : fixture.oracleDomain == nil
                    || fixture.oracleDomain == Phase10SchedulerQualificationExactOracle.domain
            guard Self.isSafeRelativePath(fixture.relativePath),
                  fixture.relativePath.hasPrefix(runDirectoryIdentity + "/"),
                  fixture.caseIndex >= 0,
                  fixture.caseIndex < caseCount,
                  fixture.inputFingerprint == caseInputFingerprints[fixture.caseIndex],
                  fixture.scenarioSeed == seed &+ UInt64(fixture.caseIndex),
                  validOracleDomain else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            let canonicalScenario = try Phase10SchedulerQualificationGenerator.canonicalScenario(
                cell: cell,
                index: fixture.caseIndex,
                seed: seed
            )
            let destination = standardizedRoot.appendingPathComponent(
                fixture.relativePath,
                isDirectory: false
            ).standardizedFileURL
            guard Phase10SchedulerQualification.Configuration.isWithin(
                destination,
                root: standardizedRoot
            ),
            !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(destination),
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
            (attributes[.type] as? FileAttributeType) == .typeRegular,
            let data = try? Data(contentsOf: destination, options: [.mappedIfSafe]),
            data.count == fixture.byteCount,
            Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data) == fixture.sha256 else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            let replay = try Phase10SchedulerQualificationArtifacts.ReplayFixture.decodeStrict(
                from: data
            )
            try Self.verifyReplaySemantics(
                replay,
                manifestEntry: fixture,
                canonicalScenario: canonicalScenario
            )
            let semanticEncoder = JSONEncoder()
            semanticEncoder.outputFormatting = [.sortedKeys]
            let semanticDigest = Phase10SchedulerQualificationPerformance.Fingerprints.digest(
                data: try semanticEncoder.encode(replay)
            )
            let semanticKey = [
                String(fixture.caseIndex),
                fixture.inputFingerprint,
                fixture.issueKind,
                fixture.severity,
                semanticDigest
            ].joined(separator: "|")
            guard seenSemanticReplayBindings.insert(semanticKey).inserted else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
        }
        try verifyCommittedBundle(at: standardizedRoot, runDirectory: runDirectory)
    }

    private func verifyCurrentBindings() throws {
        var accumulator = Phase10SchedulerQualificationInputFingerprintAccumulator(
            cell: cell,
            seed: seed,
            caseCount: caseCount
        )
        var expectedSafetyMismatchCount = 0
        var expectedOptimizationGapCount = 0
        guard caseInputFingerprints.count == caseCount else {
            throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                "receipt case digest sequence does not match its case count"
            )
        }
        for index in 0..<caseCount {
            let scenario = try Phase10SchedulerQualificationGenerator.canonicalScenario(
                cell: cell,
                index: index,
                seed: seed
            )
            guard scenario.seed == seed &+ UInt64(index),
                  caseInputFingerprints[index] == scenario.input.inputDigest else {
                throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                    "receipt case (index) does not match the canonical scenario"
                )
            }
            try accumulator.append(index: index, scenario: scenario)

            let evaluation = Phase10SchedulerQualificationVerifier.evaluate(scenario)
            expectedSafetyMismatchCount += evaluation.issues.filter {
                $0.severity == .failure
            }.count
            expectedOptimizationGapCount += evaluation.issues.filter {
                $0.kind == .intentionalOptimizationGap
            }.count
            let caseFixtures = replayFixtures.filter { $0.caseIndex == index }
            guard caseFixtures.count == evaluation.issues.count else {
                throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                    "replay manifest does not cover the actual issue transcript for case (index)"
                )
            }
            var unmatchedFixtures = caseFixtures
            for issue in evaluation.issues {
                guard let fixtureIndex = unmatchedFixtures.firstIndex(where: {
                    $0.issueKind == issue.kind.rawValue
                        && $0.severity == issue.severity.rawValue
                        && $0.scenarioSeed == scenario.seed
                        && $0.inputFingerprint == scenario.input.inputDigest
                        && $0.oracleDomain == (scenario.oracleMode == .none
                            ? nil
                            : Phase10SchedulerQualificationExactOracle.domain)
                }) else {
                    throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                        "replay manifest issue classification does not match case (index)"
                    )
                }
                unmatchedFixtures.remove(at: fixtureIndex)
            }
            guard unmatchedFixtures.isEmpty else {
                throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                    "replay manifest contains an unexecuted issue for case (index)"
                )
            }
        }
        guard accumulator.finalize() == inputFingerprint else {
            throw Phase10SchedulerQualificationReceiptError.fingerprintMismatch(
                field: "input",
                expected: accumulator.finalize(),
                actual: inputFingerprint
            )
        }
        guard safetyMismatchCount == expectedSafetyMismatchCount,
              optimizationGapCount == expectedOptimizationGapCount,
              directTest.testCount == 1,
              directTest.failedTestCount == (expectedSafetyMismatchCount == 0 ? 0 : 1),
              directTest.assertionFailureCount == expectedSafetyMismatchCount,
              directTest.skippedTestCount == 0,
              directTest.status == (expectedSafetyMismatchCount == 0 ? "passed" : "failed") else {
            throw Phase10SchedulerQualificationReceiptError.invalidOutcome
        }
        guard executionTranscriptFingerprint == Self.computeExecutionTranscriptFingerprint(
            caseInputFingerprints: caseInputFingerprints,
            replayFixtures: replayFixtures,
            directTest: directTest,
            safetyMismatchCount: safetyMismatchCount,
            optimizationGapCount: optimizationGapCount
        ) else {
            throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                "execution outcome transcript does not match the current case-run evaluation"
            )
        }
        let operatingSystem = Phase10SchedulerQualificationPerformance.currentOperatingSystemDescription()
        let swiftVersion = Phase10SchedulerQualificationPerformance.swiftDescriptionForReceipt()
        let source = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
        let build = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
            swiftVersion: swiftVersion,
            operatingSystem: operatingSystem
        )
        try verifyBinding(
            expectedSourceFingerprint: source,
            expectedInputFingerprint: inputFingerprint,
            expectedBuildFingerprint: build,
            expectedOutputRootIdentity: outputRootIdentity
        )
    }

    static func verifyReplaySemantics(
        _ replay: Phase10SchedulerQualificationArtifacts.ReplayFixture,
        manifestEntry: Phase10SchedulerQualificationReplayEntry,
        canonicalScenario: Phase10SchedulerQualification.Scenario? = nil
    ) throws {
        guard replay.schema == "hostwright.phase10.scheduler.qualification.replay.v1",
              canonicalScenario == nil || replay.original == canonicalScenario,
              replay.original.oracleMode == replay.minimized.oracleMode,
              replay.original.seed == manifestEntry.scenarioSeed,
              replay.original.input.inputDigest == manifestEntry.inputFingerprint,
              replay.originalDecision == nil
                || replay.originalDecision?.inputDigest == replay.original.input.inputDigest,
              replay.minimizedDecision == nil
                || replay.minimizedDecision?.inputDigest == replay.minimized.input.inputDigest,
              replay.issue.kind.rawValue == manifestEntry.issueKind,
              replay.issue.severity.rawValue == manifestEntry.severity else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let originalEvaluation = Phase10SchedulerQualificationVerifier.evaluate(replay.original)
        let minimizedEvaluation = Phase10SchedulerQualificationVerifier.evaluate(replay.minimized)
        guard originalEvaluation.inputDigest == replay.original.input.inputDigest,
              minimizedEvaluation.inputDigest == replay.minimized.input.inputDigest,
              originalEvaluation.issues == replay.originalIssues,
              minimizedEvaluation.issues == replay.minimizedIssues,
              originalEvaluation.decision == replay.originalDecision,
              minimizedEvaluation.decision == replay.minimizedDecision else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        guard originalEvaluation.issues.contains(replay.issue)
            || minimizedEvaluation.issues.contains(replay.issue) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        if replay.original.oracleMode == .none {
            guard replay.oracle == nil else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
        } else {
            guard replay.oracle != nil else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
        }
        let oracleCandidates: [(Phase10SchedulerQualificationExactOracle.Result, String)] =
            [
                originalEvaluation.oracle.map { ($0, replay.original.input.inputDigest) },
                minimizedEvaluation.oracle.map { ($0, replay.minimized.input.inputDigest) }
            ].compactMap { $0 }
        switch (replay.oracle, oracleCandidates.first(where: { $0.0 == replay.oracle })) {
        case (nil, nil):
            break
        case let (.some(receiptOracle), .some((expectedOracle, expectedInputDigest))):
            guard receiptOracle == expectedOracle,
                  receiptOracle.inputFingerprint == expectedInputDigest,
                  receiptOracle.domain == Phase10SchedulerQualificationExactOracle.domain else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
        default:
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
    }

    private func verifyCommittedBundle(at root: URL, runDirectory: URL) throws {
        let receiptURL = runDirectory.appendingPathComponent(
            "qualification-\(cell.rawValue)-\(seed)-\(caseCount).json",
            isDirectory: false
        )
        let manifestURL = runDirectory.appendingPathComponent("replay-manifest.json")
        let commitURL = runDirectory.appendingPathComponent("COMMITTED")
        let receiptData = try verifiedRegularData(receiptURL)
        let manifestData = try verifiedRegularData(manifestURL)
        let commitData = try verifiedRegularData(commitURL)
        let manifest = try Phase10SchedulerQualificationReplayManifest.decodeStrict(
            from: manifestData
        )
        guard manifest.schema == "hostwright.phase10.scheduler.qualification.replay-manifest.v1",
              manifest.runDirectoryIdentity == runDirectoryIdentity,
              manifest.entries == replayFixtures else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let decodedReceipt = try Phase10SchedulerQualificationRunReceipt.decodeStrict(
            from: receiptData
        )
        guard decodedReceipt == self else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let lines = String(decoding: commitData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let expectedKeys: Set<String> = [
            "receipt",
            "receiptSha256",
            "manifest",
            "manifestSha256"
        ]
        var fields: [String: String] = [:]
        var seenKeys = Set<String>()
        for line in lines.dropFirst() {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  expectedKeys.contains(parts[0]),
                  !parts[1].isEmpty,
                  seenKeys.insert(parts[0]).inserted else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            fields[parts[0]] = parts[1]
        }
        guard lines.count == expectedKeys.count + 1,
              seenKeys == expectedKeys,
              lines.first == "hostwright.phase10.scheduler.qualification.commit.v1",
              fields["receipt"] == receiptURL.lastPathComponent,
              fields["manifest"] == manifestURL.lastPathComponent,
              fields["receiptSha256"] == Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: receiptData),
              fields["manifestSha256"] == Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: manifestData) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        _ = root
    }

    private func verifiedRegularData(_ url: URL) throws -> Data {
        guard !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        return data
    }

    func replacingReplayFixtures(
        _ replayFixtures: [Phase10SchedulerQualificationReplayEntry]
    ) -> Phase10SchedulerQualificationRunReceipt {
        Phase10SchedulerQualificationRunReceipt(
            schema: schema,
            cell: cell,
            testName: testName,
            seed: seed,
            caseCount: caseCount,
            oracleDomain: oracleDomain,
            configuration: configuration,
            directTest: directTest,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: inputFingerprint,
            buildFingerprint: buildFingerprint,
            safetyMismatchCount: safetyMismatchCount,
            optimizationGapCount: optimizationGapCount,
            caseInputFingerprints: caseInputFingerprints,
            replayFixtures: replayFixtures,
            outputRootIdentity: outputRootIdentity,
            runDirectoryIdentity: runDirectoryIdentity,
            outputRootPathIdentity: outputRootPathIdentity,
            runDirectoryPathIdentity: runDirectoryPathIdentity,
            cleanupScopeVerified: cleanupScopeVerified
        )
    }

    func replacingPathIdentities(
        outputRoot: Phase10SchedulerQualificationPathIdentity,
        runDirectory: Phase10SchedulerQualificationPathIdentity
    ) -> Phase10SchedulerQualificationRunReceipt {
        Phase10SchedulerQualificationRunReceipt(
            schema: schema,
            cell: cell,
            testName: testName,
            seed: seed,
            caseCount: caseCount,
            oracleDomain: oracleDomain,
            configuration: configuration,
            directTest: directTest,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: inputFingerprint,
            buildFingerprint: buildFingerprint,
            safetyMismatchCount: safetyMismatchCount,
            optimizationGapCount: optimizationGapCount,
            caseInputFingerprints: caseInputFingerprints,
            replayFixtures: replayFixtures,
            outputRootIdentity: outputRootIdentity,
            runDirectoryIdentity: runDirectoryIdentity,
            outputRootPathIdentity: outputRoot,
            runDirectoryPathIdentity: runDirectory,
            cleanupScopeVerified: cleanupScopeVerified
        )
    }

    static func isSafeReplayPathForEmission(_ path: String) -> Bool {
        isSafeRelativePath(path)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func isSafeRunDirectoryIdentity(_ path: String) -> Bool {
        guard isSafeRelativePath(path),
              path.hasPrefix("Phase10SchedulerQualification/run-") else {
            return false
        }
        return path.split(separator: "/").count == 2
    }

    private static func validateFingerprint(_ value: String, field: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  switch $0.value {
                  case 48...57, 97...102:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw Phase10SchedulerQualificationReceiptError.invalidFingerprint(
                field: field,
                value: value
            )
        }
    }
}

extension Phase10SchedulerQualificationRunReceipt {
    static func decodeStrict(from data: Data) throws -> Self {
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var scanner = Phase10SchedulerQualificationStrictJSONScanner(
            data: data,
            allowedKeys: Phase10SchedulerQualificationStrictJSONScanner.receiptAllowedKeys
        )
        try scanner.validate()
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case cell
        case testName
        case seed
        case caseCount
        case oracleDomain
        case configuration
        case directTest
        case sourceFingerprint
        case inputFingerprint
        case buildFingerprint
        case executionTranscriptFingerprint
        case safetyMismatchCount
        case optimizationGapCount
        case caseInputFingerprints
        case replayFixtures
        case outputRootIdentity
        case cleanupScopeVerified
        case runDirectoryIdentity
        case outputRootPathIdentity
        case runDirectoryPathIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        cell = try container.decode(Phase10SchedulerQualificationRunCell.self, forKey: .cell)
        testName = try container.decode(String.self, forKey: .testName)
        seed = try container.decode(UInt64.self, forKey: .seed)
        caseCount = try container.decode(Int.self, forKey: .caseCount)
        oracleDomain = try container.decodeIfPresent(String.self, forKey: .oracleDomain)
        configuration = try container.decode(
            Phase10SchedulerQualificationReceiptConfiguration.self,
            forKey: .configuration
        )
        directTest = try container.decode(
            Phase10SchedulerQualificationDirectTestOutcome.self,
            forKey: .directTest
        )
        sourceFingerprint = try container.decode(String.self, forKey: .sourceFingerprint)
        inputFingerprint = try container.decode(String.self, forKey: .inputFingerprint)
        buildFingerprint = try container.decode(String.self, forKey: .buildFingerprint)
        executionTranscriptFingerprint = try container.decode(
            String.self,
            forKey: .executionTranscriptFingerprint
        )
        safetyMismatchCount = try container.decode(Int.self, forKey: .safetyMismatchCount)
        optimizationGapCount = try container.decode(Int.self, forKey: .optimizationGapCount)
        caseInputFingerprints = try container.decode([String].self, forKey: .caseInputFingerprints)
        replayFixtures = try container.decode(
            [Phase10SchedulerQualificationReplayEntry].self,
            forKey: .replayFixtures
        )
        outputRootIdentity = try container.decode(String.self, forKey: .outputRootIdentity)
        runDirectoryIdentity = try container.decode(String.self, forKey: .runDirectoryIdentity)
        outputRootPathIdentity = try container.decode(
            Phase10SchedulerQualificationPathIdentity.self,
            forKey: .outputRootPathIdentity
        )
        runDirectoryPathIdentity = try container.decode(
            Phase10SchedulerQualificationPathIdentity.self,
            forKey: .runDirectoryPathIdentity
        )
        cleanupScopeVerified = try container.decode(Bool.self, forKey: .cleanupScopeVerified)
        try validate()
    }
}

private struct Phase10SchedulerQualificationStrictJSONScanner {
    private let bytes: [UInt8]
    private let allowedKeys: [String: Set<String>]
    private var index = 0

    init(data: Data, allowedKeys: [String: Set<String>]) {
        bytes = Array(data)
        self.allowedKeys = allowedKeys
    }

    mutating func validate() throws {
        try value(path: "root")
        skipWhitespace()
        guard index == bytes.count else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("trailing JSON") }
    }

    private mutating func value(path: String) throws {
        skipWhitespace()
        guard index < bytes.count else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("truncated JSON") }
        switch bytes[index] {
        case 0x7B: try object(path: path)
        case 0x5B: try array(path: path)
        case 0x22: _ = try string()
        default: try scalar()
        }
    }

    private mutating func object(path: String) throws {
        index += 1
        var seen = Set<String>()
        skipWhitespace()
        if consume(0x7D) { return }
        while true {
            skipWhitespace()
            let key = try string()
            if let allowed = Self.allowedKeys(for: path, in: allowedKeys),
               !allowed.contains("*") && !allowed.contains(key) {
                throw Phase10SchedulerQualificationReceiptError.invalidSchema("unknown JSON key \(key) at \(path)")
            }
            guard seen.insert(key).inserted else {
                throw Phase10SchedulerQualificationReceiptError.invalidSchema("duplicate JSON key \(key) at \(path)")
            }
            skipWhitespace()
            guard consume(0x3A) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("missing JSON colon") }
            try value(path: Self.childPath(path: path, key: key))
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("missing JSON comma") }
        }
    }

    private mutating func array(path: String) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try value(path: path + "[]")
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("missing JSON array comma") }
        }
    }

    private mutating func scalar() throws {
        let start = index
        while index < bytes.count,
              ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("invalid JSON scalar") }
    }

    private mutating func string() throws -> String {
        guard consume(0x22) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("expected JSON string") }
        var raw = Data([0x22])
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            raw.append(byte)
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return try JSONDecoder().decode(String.self, from: raw)
            }
        }
        throw Phase10SchedulerQualificationReceiptError.invalidSchema("unterminated JSON string")
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private static func childPath(path: String, key: String) -> String {
        path == "root" ? "root." + key : path + "." + key
    }

    private static func allowedKeys(
        for path: String,
        in allowedKeys: [String: Set<String>]
    ) -> Set<String>? {
        allowedKeys[path]
    }

    static func validateJSONShape(_ data: Data, canonicalData: Data) throws {
        let actual = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let canonical = try JSONSerialization.jsonObject(
            with: canonicalData,
            options: [.fragmentsAllowed]
        )
        guard sameJSONShape(actual, canonical) else {
            throw Phase10SchedulerQualificationReceiptError.invalidSchema(
                "replay JSON contains an unknown or missing key"
            )
        }
    }

    private static func sameJSONShape(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (left as [String: Any], right as [String: Any]):
            guard left.count == right.count,
                  Set(left.keys) == Set(right.keys) else {
                return false
            }
            return left.allSatisfy { key, value in
                guard let other = right[key] else { return false }
                return sameJSONShape(value, other)
            }
        case let (left as [Any], right as [Any]):
            return left.count == right.count
                && zip(left, right).allSatisfy { sameJSONShape($0, $1) }
        case (_ as NSNull, _ as NSNull):
            return true
        case (_ as String, _ as String),
             (_ as NSNumber, _ as NSNumber):
            return true
        default:
            return false
        }
    }

    static let receiptAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "cell", "testName", "seed", "caseCount", "oracleDomain", "configuration", "directTest", "sourceFingerprint", "inputFingerprint", "buildFingerprint", "executionTranscriptFingerprint", "safetyMismatchCount", "optimizationGapCount", "caseInputFingerprints", "replayFixtures", "outputRootIdentity", "runDirectoryIdentity", "outputRootPathIdentity", "runDirectoryPathIdentity", "cleanupScopeVerified"],
        "root.configuration": ["seed", "generatedCount", "exactCount", "performanceEnabled", "performanceRepeats", "referenceMacGateEnabled", "referenceMacID", "outputRootIdentity"],
        "root.directTest": ["status", "testCount", "failedTestCount", "assertionFailureCount", "skippedTestCount", "elapsedSeconds"],
        "root.replayFixtures[]": ["relativePath", "sha256", "byteCount", "issueKind", "severity", "scenarioSeed", "inputFingerprint", "caseIndex", "oracleDomain"],
        "root.outputRootPathIdentity": ["textualPath", "resolvedPath", "device", "inode"],
        "root.runDirectoryPathIdentity": ["textualPath", "resolvedPath", "device", "inode"]
    ]

    static let performanceAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "hardware", "operatingSystem", "swiftVersion", "seed", "pendingWorkloads", "nodes", "repeats", "samplesSeconds", "p95Seconds", "referenceMacGateEnabled", "referenceMacID", "thresholdEnforced", "sourceFingerprint", "inputFingerprint", "buildFingerprint"]
    ]

    static let performanceTranscriptAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "seed", "pendingWorkloads", "nodes", "repeats", "samplesSeconds", "hardware", "operatingSystem", "swiftVersion", "referenceMacGateEnabled", "referenceMacID", "thresholdEnforced", "sourceFingerprint", "inputFingerprint", "buildFingerprint"]
    ]

    static let performanceManifestAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "recordPath", "recordSha256", "recordByteCount", "transcriptPath", "transcriptSha256", "transcriptByteCount", "outputRootIdentity", "runDirectoryIdentity", "outputRootPathIdentity", "runDirectoryPathIdentity"]
    ]

    static let manifestAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "runDirectoryIdentity", "entries"],
        "root.entries[]": ["relativePath", "sha256", "byteCount", "issueKind", "severity", "scenarioSeed", "inputFingerprint", "caseIndex", "oracleDomain"]
    ]

    static let replayAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "issue", "original", "minimized", "originalIssues", "minimizedIssues", "originalDecision", "minimizedDecision", "oracle"],
        "root.issue": ["kind", "severity", "message"],
        "root.original": ["label", "seed", "input", "oracleMode"],
        "root.minimized": ["label", "seed", "input", "oracleMode"],
        "root.originalIssues[]": ["kind", "severity", "message"],
        "root.minimizedIssues[]": ["kind", "severity", "message"],
        "root.originalDecision": ["decisionID", "inputDigest", "orderedWorkloadIDs", "workloadDecisions", "snapshotQuality"],
        "root.minimizedDecision": ["decisionID", "inputDigest", "orderedWorkloadIDs", "workloadDecisions", "snapshotQuality"],
        "root.oracle": ["inputFingerprint", "domain", "maxPlaced", "canonicalAssignment"]
    ]
}

struct Phase10SchedulerQualificationInputFingerprintAccumulator {
    private var hasher = SHA256()
    private var canonicalMaterial = Data()
    private var appendedCount = 0

    var count: Int { appendedCount }

    init(cell: Phase10SchedulerQualificationRunCell, seed: UInt64, caseCount: Int) {
        appendFrame("hostwright.phase10.scheduler.qualification.input.v1")
        appendFrame(cell.rawValue)
        appendUInt64(seed)
        appendUInt64(UInt64(caseCount))
    }

    mutating func append(
        index: Int,
        scenario: Phase10SchedulerQualification.Scenario
    ) throws {
        guard index == appendedCount else {
            throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                "expected index \(appendedCount), received \(index)"
            )
        }
        appendUInt64(UInt64(index))
        appendUInt64(scenario.seed)
        appendFrame(scenario.oracleMode.rawValue)
        appendFrame(scenario.input.inputDigest)
        appendedCount += 1
    }

    mutating func finalize() -> String {
        var finalHasher = hasher
        var bigEndian = UInt64(appendedCount).bigEndian
        finalHasher.update(
            data: Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        )
        return finalHasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func canonicalMaterialForBinding() -> Data {
        var material = canonicalMaterial
        Self.appendUInt64(UInt64(appendedCount), to: &material)
        return material
    }

    private mutating func appendFrame(_ value: String) {
        let data = Data(value.utf8)
        appendUInt64(UInt64(data.count))
        appendBytes(data)
    }

    private mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        appendBytes(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
    }

    private mutating func appendBytes(_ data: Data) {
        hasher.update(data: data)
        canonicalMaterial.append(data)
    }

    private static func appendUInt64(_ value: UInt64, to material: inout Data) {
        var bigEndian = value.bigEndian
        material.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
    }
}

struct Phase10SchedulerQualificationEvaluationMetrics: Equatable {
    var safetyMismatchCount: Int = 0
    var optimizationGapCount: Int = 0
    var replayFixtures: [Phase10SchedulerQualificationReplayEntry] = []

    mutating func ingest(
        issue: Phase10SchedulerQualification.Issue,
        scenario: Phase10SchedulerQualification.Scenario,
        receipt: Phase10SchedulerQualificationArtifacts.Receipt,
        caseIndex: Int = -1
    ) {
        if issue.severity == .failure {
            safetyMismatchCount += 1
        }
        if issue.kind == .intentionalOptimizationGap {
            optimizationGapCount += 1
        }
        replayFixtures.append(
            Phase10SchedulerQualificationReplayEntry(
                relativePath: receipt.relativePath,
                sha256: receipt.sha256,
                byteCount: receipt.byteCount,
                issueKind: issue.kind.rawValue,
                severity: issue.severity.rawValue,
                scenarioSeed: scenario.seed,
                inputFingerprint: scenario.input.inputDigest,
                caseIndex: caseIndex,
                oracleDomain: scenario.oracleMode == .none
                    ? nil
                    : Phase10SchedulerQualificationExactOracle.domain
            )
        )
    }
}

struct Phase10SchedulerQualificationRunSession {
    let record: Phase10SchedulerQualificationRunReceipt
    fileprivate let canonicalInputMaterial: Data

    fileprivate init(
        record: Phase10SchedulerQualificationRunReceipt,
        canonicalInputMaterial: Data
    ) {
        self.record = record
        self.canonicalInputMaterial = canonicalInputMaterial
    }
}

struct Phase10SchedulerQualificationReplayManifest: Codable, Equatable {
    let schema: String
    let runDirectoryIdentity: String
    let entries: [Phase10SchedulerQualificationReplayEntry]

    static func decodeStrict(from data: Data) throws -> Self {
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var scanner = Phase10SchedulerQualificationStrictJSONScanner(
            data: data,
            allowedKeys: Phase10SchedulerQualificationStrictJSONScanner.manifestAllowedKeys
        )
        try scanner.validate()
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

struct Phase10SchedulerQualificationRunReceiptBuilder {
    let cell: Phase10SchedulerQualificationRunCell
    let testName: String
    let seed: UInt64
    let caseCount: Int
    let configuration: Phase10SchedulerQualificationReceiptConfiguration
    private var inputAccumulator: Phase10SchedulerQualificationInputFingerprintAccumulator
    private var metrics = Phase10SchedulerQualificationEvaluationMetrics()
    private var oracleDomain: String?
    private var caseInputFingerprints: [String] = []
    private var appendedCount = 0
    private let runDirectoryIdentity: String

    init(
        cell: Phase10SchedulerQualificationRunCell,
        testName: String,
        seed: UInt64,
        caseCount: Int,
        configuration: Phase10SchedulerQualification.Configuration
    ) {
        self.cell = cell
        self.testName = testName
        self.seed = seed
        self.caseCount = caseCount
        self.configuration = Phase10SchedulerQualificationReceiptConfiguration(configuration)
        runDirectoryIdentity = "Phase10SchedulerQualification/run-\(UUID().uuidString.lowercased())"
        inputAccumulator = Phase10SchedulerQualificationInputFingerprintAccumulator(
            cell: cell,
            seed: seed,
            caseCount: caseCount
        )
    }

    mutating func append(
        index: Int,
        scenario: Phase10SchedulerQualification.Scenario,
        evaluation: Phase10SchedulerQualification.Evaluation,
        metrics: Phase10SchedulerQualificationEvaluationMetrics
    ) throws {
        let canonicalScenario = try Phase10SchedulerQualificationGenerator.canonicalScenario(
            cell: cell,
            index: index,
            seed: seed
        )
        guard index == appendedCount,
              scenario.seed == seed &+ UInt64(index),
              scenario == canonicalScenario,
              evaluation.isVerifierProduced,
              evaluation.inputDigest == scenario.input.inputDigest,
              evaluation.decision == nil || evaluation.decision?.inputDigest == scenario.input.inputDigest,
              metrics.replayFixtures.count == evaluation.issues.count,
              metrics.safetyMismatchCount == evaluation.issues.filter({ $0.severity == .failure }).count,
              metrics.optimizationGapCount == evaluation.issues.filter({ $0.kind == .intentionalOptimizationGap }).count else {
            throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                "case \(index) did not provide exactly one ordered evaluation and matching metrics"
            )
        }
        let expectedOracleDomain = Phase10SchedulerQualificationExactOracle.domain
        switch scenario.oracleMode {
        case .none:
            guard evaluation.oracle == nil else {
                throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                    "case \(index) supplied an oracle for a non-oracle scenario"
                )
            }
        case .feasibility, .lockedTieBreak:
            let oracleFailure = evaluation.issues.contains {
                $0.kind == .engineError || $0.kind == .harnessError
            }
            guard oracleFailure || (evaluation.oracle?.inputFingerprint == scenario.input.inputDigest
                && (evaluation.oracle?.domain == expectedOracleDomain
                    || evaluation.issues.contains(where: { $0.kind == .exactSafetyMismatch }))) else {
                throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                    "case \(index) oracle metadata did not bind to its scenario"
                )
            }
        }
        let expectedReplayDomain = scenario.oracleMode == .none
            ? nil
            : Phase10SchedulerQualificationExactOracle.domain
        for (issue, fixture) in zip(evaluation.issues, metrics.replayFixtures) {
            guard fixture.issueKind == issue.kind.rawValue,
                  fixture.severity == issue.severity.rawValue,
                  fixture.scenarioSeed == scenario.seed,
                  fixture.inputFingerprint == scenario.input.inputDigest,
                  fixture.caseIndex == index,
                  fixture.oracleDomain == expectedReplayDomain else {
                throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                    "case \(index) replay metadata did not bind to its verifier issue"
                )
            }
        }
        try inputAccumulator.append(index: index, scenario: scenario)
        caseInputFingerprints.append(scenario.input.inputDigest)
        appendedCount += 1
        // Generated invariant scenarios intentionally include the locked-tie
        // hostile case, but that per-case oracle metadata is not the exact
        // multi-resource oracle cell's root domain. Keep the root field nil
        // for generated receipts while retaining each replay's bound domain.
        if cell == .exactOracle {
            if let oracleDomain {
                if oracleDomain != evaluation.oracle?.domain {
                    self.oracleDomain = "mixed"
                }
            } else {
                oracleDomain = evaluation.oracle?.domain
            }
        }
        self.metrics.safetyMismatchCount += metrics.safetyMismatchCount
        self.metrics.optimizationGapCount += metrics.optimizationGapCount
        self.metrics.replayFixtures.append(contentsOf: metrics.replayFixtures)
    }

    mutating func makePreparedReceipt(
        elapsedSeconds: Double
    ) throws -> Phase10SchedulerQualificationRunSession {
        guard appendedCount == caseCount,
              inputAccumulator.count == caseCount else {
            throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                "appended \(appendedCount) cases for configured count \(caseCount)"
            )
        }
        let sourceFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
        let operatingSystem = Phase10SchedulerQualificationPerformance.currentOperatingSystemDescription()
        let swiftVersion = Phase10SchedulerQualificationPerformance.swiftDescriptionForReceipt()
        let buildFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
            swiftVersion: swiftVersion,
            operatingSystem: operatingSystem
        )
        let inputFingerprint = inputAccumulator.finalize()
        guard caseInputFingerprints.count == caseCount else {
            throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                "case input digest sequence is incomplete"
            )
        }
        let canonicalInputMaterial = inputAccumulator.canonicalMaterialForBinding()
        let sortedFixtures = metrics.replayFixtures.sorted { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.inputFingerprint < rhs.inputFingerprint
        }
        let directTest = Phase10SchedulerQualificationDirectTestOutcome(
            status: metrics.safetyMismatchCount == 0 ? "passed" : "failed",
            testCount: 1,
            failedTestCount: metrics.safetyMismatchCount == 0 ? 0 : 1,
            assertionFailureCount: metrics.safetyMismatchCount,
            skippedTestCount: 0,
            elapsedSeconds: elapsedSeconds
        )
        let record = Phase10SchedulerQualificationRunReceipt(
            schema: Phase10SchedulerQualificationRunReceipt.schema,
            cell: cell,
            testName: testName,
            seed: seed,
            caseCount: caseCount,
            oracleDomain: oracleDomain,
            configuration: configuration,
            directTest: directTest,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: inputFingerprint,
            buildFingerprint: buildFingerprint,
            safetyMismatchCount: metrics.safetyMismatchCount,
            optimizationGapCount: metrics.optimizationGapCount,
            caseInputFingerprints: caseInputFingerprints,
            replayFixtures: sortedFixtures,
            outputRootIdentity: configuration.outputRootIdentity,
            runDirectoryIdentity: runDirectoryIdentity,
            cleanupScopeVerified: configuration.outputRootIdentity != "temporary-phase10-owned"
        )
        return Phase10SchedulerQualificationRunSession(
            record: record,
            canonicalInputMaterial: canonicalInputMaterial
        )
    }
}

private struct Phase10SchedulerQualificationPRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func integer(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func boolean() -> Bool {
        next() & 1 == 1
    }
}

enum Phase10SchedulerQualificationGenerator {
    static func canonicalScenario(
        cell: Phase10SchedulerQualificationRunCell,
        index: Int,
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        switch cell {
        case .generatedInvariant:
            return try generatedScenario(index: index, seed: seed)
        case .exactOracle:
            return try exactScenario(index: index, seed: seed)
        }
    }

    static func generatedScenario(index: Int, seed: UInt64) throws -> Phase10SchedulerQualification.Scenario {
        let scenarioSeed = seed &+ UInt64(index)
        switch index % 12 {
        case 0:
            return try mixedScenario(index: index, seed: scenarioSeed)
        case 1:
            return try quotaAndBorrowingScenario(seed: scenarioSeed)
        case 2:
            return try topologyConflictScenario(seed: scenarioSeed)
        case 3:
            return try antiChurnScenario(seed: scenarioSeed)
        case 4:
            return try preemptionScenario(seed: scenarioSeed)
        case 5:
            return try disruptionExhaustionScenario(seed: scenarioSeed)
        case 6:
            return try exactSearchBoundScenario(seed: scenarioSeed)
        case 7:
            return try exactTieScenario(seed: scenarioSeed)
        case 8:
            return try hardSelectorTopologyScenario(seed: scenarioSeed)
        case 9:
            return try preemptionOverlapScenario(seed: scenarioSeed)
        case 10:
            return try exactPreemptionHardTopologyScenario(seed: scenarioSeed)
        default:
            return try weightedSelectorScenario(seed: scenarioSeed)
        }
    }

    static func hostileScenarios(
        seed: UInt64
    ) throws -> [Phase10SchedulerQualification.Scenario] {
        try [
            emptyFeasibilityScenario(seed: seed &+ 1),
            exactTieScenario(seed: seed &+ 2),
            quotaAndBorrowingScenario(seed: seed &+ 3),
            topologyConflictScenario(seed: seed &+ 4),
            antiChurnScenario(seed: seed &+ 5),
            preemptionScenario(seed: seed &+ 6),
            disruptionExhaustionScenario(seed: seed &+ 7),
            exactSearchBoundScenario(seed: seed &+ 8),
            hardSelectorTopologyScenario(seed: seed &+ 9),
            preemptionOverlapScenario(seed: seed &+ 10),
            exactPreemptionHardTopologyScenario(seed: seed &+ 11),
            weightedSelectorScenario(seed: seed &+ 12)
        ]
    }

    static func hardSelectorTopologyCase(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.HardSelectorTopologyCase {
        let passingNodeID = identifier(seed: seed, slot: 8_000)
        let absentNotInNodeID = identifier(seed: seed, slot: 8_001)
        let skewedTopologyNodeID = identifier(seed: seed, slot: 8_002)
        let workloadID = identifier(seed: seed, slot: 8_003)
        let observedWorkloadID = identifier(seed: seed, slot: 8_004)
        let unrelatedWorkloadID = identifier(seed: seed, slot: 8_005)
        let affinity = try NodeAffinity(
            requiredSelectors: [
                try SchedulerLabelSelector(
                    key: "class",
                    operator: .notIn,
                    values: ["gpu"]
                ),
                try SchedulerLabelSelector(key: "rack", operator: .exists),
                try SchedulerLabelSelector(
                    key: "zone",
                    operator: .in,
                    values: ["east", "west"]
                )
            ],
            forbiddenSelectors: [
                try SchedulerLabelSelector(key: "spot", operator: .doesNotExist)
            ],
            topologySpreads: [
                try SchedulerHardTopologySpread(
                    topologyKey: "zone",
                    maxSkew: 1,
                    whenUnsatisfiable: .doNotSchedule,
                    groupID: "phase10-hard"
                )
            ]
        )
        let schedulerWorkload = try workload(
            id: workloadID,
            cpu: 1,
            memory: 1,
            priority: 5,
            subject: "hard-selector",
            project: "phase10",
            affinity: affinity
        )
        let passingNode = try node(
            id: passingNodeID,
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "west"],
            labels: [
                "pool": "general",
                "zone": "west",
                "class": "cpu",
                "rack": "r1",
                "spot": "false"
            ]
        )
        let absentNotInNode = try node(
            id: absentNotInNodeID,
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "west"],
            labels: ["pool": "general", "zone": "west", "rack": "r2"]
        )
        let skewedTopologyNode = try node(
            id: skewedTopologyNodeID,
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "east"],
            labels: [
                "pool": "general",
                "zone": "east",
                "class": "cpu",
                "rack": "r1",
                "spot": "false"
            ]
        )
        let context = try HardTopologySpreadContext(
            nodeTopologyDomains: [
                passingNodeID: ["zone": "west"],
                absentNotInNodeID: ["zone": "west"],
                skewedTopologyNodeID: ["zone": "east"]
            ],
            observations: [
                try HardTopologySpreadObservation(
                    workloadID: observedWorkloadID,
                    nodeID: skewedTopologyNodeID,
                    groupID: "phase10-hard"
                ),
                try HardTopologySpreadObservation(
                    workloadID: unrelatedWorkloadID,
                    nodeID: passingNodeID,
                    groupID: "other-group"
                )
            ]
        )
        return Phase10SchedulerQualification.HardSelectorTopologyCase(
            workload: schedulerWorkload.requirements,
            nodes: [skewedTopologyNode, absentNotInNode, passingNode],
            context: context,
            passingNodeID: passingNodeID,
            absentNotInNodeID: absentNotInNodeID,
            skewedTopologyNodeID: skewedTopologyNodeID
        )
    }

    static func hardSelectorTopologyScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let hardCase = try hardSelectorTopologyCase(seed: seed)
        let schedulerWorkload = try SchedulerWorkload(
            requirements: hardCase.workload,
            priority: 5,
            subjectID: "hard-selector",
            projectID: "phase10"
        )
        return Phase10SchedulerQualification.Scenario(
            label: "hard-selector-topology",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [schedulerWorkload],
                nodes: hardCase.nodes
            ),
            oracleMode: .none
        )
    }

    static func weightedSelectorScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let preferredNode = try node(
            id: identifier(seed: seed, slot: 8_100),
            capacity: vector(cpu: 4, memory: 4),
            labels: [
                "class": "cpu",
                "tier": "on-demand",
                "rack": "r1",
                "debug": "true"
            ]
        )
        let alternativeNode = try node(
            id: identifier(seed: seed, slot: 8_101),
            capacity: vector(cpu: 4, memory: 4),
            labels: [
                "class": "gpu",
                "tier": "spot",
                "rack-avoid": "r2",
                "ephemeral": "true"
            ]
        )
        let preferredAffinity = try [
            SchedulerWeightedLabelSelectorPreference(
                weight: 4,
                selector: try SchedulerLabelSelector(
                    key: "class",
                    operator: .in,
                    values: ["cpu"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 3,
                selector: try SchedulerLabelSelector(
                    key: "tier",
                    operator: .notIn,
                    values: ["spot"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 2,
                selector: try SchedulerLabelSelector(key: "rack", operator: .exists)
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 1,
                selector: try SchedulerLabelSelector(
                    key: "ephemeral",
                    operator: .doesNotExist
                )
            )
        ]
        let preferredAntiAffinity = try [
            SchedulerWeightedLabelSelectorPreference(
                weight: 4,
                selector: try SchedulerLabelSelector(
                    key: "class",
                    operator: .in,
                    values: ["gpu"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 3,
                selector: try SchedulerLabelSelector(
                    key: "tier",
                    operator: .notIn,
                    values: ["on-demand"]
                )
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 2,
                selector: try SchedulerLabelSelector(key: "rack-avoid", operator: .exists)
            ),
            SchedulerWeightedLabelSelectorPreference(
                weight: 1,
                selector: try SchedulerLabelSelector(
                    key: "debug",
                    operator: .doesNotExist
                )
            )
        ]
        let topology = try SchedulerTopologyPreference(
            preferredAffinity: preferredAffinity,
            preferredAntiAffinity: preferredAntiAffinity
        )
        let workload = try workload(
            id: identifier(seed: seed, slot: 8_102),
            cpu: 1,
            memory: 1,
            priority: 5,
            subject: "weighted-selector",
            project: "phase10-weighted-selector",
            topology: topology
        )
        let weights = try SchedulerScoreWeights(
            fragmentation: 0,
            fairness: 0,
            topology: 1,
            locality: 0,
            hostPressureEnergy: 0,
            disruption: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "weighted-selector",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [alternativeNode, preferredNode],
                scoringWeights: weights
            ),
            oracleMode: .none
        )
    }

    static func exactScenario(
        index: Int,
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        var random = Phase10SchedulerQualificationPRNG(seed: seed &+ UInt64(index))
        let caseSeed = seed &+ UInt64(index)
        let nodeCount = random.integer(2...3)
        let workloadCount = random.integer(1...4)
        let nodes = try (0..<nodeCount).map { offset in
            try node(
                id: identifier(seed: caseSeed, slot: 1_000 + offset),
                capacity: vector(
                    cpu: Int64(random.integer(2...5)),
                    memory: Int64(random.integer(3...8)),
                    disk: Int64(random.integer(4...10))
                )
            )
        }
        let workloads = try (0..<workloadCount).map { offset in
            try exactResourceWorkload(
                id: identifier(seed: caseSeed, slot: 2_000 + offset),
                cpu: Int64(random.integer(1...3)),
                memory: Int64(random.integer(1...5)),
                disk: Int64(random.integer(1...6))
            )
        }
        let weights = try SchedulerScoreWeights(
            fragmentation: 1,
            fairness: 0,
            topology: 0,
            locality: 0,
            hostPressureEnergy: 0,
            disruption: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-multi-resource-feasibility-\(index)",
            seed: caseSeed,
            input: try SchedulerEngineInput(
                pendingWorkloads: workloads.reversed(),
                nodes: nodes.reversed(),
                scoringWeights: weights
            ),
            oracleMode: .feasibility
        )
    }

    static func statefulFairnessTrace(
        seed: UInt64,
        starvationAges: [Int64]
    ) throws -> Phase10SchedulerQualification.StatefulTrace {
        let protectedNodeID = identifier(seed: seed, slot: 7_000)
        let protectedWorkloadID = identifier(seed: seed, slot: 7_001)
        let bypassWorkloadID = identifier(seed: seed, slot: 7_002)
        let node = try node(
            id: protectedNodeID,
            capacity: vector(cpu: 1, memory: 1, disk: 1)
        )
        let protectedWorkload = try exactResourceWorkload(
            id: protectedWorkloadID,
            cpu: 1,
            memory: 1,
            disk: 1,
            priority: 0,
            subject: "protected",
            project: "stateful-fairness"
        )
        let bypassWorkload = try exactResourceWorkload(
            id: bypassWorkloadID,
            cpu: 1,
            memory: 1,
            disk: 1,
            priority: 100,
            subject: "bypass",
            project: "stateful-fairness"
        )
        let epochs = try starvationAges.enumerated().map { epoch, age in
            let fairness = try [
                SchedulerFairnessState(
                    subjectID: "bypass",
                    projectID: "stateful-fairness",
                    usage: .zero,
                    guarantee: .zero,
                    quota: nil,
                    pendingDemand: vector(cpu: 1, memory: 1, disk: 1),
                    starvationAgeUnits: 0
                ),
                SchedulerFairnessState(
                    subjectID: "protected",
                    projectID: "stateful-fairness",
                    usage: .zero,
                    guarantee: .zero,
                    quota: nil,
                    pendingDemand: vector(cpu: 1, memory: 1, disk: 1),
                    starvationAgeUnits: age
                )
            ]
            return Phase10SchedulerQualification.Scenario(
                label: "stateful-starvation-epoch-\(epoch)",
                seed: seed &+ UInt64(epoch),
                input: try SchedulerEngineInput(
                    pendingWorkloads: [bypassWorkload, protectedWorkload],
                    nodes: [node],
                    fairnessStates: fairness,
                    queuePolicy: SchedulerQueuePolicy(
                        priorityPrecedesFairness: true,
                        starvationAgeThresholdUnits: 3
                    )
                ),
                oracleMode: .none
            )
        }
        return Phase10SchedulerQualification.StatefulTrace(
            label: "stateful-starvation",
            epochs: epochs,
            protectedWorkloadID: protectedWorkloadID,
            expectedNodeID: protectedNodeID,
            protectedWorkMustBeFirst: true,
            maxMoves: 0
        )
    }

    static func statefulAntiChurnTrace(
        seed: UInt64,
        residenceUnits: [Int64]
    ) throws -> Phase10SchedulerQualification.StatefulTrace {
        let currentNodeID = identifier(seed: seed, slot: 7_100)
        let betterNodeID = identifier(seed: seed, slot: 7_101)
        let workloadID = identifier(seed: seed, slot: 7_102)
        let allocation = try vector(cpu: 2, memory: 2, disk: 2)
        let workload = try exactResourceWorkload(
            id: workloadID,
            cpu: 2,
            memory: 2,
            disk: 2,
            priority: 1,
            subject: "stable",
            project: "stateful-churn"
        )
        let current = try node(
            id: currentNodeID,
            capacity: vector(cpu: 8, memory: 8, disk: 8),
            allocation: allocation,
            topology: ["zone": "east"]
        )
        let better = try node(
            id: betterNodeID,
            capacity: vector(cpu: 8, memory: 8, disk: 8),
            topology: ["zone": "west"]
        )
        let epochs = try residenceUnits.enumerated().map { epoch, residence in
            let existing = try SchedulerExistingPlacement(
                workloadID: workloadID,
                nodeID: currentNodeID,
                allocation: allocation,
                stability: SchedulerPlacementStabilitySnapshot(
                    residenceUnits: residence
                )
            )
            return Phase10SchedulerQualification.Scenario(
                label: "stateful-anti-churn-epoch-\(epoch)",
                seed: seed &+ UInt64(epoch),
                input: try SchedulerEngineInput(
                    pendingWorkloads: [workload],
                    nodes: [better, current],
                    existingPlacements: [existing],
                    antiChurnThresholdBasisPoints: 250,
                    stabilityPolicy: SchedulerStabilityPolicy(minimumResidenceUnits: 10)
                ),
                oracleMode: .none
            )
        }
        return Phase10SchedulerQualification.StatefulTrace(
            label: "stateful-anti-churn",
            epochs: epochs,
            protectedWorkloadID: workloadID,
            expectedNodeID: currentNodeID,
            protectedWorkMustBeFirst: false,
            maxMoves: 0
        )
    }

    static func performanceInput(seed: UInt64) throws -> SchedulerEngineInput {
        let nodes = try (0..<100).map { offset in
            try node(
                id: identifier(seed: seed, slot: 10_000 + offset),
                capacity: vector(cpu: 20, memory: 20),
                topology: ["zone": offset.isMultiple(of: 2) ? "east" : "west"]
            )
        }
        let workloads = try (0..<1_000).map { offset in
            try workload(
                id: identifier(seed: seed, slot: 20_000 + offset),
                cpu: 1,
                memory: 1,
                priority: 0,
                subject: "perf-\(offset % 10)",
                project: "qualification"
            )
        }
        return try SchedulerEngineInput(
            pendingWorkloads: workloads,
            nodes: nodes,
            snapshotQuality: SchedulerSnapshotQuality(
                confidenceBasisPoints: 10_000,
                stalenessUnits: 0,
                sourceGeneration: "phase10-performance"
            )
        )
    }

    private static func mixedScenario(
        index: Int,
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        var random = Phase10SchedulerQualificationPRNG(seed: seed)
        let nodeCount = random.integer(2...4)
        var nodes: [SchedulerNode] = []
        for offset in 0..<nodeCount {
            let cpu = Int64(random.integer(5...10))
            let memory = Int64(random.integer(10...24))
            let reservation = try vector(
                cpu: Int64(random.integer(0...1)),
                memory: Int64(random.integer(0...2))
            )
            let pressure: SchedulerPressurePosture = offset == 0 && random.boolean() ? .elevated : .nominal
            nodes.append(
                try node(
                    id: identifier(seed: seed, slot: 100 + offset),
                    capacity: vector(cpu: cpu, memory: memory),
                    reservation: reservation,
                    architecture: offset.isMultiple(of: 2) ? "arm64" : "x86_64",
                    topology: ["zone": offset.isMultiple(of: 2) ? "east" : "west"],
                    posture: SchedulerHostPosture(
                        pressure: pressure,
                        energy: offset.isMultiple(of: 2) ? .efficient : .balanced
                    ),
                    acceleratorAvailability: try vector(gpu: offset.isMultiple(of: 2) ? 1 : 0)
                )
            )
        }

        let workloadCount = random.integer(2...4)
        let workloadIDs = (0..<workloadCount).map {
            identifier(seed: seed, slot: 300 + $0)
        }
        var workloads: [SchedulerWorkload] = []
        for offset in 0..<workloadCount {
            let topology: SchedulerTopologyPreference
            if offset == 0 {
                topology = try SchedulerTopologyPreference(
                    groupID: "mixed-web",
                    spreadKey: "zone",
                    preferredDomainValues: ["east"]
                )
            } else if offset.isMultiple(of: 2) {
                topology = try SchedulerTopologyPreference(
                    groupID: "mixed-web",
                    spreadKey: "zone",
                    affinityWorkloadIDs: [workloadIDs[offset - 1]]
                )
            } else {
                topology = try SchedulerTopologyPreference(
                    groupID: "mixed-web",
                    spreadKey: "zone",
                    antiAffinityWorkloadIDs: [workloadIDs[offset - 1]]
                )
            }
            let localNode = nodes[offset % nodes.count].nodeID
            let requiredArchitecture = offset.isMultiple(of: 3)
                ? [nodes.first!.snapshot.architecture]
                : []
            let constraints = offset.isMultiple(of: 2)
                ? try SchedulerAdditionalPlacementConstraints(
                    requiredVolumes: ["volume-\(offset % 2)"],
                    requiredPorts: [8_080 + offset],
                    requiredNetworks: ["network-\(offset % 2)"]
                )
                : .none
            workloads.append(
                try workload(
                    id: workloadIDs[offset],
                    cpu: Int64(random.integer(1...3)),
                    memory: Int64(random.integer(1...5)),
                    priority: Int64(random.integer(0...5)),
                    subject: "tenant-\(offset % 2)",
                    project: "mixed",
                    requiredArchitectures: requiredArchitecture,
                    acceleratorGPU: offset.isMultiple(of: 3) ? 1 : 0,
                    topology: topology,
                    locality: try SchedulerLocalityPreference(preferredNodeIDs: [localNode]),
                    constraints: constraints,
                    overhead: try vector(cpu: offset.isMultiple(of: 2) ? 1 : 0),
                    safetyMargin: try vector(memory: offset.isMultiple(of: 3) ? 1 : 0)
                )
            )
        }
        let fairness = try [
            SchedulerFairnessState(
                subjectID: "tenant-0",
                projectID: "mixed",
                usage: vector(cpu: 1, memory: 1),
                guarantee: vector(cpu: 3, memory: 4),
                quota: vector(cpu: 12, memory: 24),
                pendingDemand: vector(cpu: 1),
                starvationAgeUnits: 5,
                weight: 1
            ),
            SchedulerFairnessState(
                subjectID: "tenant-1",
                projectID: "mixed",
                usage: vector(cpu: 2, memory: 1),
                guarantee: vector(cpu: 4, memory: 4),
                quota: vector(cpu: 12, memory: 24),
                pendingDemand: vector(cpu: 1),
                starvationAgeUnits: 0,
                weight: 2
            )
        ]
        return Phase10SchedulerQualification.Scenario(
            label: "mixed-\(index)",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: workloads.reversed(),
                nodes: nodes.reversed(),
                fairnessStates: fairness.reversed(),
                antiChurnThresholdBasisPoints: 250,
                queuePolicy: SchedulerQueuePolicy(
                    priorityPrecedesFairness: true,
                    starvationAgeThresholdUnits: 4
                ),
                snapshotQuality: SchedulerSnapshotQuality(
                    confidenceBasisPoints: 9_000,
                    stalenessUnits: 1,
                    sourceGeneration: "phase10-mixed"
                )
            ),
            oracleMode: .none
        )
    }

    private static func emptyFeasibilityScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 1)
        let workloadID = identifier(seed: seed, slot: 2)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 2, memory: 2),
            health: .unhealthy
        )
        let workload = try workload(
            id: workloadID,
            cpu: 1,
            memory: 1,
            priority: 1,
            subject: "empty",
            project: "boundary"
        )
        return Phase10SchedulerQualification.Scenario(
            label: "empty-feasibility",
            seed: seed,
            input: try SchedulerEngineInput(pendingWorkloads: [workload], nodes: [node]),
            oracleMode: .none
        )
    }

    private static func exactTieScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let lowerID = identifier(seed: seed, slot: 10)
        let higherID = identifier(seed: seed, slot: 11)
        let workloadID = identifier(seed: seed, slot: 12)
        let nodes = try [
            node(id: higherID, capacity: vector(cpu: 4, memory: 4, disk: 4)),
            node(id: lowerID, capacity: vector(cpu: 4, memory: 4, disk: 4))
        ]
        let workload = try exactResourceWorkload(
            id: workloadID,
            cpu: 1,
            memory: 1,
            disk: 1
        )
        let weights = try SchedulerScoreWeights(
            fragmentation: 1,
            fairness: 0,
            topology: 0,
            locality: 0,
            hostPressureEnergy: 0,
            disruption: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-tie",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: nodes,
                scoringWeights: weights
            ),
            oracleMode: .lockedTieBreak
        )
    }

    private static func quotaAndBorrowingScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let node = try node(
            id: identifier(seed: seed, slot: 20),
            capacity: vector(cpu: 10, memory: 10)
        )
        let workload = try workload(
            id: identifier(seed: seed, slot: 21),
            cpu: 1,
            memory: 1,
            priority: 1,
            subject: "borrower",
            project: "fairness"
        )
        let borrower = try SchedulerFairnessState(
            subjectID: "borrower",
            projectID: "fairness",
            usage: vector(cpu: 2, memory: 2),
            guarantee: vector(cpu: 2, memory: 2),
            quota: vector(cpu: 8, memory: 8),
            pendingDemand: vector(cpu: 1, memory: 1),
            starvationAgeUnits: 4
        )
        let owner = try SchedulerFairnessState(
            subjectID: "owner",
            projectID: "fairness",
            usage: vector(cpu: 1, memory: 1),
            guarantee: vector(cpu: 8, memory: 8),
            quota: vector(cpu: 8, memory: 8),
            pendingDemand: .zero
        )
        return Phase10SchedulerQualification.Scenario(
            label: "quota-guarantee-borrowing",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node],
                fairnessStates: [owner, borrower],
                queuePolicy: SchedulerQueuePolicy(
                    priorityPrecedesFairness: true,
                    starvationAgeThresholdUnits: 3
                )
            ),
            oracleMode: .none
        )
    }

    private static func topologyConflictScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let east = try node(
            id: identifier(seed: seed, slot: 30),
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "east"]
        )
        let west = try node(
            id: identifier(seed: seed, slot: 31),
            capacity: vector(cpu: 4, memory: 4),
            topology: ["zone": "west"]
        )
        let firstID = identifier(seed: seed, slot: 32)
        let secondID = identifier(seed: seed, slot: 33)
        let first = try workload(
            id: firstID,
            cpu: 1,
            memory: 1,
            priority: 10,
            subject: "topology",
            project: "boundary",
            topology: try SchedulerTopologyPreference(groupID: "web", spreadKey: "zone")
        )
        let second = try workload(
            id: secondID,
            cpu: 1,
            memory: 1,
            priority: 1,
            subject: "topology",
            project: "boundary",
            topology: try SchedulerTopologyPreference(
                groupID: "web",
                spreadKey: "zone",
                antiAffinityWorkloadIDs: [firstID]
            )
        )
        return Phase10SchedulerQualification.Scenario(
            label: "topology-conflict",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [second, first],
                nodes: [west, east]
            ),
            oracleMode: .none
        )
    }

    private static func antiChurnScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let currentNodeID = identifier(seed: seed, slot: 40)
        let betterNodeID = identifier(seed: seed, slot: 41)
        let workloadID = identifier(seed: seed, slot: 42)
        let allocation = try vector(cpu: 2, memory: 2)
        let current = try node(
            id: currentNodeID,
            capacity: vector(cpu: 8, memory: 8),
            allocation: allocation,
            topology: ["zone": "east"]
        )
        let better = try node(
            id: betterNodeID,
            capacity: vector(cpu: 8, memory: 8),
            topology: ["zone": "west"]
        )
        let workload = try workload(
            id: workloadID,
            cpu: 2,
            memory: 2,
            priority: 1,
            subject: "stable",
            project: "boundary",
            locality: try SchedulerLocalityPreference(preferredNodeIDs: [betterNodeID])
        )
        let existing = try SchedulerExistingPlacement(
            workloadID: workloadID,
            nodeID: currentNodeID,
            allocation: allocation,
            stability: SchedulerPlacementStabilitySnapshot(residenceUnits: 0)
        )
        return Phase10SchedulerQualification.Scenario(
            label: "anti-churn",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [better, current],
                existingPlacements: [existing],
                antiChurnThresholdBasisPoints: 250,
                stabilityPolicy: SchedulerStabilityPolicy(minimumResidenceUnits: 10)
            ),
            oracleMode: .none
        )
    }

    private static func preemptionScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 50)
        let workloadID = identifier(seed: seed, slot: 51)
        let victimID = identifier(seed: seed, slot: 52)
        let victimAllocation = try vector(cpu: 2, memory: 2, disk: 2)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 5, memory: 5, disk: 5),
            allocation: victimAllocation,
            reservation: vector(cpu: 1, memory: 1, disk: 1)
        )
        let workload = try workload(
            id: workloadID,
            cpu: 4,
            memory: 4,
            disk: 4,
            priority: 10,
            subject: "incoming",
            project: "preemption",
            preemptionEligibility: .eligible
        )
        let victim = try SchedulerVictimAllocation(
            workloadID: victimID,
            nodeID: nodeID,
            allocation: victimAllocation,
            subjectID: "incoming",
            projectID: "preemption",
            priority: 0,
            disruptionCostBasisPoints: 2,
            budgetID: "budget-a"
        )
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget-a",
            projectID: "preemption",
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 2
        )
        return Phase10SchedulerQualification.Scenario(
            label: "preemption",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node],
                victimAllocations: [victim],
                disruptionBudgets: [budget],
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-qualification"
                )
            ),
            oracleMode: .none
        )
    }

    private static func disruptionExhaustionScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let scenario = try preemptionScenario(seed: seed)
        let exhaustedBudget = try SchedulerDisruptionBudget(
            budgetID: "budget-a",
            projectID: "preemption",
            remainingVictimCount: 0,
            remainingDisruptionCostBasisPoints: 0
        )
        return Phase10SchedulerQualification.Scenario(
            label: "disruption-exhaustion",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: scenario.input.pendingWorkloads,
                nodes: scenario.input.nodes,
                victimAllocations: scenario.input.victimAllocations,
                disruptionBudgets: [exhaustedBudget],
                preemptionPolicy: scenario.input.preemptionPolicy
            ),
            oracleMode: .none
        )
    }

    private static func preemptionOverlapScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 70)
        let victimID = identifier(seed: seed, slot: 71)
        let firstWorkloadID = identifier(seed: seed, slot: 72)
        let secondWorkloadID = identifier(seed: seed, slot: 73)
        let victimAllocation = try vector(cpu: 2, memory: 2)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 3, memory: 3),
            allocation: victimAllocation
        )
        let firstWorkload = try workload(
            id: firstWorkloadID,
            cpu: 2,
            memory: 2,
            priority: 10,
            subject: "incoming",
            project: "preemption-overlap",
            preemptionEligibility: .eligible
        )
        let secondWorkload = try workload(
            id: secondWorkloadID,
            cpu: 2,
            memory: 2,
            priority: 9,
            subject: "incoming",
            project: "preemption-overlap",
            preemptionEligibility: .eligible
        )
        let victim = try SchedulerVictimAllocation(
            workloadID: victimID,
            nodeID: nodeID,
            allocation: victimAllocation,
            subjectID: "victim",
            projectID: "preemption-overlap",
            priority: 0,
            disruptionCostBasisPoints: 1,
            budgetID: "budget-overlap"
        )
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget-overlap",
            projectID: "preemption-overlap",
            remainingVictimCount: 1,
            remainingDisruptionCostBasisPoints: 1
        )
        return Phase10SchedulerQualification.Scenario(
            label: "preemption-overlap",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [secondWorkload, firstWorkload],
                nodes: [node],
                victimAllocations: [victim],
                disruptionBudgets: [budget],
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-overlap"
                )
            ),
            oracleMode: .none
        )
    }

    static func exactPreemptionHardTopologyScenario(
        seed: UInt64,
        maxSkew: Int = 1,
        remainingVictimCount: Int = 1,
        remainingDisruptionCostBasisPoints: Int64 = 3
    ) throws -> Phase10SchedulerQualification.Scenario {
        let eastNodeID = identifier(seed: seed, slot: 8_200)
        let westNodeID = identifier(seed: seed, slot: 8_201)
        let workloadID = identifier(seed: seed, slot: 8_202)
        let targetVictimID = identifier(seed: seed, slot: 8_203)
        let anchorVictimIDs = (0..<3).map {
            identifier(seed: seed, slot: 8_204 + $0)
        }
        let topologyGroupID = "phase10-exact-preemption"
        let hardAffinity = try NodeAffinity(
            topologySpreads: [
                try SchedulerHardTopologySpread(
                    topologyKey: "zone",
                    maxSkew: maxSkew,
                    whenUnsatisfiable: .doNotSchedule,
                    groupID: topologyGroupID
                )
            ]
        )
        let workload = try workload(
            id: workloadID,
            cpu: 3,
            memory: 0,
            priority: 10,
            subject: "incoming",
            project: "exact-preemption",
            affinity: hardAffinity,
            preemptionEligibility: .eligible
        )
        let eastNode = try node(
            id: eastNodeID,
            capacity: vector(cpu: 4),
            allocation: vector(cpu: 3),
            topology: ["zone": "east"]
        )
        let westNode = try node(
            id: westNodeID,
            capacity: vector(cpu: 4),
            allocation: vector(cpu: 4),
            topology: ["zone": "west"]
        )
        let targetVictim = try SchedulerVictimAllocation(
            workloadID: targetVictimID,
            nodeID: eastNodeID,
            allocation: vector(cpu: 3),
            subjectID: "victim",
            projectID: "exact-preemption",
            priority: 0,
            disruptionCostBasisPoints: 3,
            budgetID: "budget-exact",
            topologyGroupID: topologyGroupID
        )
        let anchorVictims = try anchorVictimIDs.map { victimID in
            try SchedulerVictimAllocation(
                workloadID: victimID,
                nodeID: westNodeID,
                allocation: .zero,
                subjectID: "anchor",
                projectID: "exact-preemption",
                priority: 0,
                disruptionCostBasisPoints: 0,
                preemptible: false,
                topologyGroupID: topologyGroupID
            )
        }
        let budget = try SchedulerDisruptionBudget(
            budgetID: "budget-exact",
            projectID: "exact-preemption",
            remainingVictimCount: remainingVictimCount,
            remainingDisruptionCostBasisPoints: remainingDisruptionCostBasisPoints
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-preemption-hard-topology",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [westNode, eastNode],
                victimAllocations: [targetVictim] + anchorVictims,
                disruptionBudgets: [budget],
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-exact-preemption"
                )
            ),
            oracleMode: .none
        )
    }

    private static func exactSearchBoundScenario(
        seed: UInt64
    ) throws -> Phase10SchedulerQualification.Scenario {
        let nodeID = identifier(seed: seed, slot: 60)
        let workloadID = identifier(seed: seed, slot: 61)
        let victimOneID = identifier(seed: seed, slot: 62)
        let victimTwoID = identifier(seed: seed, slot: 63)
        let unit = try vector(cpu: 1, memory: 1)
        let node = try node(
            id: nodeID,
            capacity: vector(cpu: 3, memory: 3),
            allocation: try vector(cpu: 2, memory: 2)
        )
        let workload = try workload(
            id: workloadID,
            cpu: 3,
            memory: 3,
            priority: 10,
            subject: "incoming",
            project: "search-bound",
            preemptionEligibility: .eligible
        )
        let victims = try [
            SchedulerVictimAllocation(
                workloadID: victimOneID,
                nodeID: nodeID,
                allocation: unit,
                subjectID: "incoming",
                projectID: "search-bound",
                priority: 0,
                disruptionCostBasisPoints: 1
            ),
            SchedulerVictimAllocation(
                workloadID: victimTwoID,
                nodeID: nodeID,
                allocation: unit,
                subjectID: "incoming",
                projectID: "search-bound",
                priority: 0,
                disruptionCostBasisPoints: 1
            )
        ]
        let limits = try SchedulerEngineLimits(
            maxExactPreemptionVictimsPerNode: 2,
            maxExactPreemptionSearchStates: 1
        )
        return Phase10SchedulerQualification.Scenario(
            label: "exact-search-bound-exhaustion",
            seed: seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: [workload],
                nodes: [node],
                victimAllocations: victims,
                preemptionPolicy: SchedulerPreemptionPolicy(
                    incomingNonPreempting: false,
                    preemptionAuthorized: true,
                    minimumPriorityGap: 1,
                    authorizationReference: "phase10-search-bound"
                ),
                limits: limits
            ),
            oracleMode: .none
        )
    }

    private static func identifier(seed: UInt64, slot: Int) -> UUID {
        let value = ((seed & 0x0000_FFFF_FFFF) << 16) | UInt64(slot & 0xFFFF)
        let suffix = String(value, radix: 16)
        let padded = String(repeating: "0", count: max(0, 12 - suffix.count)) + suffix
        return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
    }

    private static func vector(
        cpu: Int64 = 0,
        memory: Int64 = 0,
        disk: Int64 = 0,
        gpu: Int64 = 0
    ) throws -> ResourceVector {
        var values: [String: Int64] = [:]
        if cpu > 0 { values["cpu"] = cpu }
        if memory > 0 { values["memory"] = memory }
        if disk > 0 { values["disk"] = disk }
        if gpu > 0 { values["gpu"] = gpu }
        return try ResourceVector(values)
    }

    private static func node(
        id: UUID,
        capacity: ResourceVector,
        allocation: ResourceVector = .zero,
        reservation: ResourceVector = .zero,
        architecture: String = "arm64",
        topology: [String: String] = [:],
        labels: [String: String]? = nil,
        posture: SchedulerHostPosture = SchedulerHostPosture(),
        health: SchedulerNodeHealth = .healthy,
        acceleratorAvailability: ResourceVector = .zero
    ) throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: NodePlacementSnapshot(
                nodeID: id,
                capacity: capacity,
                allocation: allocation,
                architecture: architecture,
                runtime: "linux-vm",
                provider: "provider",
                capabilities: ["network", "storage"],
                health: health,
                labels: labels ?? ["pool": "general", "zone": topology["zone"] ?? "none"],
                acceleratorAvailability: acceleratorAvailability
            ),
            topologyDomains: topology,
            posture: posture,
            reservation: reservation,
            availableVolumeIDs: ["volume-0", "volume-1"],
            availablePorts: [8_080, 8_081, 8_082, 8_083],
            availableNetworkIDs: ["network-0", "network-1"]
        )
    }

    private static func workload(
        id: UUID,
        cpu: Int64,
        memory: Int64,
        disk: Int64 = 0,
        priority: Int64,
        subject: String,
        project: String,
        requiredArchitectures: [String] = [],
        acceleratorGPU: Int64 = 0,
        affinity: NodeAffinity = .none,
        topology: SchedulerTopologyPreference = .none,
        locality: SchedulerLocalityPreference = .none,
        constraints: SchedulerAdditionalPlacementConstraints = .none,
        overhead: ResourceVector = .zero,
        safetyMargin: ResourceVector = .zero,
        preemptionEligibility: SchedulerWorkloadPreemptionEligibility = .nonPreempting
    ) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(
                workloadID: id,
                request: vector(cpu: cpu, memory: memory, disk: disk),
                requiredArchitectures: requiredArchitectures,
                requiredRuntime: "linux-vm",
                requiredProvider: "provider",
                requiredCapabilities: ["network"],
                affinity: affinity,
                acceleratorRequirements: vector(gpu: acceleratorGPU)
            ),
            priority: priority,
            subjectID: subject,
            projectID: project,
            topology: topology,
            locality: locality,
            constraints: constraints,
            overhead: overhead,
            safetyMargin: safetyMargin,
            preemptionEligibility: preemptionEligibility
        )
    }

    private static func exactResourceWorkload(
        id: UUID,
        cpu: Int64,
        memory: Int64,
        disk: Int64,
        priority: Int64 = 0,
        subject: String = "exact",
        project: String = "oracle"
    ) throws -> SchedulerWorkload {
        try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(
                workloadID: id,
                request: vector(cpu: cpu, memory: memory, disk: disk)
            ),
            priority: priority,
            subjectID: subject,
            projectID: project
        )
    }
}

enum Phase10SchedulerQualificationVerifier {
    static func evaluate(
        _ scenario: Phase10SchedulerQualification.Scenario
    ) -> Phase10SchedulerQualification.Evaluation {
        let decision: SchedulerDecision
        do {
            decision = try SchedulerEngine().plan(scenario.input)
        } catch {
            return Phase10SchedulerQualification.Evaluation(
                decision: nil,
                inputDigest: scenario.input.inputDigest,
                issues: [
                    Phase10SchedulerQualification.Issue(
                        kind: .engineError,
                        severity: .failure,
                        message: "SchedulerEngine.plan threw for \(scenario.label): \(String(describing: error))"
                    )
                ],
                oracle: nil
            )
        }

        var issues: [Phase10SchedulerQualification.Issue] = []
        do {
            issues.append(contentsOf: try canonicalCodableReplay(
                input: scenario.input,
                decision: decision
            ))
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON replay threw for \(scenario.label): \(String(describing: error))"
                )
            )
        }
        do {
            issues.append(contentsOf: try Phase10SchedulerQualificationInvariantChecker.check(
                input: scenario.input,
                decision: decision
            ))
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .harnessError,
                    severity: .failure,
                    message: "Invariant checker threw for \(scenario.label): \(String(describing: error))"
                )
            )
        }

        do {
            let replay = try SchedulerEngine().plan(scenario.input)
            if replay != decision {
                issues.append(
                    Phase10SchedulerQualification.Issue(
                        kind: .determinism,
                        severity: .failure,
                        message: "Replay changed the decision for \(scenario.label)."
                    )
                )
            }
            let reordered = try reorderedInput(from: scenario.input)
            let reorderedDecision = try SchedulerEngine().plan(reordered)
            if reorderedDecision != decision {
                issues.append(
                    Phase10SchedulerQualification.Issue(
                        kind: .determinism,
                        severity: .failure,
                        message: "Collection reordering changed the decision for \(scenario.label)."
                    )
                )
            }
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Replay or reordered plan threw for \(scenario.label): \(String(describing: error))"
                )
            )
        }

        guard scenario.oracleMode != .none else {
            return Phase10SchedulerQualification.Evaluation(
                decision: decision,
                inputDigest: scenario.input.inputDigest,
                issues: issues,
                oracle: nil
            )
        }
        do {
            let comparison = try Phase10SchedulerQualificationExactOracle.compare(
                input: scenario.input,
                decision: decision,
                mode: scenario.oracleMode
            )
            issues.append(contentsOf: comparison.issues)
            return Phase10SchedulerQualification.Evaluation(
                decision: decision,
                inputDigest: scenario.input.inputDigest,
                issues: issues,
                oracle: comparison.result
            )
        } catch {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .harnessError,
                    severity: .failure,
                    message: "Exact oracle threw for \(scenario.label): \(String(describing: error))"
                )
            )
            return Phase10SchedulerQualification.Evaluation(
                decision: decision,
                inputDigest: scenario.input.inputDigest,
                issues: issues,
                oracle: nil
            )
        }
    }

    private static func canonicalCodableReplay(
        input: SchedulerEngineInput,
        decision: SchedulerDecision
    ) throws -> [Phase10SchedulerQualification.Issue] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        var issues: [Phase10SchedulerQualification.Issue] = []

        let encodedInput = try encoder.encode(input)
        let decodedInput = try decoder.decode(SchedulerEngineInput.self, from: encodedInput)
        if decodedInput != input {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON input decode changed SchedulerEngineInput."
                )
            )
        }
        if try encoder.encode(decodedInput) != encodedInput {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON input re-encode was not stable."
                )
            )
        }

        let encodedDecision = try encoder.encode(decision)
        let decodedDecision = try decoder.decode(SchedulerDecision.self, from: encodedDecision)
        if decodedDecision != decision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON decision decode changed SchedulerDecision."
                )
            )
        }
        if try encoder.encode(decodedDecision) != encodedDecision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Canonical JSON decision re-encode was not stable."
                )
            )
        }

        let canonicalDecision = try SchedulerEngine().plan(decodedInput)
        if canonicalDecision != decision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Planning the canonical JSON-decoded input changed the decision."
                )
            )
        }
        let simulatedDecision = try SchedulerEngine().simulate(decodedInput)
        if simulatedDecision != decision {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .determinism,
                    severity: .failure,
                    message: "Simulating the canonical JSON-decoded input changed the planned SchedulerDecision."
                )
            )
        }
        return issues
    }

    private static func reorderedInput(
        from input: SchedulerEngineInput
    ) throws -> SchedulerEngineInput {
        let ratios = input.overcommitRatios.keys.sorted(by: >).reduce(into: [String: SchedulerResourceRatio]()) {
            result, key in
            result[key] = input.overcommitRatios[key]
        }
        return try SchedulerEngineInput(
            pendingWorkloads: input.pendingWorkloads.reversed(),
            nodes: input.nodes.reversed(),
            fairnessStates: input.fairnessStates.reversed(),
            existingPlacements: input.existingPlacements.reversed(),
            victimAllocations: input.victimAllocations.reversed(),
            disruptionBudgets: input.disruptionBudgets.reversed(),
            antiChurnThresholdBasisPoints: input.antiChurnThresholdBasisPoints,
            scoringWeights: input.scoringWeights,
            overcommitRatios: ratios,
            preemptionPolicy: input.preemptionPolicy,
            queuePolicy: input.queuePolicy,
            stabilityPolicy: input.stabilityPolicy,
            snapshotQuality: input.snapshotQuality,
            limits: input.limits
        )
    }
}

private enum Phase10SchedulerQualificationInvariantChecker {
    private struct FairnessLedger {
        var usage: ResourceVector
        let quota: ResourceVector?
    }

    static func check(
        input: SchedulerEngineInput,
        decision: SchedulerDecision
    ) throws -> [Phase10SchedulerQualification.Issue] {
        var issues: [Phase10SchedulerQualification.Issue] = []
        let expectedWorkloadIDs = input.pendingWorkloads.map(\.workloadID)
        let actualWorkloadIDs = decision.workloadDecisions.map(\.workloadID)
        if Set(actualWorkloadIDs) != Set(expectedWorkloadIDs)
            || actualWorkloadIDs.count != expectedWorkloadIDs.count
            || decision.orderedWorkloadIDs != actualWorkloadIDs {
            issues.append(issue(
                .decisionIdentity,
                "Decision workload identities do not exactly match the input workload set."
            ))
        }

        let workloads = Dictionary(uniqueKeysWithValues: input.pendingWorkloads.map {
            ($0.workloadID, $0)
        })
        let nodes = Dictionary(uniqueKeysWithValues: input.nodes.map { ($0.nodeID, $0) })
        let existing = Dictionary(uniqueKeysWithValues: input.existingPlacements.map {
            ($0.workloadID, $0)
        })
        var allocations = Dictionary(uniqueKeysWithValues: input.nodes.map {
            ($0.nodeID, $0.allocation)
        })
        var fairness = Dictionary(uniqueKeysWithValues: input.fairnessStates.map { state in
            (fairnessKey(state.subjectID, state.projectID), FairnessLedger(
                usage: state.usage,
                quota: state.quota
            ))
        })
        let victims = Dictionary(uniqueKeysWithValues: input.victimAllocations.map {
            ($0.workloadID, $0)
        })
        let budgets = Dictionary(uniqueKeysWithValues: input.disruptionBudgets.map {
            ($0.budgetID, $0)
        })
        var topologyObservations: [UUID: HardTopologySpreadObservation] = [:]
        for placement in input.existingPlacements {
            topologyObservations[placement.workloadID] = try HardTopologySpreadObservation(
                workloadID: placement.workloadID,
                nodeID: placement.nodeID,
                groupID: placement.topologyGroupID
            )
        }
        for victim in input.victimAllocations where topologyObservations[victim.workloadID] == nil {
            topologyObservations[victim.workloadID] = try HardTopologySpreadObservation(
                workloadID: victim.workloadID,
                nodeID: victim.nodeID,
                groupID: victim.topologyGroupID
            )
        }
        var plannedVictimIDs = Set<UUID>()
        var plannedBudgetCounts: [String: Int] = [:]
        var plannedBudgetCosts: [String: Int64] = [:]

        for workloadDecision in decision.workloadDecisions {
            guard let workload = workloads[workloadDecision.workloadID] else {
                issues.append(issue(
                    .decisionIdentity,
                    "Decision references unknown workload \(workloadDecision.workloadID.uuidString)."
                ))
                continue
            }

            if let placement = existing[workload.workloadID],
               let allocation = allocations[placement.nodeID] {
                if placement.allocation.fits(in: allocation) {
                    allocations[placement.nodeID] = try allocation.subtracting(placement.allocation)
                } else {
                    issues.append(issue(
                        .capacity,
                        "Existing placement \(workload.workloadID.uuidString) cannot be removed from its recorded node allocation."
                    ))
                }
                let key = fairnessKey(workload.subjectID, workload.projectID)
                if var record = fairness[key], placement.allocation.fits(in: record.usage) {
                    record.usage = try record.usage.subtracting(placement.allocation)
                    fairness[key] = record
                }
            }

            guard workloadDecision.outcome == .placed
                || workloadDecision.outcome == .retainedExistingPlacement else {
                if workloadDecision.outcome == .preemptionProposed {
                    issues.append(contentsOf: try preemptionIssues(
                        workload: workload,
                        decision: workloadDecision,
                        input: input,
                        victims: victims,
                        budgets: budgets,
                        plannedVictimIDs: &plannedVictimIDs,
                        plannedBudgetCounts: &plannedBudgetCounts,
                        plannedBudgetCosts: &plannedBudgetCosts
                    ))
                }
                continue
            }
            guard let nodeID = workloadDecision.chosenNodeID,
                  let node = nodes[nodeID],
                  let charge = workloadDecision.capacityExplanation?.chargedCapacity else {
                issues.append(issue(
                    .hardPolicy,
                    "Placed workload \(workload.workloadID.uuidString) is missing a node or charged-capacity explanation."
                ))
                continue
            }
            guard let allocation = allocations[nodeID] else {
                issues.append(issue(
                    .decisionIdentity,
                    "Placed workload \(workload.workloadID.uuidString) selected an unknown node \(nodeID.uuidString)."
                ))
                continue
            }

            let postAllocation: ResourceVector
            do {
                postAllocation = try allocation.adding(charge)
            } catch {
                issues.append(issue(
                    .capacity,
                    "Capacity arithmetic failed for \(workload.workloadID.uuidString): \(String(describing: error))."
                ))
                continue
            }
            if !postAllocation.fits(in: node.capacity) {
                issues.append(issue(
                    .capacity,
                    "Placement of \(workload.workloadID.uuidString) exceeds node \(nodeID.uuidString) schedulable capacity."
                ))
                continue
            }
            let topologyContext = try HardTopologySpreadContext(
                nodeTopologyDomains: input.nodes.reduce(into: [UUID: [String: String]]()) {
                    result, inputNode in
                    result[inputNode.nodeID] = inputNode.topologyDomains
                },
                observations: topologyObservations.values
                    .filter { $0.workloadID != workload.workloadID }
                    .sorted {
                        SchedulerOrdering.uuidPrecedes($0.workloadID, $1.workloadID)
                    }
            )
            issues.append(contentsOf: try hardPolicyIssues(
                workload: workload,
                charge: charge,
                node: node,
                allocation: allocation,
                topologyContext: topologyContext
            ))
            allocations[nodeID] = postAllocation
            topologyObservations[workload.workloadID] = try HardTopologySpreadObservation(
                workloadID: workload.workloadID,
                nodeID: nodeID,
                groupID: workload.topology.groupID
            )

            let key = fairnessKey(workload.subjectID, workload.projectID)
            if var record = fairness[key] {
                record.usage = try record.usage.adding(charge)
                if let quota = record.quota, !record.usage.fits(in: quota) {
                    issues.append(issue(
                        .quota,
                        "Placement of \(workload.workloadID.uuidString) exceeds its subject/project quota."
                    ))
                }
                fairness[key] = record
            }
        }
        issues.append(contentsOf: starvationIssues(input: input, decision: decision, workloads: workloads))
        issues.append(contentsOf: churnIssues(input: input, decision: decision, existing: existing))
        return issues
    }

    private static func preemptionIssues(
        workload: SchedulerWorkload,
        decision: SchedulerWorkloadDecision,
        input: SchedulerEngineInput,
        victims: [UUID: SchedulerVictimAllocation],
        budgets: [String: SchedulerDisruptionBudget],
        plannedVictimIDs: inout Set<UUID>,
        plannedBudgetCounts: inout [String: Int],
        plannedBudgetCosts: inout [String: Int64]
    ) throws -> [Phase10SchedulerQualification.Issue] {
        guard let proposal = decision.preemption else {
            return [issue(
                .preemption,
                "Preemption outcome for \(workload.workloadID.uuidString) is missing its proposal."
            )]
        }
        var issues: [Phase10SchedulerQualification.Issue] = []
        if !proposal.requiresFence || proposal.intentDigest != input.inputDigest {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) is not correctly fenced to this input digest."
            ))
        }
        if proposal.targetWorkloadID != workload.workloadID
            || proposal.policy != input.preemptionPolicy
            || input.preemptionPolicy.incomingNonPreempting
            || !input.preemptionPolicy.preemptionAuthorized {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) violates the input preemption policy."
            ))
        }
        guard let proposalNode = input.nodes.first(where: { $0.nodeID == proposal.nodeID }) else {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) targets an unknown node."
            ))
            return issues
        }
        guard let chargedCapacity = decision.capacityExplanation?.chargedCapacity else {
            issues.append(issue(
                .preemption,
                "Preemption proposal for \(workload.workloadID.uuidString) is missing incoming charged capacity."
            ))
            return issues
        }
        let sortedVictimIDs = proposal.victims.map(\.workloadID).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        if proposal.victimWorkloadIDs != sortedVictimIDs {
            issues.append(issue(
                .preemption,
                "Preemption proposal victim IDs do not match its canonical victim list."
            ))
        }
        if proposal.victims.isEmpty {
            issues.append(issue(
                .preemption,
                "Preemption proposal contains no victims and cannot reclaim capacity."
            ))
        }

        var reclaimed = ResourceVector.zero
        var localVictimIDs = Set<UUID>()
        var calculatedCost: Int64 = 0
        for proposedVictim in proposal.victims {
            guard let inputVictim = victims[proposedVictim.workloadID], inputVictim == proposedVictim else {
                issues.append(issue(
                    .preemption,
                    "Preemption proposal references a victim not present in the input snapshot."
                ))
                continue
            }
            if !localVictimIDs.insert(inputVictim.workloadID).inserted {
                issues.append(issue(
                    .preemption,
                    "Victim \(inputVictim.workloadID.uuidString) was duplicated in the proposal."
                ))
            }
            if inputVictim.subjectID.isEmpty || inputVictim.projectID.isEmpty {
                issues.append(issue(
                    .preemption,
                    "Preemption victim \(inputVictim.workloadID.uuidString) is missing subject/project identity."
                ))
            }
            if inputVictim.nodeID != proposal.nodeID
                || inputVictim.workloadID == workload.workloadID
                || inputVictim.allocation.isEmpty
                || !inputVictim.preemptible
                || inputVictim.priority >= workload.priority
                || workload.priority - inputVictim.priority < input.preemptionPolicy.minimumPriorityGap
                || (input.preemptionPolicy.protectedVictimStarvationAgeUnits > 0
                    && inputVictim.starvationAgeUnits
                        >= input.preemptionPolicy.protectedVictimStarvationAgeUnits) {
                issues.append(issue(
                    .preemption,
                    "Preemption proposal includes an ineligible victim \(inputVictim.workloadID.uuidString)."
                ))
            }
            if inputVictim.nodeID == proposal.nodeID,
               inputVictim.workloadID != workload.workloadID,
               !inputVictim.allocation.isEmpty {
                do {
                    reclaimed = try reclaimed.adding(inputVictim.allocation)
                } catch {
                    issues.append(issue(
                        .preemption,
                        "Preemption victim reclamation arithmetic failed: \(String(describing: error))."
                    ))
                }
            }
            if !plannedVictimIDs.insert(inputVictim.workloadID).inserted {
                issues.append(issue(
                    .preemption,
                    "Victim \(inputVictim.workloadID.uuidString) was proposed more than once in one scheduling decision."
                ))
            }
            let (nextCost, overflow) = calculatedCost.addingReportingOverflow(
                inputVictim.disruptionCostBasisPoints
            )
            if overflow {
                issues.append(issue(.preemption, "Preemption disruption cost overflowed."))
            } else {
                calculatedCost = nextCost
            }
            if let budgetID = inputVictim.budgetID {
                guard let budget = budgets[budgetID] else {
                    issues.append(issue(.preemption, "Preemption proposal references an unknown budget \(budgetID)."))
                    continue
                }
                if budget.projectID != inputVictim.projectID {
                    issues.append(issue(
                        .preemption,
                        "Preemption proposal uses budget \(budgetID) outside victim project \(inputVictim.projectID)."
                    ))
                }
                plannedBudgetCounts[budgetID, default: 0] += 1
                plannedBudgetCosts[budgetID, default: 0] += inputVictim.disruptionCostBasisPoints
                if plannedBudgetCounts[budgetID, default: 0] > budget.remainingVictimCount
                    || plannedBudgetCosts[budgetID, default: 0]
                        > budget.remainingDisruptionCostBasisPoints {
                    issues.append(issue(
                        .preemption,
                        "Preemption proposal exceeds disruption budget \(budgetID)."
                    ))
                }
            }
        }
        do {
            guard reclaimed.fits(in: proposalNode.allocation) else {
                issues.append(issue(
                    .preemption,
                    "Preemption victims reclaim more resource than the proposal node currently allocates."
                ))
                return issues
            }
            let postVictimAllocation = try proposalNode.allocation.subtracting(reclaimed)
            let postVictimRemaining = try proposalNode.schedulableCapacity.subtracting(
                postVictimAllocation
            )
            if !chargedCapacity.fits(in: postVictimRemaining) {
                issues.append(issue(
                    .preemption,
                    "Preemption victims do not reclaim enough reservation-adjusted capacity for the incoming charged request."
                ))
            }
        } catch {
            issues.append(issue(
                .preemption,
                "Preemption capacity proof failed for node \(proposal.nodeID.uuidString): \(String(describing: error))."
            ))
        }
        if calculatedCost != proposal.disruptionCostBasisPoints {
            issues.append(issue(
                .preemption,
                "Preemption proposal cost does not equal the sum of selected victim costs."
            ))
        }
        return issues
    }

    private static func starvationIssues(
        input: SchedulerEngineInput,
        decision: SchedulerDecision,
        workloads: [UUID: SchedulerWorkload]
    ) -> [Phase10SchedulerQualification.Issue] {
        let threshold = input.queuePolicy.starvationAgeThresholdUnits
        guard threshold > 0 else {
            return []
        }
        let ages = Dictionary(uniqueKeysWithValues: input.fairnessStates.map {
            (fairnessKey($0.subjectID, $0.projectID), $0.starvationAgeUnits)
        })
        let protectedIndexes = decision.workloadDecisions.enumerated().compactMap { index, item -> Int? in
            guard let workload = workloads[item.workloadID] else {
                return nil
            }
            return (ages[fairnessKey(workload.subjectID, workload.projectID)] ?? 0) >= threshold
                ? index
                : nil
        }
        guard let lastProtected = protectedIndexes.max() else {
            return []
        }
        let firstUnprotected = decision.workloadDecisions.enumerated().first { index, item in
            guard let workload = workloads[item.workloadID] else {
                return false
            }
            return (ages[fairnessKey(workload.subjectID, workload.projectID)] ?? 0) < threshold
        }?.offset
        if let firstUnprotected, firstUnprotected < lastProtected {
            return [issue(
                .starvationBound,
                "A starvation-protected workload was ordered after an unprotected workload."
            )]
        }
        return []
    }

    private static func churnIssues(
        input: SchedulerEngineInput,
        decision: SchedulerDecision,
        existing: [UUID: SchedulerExistingPlacement]
    ) -> [Phase10SchedulerQualification.Issue] {
        var issues: [Phase10SchedulerQualification.Issue] = []
        let nodes = Dictionary(uniqueKeysWithValues: input.nodes.map { ($0.nodeID, $0) })
        for item in decision.workloadDecisions {
            guard let placement = existing[item.workloadID],
                  let selectedNodeID = item.chosenNodeID,
                  let currentAlternative = item.feasibleAlternatives.first(where: {
                      $0.nodeID == placement.nodeID
                  }),
                  let selectedScore = item.scoreComponents,
                  let currentNode = nodes[placement.nodeID] else {
                continue
            }
            let pressureOverridesStability: Bool
            switch currentNode.posture.pressure {
            case .critical, .unknown, .unavailable:
                pressureOverridesStability = input.stabilityPolicy.pressureSafetyOverride
            case .nominal, .elevated:
                pressureOverridesStability = false
            }
            let stability = placement.stability
            let protected = stability.residenceUnits < input.stabilityPolicy.minimumResidenceUnits
                || stability.cooldownRemainingUnits > input.stabilityPolicy.cooldownUnitsToRetain
                || stability.recoveryDelayRemainingUnits
                    > input.stabilityPolicy.recoveryDelayUnitsToRetain
                || stability.rolloutProtected
            if protected && !pressureOverridesStability && selectedNodeID != placement.nodeID {
                issues.append(issue(
                    .churnBound,
                    "Protected existing placement \(placement.workloadID.uuidString) moved before its stability gate expired."
                ))
                continue
            }
            let improvement = selectedScore.totalBasisPoints - currentAlternative.scoreComponents.totalBasisPoints
            if selectedNodeID != placement.nodeID && improvement <= input.antiChurnThresholdBasisPoints {
                issues.append(issue(
                    .churnBound,
                    "Existing placement \(placement.workloadID.uuidString) moved without exceeding its anti-churn threshold."
                ))
            }
        }
        return issues
    }

    private static func hardPolicyIssues(
        workload: SchedulerWorkload,
        charge: ResourceVector,
        node: SchedulerNode,
        allocation: ResourceVector,
        topologyContext: HardTopologySpreadContext
    ) throws -> [Phase10SchedulerQualification.Issue] {
        var issues: [Phase10SchedulerQualification.Issue] = []
        switch node.posture.pressure {
        case .critical, .unknown, .unavailable:
            issues.append(issue(
                .hardPolicy,
                "Placement of \(workload.workloadID.uuidString) used pressure-ineligible node \(node.nodeID.uuidString)."
            ))
        case .nominal, .elevated:
            break
        }
        let dynamicRequirements = try WorkloadPlacementRequirements(
            workloadID: workload.workloadID,
            request: charge,
            requiredArchitectures: workload.requirements.requiredArchitectures,
            requiredRuntime: workload.requirements.requiredRuntime,
            requiredProvider: workload.requirements.requiredProvider,
            requiredCapabilities: workload.requirements.requiredCapabilities,
            affinity: workload.requirements.affinity,
            tolerations: workload.requirements.tolerations,
            acceleratorRequirements: workload.requirements.acceleratorRequirements
        )
        let dynamicSnapshot = try NodePlacementSnapshot(
            nodeID: node.nodeID,
            capacity: node.capacity,
            allocation: allocation,
            architecture: node.snapshot.architecture,
            runtime: node.snapshot.runtime,
            provider: node.snapshot.provider,
            capabilities: node.snapshot.capabilities,
            health: node.snapshot.health,
            maintenance: node.snapshot.maintenance,
            labels: node.snapshot.labels,
            taints: node.snapshot.taints,
            acceleratorAvailability: node.snapshot.acceleratorAvailability
        )
        let filters = HardPlacementFilterEvaluator().evaluate(
            workload: dynamicRequirements,
            on: dynamicSnapshot,
            topologyContext: topologyContext
        )
        if !filters.passed {
            issues.append(issue(
                .hardPolicy,
                "Placement of \(workload.workloadID.uuidString) bypassed hard filters: \(filters.reasons.map(\.code.rawValue).joined(separator: ","))."
            ))
        }
        if !Set(workload.constraints.requiredVolumes).isSubset(of: Set(node.availableVolumeIDs))
            || !Set(workload.constraints.requiredPorts).isSubset(of: Set(node.availablePorts))
            || !Set(workload.constraints.requiredNetworks).isSubset(of: Set(node.availableNetworkIDs)) {
            issues.append(issue(
                .hardPolicy,
                "Placement of \(workload.workloadID.uuidString) bypassed a volume, port, or network constraint."
            ))
        }
        return issues
    }

    private static func fairnessKey(_ subject: String, _ project: String) -> String {
        subject + "\u{1F}" + project
    }

    private static func issue(
        _ kind: Phase10SchedulerQualification.IssueKind,
        _ message: String
    ) -> Phase10SchedulerQualification.Issue {
        Phase10SchedulerQualification.Issue(kind: kind, severity: .failure, message: message)
    }
}

enum Phase10SchedulerQualificationExactOracle {
    static let domain = "multi-resource(cpu,memory,disk)-hard-capacity-feasibility"

    struct Result: Codable, Equatable {
        let inputFingerprint: String
        let domain: String
        let maxPlaced: Int
        let canonicalAssignment: [String: String]
    }

    struct Comparison {
        let result: Result
        let issues: [Phase10SchedulerQualification.Issue]
    }

    static func compare(
        input: SchedulerEngineInput,
        decision: SchedulerDecision,
        mode: Phase10SchedulerQualification.OracleMode
    ) throws -> Comparison {
        let result = try enumerate(input: input)
        let actualPlaced = decision.workloadDecisions.filter {
            $0.outcome == .placed || $0.outcome == .retainedExistingPlacement
        }.count
        var issues: [Phase10SchedulerQualification.Issue] = []
        if actualPlaced > result.maxPlaced {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .exactSafetyMismatch,
                    severity: .failure,
                    message: "Scheduler placed \(actualPlaced) workloads but the exact feasibility oracle found at most \(result.maxPlaced)."
                )
            )
        } else if actualPlaced < result.maxPlaced {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .intentionalOptimizationGap,
                    severity: .diagnostic,
                    message: "Scheduler placed \(actualPlaced) workloads while the exact oracle found a feasible assignment for \(result.maxPlaced); recorded as an optimization gap, not a safety mismatch."
                )
            )
        }
        let actualNodeID: UUID? = decision.workloadDecisions.first?.chosenNodeID ?? nil
        if mode == .lockedTieBreak,
           let expectedAssignment = result.canonicalAssignment[
               input.pendingWorkloads.sorted(by: { uuidPrecedes($0.workloadID, $1.workloadID) })
                   .first?.workloadID.uuidString ?? ""
           ],
           actualNodeID?.uuidString.lowercased() != expectedAssignment {
            issues.append(
                Phase10SchedulerQualification.Issue(
                    kind: .exactTieBreakMismatch,
                    severity: .failure,
                    message: "Exact score tie selected \(actualNodeID?.uuidString ?? "nil") instead of the oracle canonical node \(expectedAssignment)."
                )
            )
        }
        return Comparison(result: result, issues: issues)
    }

    private static func enumerate(input: SchedulerEngineInput) throws -> Result {
        guard isMultiResourceFeasibilityDomain(input) else {
            throw ExactOracleDomainError.unsupportedInput
        }
        let workloads = input.pendingWorkloads.sorted { uuidPrecedes($0.workloadID, $1.workloadID) }
        let nodes = input.nodes.sorted { uuidPrecedes($0.nodeID, $1.nodeID) }
        let initialRemaining = try nodes.map {
            try $0.schedulableCapacity.subtracting($0.allocation)
        }
        var bestPlaced = -1
        var bestKey: String?
        var bestAssignment: [String: String] = [:]

        func visit(
            _ index: Int,
            remaining: [ResourceVector],
            assignments: [String: String],
            placed: Int
        ) throws {
            if index == workloads.count {
                let key = workloads.map { workload in
                    workload.workloadID.uuidString.lowercased() + "=" + (assignments[workload.workloadID.uuidString] ?? "~")
                }.joined(separator: "|")
                if placed > bestPlaced || (placed == bestPlaced && (bestKey == nil || key < bestKey!)) {
                    bestPlaced = placed
                    bestKey = key
                    bestAssignment = assignments
                }
                return
            }
            let workload = workloads[index]
            let workloadKey = workload.workloadID.uuidString
            var unplaced = assignments
            unplaced[workloadKey] = "~"
            try visit(index + 1, remaining: remaining, assignments: unplaced, placed: placed)
            for nodeIndex in nodes.indices where workload.request.fits(in: remaining[nodeIndex]) {
                var nextRemaining = remaining
                nextRemaining[nodeIndex] = try nextRemaining[nodeIndex].subtracting(workload.request)
                var nextAssignments = assignments
                nextAssignments[workloadKey] = nodes[nodeIndex].nodeID.uuidString.lowercased()
                try visit(
                    index + 1,
                    remaining: nextRemaining,
                    assignments: nextAssignments,
                    placed: placed + 1
                )
            }
        }

        try visit(0, remaining: initialRemaining, assignments: [:], placed: 0)
        return Result(
            inputFingerprint: input.inputDigest,
            domain: Self.domain,
            maxPlaced: max(bestPlaced, 0),
            canonicalAssignment: bestAssignment
        )
    }

    private static func isMultiResourceFeasibilityDomain(_ input: SchedulerEngineInput) -> Bool {
        let requiredResources = ["cpu", "disk", "memory"]
        return input.fairnessStates.isEmpty
            && input.existingPlacements.isEmpty
            && input.victimAllocations.isEmpty
            && input.disruptionBudgets.isEmpty
            && input.overcommitRatios.isEmpty
            && input.scoringWeights.fragmentation == 1
            && input.scoringWeights.fairness == 0
            && input.scoringWeights.topology == 0
            && input.scoringWeights.locality == 0
            && input.scoringWeights.hostPressureEnergy == 0
            && input.scoringWeights.disruption == 0
            && input.queuePolicy == .standard
            && input.stabilityPolicy == .standard
            && input.preemptionPolicy == .standard
            && input.snapshotQuality == .standard
            && input.nodes.allSatisfy {
                $0.schedulableCapacity.resourceNames == requiredResources
                    && $0.allocation.isEmpty
                    && $0.reservation.isEmpty
                    && $0.snapshot.acceleratorAvailability.isEmpty
                    && $0.snapshot.health == .healthy
                    && $0.snapshot.maintenance == .available
                    && $0.topologyDomains.isEmpty
                    && $0.posture.pressure == .nominal
                    && $0.posture.energy == .balanced
            }
            && input.pendingWorkloads.allSatisfy {
                $0.request.resourceNames == requiredResources
                    && $0.requirements.limit == nil
                    && $0.requirements.requiredArchitectures.isEmpty
                    && $0.requirements.requiredRuntime == nil
                    && $0.requirements.requiredProvider == nil
                    && $0.requirements.requiredCapabilities.isEmpty
                    && $0.requirements.affinity == .none
                    && $0.requirements.tolerations.isEmpty
                    && $0.requirements.acceleratorRequirements.isEmpty
                    && $0.topology == .none
                    && $0.locality == .none
                    && $0.constraints == .none
                    && $0.overhead.isEmpty
                    && $0.safetyMargin.isEmpty
            }
    }

    private enum ExactOracleDomainError: Error {
        case unsupportedInput
    }

    private static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}

enum Phase10SchedulerQualificationShrinker {
    static func minimize(
        _ scenario: Phase10SchedulerQualification.Scenario,
        preserving kind: Phase10SchedulerQualification.IssueKind
    ) throws -> Phase10SchedulerQualification.Scenario {
        var current = scenario

        func preserves(_ candidate: Phase10SchedulerQualification.Scenario) -> Bool {
            Phase10SchedulerQualificationVerifier.evaluate(candidate).issues.contains {
                $0.kind == kind
            }
        }

        for workload in current.input.pendingWorkloads {
            let remaining = current.input.pendingWorkloads.filter {
                $0.workloadID != workload.workloadID
            }
            let candidate = try rebuildingScenario(with: current, pendingWorkloads: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for node in current.input.nodes {
            let remaining = current.input.nodes.filter { $0.nodeID != node.nodeID }
            let candidate = try rebuildingScenario(with: current, nodes: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for state in current.input.fairnessStates {
            let remaining = current.input.fairnessStates.filter {
                !($0.subjectID == state.subjectID && $0.projectID == state.projectID)
            }
            let candidate = try rebuildingScenario(with: current, fairnessStates: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for placement in current.input.existingPlacements {
            let remaining = current.input.existingPlacements.filter {
                $0.workloadID != placement.workloadID
            }
            let candidate = try rebuildingScenario(with: current, existingPlacements: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for victim in current.input.victimAllocations {
            let remaining = current.input.victimAllocations.filter {
                $0.workloadID != victim.workloadID
            }
            let candidate = try rebuildingScenario(with: current, victimAllocations: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        for budget in current.input.disruptionBudgets {
            let remaining = current.input.disruptionBudgets.filter { $0.budgetID != budget.budgetID }
            let candidate = try rebuildingScenario(with: current, disruptionBudgets: remaining)
            if preserves(candidate) {
                current = candidate
            }
        }
        return current
    }

    private static func rebuildingScenario(
        with original: Phase10SchedulerQualification.Scenario,
        pendingWorkloads: [SchedulerWorkload]? = nil,
        nodes: [SchedulerNode]? = nil,
        fairnessStates: [SchedulerFairnessState]? = nil,
        existingPlacements: [SchedulerExistingPlacement]? = nil,
        victimAllocations: [SchedulerVictimAllocation]? = nil,
        disruptionBudgets: [SchedulerDisruptionBudget]? = nil
    ) throws -> Phase10SchedulerQualification.Scenario {
        let input = original.input
        let selectedWorkloads = pendingWorkloads ?? input.pendingWorkloads
        let selectedNodes = nodes ?? input.nodes
        let selectedFairness = fairnessStates ?? input.fairnessStates
        let selectedExisting = existingPlacements ?? input.existingPlacements
        let selectedVictims = victimAllocations ?? input.victimAllocations
        let selectedBudgets = disruptionBudgets ?? input.disruptionBudgets
        let workloadIDs = Set(selectedWorkloads.map(\.workloadID))
        let nodeIDs = Set(selectedNodes.map(\.nodeID))
        let budgetIDs = Set(selectedBudgets.map(\.budgetID))
        let validVictims = selectedVictims.filter {
            nodeIDs.contains($0.nodeID) && ($0.budgetID == nil || budgetIDs.contains($0.budgetID!))
        }
        let validExisting = selectedExisting.filter {
            workloadIDs.contains($0.workloadID) && nodeIDs.contains($0.nodeID)
        }
        let usedBudgetIDs = Set(validVictims.compactMap(\.budgetID))
        let validBudgets = selectedBudgets.filter { usedBudgetIDs.contains($0.budgetID) }
        return Phase10SchedulerQualification.Scenario(
            label: original.label + "-minimized",
            seed: original.seed,
            input: try SchedulerEngineInput(
                pendingWorkloads: selectedWorkloads,
                nodes: selectedNodes,
                fairnessStates: selectedFairness,
                existingPlacements: validExisting,
                victimAllocations: validVictims,
                disruptionBudgets: validBudgets,
                antiChurnThresholdBasisPoints: input.antiChurnThresholdBasisPoints,
                scoringWeights: input.scoringWeights,
                overcommitRatios: input.overcommitRatios,
                preemptionPolicy: input.preemptionPolicy,
                queuePolicy: input.queuePolicy,
                stabilityPolicy: input.stabilityPolicy,
                snapshotQuality: input.snapshotQuality,
                limits: input.limits
            ),
            oracleMode: original.oracleMode
        )
    }
}

enum Phase10SchedulerQualificationArtifacts {
    static func committedReplayFilename(index: Int, sourceName: String) -> String {
        let indexString = String(index)
        let paddedIndex = String(
            repeating: "0",
            count: max(0, 8 - indexString.count)
        ) + indexString
        return "replay-\(paddedIndex)-\(sourceName)"
    }

    struct ReplayFixture: Codable {
        let schema: String
        let issue: Phase10SchedulerQualification.Issue
        let original: Phase10SchedulerQualification.Scenario
        let minimized: Phase10SchedulerQualification.Scenario
        let originalIssues: [Phase10SchedulerQualification.Issue]
        let minimizedIssues: [Phase10SchedulerQualification.Issue]
        let originalDecision: SchedulerDecision?
        let minimizedDecision: SchedulerDecision?
        let oracle: Phase10SchedulerQualificationExactOracle.Result?

        static func decodeStrict(from data: Data) throws -> Self {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var scanner = Phase10SchedulerQualificationStrictJSONScanner(
                data: data,
                allowedKeys: Phase10SchedulerQualificationStrictJSONScanner.replayAllowedKeys
            )
            try scanner.validate()
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try Phase10SchedulerQualificationStrictJSONScanner.validateJSONShape(
                data,
                canonicalData: try encoder.encode(decoded)
            )
            return decoded
        }
    }

    struct Receipt {
        let location: String
        let relativePath: String
        let retained: Bool
        let byteCount: Int
        let sha256: String
    }


    static func emitReplay(
        original: Phase10SchedulerQualification.Scenario,
        minimized: Phase10SchedulerQualification.Scenario,
        issue: Phase10SchedulerQualification.Issue,
        originalEvaluation: Phase10SchedulerQualification.Evaluation,
        minimizedEvaluation: Phase10SchedulerQualification.Evaluation,
        configuration: Phase10SchedulerQualification.Configuration
    ) throws -> Receipt {
        guard originalEvaluation.inputDigest == original.input.inputDigest,
              minimizedEvaluation.inputDigest == minimized.input.inputDigest,
              originalEvaluation.decision == nil
                || originalEvaluation.decision?.inputDigest == original.input.inputDigest,
              minimizedEvaluation.decision == nil
                || minimizedEvaluation.decision?.inputDigest == minimized.input.inputDigest,
              originalEvaluation.oracle == nil
                || originalEvaluation.oracle?.inputFingerprint == original.input.inputDigest,
              minimizedEvaluation.oracle == nil
                || minimizedEvaluation.oracle?.inputFingerprint == minimized.input.inputDigest else {
            throw Phase10SchedulerQualificationReceiptError.invalidInputSequence(
                "replay evaluation was not bound to its scenario"
            )
        }
        let fixture = ReplayFixture(
            schema: "hostwright.phase10.scheduler.qualification.replay.v1",
            issue: issue,
            original: original,
            minimized: minimized,
            originalIssues: originalEvaluation.issues,
            minimizedIssues: minimizedEvaluation.issues,
            originalDecision: originalEvaluation.decision,
            minimizedDecision: minimizedEvaluation.decision,
            oracle: minimizedEvaluation.oracle ?? originalEvaluation.oracle
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fixture)
        let filename = "replay-\(issue.kind.rawValue)-\(original.seed)-\(original.input.inputDigest.prefix(12)).json"
        return try emit(data: data, filename: filename, configuration: configuration)
    }

    static func emitPerformance(
        _ session: Phase10SchedulerQualificationPerformance.MeasurementSession,
        configuration: Phase10SchedulerQualification.Configuration
    ) throws -> Receipt {
        let record = session.record
        try record.validate()
        let currentHardware = Phase10SchedulerQualificationPerformance.currentHardwareDescription()
        guard configuration.performanceEnabled,
              record.seed == configuration.seed,
              record.repeats == configuration.performanceRepeats,
              record.hardware == currentHardware,
              record.referenceMacGateEnabled == configuration.referenceMacGateEnabled,
              record.thresholdEnforced == configuration.referenceMacGateEnabled,
              record.referenceMacID == configuration.referenceMacID else {
            throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                "performance record does not match the active configuration"
            )
        }
        try record.verifyCurrentBinding(for: session.input)
        if configuration.referenceMacGateEnabled {
            guard configuration.explicitOutputRoot != nil else {
                throw Phase10SchedulerQualificationReceiptError.invalidOutcome
            }
            guard record.hardware == configuration.referenceMacID else {
                throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                    "reference-gated performance hardware does not match the configured Mac identity"
                )
            }
            guard record.p95Seconds < 1.0 else {
                throw Phase10SchedulerQualificationReceiptError.invalidOutcome
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        _ = try Phase10SchedulerQualificationPerformance.Record.decodeStrict(from: data)
        let transcript = session.transcript
        try transcript.validate()
        guard transcript.seed == record.seed,
              transcript.pendingWorkloads == record.pendingWorkloads,
              transcript.nodes == record.nodes,
              transcript.repeats == record.repeats,
              transcript.samplesSeconds == record.samplesSeconds,
              transcript.hardware == record.hardware,
              transcript.operatingSystem == record.operatingSystem,
              transcript.swiftVersion == record.swiftVersion,
              transcript.referenceMacGateEnabled == record.referenceMacGateEnabled,
              transcript.referenceMacID == record.referenceMacID,
              transcript.thresholdEnforced == record.thresholdEnforced,
              transcript.sourceFingerprint == record.sourceFingerprint,
              transcript.inputFingerprint == record.inputFingerprint,
              transcript.buildFingerprint == record.buildFingerprint else {
            throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                "performance transcript does not match the measured record"
            )
        }
        let transcriptData = try encoder.encode(transcript)
        _ = try Phase10SchedulerQualificationPerformance.MeasurementTranscript.decodeStrict(
            from: transcriptData
        )
        if let explicitRoot = configuration.explicitOutputRoot {
            let runDirectory = try explicitRunDirectory(under: explicitRoot)
            let recordFilename = "performance-\(record.seed)-\(record.pendingWorkloads)x\(record.nodes).json"
            let recordURL = runDirectory.appendingPathComponent(recordFilename, isDirectory: false)
            let recordPath = try relativePath(destination: recordURL, root: explicitRoot)
            let transcriptFilename = "performance-transcript-\(record.seed)-\(record.pendingWorkloads)x\(record.nodes).json"
            let transcriptURL = runDirectory.appendingPathComponent(
                transcriptFilename,
                isDirectory: false
            )
            let transcriptPath = try relativePath(
                destination: transcriptURL,
                root: explicitRoot
            )
            let rootPathIdentity = try Phase10SchedulerQualificationPathIdentity.capture(explicitRoot)
            let runPathIdentity = try Phase10SchedulerQualificationPathIdentity.capture(runDirectory)
            let manifest = Phase10SchedulerQualificationPerformance.CommittedArtifactManifest(
                recordPath: recordPath,
                recordSha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data),
                recordByteCount: data.count,
                transcriptPath: transcriptPath,
                transcriptSha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: transcriptData),
                transcriptByteCount: transcriptData.count,
                outputRootIdentity: explicitRoot.standardizedFileURL.path,
                runDirectoryIdentity: try relativePath(
                    destination: runDirectory,
                    root: explicitRoot
                ),
                outputRootPathIdentity: rootPathIdentity,
                runDirectoryPathIdentity: runPathIdentity
            )
            let manifestData = try encoder.encode(manifest)
            let manifestURL = runDirectory.appendingPathComponent(
                "performance-manifest.json",
                isDirectory: false
            )
            try atomicWrite(data, to: recordURL, confinedTo: explicitRoot)
            try atomicWrite(transcriptData, to: transcriptURL, confinedTo: explicitRoot)
            try atomicWrite(manifestData, to: manifestURL, confinedTo: explicitRoot)
            let commitText = "hostwright.phase10.scheduler.qualification.performance.commit.v1\n"
                + "record=\(recordURL.lastPathComponent)\n"
                + "recordSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data))\n"
                + "transcript=\(transcriptURL.lastPathComponent)\n"
                + "transcriptSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: transcriptData))\n"
                + "manifest=\(manifestURL.lastPathComponent)\n"
                + "manifestSha256=\(Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: manifestData))\n"
            let commitURL = runDirectory.appendingPathComponent("COMMITTED", isDirectory: false)
            try atomicWrite(Data(commitText.utf8), to: commitURL, confinedTo: explicitRoot)
            try synchronizeDirectory(runDirectory)
            _ = try Phase10SchedulerQualificationPerformance.verifyCommittedArtifact(
                at: recordURL,
                root: explicitRoot
            )
            return Receipt(
                location: recordURL.path,
                relativePath: recordPath,
                retained: true,
                byteCount: data.count,
                sha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data)
            )
        }
        return try emit(
            data: data,
            filename: "performance-\(record.seed)-\(record.pendingWorkloads)x\(record.nodes).json",
            configuration: configuration
        )
    }

    static func emitQualificationReceipt(
        _ session: Phase10SchedulerQualificationRunSession,
        configuration: Phase10SchedulerQualification.Configuration
    ) throws -> Receipt {
        guard let explicitRoot = configuration.explicitOutputRoot else {
            throw Phase10SchedulerQualificationReceiptError.invalidOutcome
        }
        var record = session.record
        try record.validate(
            allowPreCommitReplayPaths: true,
            requirePathIdentities: false
        )
        guard record.configuration == Phase10SchedulerQualificationReceiptConfiguration(configuration) else {
            throw Phase10SchedulerQualificationReceiptError.invalidCrossField(
                "receipt configuration changed before emission"
            )
        }
        let operatingSystem = Phase10SchedulerQualificationPerformance.currentOperatingSystemDescription()
        let swiftVersion = Phase10SchedulerQualificationPerformance.swiftDescriptionForReceipt()
        let sourceFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
        let buildFingerprint = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
            swiftVersion: swiftVersion,
            operatingSystem: operatingSystem
        )
        let inputFingerprint = Phase10SchedulerQualificationPerformance.Fingerprints.digest(
            data: session.canonicalInputMaterial
        )
        guard record.sourceFingerprint == sourceFingerprint,
              record.inputFingerprint == inputFingerprint,
              record.buildFingerprint == buildFingerprint else {
            throw Phase10SchedulerQualificationReceiptError.fingerprintMismatch(
                field: "current-binding",
                expected: sourceFingerprint,
                actual: record.sourceFingerprint
            )
        }
        let runDirectory = try explicitRunDirectory(
            under: explicitRoot,
            identity: record.runDirectoryIdentity
        )
        record = record.replacingPathIdentities(
            outputRoot: try Phase10SchedulerQualificationPathIdentity.capture(explicitRoot),
            runDirectory: try Phase10SchedulerQualificationPathIdentity.capture(runDirectory)
        )
        try record.validate(allowPreCommitReplayPaths: true)
        var committedFixtures: [Phase10SchedulerQualificationReplayEntry] = []
        committedFixtures.reserveCapacity(record.replayFixtures.count)
        for (index, fixture) in record.replayFixtures.enumerated() {
            guard Phase10SchedulerQualificationRunReceipt.isSafeReplayPathForEmission(
                fixture.relativePath
            ) else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            let source = explicitRoot
                .appendingPathComponent(fixture.relativePath, isDirectory: false)
                .standardizedFileURL
            guard Phase10SchedulerQualification.Configuration.isWithin(
                source,
                root: explicitRoot
            ),
            !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(source),
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
            (attributes[.type] as? FileAttributeType) == .typeRegular,
            let data = try? Data(contentsOf: source, options: [.mappedIfSafe]),
            data.count == fixture.byteCount,
            Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data) == fixture.sha256 else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            let filename = Self.committedReplayFilename(
                index: index,
                sourceName: source.lastPathComponent
            )
            let destination = runDirectory.appendingPathComponent(filename, isDirectory: false)
            try atomicWrite(data, to: destination, confinedTo: explicitRoot)
            committedFixtures.append(
                Phase10SchedulerQualificationReplayEntry(
                    relativePath: "\(record.runDirectoryIdentity)/\(filename)",
                    sha256: fixture.sha256,
                    byteCount: fixture.byteCount,
                    issueKind: fixture.issueKind,
                    severity: fixture.severity,
                    scenarioSeed: fixture.scenarioSeed,
                    inputFingerprint: fixture.inputFingerprint,
                    caseIndex: fixture.caseIndex,
                    oracleDomain: fixture.oracleDomain
                )
            )
        }
        let committedRecord = record.replacingReplayFixtures(committedFixtures)
        try committedRecord.validate()
        try committedRecord.verifyBinding(
            expectedSourceFingerprint: sourceFingerprint,
            expectedInputFingerprint: inputFingerprint,
            expectedBuildFingerprint: buildFingerprint,
            expectedOutputRootIdentity: explicitRoot.standardizedFileURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = Phase10SchedulerQualificationReplayManifest(
            schema: "hostwright.phase10.scheduler.qualification.replay-manifest.v1",
            runDirectoryIdentity: record.runDirectoryIdentity,
            entries: committedFixtures
        )
        let manifestData = try encoder.encode(manifest)
        let manifestURL = runDirectory.appendingPathComponent("replay-manifest.json")
        try atomicWrite(manifestData, to: manifestURL, confinedTo: explicitRoot)
        let receiptData = try encoder.encode(committedRecord)
        _ = try Phase10SchedulerQualificationRunReceipt.decodeStrict(from: receiptData)
        let receiptURL = runDirectory.appendingPathComponent(
            "qualification-\(record.cell.rawValue)-\(record.seed)-\(record.caseCount).json",
            isDirectory: false
        )
        try atomicWrite(receiptData, to: receiptURL, confinedTo: explicitRoot)
        let receiptHash = Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: receiptData)
        let manifestHash = Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: manifestData)
        let commitText = "hostwright.phase10.scheduler.qualification.commit.v1\n"
            + "receipt=\(receiptURL.lastPathComponent)\n"
            + "receiptSha256=\(receiptHash)\n"
            + "manifest=\(manifestURL.lastPathComponent)\n"
            + "manifestSha256=\(manifestHash)\n"
        let commitMaterial = Data(commitText.utf8)
        let commitURL = runDirectory.appendingPathComponent("COMMITTED", isDirectory: false)
        try atomicWrite(commitMaterial, to: commitURL, confinedTo: explicitRoot)
        try committedRecord.verifyReplayFiles(at: explicitRoot)
        return Receipt(
            location: receiptURL.path,
            relativePath: try relativePath(destination: receiptURL, root: explicitRoot),
            retained: true,
            byteCount: receiptData.count,
            sha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: receiptData)
        )
    }

    private static func emit(
        data: Data,
        filename: String,
        configuration: Phase10SchedulerQualification.Configuration
    ) throws -> Receipt {
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains("..") else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        if let explicitRoot = configuration.explicitOutputRoot {
            let directory = try explicitRunDirectory(under: explicitRoot)
            let destination = directory.appendingPathComponent(filename, isDirectory: false)
            try atomicWrite(data, to: destination, confinedTo: explicitRoot)
            return Receipt(
                location: destination.path,
                relativePath: try relativePath(destination: destination, root: explicitRoot),
                retained: true,
                byteCount: data.count,
                sha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data)
            )
        }

        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        let directory = temporaryRunDirectory()
        do {
            try Phase10SchedulerQualification.Configuration.validateExplicitOutputRoot(root)
            let qualificationRoot = try ensureOwnedDirectory(
                named: "HostwrightPhase10SchedulerQualification",
                under: root
            )
            let replayRoot = try ensureOwnedDirectory(
                named: "replays",
                under: qualificationRoot
            )
            let runName = directory.lastPathComponent
            let actualDirectory = try ensureOwnedDirectory(named: runName, under: replayRoot)
            guard actualDirectory.standardizedFileURL == directory.standardizedFileURL else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            try synchronizeDirectory(replayRoot)
            try synchronizeDirectory(qualificationRoot)
            let destination = actualDirectory.appendingPathComponent(filename, isDirectory: false)
            try atomicWrite(data, to: destination, confinedTo: root)
            return Receipt(
                location: destination.path,
                relativePath: try relativePath(destination: destination, root: root),
                retained: false,
                byteCount: data.count,
                sha256: Phase10SchedulerQualificationPerformance.Fingerprints.digest(data: data)
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func temporaryRunDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HostwrightPhase10SchedulerQualification", isDirectory: true)
            .appendingPathComponent("replays", isDirectory: true)
            .appendingPathComponent("run-\(UUID().uuidString.lowercased())", isDirectory: true)
    }

    private static func explicitRunDirectory(
        under root: URL,
        identity: String? = nil
    ) throws -> URL {
        try Phase10SchedulerQualification.Configuration.validateExplicitOutputRoot(root)
        let runIdentity = identity ?? "Phase10SchedulerQualification/run-\(UUID().uuidString.lowercased())"
        guard Phase10SchedulerQualificationRunReceipt.isSafeReplayPathForEmission(runIdentity),
              runIdentity.hasPrefix("Phase10SchedulerQualification/run-"),
              runIdentity.split(separator: "/").count == 2 else {
            throw Phase10SchedulerQualificationReceiptError.invalidOutcome
        }
        let phaseRoot = try ensureOwnedDirectory(
            named: "Phase10SchedulerQualification",
            under: root.standardizedFileURL
        )
        let runName = String(runIdentity.split(separator: "/").last!)
        let directory = try ensureOwnedDirectory(named: runName, under: phaseRoot)
        try synchronizeDirectory(directory.deletingLastPathComponent())
        try synchronizeDirectory(root.standardizedFileURL)
        guard !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(directory) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        return directory
    }

    private static func ensureOwnedDirectory(named name: String, under parent: URL) throws -> URL {
        guard !name.isEmpty,
              !name.contains("/"),
              name != ".",
              name != ".." else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let standardizedParent = parent.standardizedFileURL
        guard !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(standardizedParent),
              let parentAttributes = try? FileManager.default.attributesOfItem(atPath: standardizedParent.path),
              (parentAttributes[.type] as? FileAttributeType) == .typeDirectory,
              let parentOwner = parentAttributes[.ownerAccountName] as? String,
              parentOwner == NSUserName(),
              let parentPermissions = parentAttributes[.posixPermissions] as? NSNumber,
              parentPermissions.intValue & 0o077 == 0 else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let child = standardizedParent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: child.path) else {
            guard !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(child),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                  (attributes[.type] as? FileAttributeType) == .typeDirectory,
                  let owner = attributes[.ownerAccountName] as? String,
                  owner == NSUserName(),
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else {
                throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
            }
            return child
        }
#if canImport(Darwin)
        guard let resolvedParent = Phase10SchedulerQualification.Configuration.resolvedRealPath(standardizedParent) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let parentDescriptor = try openPinnedAbsoluteDirectory(resolvedParent)
        defer { Darwin.close(parentDescriptor) }
        let result = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
        }
        if result != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fsync(parentDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
#else
        do {
            try FileManager.default.createDirectory(
                at: child,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            guard FileManager.default.fileExists(atPath: child.path) else { throw error }
        }
#endif
        guard !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(child),
              let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
              (attributes[.type] as? FileAttributeType) == .typeDirectory,
              let owner = attributes[.ownerAccountName] as? String,
              owner == NSUserName(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        return child
    }

    private static func relativePath(destination: URL, root: URL) throws -> String {
        let prefix = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath.hasPrefix(prefix),
              !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(destination) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let relative = String(destinationPath.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        return relative
    }

    private static func atomicWrite(
        _ data: Data,
        to destination: URL,
        confinedTo root: URL
    ) throws {
        let directory = destination.deletingLastPathComponent().standardizedFileURL
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty,
              !destinationName.contains("/"),
              destinationName != ".",
              destinationName != "..",
              Phase10SchedulerQualification.Configuration.isWithin(directory, root: root),
              !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(directory) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
#if canImport(Darwin)
        let parentDescriptor = try openPinnedDirectory(root: root, directory: directory)
        defer { Darwin.close(parentDescriptor) }
        var existing = stat()
        let inspectResult = destinationName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        if inspectResult == 0 {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let inspectError = errno
        guard inspectError == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: inspectError) ?? .EIO)
        }
        let stagingName = ".stage-\(UUID().uuidString.lowercased())"
        let stageDescriptor = stagingName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard stageDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var committed = false
        defer {
            Darwin.close(stageDescriptor)
            if !committed {
                _ = stagingName.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, 0)
                }
            }
        }
        try writeAll(data, to: stageDescriptor)
        guard Darwin.fchmod(stageDescriptor, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let renameResult = stagingName.withCString { stage in
            destinationName.withCString { destinationLeaf in
                Darwin.renameat(parentDescriptor, stage, parentDescriptor, destinationLeaf)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        committed = true
        guard fsync(parentDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
#else
        let staging = directory.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        do {
            try writeNoFollow(data, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
#endif
    }

#if canImport(Darwin)
    private static func openPinnedDirectory(root: URL, directory: URL) throws -> Int32 {
        guard Phase10SchedulerQualification.Configuration.isWithin(directory, root: root),
              let resolvedRoot = Phase10SchedulerQualification.Configuration.resolvedRealPath(root),
              let resolvedDirectory = Phase10SchedulerQualification.Configuration.resolvedRealPath(directory) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedDirectory == resolvedRoot || resolvedDirectory.hasPrefix(rootPrefix) else {
            throw Phase10SchedulerQualificationReceiptError.invalidReplayEntry
        }
        let descriptor = try openPinnedAbsoluteDirectory(resolvedRoot)
        let relative = resolvedDirectory == resolvedRoot
            ? ""
            : String(resolvedDirectory.dropFirst(rootPrefix.count))
        var current = descriptor
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            let next = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    private static func openPinnedAbsoluteDirectory(_ path: String) throws -> Int32 {
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for component in URL(fileURLWithPath: path, isDirectory: true).pathComponents {
            guard component != "/" else { continue }
            let next = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        var writeError: Error?
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard written > 0 else {
                    writeError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return
                }
                offset += written
            }
        }
        if let writeError { throw writeError }
        guard offset == data.count, fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
#endif

    private static func writeNoFollow(_ data: Data, to destination: URL) throws {
#if canImport(Darwin)
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var offset = 0
        var writeError: Error?
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard written > 0 else {
                    writeError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return
                }
                offset += written
            }
        }
        if let writeError { throw writeError }
        guard offset == data.count, fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
#else
        let handle = try FileHandle(forWritingTo: destination)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
#endif
    }

    private static func synchronizeDirectory(_ url: URL) throws {
#if canImport(Darwin)
        guard let resolved = Phase10SchedulerQualification.Configuration.resolvedRealPath(url) else {
            throw POSIXError(.ENOENT)
        }
        let descriptor = try openPinnedAbsoluteDirectory(resolved)
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
#else
        _ = url
#endif
    }

}

enum Phase10SchedulerQualificationHostileExpectations {
    static func topologyConflictFailure(
        placedNodeIDs: [UUID?]
    ) -> String? {
        guard placedNodeIDs.count == 2 else {
            return "Topology-conflict case placed \(placedNodeIDs.count) workloads; expected two."
        }
        guard placedNodeIDs[0] != placedNodeIDs[1] else {
            return "Topology-conflict case placed both workloads on the same node."
        }
        return nil
    }
}

private final class Phase10SchedulerQualificationBundleAnchor: NSObject {}

enum Phase10SchedulerQualificationPerformance {
    static let recordSchema = "hostwright.phase10.scheduler.qualification.performance.v2"

    struct MeasurementSession {
        let record: Record
        fileprivate let input: SchedulerEngineInput
        fileprivate let transcript: MeasurementTranscript

        fileprivate init(
            record: Record,
            input: SchedulerEngineInput,
            transcript: MeasurementTranscript
        ) {
            self.record = record
            self.input = input
            self.transcript = transcript
        }
    }

    struct MeasurementTranscript: Codable, Equatable {
        static let schema = "hostwright.phase10.scheduler.qualification.performance-transcript.v1"

        let schema: String
        let seed: UInt64
        let pendingWorkloads: Int
        let nodes: Int
        let repeats: Int
        let samplesSeconds: [Double]
        let hardware: String
        let operatingSystem: String
        let swiftVersion: String
        let referenceMacGateEnabled: Bool
        let referenceMacID: String?
        let thresholdEnforced: Bool
        let sourceFingerprint: String
        let inputFingerprint: String
        let buildFingerprint: String

        init(record: Record, samplesSeconds: [Double]) {
            self.schema = Self.schema
            self.seed = record.seed
            self.pendingWorkloads = record.pendingWorkloads
            self.nodes = record.nodes
            self.repeats = record.repeats
            self.samplesSeconds = samplesSeconds
            self.hardware = record.hardware
            self.operatingSystem = record.operatingSystem
            self.swiftVersion = record.swiftVersion
            self.referenceMacGateEnabled = record.referenceMacGateEnabled
            self.referenceMacID = record.referenceMacID
            self.thresholdEnforced = record.thresholdEnforced
            self.sourceFingerprint = record.sourceFingerprint
            self.inputFingerprint = record.inputFingerprint
            self.buildFingerprint = record.buildFingerprint
        }

        static func decodeStrict(from data: Data) throws -> Self {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var scanner = Phase10SchedulerQualificationStrictJSONScanner(
                data: data,
                allowedKeys: Phase10SchedulerQualificationStrictJSONScanner.performanceTranscriptAllowedKeys
            )
            try scanner.validate()
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try Phase10SchedulerQualificationStrictJSONScanner.validateJSONShape(
                data,
                canonicalData: try encoder.encode(decoded)
            )
            try decoded.validate()
            return decoded
        }

        func validate() throws {
            guard schema == Self.schema,
                  pendingWorkloads == 1_000,
                  nodes == 100,
                  repeats == samplesSeconds.count,
                  repeats > 0,
                  samplesSeconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw PerformanceError.invalidCommittedArtifact(
                    "measurement transcript shape or samples are invalid"
                )
            }
            guard thresholdEnforced == referenceMacGateEnabled else {
                throw PerformanceError.referenceConfigurationMismatch
            }
            if referenceMacGateEnabled {
                guard repeats == 7,
                      !(referenceMacID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
                let ordered = samplesSeconds.sorted()
                let percentileIndex = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
                guard ordered[percentileIndex] < 1.0 else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
            } else {
                guard referenceMacID == nil else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
            }
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                sourceFingerprint,
                field: "transcript-source"
            )
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                inputFingerprint,
                field: "transcript-input"
            )
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                buildFingerprint,
                field: "transcript-build"
            )
        }
    }

    struct CommittedArtifactManifest: Codable, Equatable {
        static let schema = "hostwright.phase10.scheduler.qualification.performance-commit.v1"

        let schema: String
        let recordPath: String
        let recordSha256: String
        let recordByteCount: Int
        let transcriptPath: String
        let transcriptSha256: String
        let transcriptByteCount: Int
        let outputRootIdentity: String
        let runDirectoryIdentity: String
        let outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity
        let runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity

        init(
            recordPath: String,
            recordSha256: String,
            recordByteCount: Int,
            transcriptPath: String,
            transcriptSha256: String,
            transcriptByteCount: Int,
            outputRootIdentity: String,
            runDirectoryIdentity: String,
            outputRootPathIdentity: Phase10SchedulerQualificationPathIdentity,
            runDirectoryPathIdentity: Phase10SchedulerQualificationPathIdentity
        ) {
            self.schema = Self.schema
            self.recordPath = recordPath
            self.recordSha256 = recordSha256
            self.recordByteCount = recordByteCount
            self.transcriptPath = transcriptPath
            self.transcriptSha256 = transcriptSha256
            self.transcriptByteCount = transcriptByteCount
            self.outputRootIdentity = outputRootIdentity
            self.runDirectoryIdentity = runDirectoryIdentity
            self.outputRootPathIdentity = outputRootPathIdentity
            self.runDirectoryPathIdentity = runDirectoryPathIdentity
        }

        static func decodeStrict(from data: Data) throws -> Self {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var scanner = Phase10SchedulerQualificationStrictJSONScanner(
                data: data,
                allowedKeys: Phase10SchedulerQualificationStrictJSONScanner.performanceManifestAllowedKeys
            )
            try scanner.validate()
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try Phase10SchedulerQualificationStrictJSONScanner.validateJSONShape(
                data,
                canonicalData: try encoder.encode(decoded)
            )
            try decoded.validate()
            return decoded
        }

        func validate() throws {
            guard schema == Self.schema,
                  Phase10SchedulerQualificationRunReceipt.isSafeReplayPathForEmission(recordPath),
                  recordByteCount > 0,
                  Phase10SchedulerQualificationRunReceipt.isSafeReplayPathForEmission(transcriptPath),
                  transcriptByteCount > 0,
                  !outputRootIdentity.isEmpty,
                  runDirectoryIdentity.hasPrefix("Phase10SchedulerQualification/run-"),
                  runDirectoryIdentity.split(separator: "/").count == 2,
                  recordPath.hasPrefix(runDirectoryIdentity + "/") else {
                throw Phase10SchedulerQualificationPerformance.PerformanceError.invalidCommittedArtifact(
                    "performance manifest identity or path is invalid"
                )
            }
            guard recordPath.split(separator: "/").count == runDirectoryIdentity.split(separator: "/").count + 1 else {
                throw Phase10SchedulerQualificationPerformance.PerformanceError.invalidCommittedArtifact(
                    "performance manifest record path is not directly beneath its run directory"
                )
            }
            guard transcriptPath.hasPrefix(runDirectoryIdentity + "/"),
                  transcriptPath.split(separator: "/").count == runDirectoryIdentity.split(separator: "/").count + 1 else {
                throw Phase10SchedulerQualificationPerformance.PerformanceError.invalidCommittedArtifact(
                    "performance manifest transcript path is not directly beneath its run directory"
                )
            }
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                recordSha256,
                field: "committed-record"
            )
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                transcriptSha256,
                field: "committed-transcript"
            )
        }
    }

    static func currentOperatingSystemDescription() -> String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static func swiftDescriptionForReceipt() -> String {
        swiftDescription()
    }

    static func currentHardwareDescription() -> String {
        hardwareDescription()
    }

    struct Record: Codable {
        let schema: String
        let hardware: String
        let operatingSystem: String
        let swiftVersion: String
        let seed: UInt64
        let pendingWorkloads: Int
        let nodes: Int
        let repeats: Int
        let samplesSeconds: [Double]
        let p95Seconds: Double
        let referenceMacGateEnabled: Bool
        let referenceMacID: String?
        let thresholdEnforced: Bool
        let sourceFingerprint: String
        let inputFingerprint: String
        let buildFingerprint: String

        init(
            schema: String,
            hardware: String,
            operatingSystem: String,
            swiftVersion: String,
            seed: UInt64,
            pendingWorkloads: Int,
            nodes: Int,
            repeats: Int,
            samplesSeconds: [Double],
            p95Seconds: Double,
            referenceMacGateEnabled: Bool,
            referenceMacID: String?,
            thresholdEnforced: Bool,
            sourceFingerprint: String,
            inputFingerprint: String,
            buildFingerprint: String
        ) {
            self.schema = schema
            self.hardware = hardware
            self.operatingSystem = operatingSystem
            self.swiftVersion = swiftVersion
            self.seed = seed
            self.pendingWorkloads = pendingWorkloads
            self.nodes = nodes
            self.repeats = repeats
            self.samplesSeconds = samplesSeconds
            self.p95Seconds = p95Seconds
            self.referenceMacGateEnabled = referenceMacGateEnabled
            self.referenceMacID = referenceMacID
            self.thresholdEnforced = thresholdEnforced
            self.sourceFingerprint = sourceFingerprint
            self.inputFingerprint = inputFingerprint
            self.buildFingerprint = buildFingerprint
        }

        static func decodeStrict(from data: Data) throws -> Self {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var scanner = Phase10SchedulerQualificationStrictJSONScanner(
                data: data,
                allowedKeys: Phase10SchedulerQualificationStrictJSONScanner.performanceAllowedKeys
            )
            try scanner.validate()
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            let input = try Phase10SchedulerQualificationGenerator.performanceInput(
                seed: decoded.seed
            )
            try decoded.verifyCurrentBinding(for: input)
            return decoded
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decode(String.self, forKey: .schema)
            hardware = try container.decode(String.self, forKey: .hardware)
            operatingSystem = try container.decode(String.self, forKey: .operatingSystem)
            swiftVersion = try container.decode(String.self, forKey: .swiftVersion)
            seed = try container.decode(UInt64.self, forKey: .seed)
            pendingWorkloads = try container.decode(Int.self, forKey: .pendingWorkloads)
            nodes = try container.decode(Int.self, forKey: .nodes)
            repeats = try container.decode(Int.self, forKey: .repeats)
            samplesSeconds = try container.decode([Double].self, forKey: .samplesSeconds)
            p95Seconds = try container.decode(Double.self, forKey: .p95Seconds)
            referenceMacGateEnabled = try container.decode(
                Bool.self,
                forKey: .referenceMacGateEnabled
            )
            referenceMacID = try container.decodeIfPresent(String.self, forKey: .referenceMacID)
            thresholdEnforced = try container.decode(Bool.self, forKey: .thresholdEnforced)
            sourceFingerprint = try container.decode(String.self, forKey: .sourceFingerprint)
            inputFingerprint = try container.decode(String.self, forKey: .inputFingerprint)
            buildFingerprint = try container.decode(String.self, forKey: .buildFingerprint)
            try validate()
        }

        func validate() throws {
            guard schema == Phase10SchedulerQualificationPerformance.recordSchema else {
                throw PerformanceError.invalidSchema(schema)
            }
            guard pendingWorkloads == 1_000, nodes == 100 else {
                throw PerformanceError.invalidShape(
                    pendingWorkloads: pendingWorkloads,
                    nodes: nodes
                )
            }
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                sourceFingerprint,
                field: "source"
            )
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                inputFingerprint,
                field: "input"
            )
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                buildFingerprint,
                field: "build"
            )
            guard repeats == samplesSeconds.count, repeats > 0 else {
                throw PerformanceError.sampleCountMismatch(
                    repeats: repeats,
                    samples: samplesSeconds.count
                )
            }
            guard samplesSeconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw PerformanceError.invalidSamples
            }
            guard p95Seconds.isFinite, p95Seconds >= 0 else {
                throw PerformanceError.invalidP95
            }
            guard thresholdEnforced == referenceMacGateEnabled else {
                throw PerformanceError.referenceConfigurationMismatch
            }
            if referenceMacGateEnabled {
                guard repeats == 7 else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
                guard !(referenceMacID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
                guard !thresholdEnforced || p95Seconds < 1.0 else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
            } else {
                guard referenceMacID == nil else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
            }
            let ordered = samplesSeconds.sorted()
            let percentileIndex = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
            guard p95Seconds == ordered[percentileIndex] else {
                throw PerformanceError.p95Mismatch(
                    expected: ordered[percentileIndex],
                    actual: p95Seconds
                )
            }
        }

        func verifyBinding(
            for input: SchedulerEngineInput,
            sourceFingerprint: String,
            buildFingerprint: String
        ) throws {
            try verifyBinding(
                expectedInputFingerprint: input.inputDigest,
                expectedSourceFingerprint: sourceFingerprint,
                expectedBuildFingerprint: buildFingerprint
            )
        }

        func verifyCurrentBinding(for input: SchedulerEngineInput) throws {
            let currentOperatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
            guard operatingSystem == currentOperatingSystem else {
                throw PerformanceError.environmentMismatch(
                    field: "operating-system",
                    expected: currentOperatingSystem,
                    actual: operatingSystem
                )
            }
            let currentSwiftVersion = Phase10SchedulerQualificationPerformance.swiftDescription()
            guard swiftVersion == currentSwiftVersion else {
                throw PerformanceError.environmentMismatch(
                    field: "swift-version",
                    expected: currentSwiftVersion,
                    actual: swiftVersion
                )
            }
            let currentHardware = Phase10SchedulerQualificationPerformance.currentHardwareDescription()
            guard hardware == currentHardware else {
                throw PerformanceError.environmentMismatch(
                    field: "hardware",
                    expected: currentHardware,
                    actual: hardware
                )
            }
            if referenceMacGateEnabled {
                guard referenceMacID == currentHardware else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
            } else {
                guard referenceMacID == nil else {
                    throw PerformanceError.referenceConfigurationMismatch
                }
            }
            let source = try Phase10SchedulerQualificationPerformance.Fingerprints.sourceFingerprint()
            let build = try Phase10SchedulerQualificationPerformance.Fingerprints.buildFingerprint(
                swiftVersion: currentSwiftVersion,
                operatingSystem: currentOperatingSystem
            )
            try verifyBinding(
                for: input,
                sourceFingerprint: source,
                buildFingerprint: build
            )
        }

        func verifyBinding(
            expectedInputFingerprint: String,
            expectedSourceFingerprint: String,
            expectedBuildFingerprint: String
        ) throws {
            try validate()
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                expectedSourceFingerprint,
                field: "expected-source"
            )
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                expectedInputFingerprint,
                field: "expected-input"
            )
            try Phase10SchedulerQualificationPerformance.validateFingerprint(
                expectedBuildFingerprint,
                field: "expected-build"
            )
            guard sourceFingerprint == expectedSourceFingerprint else {
                throw PerformanceError.fingerprintMismatch(
                    field: "source",
                    expected: expectedSourceFingerprint,
                    actual: sourceFingerprint
                )
            }
            guard inputFingerprint == expectedInputFingerprint else {
                throw PerformanceError.fingerprintMismatch(
                    field: "input",
                    expected: expectedInputFingerprint,
                    actual: inputFingerprint
                )
            }
            guard buildFingerprint == expectedBuildFingerprint else {
                throw PerformanceError.fingerprintMismatch(
                    field: "build",
                    expected: expectedBuildFingerprint,
                    actual: buildFingerprint
                )
            }
        }

        private enum CodingKeys: String, CodingKey {
            case schema
            case hardware
            case operatingSystem
            case swiftVersion
            case seed
            case pendingWorkloads
            case nodes
            case repeats
            case samplesSeconds
            case p95Seconds
            case referenceMacGateEnabled
            case referenceMacID
            case thresholdEnforced
            case sourceFingerprint
            case inputFingerprint
            case buildFingerprint
        }
    }

    static func verifyCommittedArtifact(at recordURL: URL, root: URL) throws -> Record {
        try Phase10SchedulerQualification.Configuration.validateExplicitOutputRoot(root)
        let standardizedRoot = root.standardizedFileURL
        let standardizedRecord = recordURL.standardizedFileURL
        guard Phase10SchedulerQualification.Configuration.isWithin(
            standardizedRecord,
            root: standardizedRoot
        ),
        !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(standardizedRoot),
        !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(standardizedRecord) else {
            throw PerformanceError.invalidCommittedArtifact("record path is outside the owned root")
        }
        let runDirectory = standardizedRecord.deletingLastPathComponent().standardizedFileURL
        guard Phase10SchedulerQualification.Configuration.isWithin(
            runDirectory,
            root: standardizedRoot
        ),
        !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(runDirectory) else {
            throw PerformanceError.invalidCommittedArtifact("run directory is outside the owned root")
        }
        let manifestURL = runDirectory.appendingPathComponent(
            "performance-manifest.json",
            isDirectory: false
        )
        let commitURL = runDirectory.appendingPathComponent("COMMITTED", isDirectory: false)
        let recordData = try verifiedRegularData(standardizedRecord)
        let manifestData = try verifiedRegularData(manifestURL)
        let commitData = try verifiedRegularData(commitURL)
        let manifest = try CommittedArtifactManifest.decodeStrict(from: manifestData)
        let recordPath = try relativePath(destination: standardizedRecord, root: standardizedRoot)
        let runIdentity = try relativePath(destination: runDirectory, root: standardizedRoot)
        let transcriptURL = standardizedRoot.appendingPathComponent(
            manifest.transcriptPath,
            isDirectory: false
        ).standardizedFileURL
        guard Phase10SchedulerQualification.Configuration.isWithin(
            transcriptURL,
            root: standardizedRoot
        ),
        !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(transcriptURL) else {
            throw PerformanceError.invalidCommittedArtifact("transcript path is outside the owned root")
        }
        let transcriptData = try verifiedRegularData(transcriptURL)
        guard manifest.recordPath == recordPath,
              manifest.runDirectoryIdentity == runIdentity,
              manifest.outputRootIdentity == standardizedRoot.path,
              manifest.outputRootPathIdentity.textualPath == standardizedRoot.path,
              manifest.runDirectoryPathIdentity.textualPath == runDirectory.path,
              manifest.recordByteCount == recordData.count,
              manifest.recordSha256 == Fingerprints.digest(data: recordData),
              manifest.transcriptByteCount == transcriptData.count,
              manifest.transcriptSha256 == Fingerprints.digest(data: transcriptData) else {
            throw PerformanceError.invalidCommittedArtifact(
                "performance manifest does not match the committed record or transcript"
            )
        }
        try manifest.outputRootPathIdentity.verify(at: standardizedRoot)
        try manifest.runDirectoryPathIdentity.verify(at: runDirectory)
        let record = try Record.decodeStrict(from: recordData)
        let transcript = try MeasurementTranscript.decodeStrict(from: transcriptData)
        guard transcript.seed == record.seed,
              transcript.pendingWorkloads == record.pendingWorkloads,
              transcript.nodes == record.nodes,
              transcript.repeats == record.repeats,
              transcript.samplesSeconds == record.samplesSeconds,
              transcript.hardware == record.hardware,
              transcript.operatingSystem == record.operatingSystem,
              transcript.swiftVersion == record.swiftVersion,
              transcript.referenceMacGateEnabled == record.referenceMacGateEnabled,
              transcript.referenceMacID == record.referenceMacID,
              transcript.thresholdEnforced == record.thresholdEnforced,
              transcript.sourceFingerprint == record.sourceFingerprint,
              transcript.inputFingerprint == record.inputFingerprint,
              transcript.buildFingerprint == record.buildFingerprint else {
            throw PerformanceError.invalidCommittedArtifact(
                "measurement transcript does not match the committed record"
            )
        }
        let lines = String(decoding: commitData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let expectedKeys: Set<String> = [
            "record",
            "recordSha256",
            "transcript",
            "transcriptSha256",
            "manifest",
            "manifestSha256"
        ]
        var fields: [String: String] = [:]
        var seenKeys = Set<String>()
        for line in lines.dropFirst() {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  expectedKeys.contains(parts[0]),
                  !parts[1].isEmpty,
                  seenKeys.insert(parts[0]).inserted else {
                throw PerformanceError.invalidCommittedArtifact("performance commit marker is malformed")
            }
            fields[parts[0]] = parts[1]
        }
        guard lines.count == expectedKeys.count + 1,
              seenKeys == expectedKeys,
              lines.first == "hostwright.phase10.scheduler.qualification.performance.commit.v1",
              fields["record"] == standardizedRecord.lastPathComponent,
              fields["recordSha256"] == Fingerprints.digest(data: recordData),
              fields["transcript"] == transcriptURL.lastPathComponent,
              fields["transcriptSha256"] == Fingerprints.digest(data: transcriptData),
              fields["manifest"] == manifestURL.lastPathComponent,
              fields["manifestSha256"] == Fingerprints.digest(data: manifestData) else {
            throw PerformanceError.invalidCommittedArtifact(
                "performance commit marker does not bind the record and manifest"
            )
        }
        return record
    }

    private static func verifiedRegularData(_ url: URL) throws -> Data {
        guard !Phase10SchedulerQualification.Configuration.hasSymlinkComponent(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw PerformanceError.invalidCommittedArtifact("performance artifact is not a regular file")
        }
        return data
    }

    private static func relativePath(destination: URL, root: URL) throws -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let destinationPath = destination.path
        guard destinationPath.hasPrefix(prefix) else {
            throw PerformanceError.invalidCommittedArtifact("performance artifact path escaped its root")
        }
        let relative = String(destinationPath.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PerformanceError.invalidCommittedArtifact("performance artifact relative path is invalid")
        }
        return relative
    }

    static func measure(
        configuration: Phase10SchedulerQualification.Configuration
    ) throws -> MeasurementSession {
        let input = try Phase10SchedulerQualificationGenerator.performanceInput(seed: configuration.seed)
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        let swiftVersion = swiftDescription()
        let sourceFingerprint = try Fingerprints.sourceFingerprint()
        let buildFingerprint = try Fingerprints.buildFingerprint(
            swiftVersion: swiftVersion,
            operatingSystem: operatingSystem
        )
        let engine = SchedulerEngine()
        let warmup = try engine.plan(input)
        guard warmup.workloadDecisions.count == 1_000 else {
            throw PerformanceError.incompleteWarmup(warmup.workloadDecisions.count)
        }
        var samples: [Double] = []
        samples.reserveCapacity(configuration.performanceRepeats)
        for _ in 0..<configuration.performanceRepeats {
            let start = DispatchTime.now().uptimeNanoseconds
            let decision = try engine.plan(input)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard decision.workloadDecisions.count == 1_000 else {
                throw PerformanceError.incompleteRun(decision.workloadDecisions.count)
            }
            samples.append(Double(elapsed) / 1_000_000_000)
        }
        let ordered = samples.sorted()
        let percentileIndex = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
        let record = Record(
            schema: recordSchema,
            hardware: hardwareDescription(),
            operatingSystem: operatingSystem,
            swiftVersion: swiftVersion,
            seed: configuration.seed,
            pendingWorkloads: 1_000,
            nodes: 100,
            repeats: configuration.performanceRepeats,
            samplesSeconds: samples,
            p95Seconds: ordered[percentileIndex],
            referenceMacGateEnabled: configuration.hasQualifiedReferenceMacGate,
            referenceMacID: configuration.referenceMacID,
            thresholdEnforced: configuration.hasQualifiedReferenceMacGate,
            sourceFingerprint: sourceFingerprint,
            inputFingerprint: input.inputDigest,
            buildFingerprint: buildFingerprint
        )
        try record.verifyBinding(
            for: input,
            sourceFingerprint: sourceFingerprint,
            buildFingerprint: buildFingerprint
        )
        let transcript = MeasurementTranscript(record: record, samplesSeconds: samples)
        return MeasurementSession(
            record: record,
            input: input,
            transcript: transcript
        )
    }

    enum Fingerprints {
        private static let schema = "hostwright.phase10.scheduler.qualification.fingerprint.v1"

        static func sourceFingerprint(repositoryRoot: URL? = nil) throws -> String {
            let root = (repositoryRoot ?? inferredRepositoryRoot()).standardizedFileURL
            let sourcesDirectory = root.appendingPathComponent("Sources", isDirectory: true)
            let qualificationDirectory = root.appendingPathComponent(
                "Tests/HostwrightSchedulerTests",
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: sourcesDirectory.path),
                  FileManager.default.fileExists(atPath: qualificationDirectory.path) else {
                throw PerformanceError.sourceUnavailable(root.path)
            }

            var entries: [(String, Data)] = []
            for relative in ["Package.swift", "Package.resolved"] {
                let file = root.appendingPathComponent(relative, isDirectory: false)
                guard FileManager.default.isReadableFile(atPath: file.path) else {
                    throw PerformanceError.sourceUnavailable(file.path)
                }
                entries.append((relative, try Data(contentsOf: file)))
            }
            for file in try sourceFiles(in: sourcesDirectory) {
                let relative = "Sources/"
                    + file.path.replacingOccurrences(
                        of: sourcesDirectory.path + "/",
                        with: ""
                    )
                entries.append((relative, try Data(contentsOf: file)))
            }

            for file in try sourceFiles(in: qualificationDirectory) {
                let relative = "Tests/HostwrightSchedulerTests/"
                    + file.path.replacingOccurrences(
                        of: qualificationDirectory.path + "/",
                        with: ""
                    )
                entries.append((relative, try Data(contentsOf: file)))
            }
            return digest(manifest: entries)
        }

        static func buildFingerprint(
            executableURL: URL? = nil,
            swiftVersion: String,
            operatingSystem: String
        ) throws -> String {
            let executable = executableURL ?? Bundle(
                for: Phase10SchedulerQualificationBundleAnchor.self
            ).executableURL
            guard let executable,
                  FileManager.default.isReadableFile(atPath: executable.path) else {
                throw PerformanceError.buildUnavailable(executable?.path)
            }
            let data: Data
            do {
                data = try Data(contentsOf: executable, options: [.mappedIfSafe])
            } catch {
                throw PerformanceError.buildUnavailable(executable.path)
            }
            return digest(manifest: [
                ("build/schema", Data(schema.utf8)),
                ("build/executable-name", Data(executable.lastPathComponent.utf8)),
                ("build/executable", data),
                ("build/swift-version", Data(swiftVersion.utf8)),
                ("build/operating-system", Data(operatingSystem.utf8))
            ])
        }

        static func digest(data: Data) -> String {
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }

        private static func inferredRepositoryRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        private static func sourceFiles(in directory: URL) throws -> [URL] {
            let sourceExtensions: Set<String> = [
                "c", "cc", "cpp", "h", "hpp", "m", "mm", "swift"
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw PerformanceError.sourceUnavailable(directory.path)
            }
            return try enumerator.compactMap { item -> URL? in
                guard let file = item as? URL,
                      sourceExtensions.contains(file.pathExtension.lowercased()) else {
                    return nil
                }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    return nil
                }
                return file
            }.sorted { $0.path < $1.path }
        }

        private static func digest(manifest entries: [(String, Data)]) -> String {
            var material = Data()
            material.append(contentsOf: Data(schema.utf8))
            for (path, data) in entries.sorted(by: { $0.0 < $1.0 }) {
                appendLength(path.utf8.count, to: &material)
                material.append(contentsOf: Data(path.utf8))
                appendLength(data.count, to: &material)
                material.append(data)
            }
            return digest(data: material)
        }

        private static func appendLength(_ value: Int, to data: inout Data) {
            var bigEndian = UInt64(value).bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
    }

    private static func validateFingerprint(_ value: String, field: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  switch $0.value {
                  case 48...57, 97...102: return true
                  default: return false
                  }
              }) else {
            throw PerformanceError.invalidFingerprint(field: field, value: value)
        }
    }

    private static func hardwareDescription() -> String {
        commandOutput("/usr/sbin/sysctl", arguments: ["-n", "hw.model"])
            ?? commandOutput("/usr/bin/uname", arguments: ["-m"])
            ?? "hardware-unavailable"
    }

    private static func swiftDescription() -> String {
        commandOutput("/usr/bin/xcrun", arguments: ["swift", "--version"])
            ?? "swift-version-unavailable"
    }

    private static func commandOutput(_ executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return nil
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        } catch {
            return nil
        }
    }

    enum PerformanceError: Error, LocalizedError {
        case incompleteWarmup(Int)
        case incompleteRun(Int)
        case invalidSchema(String)
        case invalidShape(pendingWorkloads: Int, nodes: Int)
        case invalidFingerprint(field: String, value: String)
        case fingerprintMismatch(field: String, expected: String, actual: String)
        case sampleCountMismatch(repeats: Int, samples: Int)
        case invalidSamples
        case invalidP95
        case p95Mismatch(expected: Double, actual: Double)
        case referenceConfigurationMismatch
        case environmentMismatch(field: String, expected: String, actual: String)
        case sourceUnavailable(String)
        case buildUnavailable(String?)
        case invalidCommittedArtifact(String)

        var errorDescription: String? {
            switch self {
            case let .incompleteWarmup(count):
                "Performance warmup returned \(count) decisions instead of 1,000."
            case let .incompleteRun(count):
                "Performance run returned \(count) decisions instead of 1,000."
            case let .invalidSchema(schema):
                "Unsupported Phase 10 performance receipt schema: \(schema)."
            case let .invalidShape(pendingWorkloads, nodes):
                "Phase 10 performance receipt must describe exactly 1,000 workloads and 100 nodes; received \(pendingWorkloads)x\(nodes)."
            case let .invalidFingerprint(field, value):
                "Phase 10 performance \(field) fingerprint must be 64 lowercase hexadecimal characters; received \(value)."
            case let .fingerprintMismatch(field, expected, actual):
                "Phase 10 performance \(field) fingerprint mismatch: expected \(expected), received \(actual)."
            case let .sampleCountMismatch(repeats, samples):
                "Phase 10 performance receipt repeats (\(repeats)) must equal sample count (\(samples))."
            case .invalidSamples:
                "Phase 10 performance receipt samples must be finite and non-negative."
            case .invalidP95:
                "Phase 10 performance receipt p95 must be finite and non-negative."
            case let .p95Mismatch(expected, actual):
                "Phase 10 performance receipt p95 must equal the recomputed sample percentile; expected \(expected), received \(actual)."
            case .referenceConfigurationMismatch:
                "Phase 10 performance receipt reference-gate and threshold fields are inconsistent."
            case let .environmentMismatch(field, expected, actual):
                "Phase 10 performance \(field) mismatch: expected \(expected), received \(actual)."
            case let .sourceUnavailable(path):
                "Phase 10 performance source fingerprint could not read \(path)."
            case let .buildUnavailable(path):
                "Phase 10 performance build fingerprint could not read \(path ?? "test-bundle executable")."
            case let .invalidCommittedArtifact(detail):
                "Phase 10 performance committed artifact is invalid: \(detail)."
            }
        }
    }
}
