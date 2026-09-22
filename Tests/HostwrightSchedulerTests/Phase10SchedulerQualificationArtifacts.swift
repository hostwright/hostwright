import Foundation
import HostwrightScheduler

#if canImport(Darwin)
import Darwin
#endif

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
