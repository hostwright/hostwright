import Darwin
import HostwrightCore
import HostwrightHealth
import HostwrightManifest
import HostwrightReconciler

public enum HostwrightCLI {
    public static let starterManifest = """
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
        do {
            let command = try CLICommand.parse(arguments: arguments)
            return try run(command: command, environment: environment)
        } catch let error as CLIUsageError {
            return failure(code: .commandUsage, message: "\(error.message)\n\n\(helpText)")
        } catch let error as ManifestParseError {
            return failure(issues: error.issues)
        } catch {
            return failure(code: .manifestFileIOFailed, message: String(describing: error))
        }
    }

    public static func run(command: CLICommand, environment: CLIEnvironment = .live) throws -> CLIRunResult {
        switch command {
        case .version:
            return CLIRunResult(standardOutput: "\(HostwrightIdentity.developmentVersion)\n")
        case .help:
            return CLIRunResult(standardOutput: helpText)
        case .initManifest:
            return try initManifest(environment: environment)
        case .validate(let path):
            let manifest = try loadValidManifest(path: path, environment: environment)
            return CLIRunResult(standardOutput: "Valid hostwright manifest: \(path)\nProject: \(manifest.project ?? "<missing>")\nServices: \(manifest.services.count)\n")
        case .plan(let path):
            let manifest = try loadValidManifest(path: path, environment: environment)
            let plan = ReconciliationPlanner().plan(manifest: manifest)
            return CLIRunResult(standardOutput: PlanRenderer.render(plan))
        case .status(let path):
            return status(path: path, environment: environment)
        case .apply(let path, let stateDatabasePath, let confirmedPlanHash):
            return ApplyCommandRunner(
                manifestPath: path,
                stateDatabasePath: stateDatabasePath,
                confirmedPlanHash: confirmedPlanHash,
                environment: environment
            ).run()
        case .doctor:
            return doctor(environment: environment)
        }
    }

    public static let helpText = """
    Hostwright CLI

    Usage:
      hostwright --version
      hostwright init
      hostwright validate [path]
      hostwright plan [path]
      hostwright status [path]
      hostwright apply [path] --state-db <path> --confirm-plan <hash>
      hostwright doctor

    Commands are non-mutating except init, which creates hostwright.yaml only when absent.
    CLI plan output is deterministic but does not perform live runtime observation.
    Apply is create-only, requires explicit state DB and plan hash confirmation, and mutates only through RuntimeAdapter.

    """

    private static func initManifest(environment: CLIEnvironment) throws -> CLIRunResult {
        let path = HostwrightIdentity.manifestFileName
        if environment.fileExists(path) {
            return failure(code: .fileAlreadyExists, message: "\(path) already exists. Phase 2 init will not overwrite it.")
        }

        try environment.writeTextFile(path, starterManifest)
        return CLIRunResult(standardOutput: "Created \(path)\n")
    }

    private static func status(path: String, environment: CLIEnvironment) -> CLIRunResult {
        guard environment.fileExists(path) else {
            return CLIRunResult(
                standardOutput: """
                Hostwright status
                Manifest: \(path) not found
                Runtime: unavailable in CLI status; no Apple container state was inspected.

                """
            )
        }

        do {
            let manifest = try loadValidManifest(path: path, environment: environment)
            return CLIRunResult(
                standardOutput: """
                Hostwright status
                Manifest: \(path) valid
                Project: \(manifest.project ?? "<missing>")
                Declared services: \(manifest.services.map(\.name).joined(separator: ", "))
                Runtime: unavailable in CLI status; no Apple container state was inspected.

                """
            )
        } catch let error as ManifestParseError {
            return CLIRunResult(
                standardOutput: """
                Hostwright status
                Manifest: \(path) invalid
                Runtime: unavailable in CLI status; no Apple container state was inspected.

                """,
                standardError: render(issues: error.issues),
                exitCode: 1
            )
        } catch {
            return failure(code: .manifestFileIOFailed, message: String(describing: error))
        }
    }

    private static func doctor(environment: CLIEnvironment) -> CLIRunResult {
        let inputs = DoctorInputs(
            operatingSystemDescription: environment.operatingSystemDescription(),
            platform: environment.platformSnapshot(),
            swiftVersion: environment.swiftVersion(),
            containerExecutablePath: environment.executablePath("container"),
            manifestExists: environment.fileExists(HostwrightIdentity.manifestFileName)
        )
        let report = HostwrightDoctor.report(inputs: inputs)
        let lines = report.checks.map { check in
            "[\(check.status.rawValue)] \(check.identifier.rawValue): \(check.message)"
        }
        return CLIRunResult(standardOutput: "Hostwright doctor\n" + lines.joined(separator: "\n") + "\n")
    }

    private static func loadValidManifest(path: String, environment: CLIEnvironment) throws -> HostwrightManifest {
        let text = try environment.readTextFile(path)
        return try ManifestValidator.validated(text)
    }

    private static func failure(issues: [ManifestIssue]) -> CLIRunResult {
        CLIRunResult(standardError: render(issues: issues), exitCode: 1)
    }

    private static func render(issues: [ManifestIssue]) -> String {
        issues.map(\.rendered).joined(separator: "\n") + "\n"
    }

    private static func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: 1)
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
