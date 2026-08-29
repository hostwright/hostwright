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
        try validateComposeDeclaredScopeBeforeInputRead(
            command: command,
            declaredScope: route.authorizationScope
        )
        if isComposeAuthorizationCommand(command) {
            return CLIControlPreparedCommand(
                request: request,
                route: route,
                environment: commandEnvironment
            )
        }
        let snapshotEnvironment = try snapshottingCommandInputs(
            command: command,
            environment: commandEnvironment,
            workingDirectory: route.workingDirectory
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

    private static func isComposeAuthorizationCommand(_ command: CLICommand) -> Bool {
        switch command {
        case .exportStack, .planStackUpdate: true
        default: false
        }
    }

    private static func validateComposeDeclaredScopeBeforeInputRead(
        command: CLICommand,
        declaredScope: CLIControlAuthorizationScope
    ) throws {
        switch command {
        case .exportStack, .planStackUpdate:
            guard let projectIdentifier = declaredScope.projectIdentifier,
                  HostwrightResourceUUID.isValid(projectIdentifier),
                  declaredScope.resourceIdentifier == nil else {
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "Compose control commands require an exact project authorization scope."
                )
            }
        default:
            break
        }
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
        let executionEnvironment: CLIEnvironment
        if isComposeAuthorizationCommand(command) {
            executionEnvironment = try snapshottingCommandInputs(
                command: command,
                environment: prepared.environment,
                workingDirectory: route.workingDirectory
            )
        } else {
            executionEnvironment = prepared.environment
        }
        return try CLIControlAuthorizationScopeResolver.withExecutionAuthorizationFence(
            command: command,
            arguments: route.arguments,
            authorizedScope: route.authorizationScope,
            environment: executionEnvironment,
            mutating: prepared.route.mutating
        ) {
            let result = HostwrightCLI.run(
                arguments: route.arguments,
                environment: executionEnvironment
            )
            return try response(requestID: request.requestID, result: result)
        }
    }

    private static func response(
        requestID: String,
        result: CLIRunResult
    ) throws -> ControlResponseEnvelope {
        ControlResponseEnvelope(
            requestID: requestID,
            status: result.exitCode == 0 ? .completed : .error,
            reasonCode: result.exitCode == 0 ? .completed : .internalError,
            result: try CLIControlResultContract.value(result),
            error: result.exitCode == 0 ? nil : SanitizedError(
                code: "cliExitNonZero",
                message: "The delegated CLI command returned a non-zero exit status."
            )
        )
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
        environment: CLIEnvironment,
        workingDirectory: String?
    ) throws -> CLIEnvironment {
        switch command {
        case .importStack(let path, _, let teamProfilePath):
            return try snapshottingTextFiles(
                [path, teamProfilePath].compactMap { $0 },
                environment: environment,
                validateManifest: false,
                workingDirectory: workingDirectory
            )
        case .exportStack(let path, _):
            return try snapshottingTextFiles(
                [path],
                environment: environment,
                validateManifest: false,
                workingDirectory: workingDirectory,
                maximumUTF8Bytes: ManifestParser.maximumUTF8Bytes
            )
        case .planStackUpdate(let currentPath, let desiredPath, _):
            return try snapshottingTextFiles(
                [currentPath, desiredPath],
                environment: environment,
                validateManifest: false,
                workingDirectory: workingDirectory,
                maximumUTF8Bytes: ManifestParser.maximumUTF8Bytes
            )
        case .migrateManifestPreview(let path, _):
            return try snapshottingTextFiles(
                [path],
                environment: environment,
                validateManifest: false,
                workingDirectory: workingDirectory
            )
        default:
            break
        }
        guard let manifestPath = CLIControlAuthorizationScopeResolver.manifestPath(for: command)
        else { return environment }
        return try snapshottingTextFiles(
            [manifestPath],
            environment: environment,
            validateManifest: true,
            workingDirectory: workingDirectory
        )
    }

    private static func snapshottingTextFiles(
        _ paths: [String],
        environment: CLIEnvironment,
        validateManifest: Bool,
        workingDirectory: String?,
        maximumUTF8Bytes: Int? = nil
    ) throws -> CLIEnvironment {
        var snapshots: [String: String] = [:]
        var snapshotFailures: [String: ManifestParseError] = [:]
        for path in paths {
            let identity = canonicalInputIdentity(path, workingDirectory: workingDirectory)
            guard snapshots[identity] == nil else { continue }
            do {
                let text = if let maximumUTF8Bytes {
                    try environment.readBoundedTextFile(path, maximumUTF8Bytes)
                } else {
                    try environment.readTextFile(path)
                }
                if let maximumUTF8Bytes, text.utf8.count > maximumUTF8Bytes {
                    snapshots[identity] = String(repeating: "x", count: maximumUTF8Bytes + 1)
                    continue
                }
                if validateManifest { _ = try ManifestValidator.validated(text) }
                snapshots[identity] = text
            } catch let error as ManifestParseError where maximumUTF8Bytes != nil {
                snapshotFailures[identity] = error
                snapshots[identity] = ""
            } catch where maximumUTF8Bytes != nil {
                snapshotFailures[identity] = .failed([
                    ManifestIssue(
                        code: .manifestFileIOFailed,
                        message: "Manifest file could not be read safely.",
                        path: "$"
                    ),
                ])
                snapshots[identity] = ""
            }
        }
        var snapshot = environment
        let originalExists = environment.fileExists
        let originalRead = environment.readTextFile
        let originalBoundedRead = environment.readBoundedTextFile
        snapshot.fileExists = { candidate in
            snapshots[canonicalInputIdentity(
                candidate,
                workingDirectory: workingDirectory
            )] != nil || originalExists(candidate)
        }
        snapshot.readTextFile = { candidate in
            let identity = canonicalInputIdentity(
                candidate,
                workingDirectory: workingDirectory
            )
            if let failure = snapshotFailures[identity] { throw failure }
            if let text = snapshots[identity] { return text }
            return try originalRead(candidate)
        }
        snapshot.readBoundedTextFile = { candidate, maximumBytes in
            let identity = canonicalInputIdentity(
                candidate,
                workingDirectory: workingDirectory
            )
            if let failure = snapshotFailures[identity] { throw failure }
            if let text = snapshots[identity] {
                guard text.utf8.count <= maximumBytes else {
                    return String(repeating: "x", count: maximumBytes + 1)
                }
                return text
            }
            return try originalBoundedRead(candidate, maximumBytes)
        }
        return snapshot
    }

    private static func canonicalInputIdentity(
        _ path: String,
        workingDirectory: String?
    ) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        if let workingDirectory {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(path)
                .standardizedFileURL.path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
