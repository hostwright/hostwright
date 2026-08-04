import Darwin
import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightCore

public struct HostwrightCommandTransportEnvironment: @unchecked Sendable {
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
        }
    ) {
        self.socketPath = socketPath
        self.persistentSend = persistentSend
        self.bootstrapSend = bootstrapSend
        self.streamRun = streamRun
        self.authorizationScope = authorizationScope
        self.requestID = requestID
        self.workingDirectory = workingDirectory
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
                    try request(route: route, requestID: requestID)
                )
                return try result(response: response, output: output)
            case .persistentControlAPI:
                let socketPath = try environment.socketPath()
                switch route.execution {
                case .unary:
                    let response = try environment.persistentSend(
                        socketPath,
                        try request(route: route, requestID: requestID)
                    )
                    if case .plugin = try CLICommand.parse(arguments: route.arguments),
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
        requestID: String
    ) throws -> ControlRequestEnvelope {
        let command = try CLICommand.parse(arguments: route.arguments)
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

    private static func pluginBody(_ options: PluginCLIOptions) throws -> ControlPlaneJSONValue {
        func source(_ value: PluginCLISource) -> ControlPlaneJSONValue {
            .object([
                "kind": .string(value.kind.rawValue),
                "locator": .string(value.locator),
            ])
        }
        func signed(
            _ value: PluginCLISource, signer: String, certificatePath: String
        ) throws -> ControlPlaneJSONValue {
            let descriptor = open(certificatePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw HostwrightDiagnostic(
                    code: .extensionInvalid,
                    message: "The trusted plugin signer certificate cannot be opened safely."
                )
            }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0,
                  metadata.st_size > 0, metadata.st_size <= 32 * 1_024 else {
                throw HostwrightDiagnostic(
                    code: .extensionInvalid,
                    message: "The trusted plugin signer certificate identity or mode is unsafe."
                )
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let certificate = try handle.read(upToCount: 32 * 1_024 + 1),
                  !certificate.isEmpty, certificate.count <= 32 * 1_024 else {
                throw HostwrightDiagnostic(
                    code: .extensionInvalid,
                    message: "The trusted plugin signer certificate must be bounded DER data."
                )
            }
            var finalMetadata = stat()
            guard fstat(descriptor, &finalMetadata) == 0,
                  finalMetadata.st_dev == metadata.st_dev,
                  finalMetadata.st_ino == metadata.st_ino,
                  finalMetadata.st_size == metadata.st_size,
                  finalMetadata.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
                  finalMetadata.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
                throw HostwrightDiagnostic(
                    code: .extensionInvalid,
                    message: "The trusted plugin signer certificate changed while being read."
                )
            }
            return .object([
                "source": source(value),
                "trustedSignerIdentifier": .string(signer),
                "trustedSignerCertificateDER": .string(certificate.base64EncodedString()),
            ])
        }
        switch options.action {
        case .list(let identifier):
            return .object(identifier.map { ["identifier": .string($0)] } ?? [:])
        case .status(let identifier, let packageDigest):
            if let identifier { return .object(["identifier": .string(identifier)]) }
            return .object(["packageDigest": .string(packageDigest!)])
        case .discover(let value, let signer, let certificate):
            return try signed(value, signer: signer, certificatePath: certificate)
        case .install(let value, let signer, let certificate):
            return try signed(value, signer: signer, certificatePath: certificate)
        case .update(let value, let signer, let certificate):
            return try signed(value, signer: signer, certificatePath: certificate)
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
