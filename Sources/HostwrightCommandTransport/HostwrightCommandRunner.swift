import Darwin
import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightCore

public struct HostwrightCommandTransportEnvironment: @unchecked Sendable {
    public typealias BoundedRequestFileRead = @Sendable (String, Int) throws -> Data
    public typealias BoundedStandardInputRead = @Sendable (Int) throws -> Data
    public typealias PersistentSend = @Sendable (
        String,
        ControlRequestEnvelope
    ) throws -> ControlResponseEnvelope
    public typealias BootstrapSend = @Sendable (
        ControlRequestEnvelope
    ) throws -> ControlResponseEnvelope
    public typealias StreamRun = @Sendable (
        String,
        CLIControlRoute,
        String
    ) throws -> CLIRunResult
    public typealias AuthorizationScope = @Sendable (
        CLICommand,
        [String]
    ) throws -> CLIControlAuthorizationScope

    public var socketPath: @Sendable () throws -> String
    public var persistentSend: PersistentSend
    public var bootstrapSend: BootstrapSend
    public var streamRun: StreamRun
    public var authorizationScope: AuthorizationScope
    public var requestID: @Sendable () -> String
    public var workingDirectory: @Sendable () throws -> String
    public var readRequestFile: BoundedRequestFileRead
    public var readStandardInput: BoundedStandardInputRead

    public init(
        socketPath: @escaping @Sendable () throws -> String,
        persistentSend: @escaping PersistentSend,
        bootstrapSend: @escaping BootstrapSend,
        streamRun: @escaping StreamRun,
        authorizationScope: @escaping AuthorizationScope = { _, _ in
            CLIControlAuthorizationScope(projectIdentifier: nil, resourceIdentifier: nil)
        },
        requestID: @escaping @Sendable () -> String,
        workingDirectory: @escaping @Sendable () throws -> String = {
            FileManager.default.currentDirectoryPath
        },
        readRequestFile: @escaping BoundedRequestFileRead = { path, maximumBytes in
            try hostwrightReadBoundedRequestFile(path: path, maximumBytes: maximumBytes)
        },
        readStandardInput: @escaping BoundedStandardInputRead = { maximumBytes in
            try hostwrightReadBoundedStandardInput(maximumBytes: maximumBytes)
        }
    ) {
        self.socketPath = socketPath
        self.persistentSend = persistentSend
        self.bootstrapSend = bootstrapSend
        self.streamRun = streamRun
        self.authorizationScope = authorizationScope
        self.requestID = requestID
        self.workingDirectory = workingDirectory
        self.readRequestFile = readRequestFile
        self.readStandardInput = readStandardInput
    }

    public static let live = HostwrightCommandTransportEnvironment(
        socketPath: {
            try HostwrightLocalPathResolver.resolve().layout.controlSocket
        },
        persistentSend: { socketPath, request in
            try PersistentControlClient(socketPath: socketPath).send(request)
        },
        bootstrapSend: { request in
            try BootstrapControlClient().send(request)
        },
        streamRun: { socketPath, route, requestID in
            try CLIControlStreamClient(socketPath: socketPath)
                .run(route: route, preparationRequestID: requestID)
        },
        authorizationScope: { command, arguments in
            try CLIControlAuthorizationScopeResolver.resolve(
                command: command,
                arguments: arguments,
                environment: .live
            )
        },
        requestID: { UUID().uuidString.lowercased() },
        workingDirectory: { FileManager.default.currentDirectoryPath }
    )
}

public enum HostwrightCommandRunner {
    public static func run(
        arguments: [String],
        environment: HostwrightCommandTransportEnvironment = .live
    ) -> CLIRunResult {
        let output = CLICommand.outputFormatHint(arguments: arguments) ?? .text
        var route: CLIControlRoute
        do {
            route = try CLIControlRoute.classify(arguments: arguments)
        } catch let usage as CLIUsageError {
            return HostwrightCLI.usageFailure(usage, output: output)
        } catch let diagnostic as HostwrightDiagnostic {
            return HostwrightCLI.diagnosticFailure(diagnostic, output: output)
        } catch {
            return HostwrightCLI.diagnosticFailure(
                HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "The CLI command could not be classified safely."
                ),
                output: output
            )
        }

        if route.transport == .localPresentation {
            return HostwrightCLI.run(arguments: route.arguments)
        }

        do {
            route = try route.withWorkingDirectory(environment.workingDirectory())
            if route.transport == .persistentControlAPI {
                route = route.withAuthorizationScope(
                    try environment.authorizationScope(
                        CLICommand.parse(arguments: route.arguments),
                        route.arguments
                    )
                )
            }
        } catch let diagnostic as HostwrightDiagnostic {
            return HostwrightCLI.diagnosticFailure(diagnostic, output: output)
        } catch {
            return HostwrightCLI.diagnosticFailure(
                HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message: "The CLI request context could not be resolved safely."
                ),
                output: output
            )
        }

        let requestID = environment.requestID()
        guard requestID.range(
            of: "^[A-Za-z0-9._:-]{1,128}$",
            options: .regularExpression
        ) != nil else {
            return HostwrightCLI.diagnosticFailure(
                HostwrightDiagnostic(
                    code: .controlAPIExecutionFailed,
                    message: "The Control API request identifier generator returned an invalid value."
                ),
                output: output
            )
        }

        do {
            switch route.transport {
            case .localPresentation:
                preconditionFailure("local presentation returned before transport dispatch")
            case .bootstrapAPI:
                let response = try environment.bootstrapSend(
                    try request(
                        route: route,
                        requestID: requestID,
                        environment: environment
                    )
                )
                return try result(response: response, output: output)
            case .persistentControlAPI:
                let socketPath = try environment.socketPath()
                switch route.execution {
                case .unary:
                    let response = try environment.persistentSend(
                        socketPath,
                        try request(
                            route: route,
                            requestID: requestID,
                            environment: environment
                        )
                    )
                    let command = try CLICommand.parse(arguments: route.arguments)
                    if case .scheduler(let options) = command {
                        return try schedulerResult(
                            response: response,
                            operation: route.operation,
                            output: options.output
                        )
                    }
                    if case .plugin = command,
                       response.status == .completed, response.reasonCode == .completed,
                       let value = response.result {
                        let data = try ControlPlaneCanonicalJSON.encode(value)
                        return CLIRunResult(standardOutput: String(decoding: data, as: UTF8.self) + "\n")
                    }
                    return try result(response: response, output: output)
                case .stream:
                    return try environment.streamRun(socketPath, route, requestID)
                }
            }
        } catch let diagnostic as HostwrightDiagnostic {
            return HostwrightCLI.diagnosticFailure(diagnostic, output: output)
        } catch {
            return HostwrightCLI.diagnosticFailure(
                HostwrightDiagnostic(
                    code: .controlAPIUnavailable,
                    message: "The authenticated local Control API is unavailable."
                ),
                output: output
            )
        }
    }

    private static func request(
        route: CLIControlRoute,
        requestID: String,
        environment: HostwrightCommandTransportEnvironment
    ) throws -> ControlRequestEnvelope {
        let command = try CLICommand.parse(arguments: route.arguments)
        if case .scheduler(let options) = command {
            return ControlRequestEnvelope(
                protocolRevision: .current,
                requestID: requestID,
                operation: route.operation,
                timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
                idempotencyKey: route.mutating ? requestID : nil,
                body: try schedulerRequestBody(
                    options: options,
                    route: route,
                    environment: environment
                )
            )
        }
        if case .plugin(let options) = command {
            return ControlRequestEnvelope(
                requestID: requestID,
                operation: route.operation,
                timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
                idempotencyKey: route.mutating ? requestID : nil,
                body: try pluginBody(options)
            )
        }
        return ControlRequestEnvelope(
            requestID: requestID,
            operation: route.operation,
            timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
            idempotencyKey: route.mutating ? requestID : nil,
            body: route.requestBody()
        )
    }

    private static func schedulerRequestBody(
        options: SchedulerCLIOptions,
        route: CLIControlRoute,
        environment: HostwrightCommandTransportEnvironment
    ) throws -> ControlPlaneJSONValue {
        let maximumBytes = SchedulerControlWireContract.maximumInputBytes
        let data: Data
        switch options.requestSource {
        case .file(let path):
            let resolvedPath: String
            if path.hasPrefix("/") {
                resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            } else if let workingDirectory = route.workingDirectory {
                resolvedPath = URL(
                    fileURLWithPath: workingDirectory,
                    isDirectory: true
                ).appendingPathComponent(path).standardizedFileURL.path
            } else {
                resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            }
            data = try environment.readRequestFile(resolvedPath, maximumBytes)
        case .standardInput:
            data = try environment.readStandardInput(maximumBytes)
        }

        guard !data.isEmpty, data.count <= maximumBytes else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The scheduler request must be non-empty JSON within the bounded Control API input limit."
            )
        }
        do {
            try Phase09StrictDecoder.validateNoDuplicateKeys(data)
            let body = try JSONDecoder().decode(ControlPlaneJSONValue.self, from: data)
            switch options.action {
            case .plan, .simulate:
                _ = try SchedulerControlWireContract.scopedInputData(from: body)
            case .status, .explain:
                _ = try SchedulerControlWireContract.decisionReference(from: body)
            case .apply:
                _ = try SchedulerControlWireContract.applyData(from: body)
            }
            return body
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The scheduler request JSON does not match the selected Control 2.2 operation."
            )
        }
    }

    private static func pluginBody(_ options: PluginCLIOptions) throws -> ControlPlaneJSONValue {
        func source(_ value: PluginCLISource) -> ControlPlaneJSONValue {
            .object([
                "kind": .string(value.kind.rawValue),
                "locator": .string(value.locator),
            ])
        }
        func trusted(
            _ value: PluginCLISource, signer: String
        ) -> ControlPlaneJSONValue {
            return .object([
                "source": source(value),
                "trustedSignerIdentifier": .string(signer),
            ])
        }
        switch options.action {
        case .list(let identifier):
            return .object(identifier.map { ["identifier": .string($0)] } ?? [:])
        case .status(let identifier, let packageDigest):
            if let identifier { return .object(["identifier": .string(identifier)]) }
            return .object(["packageDigest": .string(packageDigest!)])
        case .discover(let value, let signer):
            return trusted(value, signer: signer)
        case .install(let value, let signer):
            return trusted(value, signer: signer)
        case .update(let value, let signer):
            return trusted(value, signer: signer)
        case .activate(let digest, let generation):
            var fields: [String: ControlPlaneJSONValue] = ["packageDigest": .string(digest)]
            if let generation { fields["expectedActivationGeneration"] = .integer(Int64(generation)) }
            return .object(fields)
        case .rollback(let identifier, let generation):
            var fields: [String: ControlPlaneJSONValue] = ["identifier": .string(identifier)]
            if let generation { fields["expectedActivationGeneration"] = .integer(Int64(generation)) }
            return .object(fields)
        case .revoke(let id, let kind, let target, let reason):
            return .object([
                "revocationID": .string(id), "targetKind": .string(kind),
                "targetIdentifier": .string(target), "reason": .string(reason),
            ])
        case .quarantine(let id, let digest, let reason, let detail):
            return .object([
                "quarantineID": .string(id), "packageDigest": .string(digest),
                "reasonCode": .string(reason), "detailDigest": .string(detail),
            ])
        case .uninstall(let digest, let generation):
            return .object([
                "packageDigest": .string(digest),
                "expectedGeneration": .integer(Int64(generation)),
            ])
        }
    }

    private static func schedulerResult(
        response: ControlResponseEnvelope,
        operation: String,
        output: CLIOutputFormat
    ) throws -> CLIRunResult {
        guard response.status == .completed,
              response.reasonCode == .completed,
              response.error == nil,
              let value = response.result else {
            return try result(response: response, output: output)
        }
        let data = try ControlPlaneCanonicalJSON.encode(value)
        let canonicalJSON = String(decoding: data, as: UTF8.self)
        if output == .json {
            return CLIRunResult(standardOutput: canonicalJSON + "\n")
        }
        return CLIRunResult(
            standardOutput: "Scheduler operation: \(operation)\nStatus: completed\nResult:\n\(canonicalJSON)\n"
        )
    }

    private static func result(
        response: ControlResponseEnvelope,
        output: CLIOutputFormat
    ) throws -> CLIRunResult {
        if response.result != nil {
            return try CLIControlResultContract.result(from: response)
        }
        let code: HostwrightErrorCode
        switch response.reasonCode {
        case .invalidFrame, .invalidRequest, .unsupportedAPIVersion,
             .unsupportedProtocolRevision, .unsupportedOperation:
            code = .controlAPIInvalid
        case .unauthenticated, .identityMismatch, .unauthorized, .admissionDenied:
            code = .unsafeExposure
        case .conflict, .idempotencyConflict:
            code = .confirmationMismatch
        case .deadlineExceeded, .cancelled, .concurrencyLimit, .streamLimit,
             .slowClient, .cursorGap, .auditUnavailable, .serviceUnavailable:
            code = .controlAPIUnavailable
        case .internalError, .accepted, .completed:
            code = .controlAPIExecutionFailed
        }
        throw HostwrightDiagnostic(
            code: code,
            message: response.error?.message ?? "The Control API request was rejected safely."
        )
    }
}

@usableFromInline
internal func hostwrightReadBoundedRequestFile(
    path: String,
    maximumBytes: Int
) throws -> Data {
    guard maximumBytes > 0, maximumBytes < Int.max else {
        throw HostwrightDiagnostic(
            code: .controlAPIInvalid,
            message: "The scheduler request input limit is invalid."
        )
    }
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    } catch {
        throw HostwrightDiagnostic(
            code: .controlAPIInvalid,
            message: "The scheduler request file could not be opened safely."
        )
    }
    defer { handle.closeFile() }
    return try hostwrightReadBoundedHandle(handle, maximumBytes: maximumBytes)
}

@usableFromInline
internal func hostwrightReadBoundedStandardInput(maximumBytes: Int) throws -> Data {
    try hostwrightReadBoundedHandle(
        FileHandle.standardInput,
        maximumBytes: maximumBytes
    )
}

private func hostwrightReadBoundedHandle(
    _ handle: FileHandle,
    maximumBytes: Int
) throws -> Data {
    guard maximumBytes > 0, maximumBytes < Int.max else {
        throw HostwrightDiagnostic(
            code: .controlAPIInvalid,
            message: "The scheduler request input limit is invalid."
        )
    }
    var data = Data()
    do {
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
    } catch let diagnostic as HostwrightDiagnostic {
        throw diagnostic
    } catch {
        throw HostwrightDiagnostic(
            code: .controlAPIInvalid,
            message: "The scheduler request could not be read safely."
        )
    }
    guard !data.isEmpty else {
        throw HostwrightDiagnostic(
            code: .controlAPIInvalid,
            message: "The scheduler request must be non-empty JSON."
        )
    }
    guard data.count <= maximumBytes else {
        throw HostwrightDiagnostic(
            code: .controlAPIInvalid,
            message: "The scheduler request exceeds the bounded Control API input limit."
        )
    }
    return data
}
