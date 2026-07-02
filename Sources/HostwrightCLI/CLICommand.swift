import Foundation
import HostwrightCore

public enum CLICommand: Equatable, Sendable {
    case version
    case initManifest
    case validate(path: String)
    case plan(path: String)
    case status(path: String)
    case apply(path: String, stateDatabasePath: String, confirmedPlanHash: String)
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
            guard arguments.count == 1 else { throw CLIUsageError("init does not support flags in Phase 2.") }
            return .initManifest
        case "validate":
            return try pathCommand(arguments: arguments, commandName: "validate", make: CLICommand.validate)
        case "plan":
            return try pathCommand(arguments: arguments, commandName: "plan", make: CLICommand.plan)
        case "status":
            return try pathCommand(arguments: arguments, commandName: "status", make: CLICommand.status)
        case "apply":
            return try applyCommand(arguments: arguments)
        case "doctor":
            guard arguments.count == 1 else { throw CLIUsageError("doctor does not accept arguments in Phase 2.") }
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
                    throw CLIUsageError("apply does not support flag '\(argument)' in Phase 8B.")
                }
                guard path == nil else {
                    throw CLIUsageError("apply accepts at most one manifest path.")
                }
                path = argument
                index += 1
            }
        }

        guard let stateDatabasePath, !stateDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError("apply requires --state-db <path>. Phase 8B does not use a default state database path.")
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
