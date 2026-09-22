import Foundation
import CryptoKit
import HostwrightScheduler

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
    let canonicalInputMaterial: Data

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
