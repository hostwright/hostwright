import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightManifest
import HostwrightCore

public struct CLIControlPreparedCommand: @unchecked Sendable {
    public let request: ControlRequestEnvelope
    public let route: CLIControlRoute
    public let environment: CLIEnvironment
}

public enum CLIControlCommandExecutor {
    public static func prepare(
        request: ControlRequestEnvelope,
        environment: CLIEnvironment,
        streamPreparation: Bool = false
    ) throws -> CLIControlPreparedCommand? {
        guard let route = try streamPreparation
            ? CLIControlRoute.validateStreamPreparation(request: request)
            : CLIControlRoute.validate(request: request) else {
            return nil
        }
        let commandEnvironment = try environment.resolvingRelativePaths(
            against: route.workingDirectory
        )
        if !streamPreparation, case .stream = route.execution {
            return CLIControlPreparedCommand(
                request: request,
                route: route,
                environment: commandEnvironment
            )
        }
        let command = try CLICommand.parse(arguments: route.arguments)
        let snapshotEnvironment = try snapshottingCommandInputs(
            command: command,
            environment: commandEnvironment
        )
        let authoritativeScope = try CLIControlAuthorizationScopeResolver.resolve(
            command: command,
            arguments: route.arguments,
            environment: snapshotEnvironment
        )
        guard authoritativeScope == route.authorizationScope else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The declared CLI authorization scope does not match the daemon-authoritative target."
            )
        }
        let authoritativeRoute = route.withAuthorizationScope(authoritativeScope)
        let authoritativeRequest = ControlRequestEnvelope(
            apiVersion: request.apiVersion,
            protocolRevision: request.protocolRevision,
            requestID: request.requestID,
            operation: request.operation,
            timeoutMilliseconds: request.timeoutMilliseconds,
            idempotencyKey: request.idempotencyKey,
            body: authoritativeRoute.requestBody()
        )
        return CLIControlPreparedCommand(
            request: authoritativeRequest,
            route: authoritativeRoute,
            environment: snapshotEnvironment
        )
    }

    public static func execute(
        prepared: CLIControlPreparedCommand
    ) throws -> ControlResponseEnvelope {
        let request = prepared.request
        let route = prepared.route
        guard route.execution == .unary else {
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .rejected,
                reasonCode: .unsupportedOperation,
                error: SanitizedError(
                    code: "streamRequired",
                    message: "This CLI operation requires the persistent streaming protocol."
                )
            )
        }
        let command = try CLICommand.parse(arguments: route.arguments)
        return try CLIControlAuthorizationScopeResolver.withExecutionAuthorizationFence(
            command: command,
            arguments: route.arguments,
            authorizedScope: route.authorizationScope,
            environment: prepared.environment,
            mutating: prepared.route.mutating
        ) {
            let result = HostwrightCLI.run(
                arguments: route.arguments,
                environment: prepared.environment
            )
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: result.exitCode == 0 ? .completed : .error,
                reasonCode: result.exitCode == 0 ? .completed : .internalError,
                result: try CLIControlResultContract.value(result),
                error: result.exitCode == 0 ? nil : SanitizedError(
                    code: "cliExitNonZero",
                    message: "The delegated CLI command returned a non-zero exit status."
                )
            )
        }
    }

    public static func execute(
        request: ControlRequestEnvelope,
        environment: CLIEnvironment
    ) throws -> ControlResponseEnvelope? {
        guard let prepared = try prepare(request: request, environment: environment) else {
            return nil
        }
        return try execute(prepared: prepared)
    }

    private static func snapshottingCommandInputs(
        command: CLICommand,
        environment: CLIEnvironment
    ) throws -> CLIEnvironment {
        switch command {
        case .importStack(let path, _, let teamProfilePath):
            return try snapshottingTextFiles(
                [path, teamProfilePath].compactMap { $0 },
                environment: environment,
                validateManifest: false
            )
        case .migrateManifestPreview(let path, _):
            return try snapshottingTextFiles(
                [path],
                environment: environment,
                validateManifest: false
            )
        default:
            break
        }
        guard let manifestPath = CLIControlAuthorizationScopeResolver.manifestPath(for: command)
        else { return environment }
        return try snapshottingTextFiles(
            [manifestPath],
            environment: environment,
            validateManifest: true
        )
    }

    private static func snapshottingTextFiles(
        _ paths: [String],
        environment: CLIEnvironment,
        validateManifest: Bool
    ) throws -> CLIEnvironment {
        var snapshots: [String: String] = [:]
        for path in paths {
            let text = try environment.readTextFile(path)
            if validateManifest { _ = try ManifestValidator.validated(text) }
            snapshots[path] = text
        }
        var snapshot = environment
        let originalExists = environment.fileExists
        let originalRead = environment.readTextFile
        snapshot.fileExists = { candidate in
            snapshots[candidate] != nil || originalExists(candidate)
        }
        snapshot.readTextFile = { candidate in
            if let text = snapshots[candidate] { return text }
            return try originalRead(candidate)
        }
        return snapshot
    }
}
