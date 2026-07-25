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
        var requestID: String?
        var operation: LocalControlOperation?
        do {
            let parsedRequest = try LocalControlRequestParser.parse(requestData)
            requestID = parsedRequest.requestID
            operation = parsedRequest.operation
            try validateConfiguration(for: parsedRequest)
            let arguments = try Self.commandArguments(for: parsedRequest, configuration: configuration)
            let cliResult = HostwrightCLI.run(arguments: arguments, environment: environment)
            return try response(
                requestID: parsedRequest.requestID,
                operation: parsedRequest.operation,
                cliResult: cliResult,
                forbiddenResponseValues: [
                    parsedRequest
                        .registryProvenanceSigningKeyReference
                ].compactMap({ $0 })
            )
        } catch let diagnostic as HostwrightDiagnostic {
            return encodedFailure(
                diagnostic,
                requestID: requestID,
                operation: operation
            )
        } catch {
            return encodedFailure(
                HostwrightDiagnostic(
                    code: .controlAPIExecutionFailed,
                    message: "The local control API could not complete the request."
                ),
                requestID: requestID,
                operation: operation
            )
        }
    }

    public static func commandArguments(
        for request: LocalControlRequest,
        configuration: LocalControlConfiguration
    ) throws -> [String] {
        try LocalControlRequestParser.validate(request)
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
            var arguments = ["events"]
            if let stateDatabasePath = configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            if let project = request.project { arguments += ["--project", project] }
            if let eventType = request.eventType { arguments += ["--type", eventType] }
            if let service = request.service { arguments += ["--service", service] }
            if let severity = request.severity { arguments += ["--severity", severity] }
            arguments += ["--limit", String(request.limit ?? 100)]
            if let sort = request.sort { arguments += ["--sort", sort] }
            arguments += ["--output", "json"]
            return arguments
        case .recovery:
            var arguments = ["recovery"]
            if let stateDatabasePath = configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            if let project = request.project { arguments += ["--project", project] }
            arguments += ["--output", "json"]
            return arguments
        case .doctor:
            var arguments = ["doctor"]
            if let stateDatabasePath = configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            arguments += ["--output", "json"]
            return arguments
        case .up, .down, .run, .start, .stop, .restart, .rm, .update:
            var arguments = [request.operation.rawValue, configuration.manifestPath]
            for service in request.services?.sorted() ?? [] {
                arguments += ["--service", service]
            }
            if let stateDatabasePath = configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            if request.dryRun == true {
                arguments.append("--dry-run")
            } else if let confirmPlan = request.confirmPlan {
                arguments += ["--confirm-plan", confirmPlan]
            }
            if let runtimeProvider = request.runtimeProvider {
                arguments += ["--runtime-provider", runtimeProvider]
            }
            if let timeout = request.timeout {
                arguments += ["--timeout", String(timeout)]
            }
            if let parallelism = request.parallelism {
                arguments += ["--parallelism", String(parallelism)]
            }
            arguments += ["--output", "json"]
            return arguments
        case .image:
            return try imageCommandArguments(
                for: request,
                configuration: configuration
            )
        case .registry:
            return try registryCommandArguments(
                for: request,
                configuration: configuration
            )
        }
    }

    public static func invalidInputResult(_ diagnostic: HostwrightDiagnostic) -> LocalControlRunResult {
        LocalControlAPI(
            configuration: LocalControlConfiguration(manifestPath: "/unavailable"),
            environment: CLIEnvironment.live
        ).encodedFailure(
            diagnostic,
            requestID: nil,
            operation: nil
        )
    }

    private func response(
        requestID: String,
        operation: LocalControlOperation,
        cliResult: CLIRunResult,
        forbiddenResponseValues: [String]
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
        guard !forbiddenResponseValues.contains(where: {
            Self.contains($0, in: body)
        }) else {
            throw HostwrightDiagnostic(
                code: .controlAPIExecutionFailed,
                message:
                    "The delegated Hostwright command returned protected request material."
            )
        }

        let succeeded = cliResult.exitCode == 0
        let response = LocalControlResponse(
            requestID: requestID,
            operation: operation,
            success: succeeded,
            exitCode: cliResult.exitCode,
            result: succeeded ? body : nil,
            error: succeeded ? nil : body
        )
        return try encoded(response, exitCode: cliResult.exitCode)
    }

    private func encodedFailure(
        _ diagnostic: HostwrightDiagnostic,
        requestID: String?,
        operation: LocalControlOperation?
    ) -> LocalControlRunResult {
        let exitCode = Self.exitCode(for: diagnostic.code)
        let error = ControlJSONValue.object([
            "kind": .string("error"),
            "code": .string(diagnostic.code.rawValue),
            "message": .string(diagnostic.message)
        ])
        let response = LocalControlResponse(
            requestID: requestID,
            operation: operation,
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

    private func validateConfiguration(for request: LocalControlRequest) throws {
        if request.operation != .image &&
            (request.operation != .registry ||
                request.registryTrustOperation != nil ||
                request.registrySBOMOperation != nil ||
                request.registryVulnerabilityOperation != nil ||
                request.registryProvenanceOperation != nil) {
            try Self.validatePath(
                configuration.manifestPath,
                role: "manifest",
                allowRootOwner: true
            )
        }
        if let stateDatabasePath = configuration.stateDatabasePath {
            if (request.operation == .image ||
                request.operation == .registry),
               try Self.pathDoesNotExist(stateDatabasePath) {
                // The shared CLI state-path boundary validates and creates the
                // first-use database and its parent layout.
            } else {
                try Self.validatePath(
                    stateDatabasePath,
                    role: "state database",
                    allowRootOwner: false
                )
            }
        }
        if let teamProfilePath = configuration.teamProfilePath {
            try Self.validatePath(teamProfilePath, role: "team profile", allowRootOwner: true)
        }
    }

    private static func imageCommandArguments(
        for request: LocalControlRequest,
        configuration: LocalControlConfiguration
    ) throws -> [String] {
        guard let operation = request.imageOperation else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "Local control imageOperation is required."
            )
        }
        let references = request.imageReferences ?? []
        var arguments: [String]
        switch operation {
        case "cache-status":
            arguments = ["image", "cache", "status"]
        case "pin", "unpin":
            arguments = ["image", "cache", operation]
        default:
            arguments = ["image", operation]
        }
        switch operation {
        case "inspect", "delete":
            arguments += references
        case "pull", "push":
            arguments.append(references[0])
            arguments += ["--scheme", "https"]
            arguments += [
                "--progress",
                request.imageProgress ?? "plain"
            ]
            if let platform = request.imagePlatform {
                arguments += ["--platform", platform]
            }
            if request.imageOffline == true {
                arguments.append("--offline")
            }
        case "tag":
            arguments += [
                references[0],
                request.imageTargetReference!
            ]
        case "load":
            arguments += ["--input", request.imageArchivePath!]
            for reference in references {
                arguments += ["--reference", reference]
            }
        case "save":
            arguments += references
            arguments += ["--output", request.imageArchivePath!]
            if let platform = request.imagePlatform {
                arguments += ["--platform", platform]
            }
        case "build":
            arguments += [
                "--context", request.imageContextPath!,
                "--tag", request.imageTargetReference!
            ]
            if let file = request.imageFilePath {
                arguments += ["--file", file]
            }
            if let platform = request.imagePlatform {
                arguments += ["--platform", platform]
            }
            if request.imageNoCache == true {
                arguments.append("--no-cache")
            }
            if request.imageOffline == true {
                arguments.append("--offline")
            }
        case "prune":
            if request.dryRun == true {
                arguments.append("--dry-run")
            }
            if let confirmation = request.confirmPlan {
                arguments += ["--confirm-plan", confirmation]
            }
            if let maximumBytes = request.imageMaximumBytes,
               let targetBytes = request.imageTargetBytes {
                arguments += [
                    "--maximum-bytes", String(maximumBytes),
                    "--target-bytes", String(targetBytes)
                ]
            }
            if let retentionSeconds = request.imageRetentionSeconds {
                arguments += [
                    "--retain-seconds", String(retentionSeconds)
                ]
            }
            if let maximumDeletions =
                request.imageMaximumDeletions {
                arguments += [
                    "--max-delete", String(maximumDeletions)
                ]
            }
        case "cache-status":
            if let maximumBytes = request.imageMaximumBytes {
                arguments += [
                    "--maximum-bytes", String(maximumBytes)
                ]
            }
        case "pin", "unpin":
            arguments.append(references[0])
        default:
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "Unsupported local control image operation."
            )
        }
        if let stateDatabasePath = configuration.stateDatabasePath {
            arguments += ["--state-db", stateDatabasePath]
        }
        if let runtimeProvider = request.runtimeProvider {
            arguments += ["--runtime-provider", runtimeProvider]
        }
        arguments.append("--json")
        return arguments
    }

    private static func registryCommandArguments(
        for request: LocalControlRequest,
        configuration: LocalControlConfiguration
    ) throws -> [String] {
        if let operation = request.registryProvenanceOperation {
            var arguments = [
                "registry", "provenance", operation
            ]
            switch operation {
            case "generate":
                arguments.append(
                    request.registryProvenanceArchivePath!
                )
                arguments += [
                    "--record",
                    request.registryProvenanceBuildRecordPath!,
                    "--manifest", configuration.manifestPath,
                    "--server", request.registryServer!,
                    "--repository", request.registryRepository!,
                    "--signer",
                    request.registryProvenanceSignerID!,
                    "--signing-key-ref",
                    request
                        .registryProvenanceSigningKeyReference!
                ]
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "verify":
                arguments.append(request.registryDiscoveryID!)
                arguments += [
                    "--digest", request.registryReferrerDigest!,
                    "--manifest", configuration.manifestPath
                ]
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "status":
                arguments.append(configuration.manifestPath)
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "resume":
                arguments.append(
                    request.registryOperationGroupID!
                )
                arguments += [
                    "--confirm-plan", request.confirmPlan!
                ]
                if let reference =
                    request
                        .registryProvenanceSigningKeyReference {
                    arguments += [
                        "--signing-key-ref", reference
                    ]
                }
            default:
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message:
                        "Unsupported local control registry provenance operation."
                )
            }
            if let stateDatabasePath =
                configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            arguments.append("--json")
            return arguments
        }
        if let operation =
            request.registryVulnerabilityOperation {
            var arguments = [
                "registry", "vulnerability", operation
            ]
            switch operation {
            case "evaluate":
                arguments.append(request.registryDiscoveryID!)
                arguments += [
                    "--digest",
                    request.registryReferrerDigest!,
                    "--manifest",
                    configuration.manifestPath,
                    "--cosign",
                    request.registryCosignPath!
                ]
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "status":
                arguments.append(configuration.manifestPath)
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "grant-exception":
                arguments.append(
                    request.registryApprovalRecordPath!
                )
                arguments += [
                    "--manifest", configuration.manifestPath
                ]
            case "revoke-exception":
                arguments.append(request.registryExceptionID!)
            case "resume":
                arguments.append(
                    request.registryOperationGroupID!
                )
                arguments += [
                    "--confirm-plan", request.confirmPlan!
                ]
            default:
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message:
                        "Unsupported local control registry vulnerability operation."
                )
            }
            if let stateDatabasePath =
                configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            arguments.append("--json")
            return arguments
        }
        if let operation = request.registrySBOMOperation {
            var arguments = ["registry", "sbom", operation]
            switch operation {
            case "generate":
                arguments.append(request.registrySBOMArchivePath!)
                arguments += [
                    "--manifest", configuration.manifestPath,
                    "--server", request.registryServer!,
                    "--repository", request.registryRepository!,
                    "--format", request.registrySBOMFormat!
                ]
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
                if let descriptor =
                    request.registryProvenanceDescriptorDigest,
                   let referrer =
                    request.registryProvenanceReferrerDigest {
                    arguments += [
                        "--provenance-descriptor-digest",
                        descriptor,
                        "--provenance-referrer-digest",
                        referrer
                    ]
                }
            case "ingest":
                arguments.append(request.registryDiscoveryID!)
                arguments += [
                    "--manifest", configuration.manifestPath
                ]
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "query":
                arguments.append(configuration.manifestPath)
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "export":
                arguments.append(configuration.manifestPath)
                arguments += [
                    "--format", request.registrySBOMFormat!,
                    "--output-path", request.registrySBOMOutputPath!
                ]
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "resume":
                arguments.append(request.registryOperationGroupID!)
                arguments += [
                    "--confirm-plan", request.confirmPlan!
                ]
            default:
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message:
                        "Unsupported local control registry SBOM operation."
                )
            }
            if let stateDatabasePath =
                configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            arguments.append("--json")
            return arguments
        }
        if let operation = request.registryTrustOperation {
            var arguments = ["registry", "trust", operation]
            switch operation {
            case "verify":
                arguments.append(request.registryDiscoveryID!)
                arguments += [
                    "--manifest", configuration.manifestPath,
                    "--subject-manifest",
                    request.registrySubjectManifestPath!,
                    "--cosign", request.registryCosignPath!
                ]
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "status":
                arguments.append(configuration.manifestPath)
                if let service = request.registryServiceName {
                    arguments += ["--service", service]
                }
            case "grant-exception":
                arguments.append(request.registryApprovalRecordPath!)
                arguments += [
                    "--manifest", configuration.manifestPath
                ]
            case "revoke-exception":
                arguments.append(request.registryExceptionID!)
            default:
                throw HostwrightDiagnostic(
                    code: .controlAPIInvalid,
                    message:
                        "Unsupported local control registry trust operation."
                )
            }
            if let stateDatabasePath =
                configuration.stateDatabasePath {
                arguments += ["--state-db", stateDatabasePath]
            }
            arguments.append("--json")
            return arguments
        }
        guard let operation = request.registryReferrerOperation else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "Local control registryReferrerOperation is required."
            )
        }
        var arguments = ["registry", "referrers", operation]
        switch operation {
        case "discover", "fetch":
            arguments.append(request.registryServer!)
            arguments += [
                "--repository", request.registryRepository!,
                "--subject", request.registrySubjectDigest!
            ]
            if let artifact = request.registryArtifactType {
                arguments += ["--artifact-type", artifact]
            }
            if request.registryOffline == true {
                arguments.append("--offline")
            }
        case "publish":
            arguments.append(request.registryDiscoveryID!)
            arguments += [
                "--target-server", request.registryTargetServer!,
                "--target-repository",
                request.registryTargetRepository!
            ]
        case "copy":
            arguments.append(request.registryServer!)
            arguments += [
                "--repository", request.registryRepository!,
                "--subject", request.registrySubjectDigest!,
                "--target-server", request.registryTargetServer!,
                "--target-repository",
                request.registryTargetRepository!
            ]
            if let artifact = request.registryArtifactType {
                arguments += ["--artifact-type", artifact]
            }
        case "retain":
            arguments.append(request.registryDiscoveryID!)
            arguments += [
                "--owner", request.registryOwnerID!,
                "--expires-at", request.registryExpiresAt!
            ]
        case "release":
            arguments.append(request.registryLeaseID!)
            arguments += [
                "--fencing-token", request.registryFencingToken!
            ]
        case "status":
            arguments.append(request.registryDiscoveryID!)
        case "prune":
            arguments.append(request.registryDiscoveryID!)
            arguments += [
                "--digest", request.registryReferrerDigest!
            ]
            if let confirmation = request.confirmPlan {
                arguments += ["--confirm-plan", confirmation]
            }
        case "resume":
            arguments.append(request.registryOperationGroupID!)
            arguments += ["--confirm-plan", request.confirmPlan!]
        default:
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message: "Unsupported local control registry operation."
            )
        }
        if let stateDatabasePath = configuration.stateDatabasePath {
            arguments += ["--state-db", stateDatabasePath]
        }
        arguments.append("--json")
        return arguments
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

    private static func pathDoesNotExist(_ path: String) throws -> Bool {
        guard path.hasPrefix("/") else {
            throw HostwrightDiagnostic(
                code: .controlAPIInvalid,
                message:
                    "The configured local control state database path must be absolute."
            )
        }
        var metadata = stat()
        if lstat(path, &metadata) == 0 {
            return false
        }
        guard errno == ENOENT else {
            throw unavailable(
                "The configured local control state database path could not be inspected."
            )
        }
        return true
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

    private static func contains(
        _ protectedValue: String,
        in value: ControlJSONValue
    ) -> Bool {
        switch value {
        case .object(let object):
            object.keys.contains(where: {
                $0.contains(protectedValue)
            }) ||
                object.values.contains(where: {
                    contains(protectedValue, in: $0)
                })
        case .array(let values):
            values.contains(where: {
                contains(protectedValue, in: $0)
            })
        case .string(let string):
            string.contains(protectedValue)
        case .integer, .number, .bool, .null:
            false
        }
    }

    private static func unavailable(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .controlAPIUnavailable, message: message)
    }
}
