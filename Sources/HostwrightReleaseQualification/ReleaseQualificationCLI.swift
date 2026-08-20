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
    public let runID: String?
    public let executeSafeChecks: Bool

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
        var runID: String?
        var executeSafeChecks = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--execute-safe-checks":
                guard !executeSafeChecks else {
                    throw ReleaseQualificationCLIError.usage("duplicate --execute-safe-checks")
                }
                executeSafeChecks = true
                index += 1
            case "--root", "--ledger-root", "--cell", "--run-id":
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
        self.runID = runID
        self.executeSafeChecks = executeSafeChecks
        try validateCombination()
    }

    public static let usage =
        "hostwright-release-qualify <plan|detect|verify|status|resume|version|help> " +
        "[--root PATH] [--ledger-root PATH] [--cell ID] [--run-id ID] [--execute-safe-checks]"

    private func validateCombination() throws {
        switch command {
        case .plan:
            guard cellID == nil, runID == nil, ledgerRootPath == nil, !executeSafeChecks else {
                throw ReleaseQualificationCLIError.usage("plan accepts only --root")
            }
        case .detect:
            guard cellID == nil, runID == nil, ledgerRootPath == nil, !executeSafeChecks else {
                throw ReleaseQualificationCLIError.usage("detect accepts only --root")
            }
        case .verify:
            guard cellID != nil else {
                throw ReleaseQualificationCLIError.usage("verify requires --cell ID")
            }
            guard let cellID,
                  ReleaseQualificationSupportedMatrix.committed.cell(id: cellID) != nil else {
                throw ReleaseQualificationCLIError.usage(
                    "verify cell is not present in the committed compatibility matrix"
                )
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
            guard ledgerRootPath != nil, rootPath == nil, cellID == nil, !executeSafeChecks else {
                throw ReleaseQualificationCLIError.usage(
                    "status requires --ledger-root and accepts only optional --run-id"
                )
            }
        case .resume:
            guard ledgerRootPath != nil, rootPath == nil, cellID == nil, runID == nil,
                  !executeSafeChecks else {
                throw ReleaseQualificationCLIError.usage(
                    "resume requires --ledger-root and accepts no other option"
                )
            }
        case .version, .help:
            guard rootPath == nil, ledgerRootPath == nil, cellID == nil,
                  runID == nil, !executeSafeChecks else {
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

public struct ReleaseQualificationCLIExecutor: Sendable {
    private let detector: ReleaseQualificationEnvironmentDetector

    public init(detector: ReleaseQualificationEnvironmentDetector = .init()) {
        self.detector = detector
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
            return try ReleaseQualificationJSON.encode(
                ReleaseQualificationRegistryPlanner().plan(sourceRoot: root)
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
        var safeCheckFailures: [String] = []
        if invocation.executeSafeChecks {
            let safeChecks = try ReleaseQualificationSafeCheckRunner().run(sourceRoot: root)
            for result in safeChecks {
                if result.status == .failed {
                    safeCheckFailures.append(contentsOf: result.failures)
                    evaluation = withAdditional(
                        evaluation,
                        blockers: result.blockers,
                        status: nil,
                        failures: []
                    )
                } else if result.status == .blocked || result.status == .unavailable {
                    evaluation = withAdditional(
                        evaluation,
                        blockers: result.blockers,
                        status: nil,
                        failures: []
                    )
                }
            }
        }
        if cell.executionMode != .safeLocal || cell.authority != .local {
            evaluation = withAdditional(
                evaluation,
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: .liveRuntimePhase08Boundary,
                        field: "claim.authority",
                        detail: "live/heavy qualification requires an explicit future provider and Phase 08 release"
                    ),
                    ReleaseQualificationBlocker(
                        reason: .missingExplicitAuthority,
                        field: "claim.provider",
                        detail: "this executable never starts a live runtime or provider"
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
            status: safeCheckFailures.isEmpty ? status : .failed,
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
            failures: safeCheckFailures.sorted(),
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
        "  verify  produce bound evidence; live/heavy cells remain blocked\n" +
        "  status  read a private ledger journal or summary\n" +
        "  resume  recover interrupted private ledger journals\n"
}
