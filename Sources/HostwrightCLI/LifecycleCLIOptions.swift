import Foundation
import HostwrightCore
import HostwrightRuntime

public enum LifecycleCommandKind: String, CaseIterable, Equatable, Sendable {
    case up
    case down
    case run
    case start
    case stop
    case restart
    case rm
    case update
}

public struct LifecycleCLIOptions: Equatable, Sendable {
    public let command: LifecycleCommandKind
    public let manifestPath: String
    public let serviceNames: [String]
    public let stateDatabasePath: String?
    public let confirmationPlanSHA256: String?
    public let dryRun: Bool
    public let runtimeProvider: RuntimeProviderSelection
    public let timeoutSeconds: Int
    public let parallelism: Int
    public let output: CLIOutputFormat

    public init(
        command: LifecycleCommandKind,
        manifestPath: String = HostwrightIdentity.manifestFileName,
        serviceNames: [String] = [],
        stateDatabasePath: String? = nil,
        confirmationPlanSHA256: String? = nil,
        dryRun: Bool,
        runtimeProvider: RuntimeProviderSelection = .automatic,
        timeoutSeconds: Int = 300,
        parallelism: Int = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)),
        output: CLIOutputFormat = .text
    ) {
        self.command = command
        self.manifestPath = manifestPath
        self.serviceNames = serviceNames
        self.stateDatabasePath = stateDatabasePath
        self.confirmationPlanSHA256 = confirmationPlanSHA256
        self.dryRun = dryRun
        self.runtimeProvider = runtimeProvider
        self.timeoutSeconds = timeoutSeconds
        self.parallelism = parallelism
        self.output = output
    }
}

enum LifecycleCLIParser {
    static let maximumTimeoutSeconds = 86_400

    static func parse(arguments: [String]) throws -> LifecycleCLIOptions {
        guard let rawCommand = arguments.first,
              let command = LifecycleCommandKind(rawValue: rawCommand) else {
            throw CLIUsageError("A supported lifecycle command is required.")
        }

        var manifestPath: String?
        var serviceNames: [String] = []
        var stateDatabasePath: String?
        var confirmationPlanSHA256: String?
        var dryRun = false
        var runtimeProvider = RuntimeProviderSelection.automatic
        var runtimeProviderSelected = false
        var timeoutSeconds = 300
        var timeoutSelected = false
        var parallelism = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        var parallelismSelected = false
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--service":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("\(rawCommand) requires one value after --service.")
                }
                let serviceName = arguments[index + 1]
                guard validServiceName(serviceName), !serviceNames.contains(serviceName) else {
                    throw CLIUsageError("\(rawCommand) service names must be unique bounded identifiers.")
                }
                serviceNames.append(serviceName)
                index += 2
            case "--state-db":
                stateDatabasePath = try uniqueValue(
                    existing: stateDatabasePath,
                    arguments: arguments,
                    index: index,
                    option: "--state-db",
                    command: rawCommand
                )
                index += 2
            case "--dry-run":
                guard !dryRun, confirmationPlanSHA256 == nil else {
                    throw CLIUsageError("\(rawCommand) accepts exactly one of --dry-run or --confirm-plan.")
                }
                dryRun = true
                index += 1
            case "--confirm-plan":
                guard !dryRun, confirmationPlanSHA256 == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("\(rawCommand) accepts exactly one of --dry-run or --confirm-plan.")
                }
                let digest = arguments[index + 1]
                guard validSHA256(digest) else {
                    throw CLIUsageError("\(rawCommand) --confirm-plan requires the exact 64-character SHA-256 emitted by --dry-run.")
                }
                confirmationPlanSHA256 = digest
                index += 2
            case "--runtime-provider":
                guard !runtimeProviderSelected, index + 1 < arguments.count,
                      let selection = RuntimeProviderSelection(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("\(rawCommand) --runtime-provider requires auto, apple-cli, or containerization.")
                }
                runtimeProvider = selection
                runtimeProviderSelected = true
                index += 2
            case "--timeout":
                guard !timeoutSelected, index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]),
                      (1...maximumTimeoutSeconds).contains(value) else {
                    throw CLIUsageError("\(rawCommand) --timeout must be between 1 and \(maximumTimeoutSeconds) seconds.")
                }
                timeoutSeconds = value
                timeoutSelected = true
                index += 2
            case "--parallelism":
                guard !parallelismSelected, index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]),
                      (1...32).contains(value) else {
                    throw CLIUsageError("\(rawCommand) --parallelism must be between 1 and 32.")
                }
                parallelism = value
                parallelismSelected = true
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("\(rawCommand) accepts one output selector.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected, index + 1 < arguments.count,
                      let selected = CLIOutputFormat(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("\(rawCommand) --output supports only text or json.")
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                guard !argument.hasPrefix("-"), manifestPath == nil else {
                    throw CLIUsageError("\(rawCommand) does not support argument '\(argument)'.")
                }
                manifestPath = argument
                index += 1
            }
        }

        guard dryRun != (confirmationPlanSHA256 != nil) else {
            throw CLIUsageError("\(rawCommand) requires exactly one of --dry-run or --confirm-plan.")
        }
        if command == .run, serviceNames.count != 1 {
            throw CLIUsageError("run requires exactly one --service value.")
        }

        return LifecycleCLIOptions(
            command: command,
            manifestPath: manifestPath ?? HostwrightIdentity.manifestFileName,
            serviceNames: serviceNames.sorted(),
            stateDatabasePath: stateDatabasePath,
            confirmationPlanSHA256: confirmationPlanSHA256,
            dryRun: dryRun,
            runtimeProvider: runtimeProvider,
            timeoutSeconds: timeoutSeconds,
            parallelism: parallelism,
            output: output
        )
    }

    private static func uniqueValue(
        existing: String?,
        arguments: [String],
        index: Int,
        option: String,
        command: String
    ) throws -> String {
        guard existing == nil, index + 1 < arguments.count else {
            throw CLIUsageError("\(command) accepts one value after \(option).")
        }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("-") else {
            throw CLIUsageError("\(command) requires a value after \(option).")
        }
        return value
    }

    private static func validServiceName(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$",
            options: .regularExpression
        ) != nil
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
