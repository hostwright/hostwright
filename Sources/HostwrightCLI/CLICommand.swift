import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

public enum CLICommand: Equatable, Sendable {
    case version
    case initManifest
    case importStack(path: String, output: CLIOutputFormat, teamProfilePath: String?)
    case validate(path: String, teamProfilePath: String?)
    case plan(path: String, output: CLIOutputFormat, teamProfilePath: String?)
    case status(path: String, stateDatabasePath: String?, output: CLIOutputFormat)
    case apply(path: String, stateDatabasePath: String, confirmedPlanHash: String, teamProfilePath: String?, approvalRecordPath: String?)
    case logs(serviceName: String, path: String, tail: Int, stateDatabasePath: String?)
    case events(stateDatabasePath: String, projectName: String?, filters: EventFilters, output: CLIOutputFormat)
    case recovery(stateDatabasePath: String, projectName: String?, output: CLIOutputFormat)
    case cleanup(path: String, stateDatabasePath: String, confirmation: CleanupConfirmation, teamProfilePath: String?, approvalRecordPath: String?)
    case diagnostics(stateDatabasePath: String, bundlePath: String, projectName: String?, manifestPath: String?)
    case benchmark(options: BenchmarkCLIOptions)
    case extensionCheck(declarationPath: String, executablePath: String, output: CLIOutputFormat)
    case doctor(output: CLIOutputFormat)
    case help

    public static func parse(arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else {
            return .help
        }

        switch first {
        case "--version", "version":
            guard arguments.count == 1 else { throw CLIUsageError("version does not accept arguments.") }
            return .version
        case "--help", "-h", "help":
            guard arguments.count == 1 else { throw CLIUsageError("help does not accept arguments.") }
            return .help
        case "init":
            guard arguments.count == 1 else { throw CLIUsageError("init does not support flags.") }
            return .initManifest
        case "import-stack":
            return try importStackCommand(arguments: arguments)
        case "validate":
            return try validateCommand(arguments: arguments)
        case "plan":
            return try planCommand(arguments: arguments)
        case "status":
            return try statusCommand(arguments: arguments)
        case "apply":
            return try applyCommand(arguments: arguments)
        case "logs":
            return try logsCommand(arguments: arguments)
        case "events":
            return try eventsCommand(arguments: arguments)
        case "recovery":
            return try recoveryCommand(arguments: arguments)
        case "cleanup":
            return try cleanupCommand(arguments: arguments)
        case "diagnostics":
            return try diagnosticsCommand(arguments: arguments)
        case "benchmark":
            return try benchmarkCommand(arguments: arguments)
        case "extension":
            return try extensionCommand(arguments: arguments)
        case "doctor":
            return try doctorCommand(arguments: arguments)
        default:
            throw CLIUsageError("Unknown command '\(first)'.")
        }
    }

    public static func outputFormatHint(arguments: [String]) -> CLIOutputFormat? {
        guard let outputIndex = arguments.firstIndex(of: "--output"),
              arguments.indices.contains(arguments.index(after: outputIndex))
        else {
            return nil
        }
        return CLIOutputFormat(rawValue: arguments[arguments.index(after: outputIndex)])
    }

    private static func validateCommand(arguments: [String]) throws -> CLICommand {
        let parsed = try parsePathOutputAndProfile(arguments: arguments, commandName: "validate", supportsOutput: false)
        return .validate(path: parsed.path ?? HostwrightIdentity.manifestFileName, teamProfilePath: parsed.teamProfilePath)
    }

    private static func extensionCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2, arguments[1] == "check" else {
            throw CLIUsageError("extension supports only 'check'.")
        }

        var declarationPath: String?
        var executablePath: String?
        var output: CLIOutputFormat = .text
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--declaration":
                declarationPath = try parseUniquePathValue(
                    arguments: arguments,
                    index: index,
                    commandName: "extension check",
                    flag: "--declaration",
                    existing: declarationPath
                )
                index += 2
            case "--executable":
                executablePath = try parseUniquePathValue(
                    arguments: arguments,
                    index: index,
                    commandName: "extension check",
                    flag: "--executable",
                    existing: executablePath
                )
                index += 2
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "extension check")
                index += 2
            default:
                throw CLIUsageError("extension check supports only --declaration, --executable, and --output.")
            }
        }

        guard let declarationPath else {
            throw CLIUsageError("extension check requires --declaration <absolute-path>.")
        }
        guard let executablePath else {
            throw CLIUsageError("extension check requires --executable <absolute-path>.")
        }
        guard declarationPath.hasPrefix("/"), executablePath.hasPrefix("/") else {
            throw CLIUsageError("extension check requires absolute declaration and executable paths.")
        }
        return .extensionCheck(
            declarationPath: declarationPath,
            executablePath: executablePath,
            output: output
        )
    }

    private static func planCommand(arguments: [String]) throws -> CLICommand {
        let parsed = try parsePathOutputAndProfile(arguments: arguments, commandName: "plan")
        return .plan(
            path: parsed.path ?? HostwrightIdentity.manifestFileName,
            output: parsed.output,
            teamProfilePath: parsed.teamProfilePath
        )
    }

    private static func importStackCommand(arguments: [String]) throws -> CLICommand {
        let parsed = try parsePathOutputAndProfile(arguments: arguments, commandName: "import-stack")
        guard let path = parsed.path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("import-stack requires a stack file path.")
        }
        return .importStack(path: path, output: parsed.output, teamProfilePath: parsed.teamProfilePath)
    }

    private static func applyCommand(arguments: [String]) throws -> CLICommand {
        var path: String?
        var stateDatabasePath: String?
        var confirmedPlanHash: String?
        var teamProfilePath: String?
        var approvalRecordPath: String?
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--state-db":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("apply requires a value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--confirm-plan":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("apply requires a value after --confirm-plan.")
                }
                confirmedPlanHash = arguments[index + 1]
                index += 2
            case "--team-profile":
                teamProfilePath = try parseUniquePathValue(
                    arguments: arguments,
                    index: index,
                    commandName: "apply",
                    flag: "--team-profile",
                    existing: teamProfilePath
                )
                index += 2
            case "--approval-record":
                approvalRecordPath = try parseUniquePathValue(
                    arguments: arguments,
                    index: index,
                    commandName: "apply",
                    flag: "--approval-record",
                    existing: approvalRecordPath
                )
                index += 2
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIUsageError("apply does not support flag '\(argument)' in the confirmed single-action gate.")
                }
                guard path == nil else {
                    throw CLIUsageError("apply accepts at most one manifest path.")
                }
                path = argument
                index += 1
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("apply requires --state-db <path>. The confirmed single-action gate does not use a default state database path.")
        }

        guard let confirmedPlanHash, !confirmedPlanHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("apply requires --confirm-plan <hash>. Run plan/apply preview first and confirm the exact hash.")
        }
        try validateMutationTeamPaths(
            commandName: "apply",
            teamProfilePath: teamProfilePath,
            approvalRecordPath: approvalRecordPath,
            approvalRequired: teamProfilePath != nil
        )

        return .apply(
            path: path ?? HostwrightIdentity.manifestFileName,
            stateDatabasePath: stateDatabasePath,
            confirmedPlanHash: confirmedPlanHash,
            teamProfilePath: teamProfilePath,
            approvalRecordPath: approvalRecordPath
        )
    }

    private static func statusCommand(arguments: [String]) throws -> CLICommand {
        var path: String?
        var stateDatabasePath: String?
        var output: CLIOutputFormat = .text
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--state-db":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("status requires a value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "status")
                index += 2
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIUsageError("status does not support flag '\(argument)'.")
                }
                guard path == nil else {
                    throw CLIUsageError("status accepts at most one manifest path.")
                }
                path = argument
                index += 1
            }
        }

        return .status(path: path ?? HostwrightIdentity.manifestFileName, stateDatabasePath: stateDatabasePath, output: output)
    }

    private static func logsCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2 else {
            throw CLIUsageError("logs requires a service name.")
        }

        let serviceName = arguments[1]
        guard !serviceName.hasPrefix("-") else {
            throw CLIUsageError("logs requires a service name before flags.")
        }

        var path: String?
        var tail = 100
        var stateDatabasePath: String?
        var index = 2

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--tail":
                guard index + 1 < arguments.count, let parsed = Int(arguments[index + 1]), parsed > 0 else {
                    throw CLIUsageError("logs requires a positive integer after --tail.")
                }
                tail = min(parsed, 1_000)
                index += 2
            case "--state-db":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("logs requires a value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIUsageError("logs does not support flag '\(argument)'.")
                }
                guard path == nil else {
                    throw CLIUsageError("logs accepts at most one manifest path.")
                }
                path = argument
                index += 1
            }
        }

        return .logs(
            serviceName: serviceName,
            path: path ?? HostwrightIdentity.manifestFileName,
            tail: tail,
            stateDatabasePath: stateDatabasePath
        )
    }

    private static func eventsCommand(arguments: [String]) throws -> CLICommand {
        var stateDatabasePath: String?
        var projectName: String?
        var eventType: String?
        var serviceName: String?
        var severity: StateEventSeverity?
        var limit: Int?
        var sort: EventSortOrder = .ascending
        var output: CLIOutputFormat = .text
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("events requires a value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--project":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("events requires a value after --project.")
                }
                projectName = arguments[index + 1]
                index += 2
            case "--type":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("events requires a value after --type.")
                }
                eventType = arguments[index + 1]
                index += 2
            case "--service":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("events requires a value after --service.")
                }
                serviceName = arguments[index + 1]
                index += 2
            case "--severity":
                guard index + 1 < arguments.count, let parsed = StateEventSeverity(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("events --severity supports only 'info', 'warning', or 'error'.")
                }
                severity = parsed
                index += 2
            case "--limit":
                guard index + 1 < arguments.count, let parsed = Int(arguments[index + 1]), parsed > 0 else {
                    throw CLIUsageError("events requires a positive integer after --limit.")
                }
                limit = parsed
                index += 2
            case "--sort":
                guard index + 1 < arguments.count, let parsed = EventSortOrder(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("events --sort supports only 'asc' or 'desc'.")
                }
                sort = parsed
                index += 2
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "events")
                index += 2
            default:
                throw CLIUsageError("events supports only --state-db, --project, --type, --service, --severity, --limit, --sort, and --output.")
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("events requires --state-db <path>.")
        }
        return .events(
            stateDatabasePath: stateDatabasePath,
            projectName: projectName,
            filters: EventFilters(type: eventType, serviceName: serviceName, severity: severity, limit: limit, sort: sort),
            output: output
        )
    }

    private static func recoveryCommand(arguments: [String]) throws -> CLICommand {
        var stateDatabasePath: String?
        var projectName: String?
        var output: CLIOutputFormat = .text
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("recovery requires a value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--project":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("recovery requires a value after --project.")
                }
                projectName = arguments[index + 1]
                index += 2
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "recovery")
                index += 2
            default:
                throw CLIUsageError("recovery supports only --state-db, --project, and --output.")
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("recovery requires --state-db <path>.")
        }
        return .recovery(stateDatabasePath: stateDatabasePath, projectName: projectName, output: output)
    }

    private static func doctorCommand(arguments: [String]) throws -> CLICommand {
        var output: CLIOutputFormat = .text
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "doctor")
                index += 2
            default:
                throw CLIUsageError("doctor supports only --output.")
            }
        }
        return .doctor(output: output)
    }

    private static func benchmarkCommand(arguments: [String]) throws -> CLICommand {
        var image: String?
        var sampleCount: Int?
        var reportPath: String?
        var sourceCommit: String?
        var sourceDirty: Bool?
        var expectedContainerVersion: String?
        var attendedSleepWakeSeconds: Int?
        var confirmedLive = false
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--image":
                image = try benchmarkUniqueValue(arguments, index: index, flag: argument, existing: image)
                index += 2
            case "--samples":
                let value = try benchmarkUniqueValue(arguments, index: index, flag: argument, existing: sampleCount.map(String.init))
                guard let parsed = Int(value), (3...10).contains(parsed) else {
                    throw CLIUsageError("benchmark --samples requires an integer from 3 through 10.")
                }
                sampleCount = parsed
                index += 2
            case "--report":
                reportPath = try benchmarkUniqueValue(arguments, index: index, flag: argument, existing: reportPath)
                index += 2
            case "--source-commit":
                sourceCommit = try benchmarkUniqueValue(arguments, index: index, flag: argument, existing: sourceCommit)
                index += 2
            case "--source-dirty":
                let value = try benchmarkUniqueValue(arguments, index: index, flag: argument, existing: sourceDirty.map(String.init))
                guard value == "true" || value == "false" else {
                    throw CLIUsageError("benchmark --source-dirty supports only 'true' or 'false'.")
                }
                sourceDirty = value == "true"
                index += 2
            case "--expected-container-version":
                expectedContainerVersion = try benchmarkUniqueValue(
                    arguments,
                    index: index,
                    flag: argument,
                    existing: expectedContainerVersion
                )
                index += 2
            case "--attended-sleep-wake-seconds":
                let value = try benchmarkUniqueValue(
                    arguments,
                    index: index,
                    flag: argument,
                    existing: attendedSleepWakeSeconds.map(String.init)
                )
                guard let parsed = Int(value), (15...300).contains(parsed) else {
                    throw CLIUsageError("benchmark --attended-sleep-wake-seconds requires an integer from 15 through 300.")
                }
                attendedSleepWakeSeconds = parsed
                index += 2
            case "--confirm-live":
                guard !confirmedLive else {
                    throw CLIUsageError("benchmark accepts --confirm-live at most once.")
                }
                confirmedLive = true
                index += 1
            default:
                throw CLIUsageError("benchmark does not support argument '\(argument)'.")
            }
        }

        guard let image,
              let sampleCount,
              let reportPath,
              let sourceCommit,
              let sourceDirty,
              let expectedContainerVersion,
              confirmedLive else {
            throw CLIUsageError(
                "benchmark requires --image, --samples, --report, --source-commit, --source-dirty, --expected-container-version, and --confirm-live."
            )
        }
        guard sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
            throw CLIUsageError("benchmark --source-commit requires exactly 40 lowercase hexadecimal characters.")
        }
        guard sourceCommit != String(repeating: "0", count: 40) else {
            throw CLIUsageError("benchmark --source-commit cannot use the all-zero sentinel.")
        }
        guard AppleContainerVersionParser.isValidExpectedVersion(expectedContainerVersion) else {
            throw CLIUsageError("benchmark --expected-container-version requires an exact semantic version such as 1.0.0.")
        }
        guard BenchmarkImageReferencePolicy.isSafe(image) else {
            throw CLIUsageError("benchmark --image requires a credential-free OCI image reference without whitespace, URL syntax, or unsupported digest syntax.")
        }

        return .benchmark(
            options: BenchmarkCLIOptions(
                image: image,
                sampleCount: sampleCount,
                reportPath: reportPath,
                sourceCommit: sourceCommit,
                sourceDirty: sourceDirty,
                expectedContainerVersion: expectedContainerVersion,
                attendedSleepWakeSeconds: attendedSleepWakeSeconds,
                confirmedLive: true
            )
        )
    }

    private static func benchmarkUniqueValue(
        _ arguments: [String],
        index: Int,
        flag: String,
        existing: String?
    ) throws -> String {
        guard existing == nil else {
            throw CLIUsageError("benchmark accepts \(flag) at most once.")
        }
        guard index + 1 < arguments.count else {
            throw CLIUsageError("benchmark requires a value after \(flag).")
        }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-") else {
            throw CLIUsageError("benchmark requires a non-empty value after \(flag).")
        }
        return value
    }

    private static func parsePathOutputAndProfile(
        arguments: [String],
        commandName: String,
        supportsOutput: Bool = true
    ) throws -> (path: String?, output: CLIOutputFormat, teamProfilePath: String?) {
        var path: String?
        var output: CLIOutputFormat = .text
        var teamProfilePath: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                guard supportsOutput else {
                    throw CLIUsageError("\(commandName) does not support --output.")
                }
                output = try parseOutputValue(arguments: arguments, index: index, commandName: commandName)
                index += 2
            case "--team-profile":
                teamProfilePath = try parseUniquePathValue(
                    arguments: arguments,
                    index: index,
                    commandName: commandName,
                    flag: "--team-profile",
                    existing: teamProfilePath
                )
                index += 2
            default:
                let argument = arguments[index]
                guard !argument.hasPrefix("-") else {
                    throw CLIUsageError("\(commandName) does not support flag '\(argument)'.")
                }
                guard path == nil else {
                    throw CLIUsageError("\(commandName) accepts at most one manifest path.")
                }
                path = argument
                index += 1
            }
        }
        return (path, output, teamProfilePath)
    }

    private static func parseUniquePathValue(
        arguments: [String],
        index: Int,
        commandName: String,
        flag: String,
        existing: String?
    ) throws -> String {
        guard existing == nil else {
            throw CLIUsageError("\(commandName) accepts \(flag) at most once.")
        }
        guard index + 1 < arguments.count else {
            throw CLIUsageError("\(commandName) requires a value after \(flag).")
        }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-") else {
            throw CLIUsageError("\(commandName) requires a non-empty path after \(flag).")
        }
        return value
    }

    private static func validateMutationTeamPaths(
        commandName: String,
        teamProfilePath: String?,
        approvalRecordPath: String?,
        approvalRequired: Bool
    ) throws {
        if approvalRecordPath != nil, teamProfilePath == nil {
            throw CLIUsageError("\(commandName) requires --team-profile when --approval-record is present.")
        }
        if approvalRequired, approvalRecordPath == nil {
            throw CLIUsageError("\(commandName) requires --approval-record for a profile-aware confirmed mutation.")
        }
    }

    private static func parseOutputValue(arguments: [String], index: Int, commandName: String) throws -> CLIOutputFormat {
        guard index + 1 < arguments.count else {
            throw CLIUsageError("\(commandName) requires a value after --output.")
        }
        guard let output = CLIOutputFormat(rawValue: arguments[index + 1]) else {
            throw CLIUsageError("\(commandName) --output supports only 'text' or 'json'.")
        }
        return output
    }

    private static func cleanupCommand(arguments: [String]) throws -> CLICommand {
        var path: String?
        var stateDatabasePath: String?
        var dryRun = false
        var confirmationToken: String?
        var teamProfilePath: String?
        var approvalRecordPath: String?
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--state-db":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("cleanup requires a value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--dry-run":
                dryRun = true
                index += 1
            case "--confirm-cleanup":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("cleanup requires a value after --confirm-cleanup.")
                }
                confirmationToken = arguments[index + 1]
                index += 2
            case "--team-profile":
                teamProfilePath = try parseUniquePathValue(
                    arguments: arguments,
                    index: index,
                    commandName: "cleanup",
                    flag: "--team-profile",
                    existing: teamProfilePath
                )
                index += 2
            case "--approval-record":
                approvalRecordPath = try parseUniquePathValue(
                    arguments: arguments,
                    index: index,
                    commandName: "cleanup",
                    flag: "--approval-record",
                    existing: approvalRecordPath
                )
                index += 2
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIUsageError("cleanup does not support flag '\(argument)'.")
                }
                guard path == nil else {
                    throw CLIUsageError("cleanup accepts at most one manifest path.")
                }
                path = argument
                index += 1
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("cleanup requires --state-db <path>.")
        }
        guard dryRun != (confirmationToken != nil) else {
            throw CLIUsageError("cleanup requires exactly one of --dry-run or --confirm-cleanup <token>.")
        }
        if dryRun, approvalRecordPath != nil {
            throw CLIUsageError("cleanup --dry-run does not accept --approval-record; approve the exact emitted cleanup token before confirmed cleanup.")
        }
        try validateMutationTeamPaths(
            commandName: "cleanup",
            teamProfilePath: teamProfilePath,
            approvalRecordPath: approvalRecordPath,
            approvalRequired: confirmationToken != nil && teamProfilePath != nil
        )

        return .cleanup(
            path: path ?? HostwrightIdentity.manifestFileName,
            stateDatabasePath: stateDatabasePath,
            confirmation: dryRun ? .dryRun : .confirmed(token: confirmationToken ?? ""),
            teamProfilePath: teamProfilePath,
            approvalRecordPath: approvalRecordPath
        )
    }

    private static func diagnosticsCommand(arguments: [String]) throws -> CLICommand {
        var stateDatabasePath: String?
        var bundlePath: String?
        var projectName: String?
        var manifestPath: String?
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("diagnostics requires a value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--bundle":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("diagnostics requires a value after --bundle.")
                }
                bundlePath = arguments[index + 1]
                index += 2
            case "--project":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("diagnostics requires a value after --project.")
                }
                projectName = arguments[index + 1]
                index += 2
            case "--manifest":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("diagnostics requires a value after --manifest.")
                }
                manifestPath = arguments[index + 1]
                index += 2
            default:
                throw CLIUsageError("diagnostics supports only --state-db, --bundle, --project, and --manifest.")
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("diagnostics requires --state-db <path>.")
        }
        guard let bundlePath, !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("diagnostics requires --bundle <path>.")
        }
        return .diagnostics(stateDatabasePath: stateDatabasePath, bundlePath: bundlePath, projectName: projectName, manifestPath: manifestPath)
    }
}

public enum EventSortOrder: String, Equatable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

public struct EventFilters: Equatable, Sendable {
    public let type: String?
    public let serviceName: String?
    public let severity: StateEventSeverity?
    public let limit: Int?
    public let sort: EventSortOrder

    public init(type: String? = nil, serviceName: String? = nil, severity: StateEventSeverity? = nil, limit: Int? = nil, sort: EventSortOrder = .ascending) {
        self.type = type
        self.serviceName = serviceName
        self.severity = severity
        self.limit = limit
        self.sort = sort
    }
}

public enum CleanupConfirmation: Equatable, Sendable {
    case dryRun
    case confirmed(token: String)
}

public enum CLIOutputFormat: String, Equatable, Sendable {
    case text
    case json
}

public enum CLIExitCode: Int32, Equatable, Sendable {
    case success = 0
    case commandUsage = 64
    case validation = 65
    case stateUnavailable = 66
    case runtimeUnavailable = 69
    case confirmationMismatch = 70
    case unsafeOperation = 71
    case partialFailure = 72

    public static func mapped(from code: HostwrightErrorCode) -> CLIExitCode {
        switch code {
        case .commandUsage, .fileAlreadyExists, .fileIOFailed:
            return .commandUsage
        case .confirmationMismatch, .teamBindingMismatch:
            return .confirmationMismatch
        case .partialFailure:
            return .partialFailure
        case .manifestParseFailed, .manifestValidationFailed, .manifestUnsupportedFeature, .manifestFileIOFailed,
             .teamProfileInvalid, .teamApprovalInvalid:
            return .validation
        case .stateStoreUnavailable:
            return .stateUnavailable
        case .runtimeUnavailable, .runtimeMutationNotImplemented:
            return .runtimeUnavailable
        case .unsafeExposure:
            return .unsafeOperation
        case .benchmarkInvalid:
            return .validation
        case .benchmarkBlocked:
            return .runtimeUnavailable
        case .benchmarkFailed:
            return .partialFailure
        case .extensionInvalid:
            return .validation
        case .extensionBlocked:
            return .unsafeOperation
        case .extensionExecutionFailed:
            return .partialFailure
        case .controlAPIInvalid:
            return .validation
        case .controlAPIUnavailable:
            return .stateUnavailable
        case .controlAPIExecutionFailed:
            return .partialFailure
        case .unsupportedArchitecture, .unsupportedMacOSVersion:
            return .validation
        }
    }
}

public struct BenchmarkCLIOptions: Equatable, Sendable {
    public let image: String
    public let sampleCount: Int
    public let reportPath: String
    public let sourceCommit: String
    public let sourceDirty: Bool
    public let expectedContainerVersion: String
    public let attendedSleepWakeSeconds: Int?
    public let confirmedLive: Bool

    public init(
        image: String,
        sampleCount: Int,
        reportPath: String,
        sourceCommit: String,
        sourceDirty: Bool,
        expectedContainerVersion: String,
        attendedSleepWakeSeconds: Int? = nil,
        confirmedLive: Bool
    ) {
        self.image = image
        self.sampleCount = sampleCount
        self.reportPath = reportPath
        self.sourceCommit = sourceCommit
        self.sourceDirty = sourceDirty
        self.expectedContainerVersion = expectedContainerVersion
        self.attendedSleepWakeSeconds = attendedSleepWakeSeconds
        self.confirmedLive = confirmedLive
    }
}

public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public struct CLIRunResult: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32

    public init(standardOutput: String = "", standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}
