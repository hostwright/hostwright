import HostwrightCore

public enum CLICommand: Equatable, Sendable {
    case version
    case initManifest
    case validate(path: String)
    case plan(path: String)
    case status(path: String)
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

