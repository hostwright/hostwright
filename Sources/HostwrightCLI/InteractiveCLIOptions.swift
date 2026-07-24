import Foundation
import HostwrightCore
import HostwrightRuntime

public enum InteractiveCommandKind: String, CaseIterable, Equatable, Sendable {
    case exec
    case attach
    case copy
    case export
    case inspect
    case stats
    case logsFollow = "logs-follow"
}

public struct InteractiveCLIOptions: Equatable, Sendable {
    public let command: InteractiveCommandKind
    public let manifestPath: String
    public let serviceName: String?
    public let arguments: [String]
    public let source: String?
    public let destination: String?
    public let stateDatabasePath: String?
    public let runtimeProvider: RuntimeProviderSelection
    public let timeoutSeconds: Int
    public let output: CLIOutputFormat
    public let terminal: Bool
    public let forwardsStandardInput: Bool
    public let tail: Int

    public init(
        command: InteractiveCommandKind,
        manifestPath: String = HostwrightIdentity.manifestFileName,
        serviceName: String? = nil,
        arguments: [String] = [],
        source: String? = nil,
        destination: String? = nil,
        stateDatabasePath: String? = nil,
        runtimeProvider: RuntimeProviderSelection = .automatic,
        timeoutSeconds: Int = 300,
        output: CLIOutputFormat = .text,
        terminal: Bool = false,
        forwardsStandardInput: Bool = true,
        tail: Int = 100
    ) {
        self.command = command
        self.manifestPath = manifestPath
        self.serviceName = serviceName
        self.arguments = arguments
        self.source = source
        self.destination = destination
        self.stateDatabasePath = stateDatabasePath
        self.runtimeProvider = runtimeProvider
        self.timeoutSeconds = timeoutSeconds
        self.output = output
        self.terminal = terminal
        self.forwardsStandardInput = forwardsStandardInput
        self.tail = tail
    }
}

enum InteractiveCLIParser {
    static func parse(arguments: [String]) throws -> InteractiveCLIOptions {
        guard let rawCommand = arguments.first,
              let command = InteractiveCommandKind(rawValue: rawCommand) else {
            throw CLIUsageError("A supported interactive command is required.")
        }

        var positional: [String] = []
        var execArguments: [String] = []
        var manifestPath = HostwrightIdentity.manifestFileName
        var manifestSelected = false
        var stateDatabasePath: String?
        var runtimeProvider = RuntimeProviderSelection.automatic
        var runtimeProviderSelected = false
        var timeoutSeconds = 300
        var timeoutSelected = false
        var output = CLIOutputFormat.text
        var outputSelected = false
        var terminal = command == .attach
        var terminalSelected = false
        var forwardsStandardInput = true
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            if command == .exec, argument == "--" {
                execArguments = Array(arguments.dropFirst(index + 1))
                index = arguments.count
                break
            }
            switch argument {
            case "--manifest":
                guard !manifestSelected, index + 1 < arguments.count else {
                    throw CLIUsageError("\(rawCommand) accepts one value after --manifest.")
                }
                manifestPath = arguments[index + 1]
                manifestSelected = true
                index += 2
            case "--state-db":
                guard stateDatabasePath == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("\(rawCommand) accepts one value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
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
                      (1...LifecycleCLIParser.maximumTimeoutSeconds).contains(value) else {
                    throw CLIUsageError("\(rawCommand) --timeout must be between 1 and \(LifecycleCLIParser.maximumTimeoutSeconds) seconds.")
                }
                timeoutSeconds = value
                timeoutSelected = true
                index += 2
            case "--tty":
                guard !terminalSelected else {
                    throw CLIUsageError("\(rawCommand) accepts one terminal selector.")
                }
                terminal = true
                terminalSelected = true
                index += 1
            case "--no-tty":
                guard !terminalSelected else {
                    throw CLIUsageError("\(rawCommand) accepts one terminal selector.")
                }
                terminal = false
                terminalSelected = true
                index += 1
            case "--no-stdin":
                guard forwardsStandardInput else {
                    throw CLIUsageError("\(rawCommand) accepts --no-stdin once.")
                }
                forwardsStandardInput = false
                index += 1
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
                guard !argument.hasPrefix("-") else {
                    throw CLIUsageError("\(rawCommand) does not support argument '\(argument)'.")
                }
                positional.append(argument)
                index += 1
            }
        }

        if terminal, output == .json {
            throw CLIUsageError("\(rawCommand) interactive TTY mode and JSON output are mutually exclusive.")
        }

        switch command {
        case .exec:
            guard positional.count == 1, validServiceName(positional[0]), !execArguments.isEmpty else {
                throw CLIUsageError("exec requires one service and a non-empty command after --.")
            }
            try validateExecArguments(execArguments)
            return options(
                command: command,
                manifestPath: manifestPath,
                serviceName: positional[0],
                arguments: execArguments,
                stateDatabasePath: stateDatabasePath,
                runtimeProvider: runtimeProvider,
                timeoutSeconds: timeoutSeconds,
                output: output,
                terminal: terminal,
                forwardsStandardInput: forwardsStandardInput
            )
        case .attach:
            guard positional.count == 1, validServiceName(positional[0]), output == .text else {
                throw CLIUsageError("attach requires one service and text output.")
            }
            return options(
                command: command,
                manifestPath: manifestPath,
                serviceName: positional[0],
                stateDatabasePath: stateDatabasePath,
                runtimeProvider: runtimeProvider,
                timeoutSeconds: timeoutSeconds,
                output: output,
                terminal: terminal,
                forwardsStandardInput: forwardsStandardInput
            )
        case .copy:
            guard positional.count == 2,
                  exactlyOneContainerEndpoint(positional[0], positional[1]) else {
                throw CLIUsageError("copy requires one host path and one service:/absolute/container/path endpoint.")
            }
            return options(
                command: command,
                manifestPath: manifestPath,
                source: positional[0],
                destination: positional[1],
                stateDatabasePath: stateDatabasePath,
                runtimeProvider: runtimeProvider,
                timeoutSeconds: timeoutSeconds,
                output: output,
                terminal: false,
                forwardsStandardInput: false
            )
        case .export:
            guard positional.count == 2,
                  validServiceName(positional[0]),
                  absoluteNormalizedHostPath(positional[1]) else {
                throw CLIUsageError("export requires one service and one absolute destination path.")
            }
            return options(
                command: command,
                manifestPath: manifestPath,
                serviceName: positional[0],
                destination: positional[1],
                stateDatabasePath: stateDatabasePath,
                runtimeProvider: runtimeProvider,
                timeoutSeconds: timeoutSeconds,
                output: output,
                terminal: false,
                forwardsStandardInput: false
            )
        case .inspect, .stats, .logsFollow:
            guard positional.count == 1, validServiceName(positional[0]), !terminalSelected else {
                throw CLIUsageError("\(rawCommand) requires one service and does not accept terminal options.")
            }
            return options(
                command: command,
                manifestPath: manifestPath,
                serviceName: positional[0],
                stateDatabasePath: stateDatabasePath,
                runtimeProvider: runtimeProvider,
                timeoutSeconds: timeoutSeconds,
                output: output,
                terminal: false,
                forwardsStandardInput: false
            )
        }
    }

    private static func options(
        command: InteractiveCommandKind,
        manifestPath: String,
        serviceName: String? = nil,
        arguments: [String] = [],
        source: String? = nil,
        destination: String? = nil,
        stateDatabasePath: String?,
        runtimeProvider: RuntimeProviderSelection,
        timeoutSeconds: Int,
        output: CLIOutputFormat,
        terminal: Bool,
        forwardsStandardInput: Bool
    ) -> InteractiveCLIOptions {
        InteractiveCLIOptions(
            command: command,
            manifestPath: manifestPath,
            serviceName: serviceName,
            arguments: arguments,
            source: source,
            destination: destination,
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            timeoutSeconds: timeoutSeconds,
            output: output,
            terminal: terminal,
            forwardsStandardInput: forwardsStandardInput
        )
    }

    private static func validateExecArguments(_ arguments: [String]) throws {
        guard arguments.count <= 128,
              arguments.allSatisfy({
                  !$0.isEmpty && !$0.contains("\0") && !$0.contains("\r") && !$0.contains("\n")
              }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 16 * 1_024 else {
            throw CLIUsageError("exec command arguments exceed the bounded safe command contract.")
        }
    }

    private static func exactlyOneContainerEndpoint(_ lhs: String, _ rhs: String) -> Bool {
        let lhsContainer = containerEndpoint(lhs)
        let rhsContainer = containerEndpoint(rhs)
        guard (lhsContainer != nil) != (rhsContainer != nil) else {
            return false
        }
        let hostPath = lhsContainer == nil ? lhs : rhs
        return absoluteNormalizedHostPath(hostPath)
    }

    private static func containerEndpoint(_ value: String) -> (service: String, path: String)? {
        guard let separator = value.firstIndex(of: ":") else {
            return nil
        }
        let service = String(value[..<separator])
        let path = String(value[value.index(after: separator)...])
        guard validServiceName(service), absoluteNormalizedContainerPath(path) else {
            return nil
        }
        return (service, path)
    }

    private static func absoluteNormalizedHostPath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && !pathComponents(value).contains("..")
    }

    private static func absoluteNormalizedContainerPath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && !pathComponents(value).contains("..")
    }

    private static func pathComponents(_ value: String) -> [Substring] {
        value.split(separator: "/", omittingEmptySubsequences: true)
    }

    private static func validServiceName(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$",
            options: .regularExpression
        ) != nil
    }
}
