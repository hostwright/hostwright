import Foundation
import HostwrightCore
import HostwrightDaemonCore
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState

public struct RuntimeProviderMigrationCLIOptions: Equatable, Sendable {
    public let manifestPath: String
    public let stateDatabasePath: String?
    public let targetProviderID: RuntimeProviderID
    public let confirmationToken: String?
    public let output: CLIOutputFormat

    public init(
        manifestPath: String,
        stateDatabasePath: String?,
        targetProviderID: RuntimeProviderID,
        confirmationToken: String?,
        output: CLIOutputFormat
    ) {
        self.manifestPath = manifestPath
        self.stateDatabasePath = stateDatabasePath
        self.targetProviderID = targetProviderID
        self.confirmationToken = confirmationToken
        self.output = output
    }
}

public enum RecoveryCLIAction: Equatable, Sendable {
    case inspect
    case resume(groupID: String, confirmationPlanSHA256: String, timeoutSeconds: Int)
    case rollback(groupID: String, confirmationPlanSHA256: String, timeoutSeconds: Int)
}

public enum SecretCLIAction: Equatable, Sendable {
    case create(HostwrightSecretReference)
    case update(HostwrightSecretReference)
    case list
    case check(HostwrightSecretReference)
    case delete(HostwrightSecretReference)
}

public struct SecretCLIOptions: Equatable, Sendable {
    public let action: SecretCLIAction
    public let stateDatabasePath: String?
    public let output: CLIOutputFormat

    public init(
        action: SecretCLIAction,
        stateDatabasePath: String?,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.output = output
    }
}

public enum DaemonCLIAction: Equatable, Sendable {
    case status
    case lifecycle(DaemonLifecycleOperation)
}

public struct DaemonCLIOptions: Equatable, Sendable {
    public let action: DaemonCLIAction
    public let daemonExecutablePath: String?
    public let configPath: String?
    public let output: CLIOutputFormat

    public init(
        action: DaemonCLIAction,
        daemonExecutablePath: String?,
        configPath: String?,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.daemonExecutablePath = daemonExecutablePath
        self.configPath = configPath
        self.output = output
    }
}

public enum RestartBudgetCLIAction: Equatable, Sendable {
    case status(projectID: String?)
    case release(projectID: String, serviceName: String, holdToken: String)
}

public struct RestartBudgetCLIOptions: Equatable, Sendable {
    public let action: RestartBudgetCLIAction
    public let stateDatabasePath: String?
    public let output: CLIOutputFormat

    public init(
        action: RestartBudgetCLIAction,
        stateDatabasePath: String?,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.output = output
    }
}

public enum MaintenanceCLIAction: Equatable, Sendable {
    case preview(manifestPath: String, actions: [String], at: String?)
    case status(projectID: String?)
    case cancel(projectID: String, confirmationToken: String)
    case override(projectID: String, confirmationToken: String, reason: String)
}

public struct MaintenanceCLIOptions: Equatable, Sendable {
    public let action: MaintenanceCLIAction
    public let stateDatabasePath: String?
    public let output: CLIOutputFormat

    public init(
        action: MaintenanceCLIAction,
        stateDatabasePath: String?,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.output = output
    }
}

public enum OwnershipCLIAction: Equatable, Sendable {
    case status(projectID: String?)
    case handoff(
        groupID: String,
        planSHA256: String,
        fencingToken: String,
        priorControllerID: String,
        priorExpiry: String,
        targetControllerID: String,
        leaseSeconds: Int
    )
}

public struct OwnershipCLIOptions: Equatable, Sendable {
    public let action: OwnershipCLIAction
    public let stateDatabasePath: String?
    public let output: CLIOutputFormat

    public init(
        action: OwnershipCLIAction,
        stateDatabasePath: String?,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.output = output
    }
}

public enum CLICommand: Equatable, Sendable {
    case version
    case capabilities(output: CLIOutputFormat)
    case observabilityStatus(output: CLIOutputFormat)
    case runtimeProviders(output: CLIOutputFormat)
    case runtimeMigrate(options: RuntimeProviderMigrationCLIOptions)
    case paths(stateDatabasePath: String?, output: CLIOutputFormat)
    case state(action: StateCLIAction, stateDatabasePath: String?, output: CLIOutputFormat)
    case secret(options: SecretCLIOptions)
    case registry(options: RegistryCLIOptions)
    case image(options: ImageCLIOptions)
    case volume(options: StorageCLIOptions)
    case daemon(options: DaemonCLIOptions)
    case restartBudget(options: RestartBudgetCLIOptions)
    case maintenance(options: MaintenanceCLIOptions)
    case ownership(options: OwnershipCLIOptions)
    case migrateManifestPreview(path: String, output: CLIOutputFormat)
    case initManifest
    case importStack(path: String, output: CLIOutputFormat, teamProfilePath: String?)
    case validate(path: String, teamProfilePath: String?)
    case plan(path: String, output: CLIOutputFormat, teamProfilePath: String?)
    case status(
        path: String,
        stateDatabasePath: String?,
        output: CLIOutputFormat,
        runtimeProvider: RuntimeProviderSelection
    )
    case apply(
        path: String,
        stateDatabasePath: String?,
        confirmedPlanHash: String,
        teamProfilePath: String?,
        approvalRecordPath: String?,
        runtimeProvider: RuntimeProviderSelection
    )
    case lifecycle(options: LifecycleCLIOptions)
    case interactive(options: InteractiveCLIOptions)
    case logs(serviceName: String, path: String, tail: Int, stateDatabasePath: String?)
    case events(
        stateDatabasePath: String?,
        projectName: String?,
        filters: EventFilters,
        stream: EventStreamCLIOptions,
        output: CLIOutputFormat
    )
    case recovery(
        action: RecoveryCLIAction,
        stateDatabasePath: String?,
        projectName: String?,
        output: CLIOutputFormat
    )
    case cleanup(path: String, stateDatabasePath: String?, confirmation: CleanupConfirmation, teamProfilePath: String?, approvalRecordPath: String?)
    case diagnostics(stateDatabasePath: String?, bundlePath: String, projectName: String?, manifestPath: String?)
    case benchmark(options: BenchmarkCLIOptions)
    case extensionCheck(declarationPath: String, executablePath: String, output: CLIOutputFormat)
    case doctor(stateDatabasePath: String?, output: CLIOutputFormat)
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
        case "capabilities":
            return try capabilitiesCommand(arguments: arguments)
        case "observability":
            return try observabilityCommand(arguments: arguments)
        case "runtime":
            return try runtimeCommand(arguments: arguments)
        case "paths":
            return try pathsCommand(arguments: arguments)
        case "state":
            return try stateCommand(arguments: arguments)
        case "secret":
            return try secretCommand(arguments: arguments)
        case "registry":
            return try registryCommand(arguments: arguments)
        case "image":
            return .image(options: try ImageCLIParser.parse(arguments: arguments))
        case "volume":
            return .volume(options: try StorageCLIParser.parse(arguments: arguments))
        case "daemon":
            return try daemonCommand(arguments: arguments)
        case "restart-budget":
            return try restartBudgetCommand(arguments: arguments)
        case "maintenance":
            return try maintenanceCommand(arguments: arguments)
        case "ownership":
            return try ownershipCommand(arguments: arguments)
        case "migrate":
            return try migrateCommand(arguments: arguments)
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
        case "up", "down", "run", "start", "stop", "restart", "rm", "update":
            return .lifecycle(options: try LifecycleCLIParser.parse(arguments: arguments))
        case "exec", "attach", "copy", "export", "inspect", "stats":
            return .interactive(options: try InteractiveCLIParser.parse(arguments: arguments))
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
        if arguments.contains("--json") {
            return .json
        }
        guard let outputIndex = arguments.firstIndex(of: "--output"),
              arguments.indices.contains(arguments.index(after: outputIndex))
        else {
            return nil
        }
        return CLIOutputFormat(rawValue: arguments[arguments.index(after: outputIndex)])
    }

    private static func daemonCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2 else {
            throw CLIUsageError(
                "daemon requires status, install, validate, bootstrap, start, stop, kickstart, upgrade, rollback, disable, repair, or uninstall."
            )
        }
        let action: DaemonCLIAction
        if arguments[1] == "status" {
            action = .status
        } else if let operation = DaemonLifecycleOperation(rawValue: arguments[1]) {
            action = .lifecycle(operation)
        } else {
            throw CLIUsageError("daemon does not support operation '\(arguments[1])'.")
        }

        var daemonExecutablePath: String?
        var configPath: String?
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--daemon-executable":
                guard daemonExecutablePath == nil, index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "daemon \(arguments[1]) accepts one value after --daemon-executable."
                    )
                }
                daemonExecutablePath = arguments[index + 1]
                index += 2
            case "--config":
                guard configPath == nil, index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "daemon \(arguments[1]) accepts one value after --config."
                    )
                }
                configPath = arguments[index + 1]
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("daemon \(arguments[1]) accepts one output selector.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else {
                    throw CLIUsageError("daemon \(arguments[1]) accepts one output selector.")
                }
                output = try parseOutputValue(
                    arguments: arguments,
                    index: index,
                    commandName: "daemon \(arguments[1])"
                )
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "daemon \(arguments[1]) does not support argument '\(arguments[index])'."
                )
            }
        }

        let acceptsInputs: Bool
        switch action {
        case .lifecycle(.install), .lifecycle(.upgrade):
            acceptsInputs = true
        default:
            acceptsInputs = false
        }
        if acceptsInputs {
            guard let daemonExecutablePath,
                  daemonExecutablePath.hasPrefix("/"),
                  let configPath,
                  configPath.hasPrefix("/") else {
                throw CLIUsageError(
                    "daemon \(arguments[1]) requires --daemon-executable <absolute-path> and --config <absolute-path>."
                )
            }
        } else if daemonExecutablePath != nil || configPath != nil {
            throw CLIUsageError(
                "daemon \(arguments[1]) does not accept --daemon-executable or --config."
            )
        }
        return .daemon(
            options: DaemonCLIOptions(
                action: action,
                daemonExecutablePath: daemonExecutablePath,
                configPath: configPath,
                output: output
            )
        )
    }

    private static func restartBudgetCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2, ["status", "release"].contains(arguments[1]) else {
            throw CLIUsageError("restart-budget requires status or release.")
        }
        let verb = arguments[1]
        var projectID: String?
        var serviceName: String?
        var holdToken: String?
        var stateDatabasePath: String?
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--project", "--service", "--confirm-hold", "--state-db", "--output":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("restart-budget requires one value after \(argument).")
                }
                let value = arguments[index + 1]
                switch argument {
                case "--project":
                    guard projectID == nil else { throw CLIUsageError("restart-budget accepts --project once.") }
                    projectID = value
                case "--service":
                    guard serviceName == nil else { throw CLIUsageError("restart-budget accepts --service once.") }
                    serviceName = value
                case "--confirm-hold":
                    guard holdToken == nil else { throw CLIUsageError("restart-budget accepts --confirm-hold once.") }
                    holdToken = value
                case "--state-db":
                    guard stateDatabasePath == nil else { throw CLIUsageError("restart-budget accepts --state-db once.") }
                    stateDatabasePath = value
                case "--output":
                    guard !outputSelected, let parsed = CLIOutputFormat(rawValue: value) else {
                        throw CLIUsageError("restart-budget --output requires text or json once.")
                    }
                    output = parsed
                    outputSelected = true
                default:
                    break
                }
                index += 2
            case "--json":
                guard !outputSelected else { throw CLIUsageError("restart-budget accepts one output selector.") }
                output = .json
                outputSelected = true
                index += 1
            default:
                throw CLIUsageError("Unsupported restart-budget option '\(argument)'.")
            }
        }
        if let projectID,
           projectID.range(of: "^project-[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$", options: .regularExpression) == nil {
            throw CLIUsageError("restart-budget --project requires an exact bounded project ID.")
        }
        if let serviceName,
           serviceName.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) == nil {
            throw CLIUsageError("restart-budget --service requires a Manifest v2 service name.")
        }
        let action: RestartBudgetCLIAction
        if verb == "status" {
            guard serviceName == nil, holdToken == nil else {
                throw CLIUsageError("restart-budget status accepts only optional --project, state, and output selectors.")
            }
            action = .status(projectID: projectID)
        } else {
            guard let projectID, let serviceName, let holdToken,
                  holdToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw CLIUsageError("restart-budget release requires exact --project, --service, and --confirm-hold SHA-256 values.")
            }
            action = .release(projectID: projectID, serviceName: serviceName, holdToken: holdToken)
        }
        return .restartBudget(
            options: RestartBudgetCLIOptions(
                action: action,
                stateDatabasePath: stateDatabasePath,
                output: output
            )
        )
    }

    private static func maintenanceCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2,
              ["preview", "status", "cancel", "override"].contains(arguments[1]) else {
            throw CLIUsageError("maintenance requires preview, status, cancel, or override.")
        }
        let verb = arguments[1]
        var manifestPath: String?
        var actions: [String] = []
        var at: String?
        var projectID: String?
        var confirmationToken: String?
        var reason: String?
        var stateDatabasePath: String?
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--action", "--at", "--project", "--confirm-deferral", "--reason", "--state-db", "--output":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("maintenance requires one value after \(argument).")
                }
                let value = arguments[index + 1]
                switch argument {
                case "--action": actions.append(value)
                case "--at":
                    guard at == nil else { throw CLIUsageError("maintenance accepts --at once.") }
                    at = value
                case "--project":
                    guard projectID == nil else { throw CLIUsageError("maintenance accepts --project once.") }
                    projectID = value
                case "--confirm-deferral":
                    guard confirmationToken == nil else { throw CLIUsageError("maintenance accepts --confirm-deferral once.") }
                    confirmationToken = value
                case "--reason":
                    guard reason == nil else { throw CLIUsageError("maintenance accepts --reason once.") }
                    reason = value
                case "--state-db":
                    guard stateDatabasePath == nil else { throw CLIUsageError("maintenance accepts --state-db once.") }
                    stateDatabasePath = value
                case "--output":
                    guard !outputSelected, let parsed = CLIOutputFormat(rawValue: value) else {
                        throw CLIUsageError("maintenance --output requires text or json once.")
                    }
                    output = parsed
                    outputSelected = true
                default: break
                }
                index += 2
            case "--json":
                guard !outputSelected else { throw CLIUsageError("maintenance accepts one output selector.") }
                output = .json
                outputSelected = true
                index += 1
            default:
                guard verb == "preview", manifestPath == nil, !argument.hasPrefix("-") else {
                    throw CLIUsageError("Unsupported maintenance option '\(argument)'.")
                }
                manifestPath = argument
                index += 1
            }
        }
        if let projectID,
           projectID.range(of: "^project-[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$", options: .regularExpression) == nil {
            throw CLIUsageError("maintenance --project requires an exact bounded project ID.")
        }
        if let confirmationToken,
           confirmationToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil {
            throw CLIUsageError("maintenance --confirm-deferral requires an exact SHA-256 token.")
        }
        let action: MaintenanceCLIAction
        switch verb {
        case "preview":
            guard projectID == nil, confirmationToken == nil, reason == nil,
                  let manifestPath, !actions.isEmpty,
                  Set(actions).count == actions.count,
                  actions.allSatisfy({ ["create", "start", "restart", "update", "remove"].contains($0) }) else {
                throw CLIUsageError("maintenance preview requires a manifest and one or more unique elective --action values.")
            }
            if let at {
                let formatter = ISO8601DateFormatter()
                guard let date = formatter.date(from: at), formatter.string(from: date) == at else {
                    throw CLIUsageError("maintenance preview --at requires canonical RFC3339 UTC.")
                }
            }
            action = .preview(manifestPath: manifestPath, actions: actions.sorted(), at: at)
        case "status":
            guard manifestPath == nil, actions.isEmpty, at == nil, confirmationToken == nil, reason == nil else {
                throw CLIUsageError("maintenance status accepts only optional --project, state, and output selectors.")
            }
            action = .status(projectID: projectID)
        case "cancel":
            guard manifestPath == nil, actions.isEmpty, at == nil, reason == nil,
                  let projectID, let confirmationToken else {
                throw CLIUsageError("maintenance cancel requires exact --project and --confirm-deferral values.")
            }
            action = .cancel(projectID: projectID, confirmationToken: confirmationToken)
        default:
            guard manifestPath == nil, actions.isEmpty, at == nil,
                  let projectID, let confirmationToken, let reason,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reason.utf8.count <= 512,
                  reason.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw CLIUsageError("maintenance override requires exact --project, --confirm-deferral, and bounded --reason values.")
            }
            action = .override(projectID: projectID, confirmationToken: confirmationToken, reason: reason)
        }
        return .maintenance(options: MaintenanceCLIOptions(action: action, stateDatabasePath: stateDatabasePath, output: output))
    }

    private static func ownershipCommand(
        arguments: [String]
    ) throws -> CLICommand {
        guard arguments.count >= 2,
              ["status", "handoff"].contains(arguments[1]) else {
            throw CLIUsageError("ownership requires status or handoff.")
        }
        let verb = arguments[1]
        var projectID: String?
        var groupID: String?
        var planSHA256: String?
        var fencingToken: String?
        var priorControllerID: String?
        var priorExpiry: String?
        var targetControllerID: String?
        var leaseSeconds: Int?
        var stateDatabasePath: String?
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 2

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--project", "--group", "--confirm-plan", "--confirm-fence",
                 "--from-controller", "--from-expiry", "--to-controller",
                 "--lease-seconds", "--state-db", "--output":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "ownership requires one value after \(argument)."
                    )
                }
                let value = arguments[index + 1]
                switch argument {
                case "--project":
                    guard projectID == nil else {
                        throw CLIUsageError("ownership accepts --project once.")
                    }
                    projectID = value
                case "--group":
                    guard groupID == nil else {
                        throw CLIUsageError("ownership accepts --group once.")
                    }
                    groupID = value.lowercased()
                case "--confirm-plan":
                    guard planSHA256 == nil else {
                        throw CLIUsageError(
                            "ownership accepts --confirm-plan once."
                        )
                    }
                    planSHA256 = value.lowercased()
                case "--confirm-fence":
                    guard fencingToken == nil else {
                        throw CLIUsageError(
                            "ownership accepts --confirm-fence once."
                        )
                    }
                    fencingToken = value.lowercased()
                case "--from-controller":
                    guard priorControllerID == nil else {
                        throw CLIUsageError(
                            "ownership accepts --from-controller once."
                        )
                    }
                    priorControllerID = value
                case "--from-expiry":
                    guard priorExpiry == nil else {
                        throw CLIUsageError(
                            "ownership accepts --from-expiry once."
                        )
                    }
                    priorExpiry = value
                case "--to-controller":
                    guard targetControllerID == nil else {
                        throw CLIUsageError(
                            "ownership accepts --to-controller once."
                        )
                    }
                    targetControllerID = [
                        "resume": "hostwright-recovery-resume",
                        "rollback": "hostwright-recovery-rollback"
                    ][value]
                    guard targetControllerID != nil else {
                        throw CLIUsageError(
                            "ownership --to-controller requires resume or rollback."
                        )
                    }
                case "--lease-seconds":
                    guard leaseSeconds == nil,
                          let parsed = Int(value),
                          (1...900).contains(parsed) else {
                        throw CLIUsageError(
                            "ownership --lease-seconds requires 1 through 900."
                        )
                    }
                    leaseSeconds = parsed
                case "--state-db":
                    guard stateDatabasePath == nil else {
                        throw CLIUsageError("ownership accepts --state-db once.")
                    }
                    stateDatabasePath = value
                case "--output":
                    guard !outputSelected,
                          let parsed = CLIOutputFormat(rawValue: value) else {
                        throw CLIUsageError(
                            "ownership --output requires text or json once."
                        )
                    }
                    output = parsed
                    outputSelected = true
                default:
                    preconditionFailure("Unknown ownership parser option.")
                }
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "ownership accepts one output selector."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            default:
                throw CLIUsageError(
                    "Unsupported ownership option '\(argument)'."
                )
            }
        }

        if let projectID,
           projectID.range(
               of: "^project-[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$",
               options: .regularExpression
           ) == nil {
            throw CLIUsageError(
                "ownership --project requires an exact bounded project ID."
            )
        }
        let action: OwnershipCLIAction
        if verb == "status" {
            guard groupID == nil, planSHA256 == nil, fencingToken == nil,
                  priorControllerID == nil, priorExpiry == nil,
                  targetControllerID == nil, leaseSeconds == nil else {
                throw CLIUsageError(
                    "ownership status accepts only optional --project, state, and output selectors."
                )
            }
            action = .status(projectID: projectID)
        } else {
            guard projectID == nil,
                  let groupID, HostwrightResourceUUID.isValid(groupID),
                  let planSHA256,
                  planSHA256.range(
                      of: "^[a-f0-9]{64}$",
                      options: .regularExpression
                  ) != nil,
                  let fencingToken,
                  HostwrightResourceUUID.isValid(fencingToken),
                  let priorControllerID,
                  !priorControllerID.isEmpty,
                  priorControllerID.utf8.count <= 128,
                  priorControllerID.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  let priorExpiry,
                  let expiryDate = ISO8601DateFormatter().date(
                      from: priorExpiry
                  ),
                  ISO8601DateFormatter().string(from: expiryDate) ==
                    priorExpiry,
                  let targetControllerID,
                  let leaseSeconds else {
                throw CLIUsageError(
                    "ownership handoff requires exact group, plan, fence, prior controller/expiry, target controller, and bounded lease values."
                )
            }
            action = .handoff(
                groupID: groupID,
                planSHA256: planSHA256,
                fencingToken: fencingToken,
                priorControllerID: priorControllerID,
                priorExpiry: priorExpiry,
                targetControllerID: targetControllerID,
                leaseSeconds: leaseSeconds
            )
        }
        return .ownership(
            options: OwnershipCLIOptions(
                action: action,
                stateDatabasePath: stateDatabasePath,
                output: output
            )
        )
    }

    private static func capabilitiesCommand(arguments: [String]) throws -> CLICommand {
        let options = Array(arguments.dropFirst())
        if options.isEmpty {
            return .capabilities(output: .text)
        }
        if options == ["--json"] {
            return .capabilities(output: .json)
        }
        if options.count == 2, options[0] == "--output" {
            let value = options[1]
            guard let output = CLIOutputFormat(rawValue: value) else {
                throw CLIUsageError("capabilities --output supports only 'text' or 'json'.")
            }
            return .capabilities(output: output)
        }
        throw CLIUsageError("capabilities supports only --json or --output text|json.")
    }

    private static func observabilityCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2, arguments[1] == "status" else {
            throw CLIUsageError("observability requires status.")
        }
        let options = Array(arguments.dropFirst(2))
        if options.isEmpty {
            return .observabilityStatus(output: .text)
        }
        if options == ["--json"] {
            return .observabilityStatus(output: .json)
        }
        if options.count == 2, options[0] == "--output",
           let output = CLIOutputFormat(rawValue: options[1]) {
            return .observabilityStatus(output: output)
        }
        throw CLIUsageError("observability status supports only --json or --output text|json.")
    }

    private static func runtimeCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2 else {
            throw CLIUsageError("runtime requires providers or migrate.")
        }
        if arguments[1] == "migrate" {
            return try runtimeMigrationCommand(arguments: arguments)
        }
        guard arguments[1] == "providers" else {
            throw CLIUsageError("runtime supports providers and migrate.")
        }
        let options = Array(arguments.dropFirst(2))
        if options.isEmpty {
            return .runtimeProviders(output: .text)
        }
        if options == ["--json"] {
            return .runtimeProviders(output: .json)
        }
        throw CLIUsageError("runtime providers supports only --json.")
    }

    private static func runtimeMigrationCommand(arguments: [String]) throws -> CLICommand {
        var path: String?
        var stateDatabasePath: String?
        var targetProvider: RuntimeProviderID?
        var confirmationToken: String?
        var dryRun = false
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard stateDatabasePath == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("runtime migrate accepts one value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--to":
                guard targetProvider == nil, index + 1 < arguments.count,
                      let selection = RuntimeProviderSelection(rawValue: arguments[index + 1]),
                      let providerID = selection.explicitProviderID else {
                    throw CLIUsageError("runtime migrate --to requires apple-cli or containerization.")
                }
                targetProvider = providerID
                index += 2
            case "--dry-run":
                guard !dryRun, confirmationToken == nil else {
                    throw CLIUsageError("runtime migrate accepts exactly one of --dry-run or --confirm-migration.")
                }
                dryRun = true
                index += 1
            case "--confirm-migration":
                guard confirmationToken == nil, !dryRun, index + 1 < arguments.count else {
                    throw CLIUsageError("runtime migrate accepts exactly one of --dry-run or --confirm-migration.")
                }
                let token = arguments[index + 1]
                guard token.hasPrefix(RuntimeProviderMigrationPlan.confirmationPrefix),
                      token.count == RuntimeProviderMigrationPlan.confirmationPrefix.count + 64 else {
                    throw CLIUsageError("runtime migrate requires the exact token emitted by --dry-run.")
                }
                confirmationToken = token
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("runtime migrate accepts one output selector.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else {
                    throw CLIUsageError("runtime migrate accepts one output selector.")
                }
                output = try parseOutputValue(
                    arguments: arguments,
                    index: index,
                    commandName: "runtime migrate"
                )
                outputSelected = true
                index += 2
            default:
                let argument = arguments[index]
                guard !argument.hasPrefix("-"), path == nil else {
                    throw CLIUsageError("runtime migrate does not support argument '\(argument)'.")
                }
                path = argument
                index += 1
            }
        }
        guard let targetProvider else {
            throw CLIUsageError("runtime migrate requires --to apple-cli|containerization.")
        }
        guard dryRun != (confirmationToken != nil) else {
            throw CLIUsageError("runtime migrate requires exactly one of --dry-run or --confirm-migration <token>.")
        }
        return .runtimeMigrate(
            options: RuntimeProviderMigrationCLIOptions(
                manifestPath: path ?? HostwrightIdentity.manifestFileName,
                stateDatabasePath: stateDatabasePath,
                targetProviderID: targetProvider,
                confirmationToken: confirmationToken,
                output: output
            )
        )
    }

    private static func pathsCommand(arguments: [String]) throws -> CLICommand {
        var stateDatabasePath: String?
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard stateDatabasePath == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("paths accepts one value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--json":
                guard !outputSelected else { throw CLIUsageError("paths accepts one output selector.") }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else { throw CLIUsageError("paths accepts one output selector.") }
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "paths")
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError("paths supports only --state-db, --json, and --output text|json.")
            }
        }
        return .paths(stateDatabasePath: stateDatabasePath, output: output)
    }

    private static func stateCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2 else {
            throw CLIUsageError("state requires integrity, backup, backups, restore, repair, recover, retention, or compact.")
        }
        let operation = arguments[1]
        guard ["integrity", "backup", "backups", "restore", "repair", "recover", "retention", "compact"].contains(operation) else {
            throw CLIUsageError("state supports integrity, backup, backups, restore, repair, recover, retention, and compact.")
        }

        var stateDatabasePath: String?
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var backupID: String?
        var dryRun = false
        var confirmationToken: String?
        var manifestPath: String?
        var index = 2
        if operation == "retention" || operation == "compact" {
            guard index < arguments.count,
                  !arguments[index].hasPrefix("-") else {
                throw CLIUsageError("state \(operation) requires one manifest path.")
            }
            manifestPath = arguments[index]
            index += 1
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard stateDatabasePath == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("state \(operation) accepts one value after --state-db.")
                }
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw CLIUsageError("state \(operation) requires a non-empty path after --state-db.")
                }
                stateDatabasePath = value
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("state \(operation) accepts one output selector.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else {
                    throw CLIUsageError("state \(operation) accepts one output selector.")
                }
                output = try parseOutputValue(
                    arguments: arguments,
                    index: index,
                    commandName: "state \(operation)"
                )
                outputSelected = true
                index += 2
            case "--backup":
                guard operation == "restore", backupID == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("state restore accepts one non-empty value after --backup.")
                }
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw CLIUsageError("state restore requires a non-empty backup identifier.")
                }
                backupID = value
                index += 2
            case "--dry-run":
                guard operation == "restore" || operation == "repair" || operation == "compact", !dryRun else {
                    throw CLIUsageError("state \(operation) accepts --dry-run at most once.")
                }
                dryRun = true
                index += 1
            case "--confirm-restore":
                guard operation == "restore", confirmationToken == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("state restore accepts one value after --confirm-restore.")
                }
                confirmationToken = try parseStateConfirmationToken(
                    arguments[index + 1],
                    flag: "--confirm-restore"
                )
                index += 2
            case "--confirm-repair":
                guard operation == "repair", confirmationToken == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("state repair accepts one value after --confirm-repair.")
                }
                confirmationToken = try parseStateConfirmationToken(
                    arguments[index + 1],
                    flag: "--confirm-repair"
                )
                index += 2
            case "--confirm-compact":
                guard operation == "compact", confirmationToken == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("state compact accepts one value after --confirm-compact.")
                }
                confirmationToken = try parseStateConfirmationToken(
                    arguments[index + 1],
                    flag: "--confirm-compact"
                )
                index += 2
            default:
                throw CLIUsageError("state \(operation) does not support argument '\(arguments[index])'.")
            }
        }

        let action: StateCLIAction
        switch operation {
        case "integrity":
            guard backupID == nil, !dryRun, confirmationToken == nil else {
                throw CLIUsageError("state integrity is read-only and does not accept mutation flags.")
            }
            action = .integrity
        case "backup":
            action = .backup
        case "backups":
            action = .backups
        case "recover":
            action = .recover
        case "retention":
            guard let manifestPath, !dryRun, confirmationToken == nil else {
                throw CLIUsageError("state retention is read-only and accepts one manifest path.")
            }
            action = .retention(manifestPath: manifestPath)
        case "compact":
            guard let manifestPath, dryRun != (confirmationToken != nil) else {
                throw CLIUsageError("state compact requires a manifest and exactly one of --dry-run or --confirm-compact <token>.")
            }
            action = .compact(
                manifestPath: manifestPath,
                confirmation: dryRun ? .dryRun : .confirmed(token: confirmationToken ?? "")
            )
        case "restore":
            guard let backupID else {
                throw CLIUsageError("state restore requires --backup <id>.")
            }
            guard dryRun != (confirmationToken != nil) else {
                throw CLIUsageError("state restore requires exactly one of --dry-run or --confirm-restore <token>.")
            }
            action = .restore(
                backupID: backupID,
                confirmation: dryRun ? .dryRun : .confirmed(token: confirmationToken ?? "")
            )
        case "repair":
            guard dryRun != (confirmationToken != nil) else {
                throw CLIUsageError("state repair requires exactly one of --dry-run or --confirm-repair <token>.")
            }
            action = .repair(
                confirmation: dryRun ? .dryRun : .confirmed(token: confirmationToken ?? "")
            )
        default:
            fatalError("validated state operation was not handled")
        }
        return .state(
            action: action,
            stateDatabasePath: stateDatabasePath,
            output: output
        )
    }

    private static func secretCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 2 else {
            throw CLIUsageError("secret requires create, update, list, check, or delete.")
        }

        let operation = arguments[1]
        let reference: HostwrightSecretReference?
        var index: Int
        if operation == "list" {
            reference = nil
            index = 2
        } else {
            guard ["create", "update", "check", "delete"].contains(operation),
                  arguments.count >= 3 else {
                throw CLIUsageError(
                    "secret requires create, update, list, check, or delete; item operations require keychain://<service>/<account>."
                )
            }
            do {
                let parsed = try HostwrightSecretReference.parse(arguments[2])
                guard parsed.providerKind == .keychain else {
                    throw CLIUsageError(
                        "secret item references must use keychain://<service>/<account>."
                    )
                }
                reference = parsed
            } catch let error as CLIUsageError {
                throw error
            } catch {
                throw CLIUsageError(
                    "secret item references must use keychain://<service>/<account>."
                )
            }
            index = 3
        }

        var stateDatabasePath: String?
        var output: CLIOutputFormat = .text
        var outputSelected = false
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard operation == "create" || operation == "update" || operation == "delete",
                      stateDatabasePath == nil,
                      index + 1 < arguments.count else {
                    throw CLIUsageError("secret accepts one value after --state-db.")
                }
                let value = arguments[index + 1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw CLIUsageError(
                        "secret requires a non-empty path after --state-db."
                    )
                }
                stateDatabasePath = value
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("secret accepts only one output selection.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected, index + 1 < arguments.count,
                      let selected = CLIOutputFormat(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("secret --output supports only text or json.")
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "secret values must be provided through stdin or an attended TTY, never command arguments."
                )
            }
        }

        let action: SecretCLIAction
        switch (operation, reference) {
        case ("create", .some(let reference)):
            action = .create(reference)
        case ("update", .some(let reference)):
            action = .update(reference)
        case ("list", .none):
            action = .list
        case ("check", .some(let reference)):
            action = .check(reference)
        case ("delete", .some(let reference)):
            action = .delete(reference)
        default:
            throw CLIUsageError("Invalid secret operation.")
        }
        return .secret(
            options: SecretCLIOptions(
                action: action,
                stateDatabasePath: stateDatabasePath,
                output: output
            )
        )
    }

    private static func registryCommand(arguments: [String]) throws -> CLICommand {
        if arguments.count > 1,
           arguments[1] == "provenance" {
            return .registry(
                options: try RegistryProvenanceCLIParser.parse(
                    arguments: arguments
                )
            )
        }
        if arguments.count > 1,
           arguments[1] == "vulnerability" {
            return .registry(
                options: try RegistryVulnerabilityCLIParser.parse(
                    arguments: arguments
                )
            )
        }
        if arguments.count > 1, arguments[1] == "sbom" {
            return .registry(
                options: try RegistrySBOMCLIParser.parse(
                    arguments: arguments
                )
            )
        }
        if arguments.count > 1, arguments[1] == "trust" {
            return .registry(
                options: try RegistryTrustCLIParser.parse(
                    arguments: arguments
                )
            )
        }
        if arguments.count > 1, arguments[1] == "referrers" {
            return .registry(
                options: try RegistryReferrerCLIParser.parse(
                    arguments: arguments
                )
            )
        }
        guard arguments.count >= 3,
              ["login", "logout", "status"].contains(arguments[1]) else {
            throw CLIUsageError(
                "registry requires login, logout, or status followed by a registry host."
            )
        }
        let operation = arguments[1]
        let server = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty,
              server.utf8.count <= 512,
              !server.hasPrefix("-") else {
            throw CLIUsageError("registry requires a bounded registry host.")
        }

        var username: String?
        var repository: String?
        var actions: [String] = []
        var stateDatabasePath: String?
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--username":
                guard operation == "login",
                      username == nil,
                      index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "registry login accepts one value after --username."
                    )
                }
                let value = arguments[index + 1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      value.utf8.count <= 256,
                      !value.hasPrefix("-"),
                      value.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw CLIUsageError(
                        "registry login requires a bounded username."
                    )
                }
                username = value
                index += 2
            case "--repository":
                guard operation == "status",
                      repository == nil,
                      index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "registry status accepts one value after --repository."
                    )
                }
                let value = arguments[index + 1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      value.utf8.count <= 255,
                      !value.hasPrefix("-") else {
                    throw CLIUsageError(
                        "registry status requires a bounded repository name."
                    )
                }
                repository = value
                index += 2
            case "--action":
                guard operation == "status",
                      index + 1 < arguments.count,
                      ["pull", "push"].contains(arguments[index + 1]),
                      !actions.contains(arguments[index + 1]) else {
                    throw CLIUsageError(
                        "registry status --action accepts unique pull or push values."
                    )
                }
                actions.append(arguments[index + 1])
                index += 2
            case "--state-db":
                guard operation == "login" || operation == "logout",
                      stateDatabasePath == nil,
                      index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "registry login and logout accept one value after --state-db."
                    )
                }
                let value = arguments[index + 1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw CLIUsageError(
                        "registry requires a non-empty path after --state-db."
                    )
                }
                stateDatabasePath = value
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "registry accepts only one output selection."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected,
                      index + 1 < arguments.count,
                      let selected = CLIOutputFormat(
                          rawValue: arguments[index + 1]
                      ) else {
                    throw CLIUsageError(
                        "registry --output supports only text or json."
                    )
                }
                output = selected
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError(
                    "registry credentials must be provided through stdin or configured credential stores, never command arguments."
                )
            }
        }

        let action: RegistryCLIAction
        switch operation {
        case "login":
            guard let username else {
                throw CLIUsageError(
                    "registry login requires --username <name>; the secret is read from stdin or an attended TTY."
                )
            }
            action = .login(server: server, username: username)
        case "logout":
            guard username == nil,
                  repository == nil,
                  actions.isEmpty else {
                throw CLIUsageError(
                    "registry logout accepts only the registry host and output or state options."
                )
            }
            action = .logout(server: server)
        case "status":
            guard username == nil,
                  stateDatabasePath == nil,
                  repository != nil || actions.isEmpty else {
                throw CLIUsageError(
                    "registry status --action requires --repository."
                )
            }
            action = .status(
                server: server,
                repository: repository,
                actions: actions.isEmpty && repository != nil
                    ? ["pull"]
                    : actions.sorted()
            )
        default:
            preconditionFailure("Validated registry operation was not handled.")
        }
        return .registry(
            options: RegistryCLIOptions(
                action: action,
                stateDatabasePath: stateDatabasePath,
                output: output
            )
        )
    }

    private static func parseStateConfirmationToken(
        _ value: String,
        flag: String
    ) throws -> String {
        guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw CLIUsageError("\(flag) requires the exact 64-character token emitted by the dry-run plan.")
        }
        return value
    }

    private static func migrateCommand(arguments: [String]) throws -> CLICommand {
        guard arguments.count >= 3, arguments[1] == "preview" else {
            throw CLIUsageError("migrate supports only the read-only 'preview <path>' operation.")
        }
        let path = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("-") else {
            throw CLIUsageError("migrate preview requires a manifest path.")
        }

        let options = Array(arguments.dropFirst(3))
        if options.isEmpty {
            return .migrateManifestPreview(path: path, output: .text)
        }
        if options == ["--json"] {
            return .migrateManifestPreview(path: path, output: .json)
        }
        if options.count == 2, options[0] == "--output" {
            let value = options[1]
            guard let output = CLIOutputFormat(rawValue: value) else {
                throw CLIUsageError("migrate preview --output supports only 'text' or 'json'.")
            }
            return .migrateManifestPreview(path: path, output: output)
        }
        throw CLIUsageError("migrate preview supports only --json or --output text|json.")
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
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var runtimeProviderSelected = false
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
            case "--runtime-provider":
                guard !runtimeProviderSelected, index + 1 < arguments.count,
                      let parsed = RuntimeProviderSelection(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("apply accepts one --runtime-provider value: auto, apple-cli, or containerization.")
                }
                runtimeProvider = parsed
                runtimeProviderSelected = true
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
            approvalRecordPath: approvalRecordPath,
            runtimeProvider: runtimeProvider
        )
    }

    private static func statusCommand(arguments: [String]) throws -> CLICommand {
        var path: String?
        var stateDatabasePath: String?
        var output: CLIOutputFormat = .text
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var runtimeProviderSelected = false
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
            case "--runtime-provider":
                guard !runtimeProviderSelected, index + 1 < arguments.count,
                      let parsed = RuntimeProviderSelection(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("status accepts one --runtime-provider value: auto, apple-cli, or containerization.")
                }
                runtimeProvider = parsed
                runtimeProviderSelected = true
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

        return .status(
            path: path ?? HostwrightIdentity.manifestFileName,
            stateDatabasePath: stateDatabasePath,
            output: output,
            runtimeProvider: runtimeProvider
        )
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
        var follows = false
        var runtimeProvider = RuntimeProviderSelection.automatic
        var runtimeProviderSelected = false
        var timeoutSeconds = 300
        var timeoutSelected = false
        var output = CLIOutputFormat.text
        var outputSelected = false
        var index = 2

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--follow":
                guard !follows else {
                    throw CLIUsageError("logs accepts --follow once.")
                }
                follows = true
                index += 1
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
            case "--runtime-provider":
                guard !runtimeProviderSelected,
                      index + 1 < arguments.count,
                      let selected = RuntimeProviderSelection(
                          rawValue: arguments[index + 1]
                      ) else {
                    throw CLIUsageError(
                        "logs --runtime-provider requires auto, apple-cli, or containerization."
                    )
                }
                runtimeProvider = selected
                runtimeProviderSelected = true
                index += 2
            case "--timeout":
                guard !timeoutSelected,
                      index + 1 < arguments.count,
                      let selected = Int(arguments[index + 1]),
                      (1...LifecycleCLIParser.maximumTimeoutSeconds).contains(selected) else {
                    throw CLIUsageError(
                        "logs --timeout must be between 1 and \(LifecycleCLIParser.maximumTimeoutSeconds) seconds."
                    )
                }
                timeoutSeconds = selected
                timeoutSelected = true
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("logs accepts one output selector.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected,
                      index + 1 < arguments.count,
                      let selected = CLIOutputFormat(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("logs --output supports only text or json.")
                }
                output = selected
                outputSelected = true
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

        if follows {
            return .interactive(
                options: InteractiveCLIOptions(
                    command: .logsFollow,
                    manifestPath: path ?? HostwrightIdentity.manifestFileName,
                    serviceName: serviceName,
                    stateDatabasePath: stateDatabasePath,
                    runtimeProvider: runtimeProvider,
                    timeoutSeconds: timeoutSeconds,
                    output: output,
                    terminal: false,
                    forwardsStandardInput: false,
                    tail: tail
                )
            )
        }
        guard !runtimeProviderSelected, !timeoutSelected, !outputSelected else {
            throw CLIUsageError(
                "logs runtime-provider, timeout, and output selectors require --follow."
            )
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
        var cursor: String?
        var watch = false
        var timeoutSeconds = EventStreamCLIOptions.defaultTimeoutSeconds
        var timeoutSelected = false
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
                projectName = try eventFilterValue(arguments[index + 1], label: "project")
                index += 2
            case "--type":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("events requires a value after --type.")
                }
                eventType = try eventFilterValue(arguments[index + 1], label: "type")
                index += 2
            case "--service":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("events requires a value after --service.")
                }
                serviceName = try eventFilterValue(arguments[index + 1], label: "service")
                index += 2
            case "--severity":
                guard index + 1 < arguments.count, let parsed = StateEventSeverity(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("events --severity supports only 'info', 'warning', or 'error'.")
                }
                severity = parsed
                index += 2
            case "--limit":
                guard index + 1 < arguments.count,
                      let parsed = Int(arguments[index + 1]),
                      (1...HostwrightEventStreamPage.maximumPageSize).contains(parsed) else {
                    throw CLIUsageError(
                        "events --limit must be between 1 and \(HostwrightEventStreamPage.maximumPageSize)."
                    )
                }
                limit = parsed
                index += 2
            case "--sort":
                guard index + 1 < arguments.count, let parsed = EventSortOrder(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError("events --sort supports only 'asc' or 'desc'.")
                }
                sort = parsed
                index += 2
            case "--cursor":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("events requires a value after --cursor.")
                }
                let value = arguments[index + 1]
                guard !value.isEmpty,
                      value.utf8.count <= HostwrightEventCursor.maximumTokenBytes else {
                    throw CLIUsageError("events --cursor is empty or exceeds the cursor limit.")
                }
                cursor = value
                index += 2
            case "--watch":
                watch = true
                index += 1
            case "--timeout":
                guard index + 1 < arguments.count,
                      let parsed = Int(arguments[index + 1]),
                      (1...EventStreamCLIOptions.maximumTimeoutSeconds).contains(parsed) else {
                    throw CLIUsageError(
                        "events --timeout must be between 1 and \(EventStreamCLIOptions.maximumTimeoutSeconds) seconds."
                    )
                }
                timeoutSeconds = parsed
                timeoutSelected = true
                index += 2
            case "--output":
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "events")
                index += 2
            default:
                throw CLIUsageError("events supports only --state-db, --project, --type, --service, --severity, --limit, --sort, --cursor, --watch, --timeout, and --output.")
            }
        }

        guard !timeoutSelected || watch else {
            throw CLIUsageError("events --timeout requires --watch.")
        }
        guard (cursor == nil && !watch) || sort == .ascending else {
            throw CLIUsageError("events cursor and watch modes require --sort asc.")
        }

        return .events(
            stateDatabasePath: stateDatabasePath,
            projectName: projectName,
            filters: EventFilters(type: eventType, serviceName: serviceName, severity: severity, limit: limit, sort: sort),
            stream: EventStreamCLIOptions(
                cursor: cursor,
                watch: watch,
                timeoutSeconds: timeoutSeconds
            ),
            output: output
        )
    }

    private static func eventFilterValue(_ value: String, label: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value.range(of: "^[ -~]+$", options: .regularExpression) != nil else {
            throw CLIUsageError("events --\(label) must be printable text within 255 bytes.")
        }
        return value
    }

    private static func recoveryCommand(arguments: [String]) throws -> CLICommand {
        var stateDatabasePath: String?
        var projectName: String?
        var output: CLIOutputFormat = .text
        var groupID: String?
        var confirmationPlanSHA256: String?
        var timeoutSeconds = 120
        let operation: String?
        var index: Int

        if arguments.count > 1, ["resume", "rollback"].contains(arguments[1]) {
            operation = arguments[1]
            index = 2
        } else {
            operation = nil
            index = 1
        }

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
            case "--group":
                guard operation != nil, groupID == nil, index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "recovery resume/rollback requires exactly one value after --group."
                    )
                }
                let candidate = arguments[index + 1].lowercased()
                guard HostwrightResourceUUID.isValid(candidate) else {
                    throw CLIUsageError(
                        "recovery --group requires the exact lifecycle operation-group UUID."
                    )
                }
                groupID = candidate
                index += 2
            case "--confirm-plan":
                guard operation != nil,
                      confirmationPlanSHA256 == nil,
                      index + 1 < arguments.count else {
                    throw CLIUsageError(
                        "recovery resume/rollback requires exactly one value after --confirm-plan."
                    )
                }
                let digest = arguments[index + 1].lowercased()
                guard digest.count == 64,
                      digest.allSatisfy({ $0.isHexDigit }) else {
                    throw CLIUsageError(
                        "recovery --confirm-plan requires the exact 64-character SHA-256 shown by recovery status."
                    )
                }
                confirmationPlanSHA256 = digest
                index += 2
            case "--timeout":
                guard operation != nil,
                      index + 1 < arguments.count,
                      let parsed = Int(arguments[index + 1]),
                      (1...RuntimeCommandTimeout.maximumSeconds).contains(parsed) else {
                    throw CLIUsageError(
                        "recovery resume/rollback --timeout must be between 1 and " +
                            "\(RuntimeCommandTimeout.maximumSeconds) seconds."
                    )
                }
                timeoutSeconds = parsed
                index += 2
            default:
                throw CLIUsageError(
                    "recovery supports inspection or the confirmed resume/rollback operations."
                )
            }
        }

        let action: RecoveryCLIAction
        switch operation {
        case nil:
            action = .inspect
        case "resume":
            guard let groupID, let confirmationPlanSHA256 else {
                throw CLIUsageError(
                    "recovery resume requires --group <uuid> and --confirm-plan <sha256>."
                )
            }
            action = .resume(
                groupID: groupID,
                confirmationPlanSHA256: confirmationPlanSHA256,
                timeoutSeconds: timeoutSeconds
            )
        case "rollback":
            guard let groupID, let confirmationPlanSHA256 else {
                throw CLIUsageError(
                    "recovery rollback requires --group <uuid> and --confirm-plan <sha256>."
                )
            }
            action = .rollback(
                groupID: groupID,
                confirmationPlanSHA256: confirmationPlanSHA256,
                timeoutSeconds: timeoutSeconds
            )
        default:
            preconditionFailure("Recovery parser admitted an unknown operation.")
        }

        return .recovery(
            action: action,
            stateDatabasePath: stateDatabasePath,
            projectName: projectName,
            output: output
        )
    }

    private static func doctorCommand(arguments: [String]) throws -> CLICommand {
        var stateDatabasePath: String?
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                guard stateDatabasePath == nil, index + 1 < arguments.count else {
                    throw CLIUsageError("doctor requires one value after --state-db.")
                }
                stateDatabasePath = arguments[index + 1]
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("doctor output format may be selected only once.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else {
                    throw CLIUsageError("doctor output format may be selected only once.")
                }
                output = try parseOutputValue(arguments: arguments, index: index, commandName: "doctor")
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError("doctor supports only --state-db, --json, and --output.")
            }
        }
        return .doctor(stateDatabasePath: stateDatabasePath, output: output)
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

public struct EventStreamCLIOptions: Equatable, Sendable {
    public static let defaultTimeoutSeconds = 30
    public static let maximumTimeoutSeconds = 300

    public let cursor: String?
    public let watch: Bool
    public let timeoutSeconds: Int

    public init(
        cursor: String? = nil,
        watch: Bool = false,
        timeoutSeconds: Int = EventStreamCLIOptions.defaultTimeoutSeconds
    ) {
        self.cursor = cursor
        self.watch = watch
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum CleanupConfirmation: Equatable, Sendable {
    case dryRun
    case confirmed(token: String)
}

public enum StateCLIAction: Equatable, Sendable {
    case integrity
    case backup
    case backups
    case restore(backupID: String, confirmation: StateMutationConfirmation)
    case repair(confirmation: StateMutationConfirmation)
    case recover
    case retention(manifestPath: String)
    case compact(manifestPath: String, confirmation: StateMutationConfirmation)
}

public enum StateMutationConfirmation: Equatable, Sendable {
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
        case .secretInvalid:
            return .validation
        case .secretUnavailable:
            return .runtimeUnavailable
        case .secretNotFound:
            return .stateUnavailable
        case .secretConflict, .secretCancelled, .secretPartialEffect:
            return .partialFailure
        case .secretDenied:
            return .unsafeOperation
        case .registryInvalid:
            return .validation
        case .registryCredentialUnavailable, .registryTransportUnavailable:
            return .runtimeUnavailable
        case .registryAuthenticationDenied, .registryScopeDenied:
            return .unsafeOperation
        case .registryCancelled, .registryPartialEffect:
            return .partialFailure
        case .imageInvalid:
            return .validation
        case .imageUnavailable:
            return .runtimeUnavailable
        case .imageConflict, .imageCancelled, .imagePartialEffect:
            return .partialFailure
        case .imageDenied:
            return .unsafeOperation
        case .storageInvalid:
            return .validation
        case .storageUnavailable:
            return .runtimeUnavailable
        case .storageConflict, .storageCancelled,
             .storagePartialEffect:
            return .partialFailure
        case .storageDenied:
            return .unsafeOperation
        case .daemonInvalid:
            return .validation
        case .daemonUnavailable:
            return .runtimeUnavailable
        case .daemonConflict, .daemonCancelled, .daemonPartialEffect:
            return .partialFailure
        case .daemonDenied:
            return .unsafeOperation
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
