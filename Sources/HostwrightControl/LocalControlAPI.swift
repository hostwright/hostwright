import Darwin
import Foundation
import HostwrightCLI
import HostwrightCore

public struct LocalControlAPI: Sendable {
    public static let maximumResponseBytes = 1_024 * 1_024

    public let configuration: LocalControlConfiguration
    private let environment: CLIEnvironment

    public init(configuration: LocalControlConfiguration) {
        self.configuration = configuration
        self.environment = Self.liveEnvironment(manifestPath: configuration.manifestPath)
    }

    init(configuration: LocalControlConfiguration, environment: CLIEnvironment) {
        self.configuration = configuration
        self.environment = environment
    }

    public func run(requestData: Data) -> LocalControlRunResult {
        var request: LocalControlRequest?
        do {
            let parsedRequest = try LocalControlRequestParser.parse(requestData)
            request = parsedRequest
            try validateConfiguration()
            let arguments = try Self.commandArguments(for: parsedRequest, configuration: configuration)
            let cliResult = HostwrightCLI.run(arguments: arguments, environment: environment)
            return try response(for: parsedRequest, cliResult: cliResult)
        } catch let diagnostic as HostwrightDiagnostic {
            return encodedFailure(diagnostic, request: request)
        } catch {
            return encodedFailure(
                HostwrightDiagnostic(
                    code: .controlAPIExecutionFailed,
                    message: "The local control API could not complete the request."
                ),
                request: request
            )
        }
    }

    public static func commandArguments(
        for request: LocalControlRequest,
        configuration: LocalControlConfiguration
    ) throws -> [String] {
        switch request.operation {
        case .plan:
            var arguments = ["plan", configuration.manifestPath, "--output", "json"]
            if let teamProfilePath = configuration.teamProfilePath {
                arguments += ["--team-profile", teamProfilePath]
            }
            return arguments
        case .status:
            var arguments = ["status", configuration.manifestPath]
            if let stateDatabasePath = configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            arguments += ["--output", "json"]
            return arguments
        case .events:
            guard let stateDatabasePath = configuration.stateDatabasePath else {
                throw unavailable("The events operation requires an explicit configured state database path.")
            }
            var arguments = ["events", "--state-db", stateDatabasePath]
            if let project = request.project { arguments += ["--project", project] }
            if let eventType = request.eventType { arguments += ["--type", eventType] }
            if let service = request.service { arguments += ["--service", service] }
            if let severity = request.severity { arguments += ["--severity", severity] }
            arguments += ["--limit", String(request.limit ?? 100)]
            if let sort = request.sort { arguments += ["--sort", sort] }
            arguments += ["--output", "json"]
            return arguments
        case .recovery:
            guard let stateDatabasePath = configuration.stateDatabasePath else {
                throw unavailable("The recovery operation requires an explicit configured state database path.")
            }
            var arguments = ["recovery", "--state-db", stateDatabasePath]
            if let project = request.project { arguments += ["--project", project] }
            arguments += ["--output", "json"]
            return arguments
        case .doctor:
            return ["doctor", "--output", "json"]
        }
    }

    public static func invalidInputResult(_ diagnostic: HostwrightDiagnostic) -> LocalControlRunResult {
        LocalControlAPI(
            configuration: LocalControlConfiguration(manifestPath: "/unavailable"),
            environment: CLIEnvironment.live
        ).encodedFailure(diagnostic, request: nil)
    }

    private func response(
        for request: LocalControlRequest,
        cliResult: CLIRunResult
    ) throws -> LocalControlRunResult {
        let output = Data(cliResult.standardOutput.utf8)
        let error = Data(cliResult.standardError.utf8)
        guard output.count <= Self.maximumResponseBytes,
              error.count <= Self.maximumResponseBytes else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The delegated Hostwright response exceeded the 1 MiB local control limit."
            )
        }
        guard output.isEmpty != error.isEmpty else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The delegated Hostwright command returned an invalid output channel combination."
            )
        }

        let bodyData = output.isEmpty ? error : output
        let body: ControlJSONValue
        do {
            body = try JSONDecoder().decode(ControlJSONValue.self, from: bodyData)
        } catch {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The delegated Hostwright command did not return one valid JSON value."
            )
        }
        guard case .object = body else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The delegated Hostwright command response must be one JSON object."
            )
        }

        let succeeded = cliResult.exitCode == 0
        let response = LocalControlResponse(
            requestID: request.requestID,
            operation: request.operation,
            success: succeeded,
            exitCode: cliResult.exitCode,
            result: succeeded ? body : nil,
            error: succeeded ? nil : body
        )
        return try encoded(response, exitCode: cliResult.exitCode)
    }

    private func encodedFailure(
        _ diagnostic: HostwrightDiagnostic,
        request: LocalControlRequest?
    ) -> LocalControlRunResult {
        let exitCode = Self.exitCode(for: diagnostic.code)
        let error = ControlJSONValue.object([
            "kind": .string("error"),
            "code": .string(diagnostic.code.rawValue),
            "message": .string(diagnostic.message)
        ])
        let response = LocalControlResponse(
            requestID: request?.requestID,
            operation: request?.operation,
            success: false,
            exitCode: exitCode,
            error: error
        )
        do {
            return try encoded(response, exitCode: exitCode)
        } catch {
            return LocalControlRunResult(
                standardError: "HW-API-003: Could not encode the local control error response.\n",
                exitCode: LocalControlExitCode.executionFailed.rawValue
            )
        }
    }

    private func encoded(_ response: LocalControlResponse, exitCode: Int32) throws -> LocalControlRunResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(response) + Data("\n".utf8)
        guard data.count <= Self.maximumResponseBytes else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message: "The local control response exceeded the 1 MiB limit."
            )
        }
        return LocalControlRunResult(standardOutput: data, exitCode: exitCode)
    }

    private func validateConfiguration() throws {
        try Self.validatePath(configuration.manifestPath, role: "manifest", allowRootOwner: true)
        if let stateDatabasePath = configuration.stateDatabasePath {
            try Self.validatePath(stateDatabasePath, role: "state database", allowRootOwner: false)
        }
        if let teamProfilePath = configuration.teamProfilePath {
            try Self.validatePath(teamProfilePath, role: "team profile", allowRootOwner: true)
        }
    }

    private static func validatePath(
        _ path: String,
        role: String,
        allowRootOwner: Bool
    ) throws {
        guard path.hasPrefix("/") else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "The configured local control \(role) path must be absolute."
            )
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw unavailable("The configured local control \(role) must be an existing regular non-symlink file.")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw unavailable("The configured local control \(role) must be an existing regular non-symlink file.")
        }
        let allowedOwners: Set<uid_t> = allowRootOwner ? [geteuid(), 0] : [geteuid()]
        guard allowedOwners.contains(metadata.st_uid),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_mode & (S_ISUID | S_ISGID) == 0 else {
            throw unavailable("The configured local control \(role) has unsafe ownership or mode.")
        }
    }

    private static func liveEnvironment(manifestPath: String) -> CLIEnvironment {
        var environment = CLIEnvironment.live
        let fileExists = environment.fileExists
        environment.fileExists = { path in
            path == HostwrightIdentity.manifestFileName ? fileExists(manifestPath) : fileExists(path)
        }
        return environment
    }

    private static func exitCode(for code: HostwrightErrorCode) -> Int32 {
        switch code {
        case .controlAPIInvalid:
            LocalControlExitCode.invalidRequest.rawValue
        case .controlAPIUnavailable:
            LocalControlExitCode.unavailable.rawValue
        case .controlAPIExecutionFailed:
            LocalControlExitCode.executionFailed.rawValue
        default:
            LocalControlExitCode.executionFailed.rawValue
        }
    }

    private static func unavailable(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .controlAPIUnavailable, message: message)
    }
}
