import Darwin
import Foundation
import HostwrightCore
import HostwrightExtensions
import HostwrightHealth
import HostwrightImport
import HostwrightManifest
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRuntime

public enum HostwrightCLI {
    public static let starterManifest = """
    version: 1
    project: api-local

    services:
      api:
        image: ghcr.io/example/api:latest
        ports:
          - "8080:8080"
        env:
          APP_ENV: development
        health:
          command: ["curl", "-f", "http://localhost:8080/health"]
          interval: 10s
        restart:
          policy: on-failure
      redis:
        image: redis:7
        ports:
          - "6379:6379"

    """

    public static func run(arguments: [String], environment: CLIEnvironment = .live) -> CLIRunResult {
        let outputHint = CLICommand.outputFormatHint(arguments: arguments) ?? .text
        do {
            let command = try CLICommand.parse(arguments: arguments)
            return try run(command: command, environment: environment)
        } catch let error as HostwrightDiagnostic {
            return failure(code: error.code, message: error.message, output: outputHint)
        } catch let error as CLIUsageError {
            return failure(code: .commandUsage, message: "\(error.message)\n\n\(helpText)", output: outputHint)
        } catch let error as ManifestParseError {
            return failure(issues: error.issues, output: outputHint)
        } catch {
            return failure(code: .fileIOFailed, message: String(describing: error), output: outputHint)
        }
    }

    public static func run(command: CLICommand, environment: CLIEnvironment = .live) throws -> CLIRunResult {
        switch command {
        case .version:
            return CLIRunResult(standardOutput: "\(HostwrightIdentity.version)\n")
        case .help:
            return CLIRunResult(standardOutput: helpText)
        case .initManifest:
            return try initManifest(environment: environment)
        case .importStack(let path, let output, let teamProfilePath):
            return try importStack(path: path, output: output, teamProfilePath: teamProfilePath, environment: environment)
        case .validate(let path, let teamProfilePath):
            let validated = try loadValidManifest(path: path, teamProfilePath: teamProfilePath, environment: environment)
            let standardOutput = "Valid hostwright manifest: \(path)\nProject: \(validated.manifest.project ?? "<missing>")\nServices: \(validated.manifest.services.count)\n" + hostwrightTeamProfileText(validated)
            return CLIRunResult(standardOutput: standardOutput)
        case .plan(let path, let output, let teamProfilePath):
            let validated = try loadValidManifest(path: path, teamProfilePath: teamProfilePath, environment: environment)
            let plan = ReconciliationPlanner().plan(manifest: validated.manifest)
            let binding = validated.previewBinding(planHash: plan.planHash)
            let standardOutput = output == .json
                ? CLIJSON.plan(plan, teamBinding: binding)
                : PlanRenderer.render(plan) + hostwrightTeamProfileText(validated, planHash: plan.planHash)
            return CLIRunResult(standardOutput: standardOutput)
        case .status(let path, let stateDatabasePath, let output):
            return StatusCommandRunner(
                manifestPath: path,
                stateDatabasePath: stateDatabasePath,
                output: output,
                environment: environment
            ).run()
        case .apply(let path, let stateDatabasePath, let confirmedPlanHash, let teamProfilePath, let approvalRecordPath):
            return ApplyCommandRunner(
                manifestPath: path,
                stateDatabasePath: stateDatabasePath,
                confirmedPlanHash: confirmedPlanHash,
                teamProfilePath: teamProfilePath,
                approvalRecordPath: approvalRecordPath,
                environment: environment
            ).run()
        case .logs(let serviceName, let path, let tail, let stateDatabasePath):
            return LogsCommandRunner(
                serviceName: serviceName,
                manifestPath: path,
                tail: tail,
                stateDatabasePath: stateDatabasePath,
                environment: environment
            ).run()
        case .events(let stateDatabasePath, let projectName, let filters, let output):
            return EventsCommandRunner(
                stateDatabasePath: stateDatabasePath,
                projectName: projectName,
                filters: filters,
                output: output
            ).run()
        case .recovery(let stateDatabasePath, let projectName, let output):
            return RecoveryCommandRunner(
                stateDatabasePath: stateDatabasePath,
                projectName: projectName,
                output: output
            ).run()
        case .cleanup(let path, let stateDatabasePath, let confirmation, let teamProfilePath, let approvalRecordPath):
            return CleanupCommandRunner(
                manifestPath: path,
                stateDatabasePath: stateDatabasePath,
                confirmation: confirmation,
                teamProfilePath: teamProfilePath,
                approvalRecordPath: approvalRecordPath,
                environment: environment
            ).run()
        case .diagnostics(let stateDatabasePath, let bundlePath, let projectName, let manifestPath):
            return DiagnosticsCommandRunner(
                stateDatabasePath: stateDatabasePath,
                bundlePath: bundlePath,
                projectName: projectName,
                manifestPath: manifestPath,
                environment: environment
            ).run()
        case .benchmark(let options):
            return try BenchmarkCommandRunner(options: options, environment: environment).run()
        case .extensionCheck(let declarationPath, let executablePath, let output):
            return try checkExtension(
                declarationPath: declarationPath,
                executablePath: executablePath,
                output: output
            )
        case .doctor(let output):
            return doctor(environment: environment, output: output)
        }
    }

    public static let helpText = """
    Hostwright CLI

    Usage:
      hostwright --version
      hostwright init
      hostwright import-stack <path> [--output text|json] [--team-profile <path>]
      hostwright validate [path] [--team-profile <path>]
      hostwright plan [path] [--output text|json] [--team-profile <path>]
      hostwright status [path] [--state-db <path>] [--output text|json]
      hostwright apply [path] --state-db <path> --confirm-plan <hash> [--team-profile <path> --approval-record <path>]
      hostwright logs <service> [path] [--tail <n>] [--state-db <path>]
      hostwright events --state-db <path> [--project <name>] [--type <event>] [--service <name>] [--severity info|warning|error] [--limit <n>] [--sort asc|desc] [--output text|json]
      hostwright recovery --state-db <path> [--project <name>] [--output text|json]
      hostwright cleanup [path] --state-db <path> --dry-run [--team-profile <path>]
      hostwright cleanup [path] --state-db <path> --confirm-cleanup <token> [--team-profile <path> --approval-record <path>]
      hostwright diagnostics --state-db <path> --bundle <path> [--project <name>] [--manifest <path>]
      hostwright benchmark --image <local-image> --samples <3-10> --report <path> --source-commit <40-hex> --source-dirty <true|false> --expected-container-version <version> [--attended-sleep-wake-seconds <15-300>] --confirm-live
      hostwright extension check --declaration <absolute-path> --executable <absolute-path> [--output text|json]
      hostwright doctor [--output text|json]

    Most commands are read-only. init writes hostwright.yaml only when absent.
    import-stack reads a narrow safe stack-file subset and prints converted hostwright.yaml; it does not write files, observe runtime, or imply Compose parity.
    CLI plan output is deterministic but does not perform live runtime observation.
    Apply can execute exactly one confirmed createMissingService or restart-policy-allowed startManagedService action through RuntimeAdapter.
    Cleanup deletes only exact cleanup-eligible Hostwright-owned stopped/created/exited containers after dry-run token confirmation.
    Diagnostics writes a local redacted JSON bundle only. It never uploads telemetry.
    JSON output is supported for import-stack, plan, status, events, recovery, extension check, doctor, and errors when --output json is present.
    Team profiles and approvals are loaded only from explicit local paths. Profile-aware mutations require an approval bound to the exact profile, manifest, and plan or cleanup token.
    Benchmark runs are explicit local hardware evidence. They refuse image pulls and broad cleanup, use bounded disposable Hostwright-owned resources, and write only the requested non-existing report path.
    Extension check executes one reviewed-local protocol handshake from explicit absolute paths. The protocol grants no Hostwright capability, but the reviewed executable still has the invoking macOS account's ambient privileges; it is not sandboxed.

    Examples:
      hostwright plan --output json
      hostwright import-stack compose.yaml --output json
      hostwright status --state-db /tmp/hostwright.sqlite --output json
      hostwright events --state-db /tmp/hostwright.sqlite --project api-local --output json
      hostwright recovery --state-db /tmp/hostwright.sqlite --output json
      hostwright diagnostics --state-db /tmp/hostwright.sqlite --bundle /tmp/hostwright-diagnostics.json
      hostwright benchmark --image docker.io/library/python:alpine --samples 3 --report /tmp/hostwright-benchmark.json --source-commit 0123456789012345678901234567890123456789 --source-dirty true --expected-container-version 1.0.0 --confirm-live
      hostwright extension check --declaration /tmp/extension.json --executable /tmp/extension --output json
      hostwright doctor --output json

    """

    private static func initManifest(environment: CLIEnvironment) throws -> CLIRunResult {
        let path = HostwrightIdentity.manifestFileName
        if environment.fileExists(path) {
            return failure(code: .fileAlreadyExists, message: "\(path) already exists. init will not overwrite it.")
        }

        try hostwrightWriteLocalText(path: path, text: starterManifest, role: "starter manifest", environment: environment)
        return CLIRunResult(standardOutput: "Created \(path)\n")
    }

    private static func importStack(
        path: String,
        output: CLIOutputFormat,
        teamProfilePath: String?,
        environment: CLIEnvironment
    ) throws -> CLIRunResult {
        let text = try hostwrightReadLocalText(path: path, role: "stack file", environment: environment)
        let result = StackFileImporter.convert(text)
        let exitCode: CLIExitCode = result.succeeded ? .success : .validation
        var validatedManifest: TeamValidatedManifest?
        if let manifestText = result.manifestText, result.succeeded {
            validatedManifest = try hostwrightValidatedManifest(
                text: manifestText,
                teamProfilePath: teamProfilePath,
                environment: environment
            )
        }

        if output == .json {
            if result.succeeded {
                return CLIRunResult(
                    standardOutput: CLIJSON.stackImport(path: path, result: result, validatedManifest: validatedManifest),
                    exitCode: exitCode.rawValue
                )
            }
            return CLIRunResult(standardError: CLIJSON.stackImportError(path: path, result: result, exitCode: exitCode), exitCode: exitCode.rawValue)
        }

        if result.succeeded, let manifestText = result.manifestText {
            let warningText = result.warnings.isEmpty ? "" : result.warnings.map(\.rendered).joined(separator: "\n") + "\n"
            let teamText = validatedManifest.map { hostwrightTeamProfileText($0) } ?? ""
            return CLIRunResult(standardOutput: manifestText, standardError: warningText + teamText, exitCode: exitCode.rawValue)
        }

        return CLIRunResult(
            standardError: result.errors.map(\.rendered).joined(separator: "\n") + "\n",
            exitCode: exitCode.rawValue
        )
    }

    private static func doctor(environment: CLIEnvironment, output: CLIOutputFormat) -> CLIRunResult {
        let inputs = DoctorInputs(
            operatingSystemDescription: environment.operatingSystemDescription(),
            platform: environment.platformSnapshot(),
            swiftVersion: environment.swiftVersion(),
            containerExecutablePath: environment.executablePath("container"),
            manifestExists: environment.fileExists(HostwrightIdentity.manifestFileName),
            resourceSnapshot: environment.resourceSnapshot()
        )
        let report = HostwrightDoctor.report(inputs: inputs)
        let exitCode = report.hasFailures ? CLIExitCode.validation.rawValue : CLIExitCode.success.rawValue
        if output == .json {
            return CLIRunResult(standardOutput: CLIJSON.doctor(report), exitCode: exitCode)
        }
        let lines = report.checks.map { check in
            "[\(check.status.rawValue)] \(check.identifier.rawValue): \(check.message)"
        }
        return CLIRunResult(standardOutput: "Hostwright doctor\n" + lines.joined(separator: "\n") + "\n", exitCode: exitCode)
    }

    private static func checkExtension(
        declarationPath: String,
        executablePath: String,
        output: CLIOutputFormat
    ) throws -> CLIRunResult {
        let result = try ReviewedLocalExtensionHost().check(
            declarationURL: URL(fileURLWithPath: declarationPath),
            executableURL: URL(fileURLWithPath: executablePath)
        )
        if output == .json {
            return CLIRunResult(standardOutput: CLIJSON.extensionHandshake(result))
        }
        return CLIRunResult(
            standardOutput: """
            Reviewed-local extension handshake ready
            Identifier: \(result.identifier)
            Capability: \(result.capability.rawValue)
            Protocol version: \(result.protocolVersion)
            Declaration SHA-256: \(result.declarationSHA256)
            Executable SHA-256: \(result.executableSHA256)
            Duration: \(result.durationMilliseconds) ms
            Staging cleanup: succeeded

            """
        )
    }

    private static func loadValidManifest(
        path: String,
        teamProfilePath: String?,
        environment: CLIEnvironment
    ) throws -> TeamValidatedManifest {
        let text = try hostwrightReadManifestText(path: path, environment: environment)
        return try hostwrightValidatedManifest(text: text, teamProfilePath: teamProfilePath, environment: environment)
    }

    private static func failure(issues: [ManifestIssue], output: CLIOutputFormat = .text) -> CLIRunResult {
        let exitCode = CLIExitCode.validation
        if output == .json {
            return CLIRunResult(standardError: CLIJSON.manifestError(issues: issues, exitCode: exitCode), exitCode: exitCode.rawValue)
        }
        return CLIRunResult(standardError: render(issues: issues), exitCode: exitCode.rawValue)
    }

    private static func render(issues: [ManifestIssue]) -> String {
        issues.map(\.rendered).joined(separator: "\n") + "\n"
    }

    private static func failure(code: HostwrightErrorCode, message: String, output: CLIOutputFormat = .text) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        let redactedMessage = RuntimeRedactionPolicy.default.redact(message)
        if output == .json {
            return CLIRunResult(standardError: CLIJSON.error(code: code, message: redactedMessage, exitCode: exitCode), exitCode: exitCode.rawValue)
        }
        return CLIRunResult(standardError: "\(code.rawValue): \(redactedMessage)\n", exitCode: exitCode.rawValue)
    }
}

let result = HostwrightCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
if !result.standardOutput.isEmpty {
    print(result.standardOutput, terminator: "")
}
if !result.standardError.isEmpty {
    fputs(result.standardError, stderr)
}
exit(result.exitCode)
