import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

public enum CLIControlTransportKind: String, Codable, Equatable, Sendable {
    case localPresentation = "local-presentation"
    case bootstrapAPI = "bootstrap-api"
    case persistentControlAPI = "persistent-control-api"
}

public enum CLIControlExecutionKind: Equatable, Sendable {
    case unary
    case stream(ControlStreamSource)
}

public struct CLIControlRoute: Equatable, Sendable {
    public static let bodySchemaVersion = 1
    public static let maximumArgumentCount = 512
    public static let maximumArgumentBytes = 16 * 1_024
    public static let maximumCombinedArgumentBytes = 48 * 1_024

    public let transport: CLIControlTransportKind
    public let execution: CLIControlExecutionKind
    public let operation: String
    public let subcommand: String
    public let mutating: Bool
    public let output: CLIOutputFormat
    public let arguments: [String]
    public let authorizationScope: CLIControlAuthorizationScope
    public let workingDirectory: String?

    public static func classify(arguments: [String]) throws -> CLIControlRoute {
        try validateArguments(arguments)
        let command = try CLICommand.parse(arguments: arguments)
        let output = CLICommand.outputFormatHint(arguments: arguments) ?? .text
        let operation = normalizedOperation(arguments)
        let subcommand = semanticSubcommand(arguments)
        let transport: CLIControlTransportKind
        let execution: CLIControlExecutionKind

        switch command {
        case .help, .version:
            transport = .localPresentation
            execution = .unary
        case .daemon(let options):
            switch options.action {
            case .lifecycle(.install), .lifecycle(.repair), .lifecycle(.uninstall):
                transport = .bootstrapAPI
            default:
                transport = .persistentControlAPI
            }
            execution = .unary
        case .interactive(let options):
            transport = .persistentControlAPI
            switch options.command {
            case .exec: execution = .stream(.exec)
            case .attach: execution = .stream(.attach)
            case .logsFollow: execution = .stream(.logs)
            case .copy, .export, .inspect, .stats: execution = .unary
            }
        case .logs:
            transport = .persistentControlAPI
            execution = .stream(.logs)
        case .events(_, _, _, let stream, _):
            transport = .persistentControlAPI
            execution = stream.cursor == nil && !stream.watch ? .unary : .stream(.events)
        default:
            transport = .persistentControlAPI
            execution = .unary
        }

        return CLIControlRoute(
            transport: transport,
            execution: execution,
            operation: operation,
            subcommand: subcommand,
            mutating: mutationIntent(command: command, operation: operation, subcommand: subcommand),
            output: output,
            arguments: arguments,
            authorizationScope: CLIControlAuthorizationScope(
                projectIdentifier: nil,
                resourceIdentifier: nil
            ),
            workingDirectory: nil
        )
    }

    public func withAuthorizationScope(_ scope: CLIControlAuthorizationScope) -> Self {
        CLIControlRoute(
            transport: transport,
            execution: execution,
            operation: operation,
            subcommand: subcommand,
            mutating: mutating,
            output: output,
            arguments: arguments,
            authorizationScope: scope,
            workingDirectory: workingDirectory
        )
    }

    public func withWorkingDirectory(_ path: String) throws -> Self {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI working directory is not a canonical absolute path."
            )
        }
        return CLIControlRoute(
            transport: transport,
            execution: execution,
            operation: operation,
            subcommand: subcommand,
            mutating: mutating,
            output: output,
            arguments: arguments,
            authorizationScope: authorizationScope,
            workingDirectory: path
        )
    }

    public func requestBody() -> ControlPlaneJSONValue {
        .object([
            "arguments": .array(arguments.map(ControlPlaneJSONValue.string)),
            "authorizationProjectID": authorizationScope.projectIdentifier
                .map(ControlPlaneJSONValue.string) ?? .null,
            "authorizationResourceID": authorizationScope.resourceIdentifier
                .map(ControlPlaneJSONValue.string) ?? .null,
            "commandOperation": .string(operation),
            "commandSchemaVersion": .integer(Int64(Self.bodySchemaVersion)),
            "mutating": .bool(mutating),
            "subcommand": .string(subcommand),
            "workingDirectory": workingDirectory.map(ControlPlaneJSONValue.string) ?? .null,
        ])
    }

    public static func validate(
        request: ControlRequestEnvelope,
        expectedTransport: CLIControlTransportKind = .persistentControlAPI
    ) throws -> CLIControlRoute? {
        guard case .object(let fields)? = request.body,
              fields["commandSchemaVersion"] != nil || fields["commandOperation"] != nil else {
            return nil
        }
        guard Set(fields.keys) == [
            "arguments", "authorizationProjectID", "authorizationResourceID",
            "commandOperation", "commandSchemaVersion", "mutating", "subcommand",
            "workingDirectory",
        ],
              case .integer(Int64(bodySchemaVersion))? = fields["commandSchemaVersion"],
              case .array(let encodedArguments)? = fields["arguments"],
              case .string(let declaredOperation)? = fields["commandOperation"],
              case .bool(let declaredMutation)? = fields["mutating"],
              case .string(let declaredSubcommand)? = fields["subcommand"] else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI control request body does not match command schema v1."
            )
        }
        let declaredScope = try authorizationScope(fields)
        let declaredWorkingDirectory = try workingDirectory(fields)
        let arguments = try encodedArguments.map { value -> String in
            guard case .string(let argument) = value else {
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "CLI control arguments must be strings."
                )
            }
            return argument
        }
        let route = try classify(arguments: arguments)
        guard route.transport == expectedTransport,
              route.operation == request.operation,
              route.operation == declaredOperation,
              route.subcommand == declaredSubcommand,
              route.mutating == declaredMutation else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI control request metadata does not match its parsed command."
            )
        }
        let scoped = route.withAuthorizationScope(declaredScope)
        return try declaredWorkingDirectory.map(scoped.withWorkingDirectory) ?? scoped
    }

    public static func validateStreamPreparation(
        request: ControlRequestEnvelope
    ) throws -> CLIControlRoute? {
        guard request.operation == CLIControlStreamPreparationContract.operation else {
            return nil
        }
        guard case .object(let fields)? = request.body,
              Set(fields.keys) == [
                "arguments", "authorizationProjectID", "authorizationResourceID",
                "commandOperation", "commandSchemaVersion", "mutating", "subcommand",
                "workingDirectory",
            ],
              case .integer(Int64(bodySchemaVersion))? = fields["commandSchemaVersion"],
              case .array(let encodedArguments)? = fields["arguments"],
              case .string(let declaredOperation)? = fields["commandOperation"],
              case .bool(let declaredMutation)? = fields["mutating"],
              case .string(let declaredSubcommand)? = fields["subcommand"] else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The stream preparation body does not match command schema v1."
            )
        }
        let declaredScope = try authorizationScope(fields)
        let declaredWorkingDirectory = try workingDirectory(fields)
        let arguments = try encodedArguments.map { value -> String in
            guard case .string(let argument) = value else {
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "CLI stream preparation arguments must be strings."
                )
            }
            return argument
        }
        let route = try classify(arguments: arguments)
        guard route.transport == .persistentControlAPI,
              route.operation == declaredOperation,
              route.subcommand == declaredSubcommand,
              route.mutating == declaredMutation,
              case .stream = route.execution else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The stream preparation metadata does not match its parsed command."
            )
        }
        let scoped = route.withAuthorizationScope(declaredScope)
        return try declaredWorkingDirectory.map(scoped.withWorkingDirectory) ?? scoped
    }

    private static func authorizationScope(
        _ fields: [String: ControlPlaneJSONValue]
    ) throws -> CLIControlAuthorizationScope {
        func optionalIdentifier(_ key: String) throws -> String? {
            guard let value = fields[key] else {
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "The CLI authorization scope is incomplete."
                )
            }
            switch value {
            case .null: return nil
            case .string(let identifier):
                guard !identifier.isEmpty, identifier.utf8.count <= 128,
                      identifier.range(
                        of: "^[A-Za-z0-9._:-]+$",
                        options: .regularExpression
                      ) != nil else {
                    throw HostwrightDiagnostic(
                        code: .controlAPIInvalid,
                        message: "The CLI authorization scope is invalid."
                    )
                }
                return identifier
            default:
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "The CLI authorization scope is invalid."
                )
            }
        }
        return CLIControlAuthorizationScope(
            projectIdentifier: try optionalIdentifier("authorizationProjectID"),
            resourceIdentifier: try optionalIdentifier("authorizationResourceID")
        )
    }

    private static func workingDirectory(
        _ fields: [String: ControlPlaneJSONValue]
    ) throws -> String? {
        guard let value = fields["workingDirectory"] else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI request working directory is missing."
            )
        }
        switch value {
        case .null:
            return nil
        case .string(let path):
            guard path.hasPrefix("/"), path.utf8.count <= 4_096,
                  URL(fileURLWithPath: path).standardizedFileURL.path == path else {
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "The CLI request working directory is invalid."
                )
            }
            return path
        default:
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI request working directory is invalid."
            )
        }
    }

    private static func validateArguments(_ arguments: [String]) throws {
        let combined = arguments.reduce(0) { $0 + $1.utf8.count }
        guard arguments.count <= maximumArgumentCount,
              combined <= maximumCombinedArgumentBytes,
              arguments.allSatisfy({ $0.utf8.count <= maximumArgumentBytes }) else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The CLI command exceeds the bounded Control API argument limits."
            )
        }
    }

    private static func normalizedOperation(_ arguments: [String]) -> String {
        guard let first = arguments.first else { return "help" }
        if first == "extension", arguments.count >= 2, arguments[1] != "check" {
            return "plugin.\(arguments[1])"
        }
        switch first {
        case "--version": return "version"
        case "--help", "-h": return "help"
        case "scheduler":
            guard arguments.count >= 2, !arguments[1].hasPrefix("-") else {
                return first
            }
            return "scheduler.\(arguments[1])"
        default: return first
        }
    }

    private static func semanticSubcommand(_ arguments: [String]) -> String {
        guard let operation = arguments.first else { return "help" }
        if ["--version", "version", "--help", "-h", "help"].contains(operation) {
            return normalizedOperation(arguments)
        }
        func value(_ index: Int) -> String? {
            guard arguments.indices.contains(index), !arguments[index].hasPrefix("-") else {
                return nil
            }
            return arguments[index]
        }
        switch operation {
        case "extension":
            return value(1) ?? operation
        case "registry":
            guard let first = value(1) else { return operation }
            if ["referrers", "trust", "sbom", "vulnerability", "provenance"].contains(first),
               let second = value(2) {
                return "\(first).\(second)"
            }
            return first
        case "image", "volume":
            guard let first = value(1) else { return operation }
            if ["backup", "cache", "snapshot", "remote"].contains(first),
               let second = value(2) {
                return "\(first).\(second)"
            }
            return first
        case "diagnostics":
            if value(1) == "support", let verb = value(2) { return "support.\(verb)" }
            return "inspect"
        default:
            return value(1) ?? operation
        }
    }

    private static func mutationIntent(
        command: CLICommand,
        operation: String,
        subcommand: String
    ) -> Bool {
        switch command {
        case .version, .help, .capabilities, .observabilityStatus, .runtimeProviders,
             .paths, .migrateManifestPreview, .importStack, .validate, .plan, .status,
             .logs, .doctor:
            return false
        case .runtimeMigrate, .apply, .lifecycle, .cleanup, .benchmark, .extensionCheck,
             .initManifest:
            return true
        case .plugin(let options):
            switch options.action {
            case .list, .status, .discover: return false
            case .install, .update, .activate, .rollback, .revoke, .quarantine, .uninstall:
                return true
            }
        case .events:
            return false
        case .interactive(let options):
            return ![.inspect, .stats].contains(options.command)
        case .state(let action, _, _):
            switch action {
            case .integrity, .backups: return false
            case .backup, .restore, .repair, .recover, .retention, .compact: return true
            }
        case .secret(let options):
            switch options.action {
            case .list, .check: return false
            case .create, .update, .delete: return true
            }
        case .daemon(let options):
            switch options.action {
            case .status, .lifecycle(.validate): return false
            case .lifecycle: return true
            }
        case .restartBudget(let options):
            if case .status = options.action { return false }
            return true
        case .maintenance(let options):
            switch options.action {
            case .preview, .status: return false
            case .cancel, .override: return true
            }
        case .ownership(let options):
            if case .status = options.action { return false }
            return true
        case .metrics:
            return false
        case .traces:
            return false
        case .supportBundle(let options):
            switch options.action {
            case .status, .preview: return false
            case .create, .delete, .recover: return true
            }
        case .recovery(let action, _, _, _):
            if case .inspect = action { return false }
            return true
        case .diagnostics:
            return false
        case .scheduler(let options):
            return options.action == .apply
        case .registry(let options):
            switch options.action {
            case .status:
                return false
            case .referrers(let action):
                if case .status = action { return false }
                return true
            case .trust(let action):
                if case .status = action { return false }
                return true
            case .sbom(let action):
                if case .query = action { return false }
                return true
            case .vulnerability(let action):
                if case .status = action { return false }
                return true
            case .provenance(let action):
                if case .status = action { return false }
                return true
            case .login, .logout:
                return true
            }
        case .image(let options):
            switch options.action {
            case .inspect, .cacheStatus:
                return false
            case .pull, .push, .tag, .load, .save, .build, .delete, .prune,
                 .pin, .unpin:
                return true
            }
        case .volume(let options):
            switch options.action {
            case .list, .inspect, .capacity, .health:
                return false
            case .recover, .delete, .prune:
                return true
            case .snapshot(let action):
                switch action {
                case .list, .inspect: return false
                case .create, .retain, .export, .restore, .delete: return true
                }
            case .backup(let action):
                switch action {
                case .list, .inspect, .verify: return false
                case .create, .retain, .restore, .delete: return true
                }
            }
        }
    }
}
