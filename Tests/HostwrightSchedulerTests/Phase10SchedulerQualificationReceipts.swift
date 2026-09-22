import Foundation
import HostwrightScheduler

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
