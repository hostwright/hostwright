import Foundation
import HostwrightCore

public enum CLICommand: Equatable, Sendable {
    case version
    case initManifest
    case validate(path: String)
    case plan(path: String, output: CLIOutputFormat)
    case status(path: String, stateDatabasePath: String?, output: CLIOutputFormat)
    case apply(path: String, stateDatabasePath: String, confirmedPlanHash: String)
    case logs(serviceName: String, path: String, tail: Int, stateDatabasePath: String?)
    case events(stateDatabasePath: String, projectName: String?, output: CLIOutputFormat)
    case recovery(stateDatabasePath: String, projectName: String?, output: CLIOutputFormat)
    case cleanup(path: String, stateDatabasePath: String, confirmation: CleanupConfirmation)
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
        case "validate":
            return try pathCommand(arguments: arguments, commandName: "validate", make: CLICommand.validate)
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

    private static func pathCommand(arguments: [String], commandName: String, make: (String) -> CLICommand) throws -> CLICommand {
        if arguments.count == 1 {
            return make(HostwrightIdentity.manifestFileName)
        }

        if arguments.count == 2 {
            return make(arguments[1])
        }

        throw CLIUsageError("\(commandName) accepts at most one manifest path.")
    }

    private static func planCommand(arguments: [String]) throws -> CLICommand {
        let parsed = try parsePathAndOutput(arguments: arguments, commandName: "plan")
        return .plan(path: parsed.path ?? HostwrightIdentity.manifestFileName, output: parsed.output)
    }

    private static func applyCommand(arguments: [String]) throws -> CLICommand {
        var path: String?
        var stateDatabasePath: String?
        var confirmedPlanHash: String?
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

        return .apply(
            path: path ?? HostwrightIdentity.manifestFileName,
            stateDatabasePath: stateDatabasePath,
            confirmedPlanHash: confirmedPlanHash
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
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "events")
                index += 2
            default:
                throw CLIUsageError("events supports only --state-db, --project, and --output.")
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("events requires --state-db <path>.")
        }
        return .events(stateDatabasePath: stateDatabasePath, projectName: projectName, output: output)
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

    private static func parsePathAndOutput(arguments: [String], commandName: String) throws -> (path: String?, output: CLIOutputFormat) {
        var path: String?
        var output: CLIOutputFormat = .text
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: commandName)
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
        return (path, output)
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

        return .cleanup(
            path: path ?? HostwrightIdentity.manifestFileName,
            stateDatabasePath: stateDatabasePath,
            confirmation: dryRun ? .dryRun : .confirmed(token: confirmationToken ?? "")
        )
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
        case .commandUsage, .fileAlreadyExists:
            return .commandUsage
        case .confirmationMismatch:
            return .confirmationMismatch
        case .partialFailure:
            return .partialFailure
        case .manifestParseFailed, .manifestValidationFailed, .manifestUnsupportedFeature, .manifestFileIOFailed:
            return .validation
        case .stateStoreUnavailable:
            return .stateUnavailable
        case .runtimeUnavailable, .runtimeMutationNotImplemented:
            return .runtimeUnavailable
        case .unsafeExposure:
            return .unsafeOperation
        case .unsupportedArchitecture, .unsupportedMacOSVersion:
            return .validation
        }
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
