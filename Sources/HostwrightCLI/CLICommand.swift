import Foundation
import HostwrightCore

public enum CLICommand: Equatable, Sendable {
    case version
    case initManifest
    case validate(path: String)
    case plan(path: String)
    case status(path: String, stateDatabasePath: String?)
    case apply(path: String, stateDatabasePath: String, confirmedPlanHash: String)
    case logs(serviceName: String, path: String, tail: Int, stateDatabasePath: String?)
    case events(stateDatabasePath: String, projectName: String?)
    case cleanup(path: String, stateDatabasePath: String, confirmation: CleanupConfirmation)
    case doctor
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
            return try pathCommand(arguments: arguments, commandName: "plan", make: CLICommand.plan)
        case "status":
            return try statusCommand(arguments: arguments)
        case "apply":
            return try applyCommand(arguments: arguments)
        case "logs":
            return try logsCommand(arguments: arguments)
        case "events":
            return try eventsCommand(arguments: arguments)
        case "cleanup":
            return try cleanupCommand(arguments: arguments)
        case "doctor":
            guard arguments.count == 1 else { throw CLIUsageError("doctor does not accept arguments.") }
            return .doctor
        default:
            throw CLIUsageError("Unknown command '\(first)'.")
        }
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

        return .status(path: path ?? HostwrightIdentity.manifestFileName, stateDatabasePath: stateDatabasePath)
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
            default:
                throw CLIUsageError("events supports only --state-db and --project.")
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("events requires --state-db <path>.")
        }
        return .events(stateDatabasePath: stateDatabasePath, projectName: projectName)
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
