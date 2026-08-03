import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightState

public struct CLIControlAuthorizationScope: Equatable, Sendable {
    public let projectIdentifier: String?
    public let resourceIdentifier: String?

    public init(projectIdentifier: String?, resourceIdentifier: String?) {
        self.projectIdentifier = projectIdentifier
        self.resourceIdentifier = resourceIdentifier
    }
}

public enum CLIControlAuthorizationScopeResolver {
    public static func withExecutionAuthorizationFence<T>(
        command: CLICommand,
        environment: CLIEnvironment,
        _ body: () throws -> T
    ) throws -> T {
        guard let stateDatabasePath = try stateDatabasePath(
            for: command,
            environment: environment
        ) else {
            return try body()
        }
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
        )
        return try StateUpgradeService(store: store).withExclusiveLifecycleFence(body)
    }

    public static func validate(
        declared: CLIControlAuthorizationScope,
        command: CLICommand,
        arguments: [String],
        environment: CLIEnvironment
    ) throws {
        let authoritative = try resolve(
            command: command,
            arguments: arguments,
            environment: environment
        )
        guard authoritative == declared else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The declared CLI authorization scope does not match the authoritative command target."
            )
        }
    }

    public static func resolve(
        command: CLICommand,
        arguments: [String],
        environment: CLIEnvironment
    ) throws -> CLIControlAuthorizationScope {
        let explicitProject = option("--project", in: arguments)
        let explicitServices = options("--service", in: arguments)
        let manifestPath = manifestPath(for: command)
        let directProject = directProjectIdentifier(for: command)
        let projectStateID: String?
        if let directProject {
            projectStateID = directProject.hasPrefix("project-")
                ? directProject : "project-\(directProject)"
        } else if let explicitProject {
            projectStateID = explicitProject.hasPrefix("project-")
                ? explicitProject : "project-\(explicitProject)"
        } else if let manifestPath {
            let text = try environment.readTextFile(manifestPath)
            guard let project = try ManifestValidator.validated(text).project, !project.isEmpty else {
                throw HostwrightDiagnostic(
                    code: .manifestValidationFailed,
                    message: "The command manifest does not declare an authorization project."
                )
            }
            projectStateID = "project-\(project)"
        } else {
            projectStateID = nil
        }

        var projectIdentifier = projectStateID.map {
            HostwrightResourceUUID.legacy(kind: "project", identifier: $0)
        }

        var serviceNames = explicitServices
        if serviceNames.isEmpty, case .interactive(let options) = command {
            serviceNames = [try InteractiveOperationBuilder.requestedService(options)]
        } else if serviceNames.isEmpty, case .logs(let serviceName, _, _, _) = command {
            serviceNames = [serviceName]
        }
        guard let projectStateID,
              let stateDatabasePath = try stateDatabasePath(for: command, environment: environment),
              environment.fileExists(stateDatabasePath) else {
            return CLIControlAuthorizationScope(
                projectIdentifier: projectIdentifier,
                resourceIdentifier: nil
            )
        }
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
        )
        guard try store.schemaVersion() == HostwrightContractVersions.stateSchema else {
            throw HostwrightDiagnostic(
                code: .stateStoreUnavailable,
                message: "The daemon state schema cannot establish the requested authorization scope."
            )
        }
        if let project = try? store.desiredStates.loadProject(id: projectStateID) {
            guard HostwrightResourceUUID.isValid(project.resourceUUID) else {
                throw HostwrightDiagnostic(
                    code: .stateStoreUnavailable,
                    message: "The daemon state cannot establish the requested project UUID."
                )
            }
            projectIdentifier = project.resourceUUID
        }
        guard serviceNames.count == 1 else {
            return CLIControlAuthorizationScope(
                projectIdentifier: projectIdentifier,
                resourceIdentifier: nil
            )
        }
        let matches = try store.ownership.loadAll().filter {
            $0.projectID == projectStateID && $0.serviceName == serviceNames[0]
        }
        guard matches.count <= 1 else {
            throw HostwrightDiagnostic(
                code: .stateStoreUnavailable,
                message: "The requested service has ambiguous authorization ownership."
            )
        }
        return CLIControlAuthorizationScope(
            projectIdentifier: projectIdentifier,
            resourceIdentifier: matches.first?.resourceUUID
        )
    }

    public static func manifestPath(for command: CLICommand) -> String? {
        switch command {
        case .runtimeMigrate(let options): return options.manifestPath
        case .validate(let path, _), .plan(let path, _, _), .status(let path, _, _, _),
             .apply(let path, _, _, _, _, _), .cleanup(let path, _, _, _, _):
            return path
        case .lifecycle(let options): return options.manifestPath
        case .interactive(let options): return options.manifestPath
        case .logs(_, let path, _, _): return path
        case .maintenance(let options):
            if case .preview(let path, _, _) = options.action { return path }
            return nil
        case .supportBundle(let options): return options.manifestPath
        case .diagnostics(_, _, _, let manifestPath): return manifestPath
        default: return nil
        }
    }

    private static func directProjectIdentifier(for command: CLICommand) -> String? {
        switch command {
        case .events(_, let projectName, _, _, _),
             .recovery(_, _, let projectName, _):
            return projectName
        case .supportBundle(let options): return options.projectName
        case .diagnostics(_, _, let projectName, _): return projectName
        case .restartBudget(let options):
            switch options.action {
            case .status(let projectID): return projectID
            case .release(let projectID, _, _): return projectID
            }
        case .maintenance(let options):
            switch options.action {
            case .preview: return nil
            case .status(let projectID): return projectID
            case .cancel(let projectID, _), .override(let projectID, _, _): return projectID
            }
        default: return nil
        }
    }

    private static func stateDatabasePath(
        for command: CLICommand,
        environment: CLIEnvironment
    ) throws -> String? {
        let explicit: String?
        switch command {
        case .runtimeMigrate(let options): explicit = options.stateDatabasePath
        case .status(_, let path, _, _), .apply(_, let path, _, _, _, _),
             .logs(_, _, _, let path), .events(let path, _, _, _, _),
             .recovery(_, let path, _, _), .cleanup(_, let path, _, _, _),
             .diagnostics(let path, _, _, _): explicit = path
        case .lifecycle(let options): explicit = options.stateDatabasePath
        case .interactive(let options): explicit = options.stateDatabasePath
        case .restartBudget(let options): explicit = options.stateDatabasePath
        case .maintenance(let options): explicit = options.stateDatabasePath
        case .supportBundle(let options): explicit = options.stateDatabasePath
        default: return nil
        }
        return try environment.localPathResolution(explicit).stateDatabasePath
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        options(name, in: arguments).first
    }

    private static func options(_ name: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == name, arguments.indices.contains(index + 1) {
                values.append(arguments[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return values
    }
}
