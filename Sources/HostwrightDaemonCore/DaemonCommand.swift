import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

public enum DaemonCommand: Equatable, Sendable {
    case help
    case version
    case run(DaemonConfiguration)

    public static func parse(arguments: [String]) throws -> DaemonCommand {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
            return .help
        }
        if arguments == ["--version"] || arguments == ["version"] {
            return .version
        }

        var foreground = false
        var configPath: String?
        var stateDatabasePath: String?
        var lockFilePath: String?
        var cadenceSeconds = 30
        var jitterSeconds = 5
        var maxBackoffSeconds = 300
        var maxIterations: Int?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--foreground":
                foreground = true
                index += 1
            case "--config":
                configPath = try value(after: argument, in: arguments, at: index)
                index += 2
            case "--state-db":
                stateDatabasePath = try value(after: argument, in: arguments, at: index)
                index += 2
            case "--lock-file":
                lockFilePath = try value(after: argument, in: arguments, at: index)
                index += 2
            case "--interval":
                cadenceSeconds = try positiveInteger(after: argument, in: arguments, at: index)
                index += 2
            case "--jitter":
                jitterSeconds = try nonNegativeInteger(after: argument, in: arguments, at: index)
                index += 2
            case "--max-backoff":
                maxBackoffSeconds = try positiveInteger(after: argument, in: arguments, at: index)
                index += 2
            case "--max-iterations":
                maxIterations = try positiveInteger(after: argument, in: arguments, at: index)
                index += 2
            default:
                throw DaemonError.invalidConfiguration("Unsupported argument '\(argument)'.")
            }
        }

        guard foreground else {
            throw DaemonError.invalidConfiguration("--foreground is required; launch agent installation is not implemented.")
        }

        let configuration = DaemonConfiguration(
            configPath: configPath ?? "",
            stateDatabasePath: stateDatabasePath ?? "",
            lockFilePath: lockFilePath,
            cadenceSeconds: cadenceSeconds,
            jitterSeconds: jitterSeconds,
            maxBackoffSeconds: maxBackoffSeconds,
            maxIterations: maxIterations
        )
        try configuration.validate()
        return .run(configuration)
    }

    private static func value(after flag: String, in arguments: [String], at index: Int) throws -> String {
        guard index + 1 < arguments.count else {
            throw DaemonError.invalidConfiguration("\(flag) requires a value.")
        }
        return arguments[index + 1]
    }

    private static func positiveInteger(after flag: String, in arguments: [String], at index: Int) throws -> Int {
        let raw = try value(after: flag, in: arguments, at: index)
        guard let value = Int(raw), value > 0 else {
            throw DaemonError.invalidConfiguration("\(flag) requires a positive integer.")
        }
        return value
    }

    private static func nonNegativeInteger(after flag: String, in arguments: [String], at index: Int) throws -> Int {
        let raw = try value(after: flag, in: arguments, at: index)
        guard let value = Int(raw), value >= 0 else {
            throw DaemonError.invalidConfiguration("\(flag) requires zero or a positive integer.")
        }
        return value
    }
}

public struct DaemonProcessResult: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32

    public init(standardOutput: String = "", standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

public enum HostwrightDaemonMain {
    public static let helpText = """
    hostwrightd foreground development loop

    Usage:
      hostwrightd --foreground --config <hostwright.yaml> --state-db <path> [options]

    Required:
      --foreground              Run in foreground development mode.
      --config <path>           Explicit Hostwright manifest/config path.
      --state-db <path>         Explicit SQLite state database path.

    Options:
      --interval <seconds>      Base reconciliation cadence. Default: 30.
      --jitter <seconds>        Deterministic jitter cap. Default: 5.
      --max-backoff <seconds>   Maximum retry backoff. Default: 300.
      --max-iterations <count>  Stop after count loop iterations; intended for tests/dev proof.
      --lock-file <path>        Explicit daemon lock file. Default: <state-db>.hostwrightd.lock.
      --version                 Print version.
      --help                    Show this help.

    Safety:
      This phase observes, plans, and records daemon loop attempts only.
      It does not install a launch agent and does not perform unattended runtime mutation.

    """

    public static func run(
        arguments: [String],
        runtimeAdapter: any RuntimeAdapter,
        shutdownToken: DaemonShutdownToken = DaemonShutdownToken()
    ) async -> DaemonProcessResult {
        do {
            switch try DaemonCommand.parse(arguments: arguments) {
            case .help:
                return DaemonProcessResult(standardOutput: helpText)
            case .version:
                return DaemonProcessResult(standardOutput: "\(HostwrightIdentity.version)\n")
            case .run(let configuration):
                let clock = SystemDaemonClock(shutdownToken: shutdownToken)
                let runner = DaemonLoopRunner(
                    configuration: configuration,
                    runtimeAdapter: runtimeAdapter,
                    clock: clock,
                    instanceLock: FileDaemonInstanceLock(path: configuration.lockFilePath),
                    shutdownToken: shutdownToken,
                    readConfig: { try String(contentsOfFile: $0, encoding: .utf8) }
                )
                let summary = try await runner.run()
                return DaemonProcessResult(
                    standardOutput: """
                    hostwrightd foreground dev loop stopped
                    Iterations: \(summary.iterations)
                    Successful: \(summary.successfulIterations)
                    Failed: \(summary.failedIterations)
                    Shutdown requested: \(summary.stoppedByShutdown)

                    """
                )
            }
        } catch let error as DaemonError {
            return DaemonProcessResult(standardError: "\(error)\n", exitCode: 64)
        } catch let error as StateStoreError {
            return DaemonProcessResult(standardError: "\(HostwrightErrorCode.stateStoreUnavailable.rawValue): \(error)\n", exitCode: 66)
        } catch {
            return DaemonProcessResult(standardError: "\(HostwrightErrorCode.runtimeUnavailable.rawValue): \(RuntimeRedactionPolicy.default.redact(String(describing: error)))\n", exitCode: 69)
        }
    }
}
