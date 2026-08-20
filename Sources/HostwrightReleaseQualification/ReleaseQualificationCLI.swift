import Foundation
import HostwrightCore

public enum ReleaseQualificationCLICommand: String, Codable, Sendable {
    case plan
    case detect
    case verify
    case status
    case resume
    case version
    case help
}

public enum ReleaseQualificationCLIError: Error, Equatable, Sendable, CustomStringConvertible {
    case usage(String)
    case blocked(String)
    case failed(String)
    case stale(String)

    public var description: String {
        switch self {
        case .usage(let detail): "usage: \(detail)"
        case .blocked(let detail): "blocked: \(detail)"
        case .failed(let detail): "failed: \(detail)"
        case .stale(let detail): "stale: \(detail)"
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .blocked: 69
        case .failed: 70
        case .stale: 75
        }
    }
}

public struct ReleaseQualificationCLIInvocation: Equatable, Sendable {
    public let command: ReleaseQualificationCLICommand
    public let rootPath: String?
    public let ledgerRootPath: String?
    public let cellID: String?
    public let laneID: String?
    public let runID: String?

    public init(arguments: [String]) throws {
        guard !arguments.isEmpty, arguments.count <= 32 else {
            throw ReleaseQualificationCLIError.usage(Self.usage)
        }
        guard arguments.allSatisfy({
            !$0.isEmpty &&
                $0.utf8.count <= ReleaseQualificationLimits.maximumCommandArgumentBytes &&
                $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw ReleaseQualificationCLIError.usage("arguments are empty, oversized, or contain control characters")
        }
        guard let command = ReleaseQualificationCLICommand(rawValue: arguments[0]) else {
            throw ReleaseQualificationCLIError.usage(Self.usage)
        }
        self.command = command

        var rootPath: String?
        var ledgerRootPath: String?
        var cellID: String?
        var laneID: String?
        var runID: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--root", "--ledger-root", "--cell", "--lane", "--run-id":
                guard index + 1 < arguments.count else {
                    throw ReleaseQualificationCLIError.usage("missing value for \(argument)")
                }
                let value = arguments[index + 1]
                guard !value.hasPrefix("-") else {
                    throw ReleaseQualificationCLIError.usage("invalid value for \(argument)")
                }
                switch argument {
                case "--root":
                    guard rootPath == nil else {
                        throw ReleaseQualificationCLIError.usage("duplicate --root")
                    }
                    rootPath = value
                case "--ledger-root":
                    guard ledgerRootPath == nil else {
                        throw ReleaseQualificationCLIError.usage("duplicate --ledger-root")
                    }
                    ledgerRootPath = value
                case "--cell":
                    guard cellID == nil else {
                        throw ReleaseQualificationCLIError.usage("duplicate --cell")
                    }
                    cellID = value
                case "--lane":
                    guard laneID == nil else {
                        throw ReleaseQualificationCLIError.usage("duplicate --lane")
                    }
                    laneID = value
                case "--run-id":
                    guard runID == nil else {
                        throw ReleaseQualificationCLIError.usage("duplicate --run-id")
                    }
                    runID = value
                default:
                    throw ReleaseQualificationCLIError.usage(Self.usage)
                }
                index += 2
            case "--help":
                guard command == .help else {
                    throw ReleaseQualificationCLIError.usage("--help must be the command")
                }
                index += 1
            default:
                throw ReleaseQualificationCLIError.usage("unknown option \(argument)")
            }
        }
        self.rootPath = rootPath
        self.ledgerRootPath = ledgerRootPath
        self.cellID = cellID
        self.laneID = laneID
        self.runID = runID
        try validateCombination()
    }

    public static let usage =
        "hostwright-release-qualify <plan|detect|verify|status|resume|version|help> " +
        "[--root PATH] [--ledger-root PATH] [--cell ID|--lane ID] [--run-id ID]"

    private func validateCombination() throws {
        switch command {
        case .plan:
            guard cellID == nil, laneID == nil, runID == nil, ledgerRootPath == nil else {
                throw ReleaseQualificationCLIError.usage("plan accepts only --root")
            }
        case .detect:
            guard cellID == nil, laneID == nil, runID == nil, ledgerRootPath == nil else {
                throw ReleaseQualificationCLIError.usage("detect accepts only --root")
            }
        case .verify:
            guard (cellID == nil) != (laneID == nil) else {
                throw ReleaseQualificationCLIError.usage(
                    "verify requires exactly one of --cell ID or --lane ID"
                )
            }
            if let cellID {
                guard ReleaseQualificationSupportedMatrix.committed.cell(id: cellID) != nil else {
                    throw ReleaseQualificationCLIError.usage(
                        "verify cell is not present in the committed compatibility matrix"
                    )
                }
            }
            if let laneID {
                guard ReleaseQualificationDefaultRegistry.registry.lanes.contains(
                    where: { $0.id == laneID }
                ) else {
                    throw ReleaseQualificationCLIError.usage(
                        "verify lane is not present in the committed qualification registry"
                    )
                }
            }
            if ledgerRootPath != nil {
                guard runID != nil else {
                    throw ReleaseQualificationCLIError.usage(
                        "verify with --ledger-root requires an explicit --run-id"
                    )
                }
            } else {
                guard runID == nil else {
                    throw ReleaseQualificationCLIError.usage(
                        "--run-id is only valid with --ledger-root"
                    )
                }
            }
        case .status:
            guard ledgerRootPath != nil, rootPath == nil, cellID == nil, laneID == nil else {
                throw ReleaseQualificationCLIError.usage(
                    "status requires --ledger-root and accepts only optional --run-id"
                )
            }
        case .resume:
            guard ledgerRootPath != nil, rootPath == nil, cellID == nil, laneID == nil,
                  runID == nil else {
                throw ReleaseQualificationCLIError.usage(
                    "resume requires --ledger-root and accepts no other option"
                )
            }
        case .version, .help:
            guard rootPath == nil, ledgerRootPath == nil, cellID == nil, laneID == nil,
                  runID == nil else {
                throw ReleaseQualificationCLIError.usage(
                    "\(command.rawValue) does not accept options"
                )
            }
        }
    }
}

public struct ReleaseQualificationCLIResumeReport: Codable, Equatable, Sendable {
    public let recoveredRunIDs: [String]
    public let summary: ReleaseQualificationLedgerSummary

    public init(recoveredRunIDs: [String], summary: ReleaseQualificationLedgerSummary) {
        self.recoveredRunIDs = recoveredRunIDs.sorted()
        self.summary = summary
    }
}

public struct ReleaseQualificationCLIVersion: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let tool: String
    public let releaseTarget: String

    public init() {
        schemaVersion = ReleaseQualificationLimits.schemaVersion
        tool = "hostwright-release-qualify"
        releaseTarget = ReleaseQualificationSupportedMatrix.committed.releaseTarget
    }
}

enum ReleaseQualificationLaneEvidenceStatus {
    static func resolve(
        executionStatus: ReleaseQualificationOutcomeStatus,
        sourceAvailability: ReleaseQualificationFactStatus,
        sourceDirty: Bool?,
        sourceChangedDuringExecution: Bool = false
    ) -> ReleaseQualificationOutcomeStatus {
        if sourceAvailability != .available {
            return executionStatus == .passed || executionStatus == .dirty
                ? .unavailable
                : executionStatus
        }
        if sourceChangedDuringExecution,
           executionStatus == .passed || executionStatus == .dirty {
            return .stale
        }
        if sourceDirty == true, executionStatus == .passed {
            return .dirty
        }
        return executionStatus
    }
}

enum ReleaseQualificationLocalLaneEvidenceClass {
    static func resolve(for lane: ReleaseQualificationLane) throws -> HostwrightEvidenceClass {
        let expected: HostwrightEvidenceClass
        switch lane.id {
        case "dependency-lock-integrity",
             "documentation-source-contracts",
             "license-policy":
            expected = .localIntegration
        case "secret-scan":
            expected = .securityAssessment
        default:
            throw ReleaseQualificationContractError.invalid(
                field: "lane.id",
                reason: "no local evidence producer is bound to this lane"
            )
        }
        guard lane.requiredEvidenceClasses.contains(expected) else {
            throw ReleaseQualificationContractError.invalid(
                field: "lane.requiredEvidenceClasses",
                reason: "local lane producer evidence class is not declared"
            )
        }
        return expected
    }
}

public struct ReleaseQualificationCLIExecutor: Sendable {
    private let detector: ReleaseQualificationEnvironmentDetector
    private let localLaneRunner: ReleaseQualificationLocalLaneRunner

    public init(
        detector: ReleaseQualificationEnvironmentDetector = .init(),
        localLaneRunner: ReleaseQualificationLocalLaneRunner = .init()
    ) {
        self.detector = detector
        self.localLaneRunner = localLaneRunner
    }

    public func execute(
        _ invocation: ReleaseQualificationCLIInvocation,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> Data {
        switch invocation.command {
        case .help:
            return Data(Self.helpText.utf8)
        case .version:
            return try ReleaseQualificationJSON.encode(ReleaseQualificationCLIVersion())
        case .plan:
            let root = try resolveSourceRoot(invocation.rootPath, currentDirectory: currentDirectory)
            let environment = try detect(root: root)
            return try ReleaseQualificationJSON.encode(
                ReleaseQualificationRegistryPlanner().plan(
                    sourceRoot: root,
                    environment: environment
                )
            )
        case .detect:
            let root = try resolveSourceRoot(invocation.rootPath, currentDirectory: currentDirectory)
            let environment = try detect(root: root)
            let evaluations = ReleaseQualificationSupportedMatrix.committed.cells.map {
                ReleaseQualificationEnvironmentEvaluator().evaluate(
                    cell: $0,
                    environment: environment
                )
            }
            return try ReleaseQualificationJSON.encode(
                ReleaseQualificationDetectionDocument(
                    environment: environment,
                    evaluations: evaluations
                )
            )
        case .verify:
            return try executeVerify(invocation, currentDirectory: currentDirectory)
        case .status:
            return try executeStatus(invocation, currentDirectory: currentDirectory)
        case .resume:
            return try executeResume(invocation, currentDirectory: currentDirectory)
        }
    }

    private func executeVerify(
        _ invocation: ReleaseQualificationCLIInvocation,
        currentDirectory: URL
    ) throws -> Data {
        if invocation.laneID != nil {
            return try executeLaneVerify(invocation, currentDirectory: currentDirectory)
        }
        let root = try resolveSourceRoot(invocation.rootPath, currentDirectory: currentDirectory)
        let environment = try detect(root: root)
        guard let cellID = invocation.cellID,
              let cell = ReleaseQualificationSupportedMatrix.committed.cell(id: cellID) else {
            throw ReleaseQualificationCLIError.usage(
                "verify cell is not present in the committed compatibility matrix"
            )
        }
        var evaluation = ReleaseQualificationEnvironmentEvaluator().evaluate(
            cell: cell,
            environment: environment
        )
        if cell.executionMode != .safeLocal || cell.authority != .local {
            evaluation = withAdditional(
                evaluation,
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: .missingExplicitAuthority,
                        field: "claim.provider",
                        detail: "Phase 08 authority is released, but this executable still requires an explicit live/heavy provider"
                    )
                ],
                status: nil,
                failures: []
            )
        }
        let claim = ReleaseQualificationClaim(
            id: "matrix.\(cell.id)",
            title: cell.claim,
            matrixCellID: cell.id,
            executionMode: cell.executionMode,
            authority: cell.authority,
            requiredEvidenceClasses: cell.requiredEvidenceClasses
        )
        let status = evaluation.status
        let commandHashes =
            environment.commands.flatMap {
                [$0.standardOutputSHA256, $0.standardErrorSHA256]
            }
        let runID = invocation.runID ?? "nonledger-\(cell.id)"
        let replayKey = try ReleaseQualificationLedgerStore.replayKey(
            claim: claim,
            environment: environment,
            commands: environment.commands
        )
        let evidence = ReleaseQualificationEvidence(
            runID: runID,
            claim: claim,
            evidenceClass: cell.requiredEvidenceClasses[0],
            status: status,
            simulation: .real,
            source: environment.source,
            environment: environment,
            startedAt: ReleaseQualificationTimestamp(),
            endedAt: ReleaseQualificationTimestamp(),
            durationMilliseconds: 0,
            commands: environment.commands,
            rawOutputSHA256: commandHashes,
            artifacts: [],
            blockers: evaluation.blockers,
            failures: [],
            replayKey: replayKey
        )
        try evidence.validate()
        if let ledgerRootPath = invocation.ledgerRootPath {
            let ledger = try ReleaseQualificationLedgerStore(
                root: try resolveLedgerRoot(ledgerRootPath, currentDirectory: currentDirectory)
            )
            _ = try ledger.begin(
                runID: runID,
                claim: claim,
                replayKey: replayKey
            )
            _ = try ledger.complete(runID: runID, evidence: evidence)
        }
        return try ReleaseQualificationJSON.encode(evidence)
    }

    private func executeLaneVerify(
        _ invocation: ReleaseQualificationCLIInvocation,
        currentDirectory: URL
    ) throws -> Data {
        let root = try resolveSourceRoot(invocation.rootPath, currentDirectory: currentDirectory)
        let environment = try detect(root: root)
        guard let laneID = invocation.laneID,
              let lane = ReleaseQualificationDefaultRegistry.registry.lanes.first(
                  where: { $0.id == laneID }
              ) else {
            throw ReleaseQualificationCLIError.usage(
                "verify lane is not present in the committed qualification registry"
            )
        }
        guard let sourceCommit = environment.source.commit else {
            throw ReleaseQualificationCLIError.blocked(
                "local qualification requires an exact source commit"
            )
        }
        let evidenceClass = try ReleaseQualificationLocalLaneEvidenceClass.resolve(for: lane)
        let execution = try localLaneRunner.run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: sourceCommit
        )
        let postExecutionSource = try detector.detectSourceState(sourceRoot: root)
        let sourceAvailableThroughout =
            environment.source.availability.status == .available &&
            postExecutionSource.source.availability.status == .available
        let sourceChangedDuringExecution =
            sourceAvailableThroughout && postExecutionSource.source != environment.source
        var blockers = execution.blockers
        let status = ReleaseQualificationLaneEvidenceStatus.resolve(
            executionStatus: execution.status,
            sourceAvailability: sourceAvailableThroughout ? .available : .unavailable,
            sourceDirty: environment.source.dirty,
            sourceChangedDuringExecution: sourceChangedDuringExecution
        )
        if !sourceAvailableThroughout {
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .sourceCommitUnavailable,
                    field: "environment.source",
                    detail: "source identity was unavailable before or after lane execution"
                )
            )
        } else if environment.source.dirty == true {
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .dirtySource,
                    field: "environment.source",
                    detail: "dirty source cannot satisfy a release qualification lane"
                )
            )
        }
        if sourceChangedDuringExecution {
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .staleEvidence,
                    field: "environment.source",
                    detail: "source identity changed while the qualification lane was executing"
                )
            )
        }
        blockers = Array(Set(blockers)).sorted {
            ($0.field, $0.reason.rawValue, $0.detail) <
                ($1.field, $1.reason.rawValue, $1.detail)
        }
        let claim = ReleaseQualificationClaim(
            id: "lane.\(lane.id)",
            title: lane.target,
            matrixCellID: nil,
            executionMode: lane.executionMode,
            authority: lane.authority,
            requiredEvidenceClasses: lane.requiredEvidenceClasses
        )
        let commands = environment.commands + execution.commands + postExecutionSource.commands
        let replayKey = try ReleaseQualificationLedgerStore.replayKey(
            claim: claim,
            environment: environment,
            commands: commands
        )
        let timestamp = ReleaseQualificationTimestamp()
        let evidence = ReleaseQualificationEvidence(
            runID: invocation.runID ?? "nonledger-lane-\(lane.id)",
            claim: claim,
            evidenceClass: evidenceClass,
            status: status,
            simulation: .real,
            source: environment.source,
            environment: environment,
            startedAt: commands.first?.startedAt ?? timestamp,
            endedAt: commands.last?.endedAt ?? timestamp,
            durationMilliseconds: commands.reduce(0) { partial, command in
                partial + command.durationMilliseconds
            },
            commands: commands,
            rawOutputSHA256: commands.flatMap {
                [$0.standardOutputSHA256, $0.standardErrorSHA256]
            },
            artifacts: [],
            blockers: blockers,
            failures: execution.failures,
            replayKey: replayKey
        )
        try evidence.validate()
        if let ledgerRootPath = invocation.ledgerRootPath {
            let ledger = try ReleaseQualificationLedgerStore(
                root: try resolveLedgerRoot(
                    ledgerRootPath,
                    currentDirectory: currentDirectory
                )
            )
            _ = try ledger.begin(
                runID: evidence.runID,
                claim: claim,
                replayKey: replayKey
            )
            _ = try ledger.complete(runID: evidence.runID, evidence: evidence)
        }
        return try ReleaseQualificationJSON.encode(evidence)
    }

    private func executeStatus(
        _ invocation: ReleaseQualificationCLIInvocation,
        currentDirectory: URL
    ) throws -> Data {
        guard let path = invocation.ledgerRootPath else {
            throw ReleaseQualificationCLIError.usage("status requires --ledger-root")
        }
        let ledger = try ReleaseQualificationLedgerStore(
            root: try resolveLedgerRoot(path, currentDirectory: currentDirectory),
            createIfMissing: false
        )
        if let runID = invocation.runID {
            return try ReleaseQualificationJSON.encode(ledger.journal(runID: runID))
        }
        return try ReleaseQualificationJSON.encode(try ledger.summary())
    }

    private func executeResume(
        _ invocation: ReleaseQualificationCLIInvocation,
        currentDirectory: URL
    ) throws -> Data {
        guard let path = invocation.ledgerRootPath else {
            throw ReleaseQualificationCLIError.usage("resume requires --ledger-root")
        }
        let ledger = try ReleaseQualificationLedgerStore(
            root: try resolveLedgerRoot(path, currentDirectory: currentDirectory),
            createIfMissing: false
        )
        let recovered = try ledger.recover()
        return try ReleaseQualificationJSON.encode(
            ReleaseQualificationCLIResumeReport(
                recoveredRunIDs: recovered,
                summary: try ledger.summary()
            )
        )
    }

    private func detect(root: URL) throws -> ReleaseQualificationDetectedEnvironment {
        do {
            return try detector.detect(sourceRoot: root)
        } catch let error as ReleaseQualificationContractError {
            throw ReleaseQualificationCLIError.blocked(error.description)
        } catch {
            throw ReleaseQualificationCLIError.failed(error.localizedDescription)
        }
    }

    private func resolveSourceRoot(
        _ value: String?,
        currentDirectory: URL
    ) throws -> URL {
        let root = try resolvePath(value, currentDirectory: currentDirectory)
        guard try ReleaseQualificationFile.isDirectory(root) else {
            throw ReleaseQualificationCLIError.usage("source root is not a directory")
        }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path else {
            throw ReleaseQualificationCLIError.usage("source root must not be a symbolic link")
        }
        return root
    }

    private func resolveLedgerRoot(
        _ value: String,
        currentDirectory: URL
    ) throws -> URL {
        let root = try resolvePath(value, currentDirectory: currentDirectory)
        guard root.path != "/" else {
            throw ReleaseQualificationCLIError.usage("ledger root must not be the filesystem root")
        }
        return root
    }

    private func resolvePath(
        _ value: String?,
        currentDirectory: URL
    ) throws -> URL {
        let path = value ?? currentDirectory.path
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : currentDirectory.appendingPathComponent(path)
        let standardized = url.standardizedFileURL
        guard ReleaseQualificationPath.isNormalizedAbsolute(standardized.path) else {
            throw ReleaseQualificationCLIError.usage("path is not normalized and absolute")
        }
        return standardized
    }

    private func withAdditional(
        _ evaluation: ReleaseQualificationEvaluation,
        blockers: [ReleaseQualificationBlocker],
        status: ReleaseQualificationOutcomeStatus?,
        failures: [String]
    ) -> ReleaseQualificationEvaluation {
        let merged = Array(Set(evaluation.blockers + blockers)).sorted {
            ($0.field, $0.reason.rawValue, $0.detail) <
                ($1.field, $1.reason.rawValue, $1.detail)
        }
        let finalStatus = status ?? {
            if evaluation.status == .dirty { return ReleaseQualificationOutcomeStatus.dirty }
            if evaluation.status == .unavailable { return .unavailable }
            return merged.isEmpty ? .passed : .blocked
        }()
        return ReleaseQualificationEvaluation(
            cellID: evaluation.cellID,
            status: finalStatus,
            blockers: merged,
            matched: merged.isEmpty
        )
    }

    private static let helpText =
        "hostwright-release-qualify plan|detect|verify|status|resume|version|help\n" +
        "  plan    print the committed matrix and bounded gate plan\n" +
        "  detect  detect local facts and evaluate committed matrix cells\n" +
        "  verify  produce cell evidence or run one bounded local lane\n" +
        "  status  read a private ledger journal or summary\n" +
        "  resume  recover interrupted private ledger journals\n"
}
