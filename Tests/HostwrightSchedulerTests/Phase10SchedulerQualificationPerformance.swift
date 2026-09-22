import Dispatch
import Foundation
import CryptoKit
import HostwrightScheduler

private final class Phase10SchedulerQualificationBundleAnchor: NSObject {}

enum Phase10SchedulerQualificationPerformance {
    static let recordSchema = "hostwright.phase10.scheduler.qualification.performance.v2"

    struct MeasurementSession {
        let record: Record
        let input: SchedulerEngineInput
        let transcript: MeasurementTranscript

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
