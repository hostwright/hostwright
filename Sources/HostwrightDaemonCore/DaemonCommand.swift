import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

public enum DaemonCommand: Equatable, Sendable {
    case help
    case version
    case run(DaemonConfiguration)

    public static func parse(
        arguments: [String],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DaemonCommand {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
            return .help
        }
        if arguments == ["--version"] || arguments == ["version"] {
            return .version
        }

        var mode: DaemonMode?
        var configPath: String?
        var stateDatabasePath: String?
        var lockFilePath: String?
        var cadenceSeconds = 5
        var jitterSeconds = 0
        var maxBackoffSeconds = 300
        var maximumParallelism = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        var maxIterations: Int?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--foreground":
                guard mode == nil else {
                    throw DaemonError.invalidConfiguration(
                        "Select exactly one of --foreground or --service."
                    )
                }
                mode = .foregroundDev
                index += 1
            case "--service":
                guard mode == nil else {
                    throw DaemonError.invalidConfiguration(
                        "Select exactly one of --foreground or --service."
                    )
                }
                mode = .managedService
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
            case "--parallelism":
                maximumParallelism = try positiveInteger(after: argument, in: arguments, at: index)
                index += 2
            case "--max-iterations":
                maxIterations = try positiveInteger(after: argument, in: arguments, at: index)
                index += 2
            default:
                throw DaemonError.invalidConfiguration("Unsupported argument '\(argument)'.")
            }
        }

        guard let mode else {
            throw DaemonError.invalidConfiguration(
                "Select exactly one of --foreground or --service."
            )
        }

        let resolution: HostwrightLocalPathResolution
        do {
            resolution = try HostwrightLocalPathResolver.resolve(
                explicitStateDatabasePath: stateDatabasePath,
                homeDirectory: homeDirectory,
                environment: mode == .managedService ? [:] : environment
            )
        } catch {
            throw DaemonError.invalidConfiguration(String(describing: error))
        }
        let resolvedLockPath: String
        do {
            resolvedLockPath = try resolution.daemonLockPath(explicitLockPath: lockFilePath)
        } catch {
            throw DaemonError.invalidConfiguration(String(describing: error))
        }
        let configuration = DaemonConfiguration(
            mode: mode,
            configPath: configPath ?? "",
            stateStoreConfiguration: StateStoreConfiguration(localPathResolution: resolution),
            lockFilePath: resolvedLockPath,
            cadenceSeconds: cadenceSeconds,
            jitterSeconds: jitterSeconds,
            maxBackoffSeconds: maxBackoffSeconds,
            maximumParallelism: maximumParallelism,
            maxIterations: maxIterations
        )
        try configuration.validate()
        return .run(configuration)
    }

    package static func managedServiceEnvironment(
        homeDirectory: String
    ) -> [String: String] {
        [
            "HOME": homeDirectory,
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": SecureSubprocessEnvironment.trustedSystemPath
        ]
    }

    package static func currentUserHomeDirectory(
        userID: uid_t = geteuid()
    ) throws -> String {
        guard let record = getpwuid(userID), let directory = record.pointee.pw_dir else {
            throw DaemonError.invalidConfiguration(
                "managed service current-user home could not be resolved."
            )
        }
        do {
            return try SecureExecutableResolver.verifyWorkingDirectory(
                path: String(cString: directory)
            )
        } catch {
            throw DaemonError.invalidConfiguration(
                "managed service current-user home is unsafe."
            )
        }
    }

    package static func managedServiceEnvironmentRequiresReexec(
        inheritedEnvironment: [String: String],
        homeDirectory: String
    ) -> Bool {
        inheritedEnvironment != managedServiceEnvironment(homeDirectory: homeDirectory)
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
    hostwrightd reconciliation service

    Usage:
      hostwrightd --foreground --config <hostwright.yaml> [--state-db <path>] [options]
      hostwrightd --service --config <absolute-hostwright.yaml> [--state-db <path>] [options]

    Required:
      --foreground              Run in foreground development mode.
      --service                 Run as the managed per-user LaunchAgent.
      --config <path>           Explicit Hostwright manifest/config path.

    Options:
      --interval <seconds>      Base reconciliation cadence. Default: 5.
      --jitter <seconds>        Deterministic jitter cap. Default: 0.
      --max-backoff <seconds>   Maximum retry backoff. Default: 300.
      --parallelism <count>     Lifecycle DAG parallelism from 1 through 32. Default: min(4, CPUs).
      --max-iterations <count>  Stop after count loop iterations; intended for tests/dev proof.
      --state-db <path>         Optional SQLite override; defaults to Application Support.
      --lock-file <path>        Optional lock override; defaults to Application Support/run.
      --version                 Print version.
      --help                    Show this help.

    Safety:
      Each healthy loop validates, observes, plans, and reconciles through the shared lifecycle saga.
      LaunchAgent lifecycle is controlled by hostwright daemon; hostwrightd does not self-install.
      Mutations require exact provider capability, ownership, plan confirmation, and durable fencing.

    """

    public static func run(
        arguments: [String],
        runtimeAdapter: any RuntimeAdapter,
        reconciliationDriver: any DaemonReconciliationDriving,
        shutdownToken: DaemonShutdownToken = DaemonShutdownToken()
    ) async -> DaemonProcessResult {
        do {
            let isManagedService = arguments.contains("--service")
            let homeDirectory = isManagedService
                ? try DaemonCommand.currentUserHomeDirectory()
                : FileManager.default.homeDirectoryForCurrentUser.path
            let environment = isManagedService
                ? DaemonCommand.managedServiceEnvironment(homeDirectory: homeDirectory)
                : ProcessInfo.processInfo.environment
            switch try DaemonCommand.parse(
                arguments: arguments,
                homeDirectory: homeDirectory,
                environment: environment
            ) {
            case .help:
                return DaemonProcessResult(standardOutput: helpText)
            case .version:
                return DaemonProcessResult(standardOutput: "\(HostwrightIdentity.version)\n")
            case .run(let configuration):
                let clock = SystemDaemonClock(shutdownToken: shutdownToken)
                let runner = DaemonLoopRunner(
                    configuration: configuration,
                    runtimeAdapter: runtimeAdapter,
                    reconciliationDriver: reconciliationDriver,
                    clock: clock,
                    instanceLock: FileDaemonInstanceLock(path: configuration.lockFilePath),
                    shutdownToken: shutdownToken,
                    readConfig: { try String(contentsOfFile: $0, encoding: .utf8) }
                )
                let summary = try await runner.run()
                return DaemonProcessResult(
                    standardOutput: """
                    hostwrightd \(configuration.mode.rawValue) loop stopped
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
