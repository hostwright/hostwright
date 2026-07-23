import Darwin
import Dispatch
import Foundation
import HostwrightCore
import HostwrightDistribution

@main
enum HostwrightDistributionCLI {
    static func main() {
        let signalCancellation = DistributionSignalCancellation()
        do {
            let result = try run(
                Array(CommandLine.arguments.dropFirst()),
                cancellation: signalCancellation.cancellation
            )
            if !result.output.isEmpty {
                FileHandle.standardOutput.write(Data(result.output.utf8))
            }
            if !result.error.isEmpty {
                FileHandle.standardError.write(Data(result.error.utf8))
            }
            exit(result.exitCode)
        } catch let error as DistributionError {
            let exitCode = errorExitCode(error)
            writeError(error, exitCode: exitCode)
            exit(exitCode)
        } catch {
            writeUnexpectedError()
            exit(72)
        }
    }

    private static func run(
        _ arguments: [String],
        cancellation: SecureSubprocessCancellation
    ) throws -> ToolResult {
        guard let command = arguments.first else {
            return ToolResult(output: helpText, exitCode: 0)
        }
        let values = Array(arguments.dropFirst())
        switch command {
        case "--version":
            guard values.isEmpty else {
                throw DistributionError.invalidArguments("--version does not accept arguments.")
            }
            return ToolResult(output: "\(HostwrightIdentity.version)\n", exitCode: 0)
        case "release":
            let options = try parse(values, required: [
                "--source-root", "--output-dir", "--expected-commit", "--expected-version",
                "--release-tag", "--application-identity", "--installer-identity",
                "--team-id", "--notary-keychain-profile"
            ], optional: ["--format"])
            let format = try outputFormat(options)
            let report = try TrustedReleaseBuilder().build(
                TrustedReleaseBuildRequest(
                    sourceRoot: fileURL(options["--source-root"]!),
                    outputDirectory: fileURL(options["--output-dir"]!),
                    expectedCommit: options["--expected-commit"]!,
                    expectedVersion: options["--expected-version"]!,
                    releaseTag: options["--release-tag"]!,
                    applicationIdentityFingerprint: options["--application-identity"]!,
                    installerIdentityFingerprint: options["--installer-identity"]!,
                    teamIdentifier: options["--team-id"]!,
                    notaryKeychainProfile: options["--notary-keychain-profile"]!
                ),
                cancellation: cancellation
            )
            if format == .json {
                return ToolResult(
                    output: try jsonLine(
                        TrustedReleaseCommandOutput(
                            report: report,
                            releaseDirectory: fileURL(options["--output-dir"]!).path
                        )
                    ),
                    exitCode: 0
                )
            }
            return ToolResult(
                output: "Trusted release output: \(options["--output-dir"]!)\nArchive: \(report.manifest.archive.fileName)\nPackage: \(report.manifest.package.fileName)\nStatus: \(report.evidence.status.rawValue)\n",
                exitCode: 0
            )
        case "verify-release":
            let options = try parse(
                values,
                required: ["--release-dir", "--team-id"],
                optional: ["--format"]
            )
            let format = try outputFormat(options)
            let result = try TrustedReleaseVerifier().verify(
                releaseDirectory: fileURL(options["--release-dir"]!),
                expectedTeamIdentifier: options["--team-id"]!,
                cancellation: cancellation
            )
            if format == .json {
                return ToolResult(
                    output: try jsonLine(TrustedReleaseVerificationCommandOutput(result: result)),
                    exitCode: 0
                )
            }
            return ToolResult(
                output: "Verified trusted release\nVersion: \(result.manifest.packageVersion)\nCommit: \(result.manifest.sourceCommit)\nTeam: \(result.manifest.applicationSigner.teamIdentifier)\nStatus: passed\n",
                exitCode: 0
            )
        case "homebrew-formula":
            let options = try parse(
                values,
                required: ["--release-dir", "--team-id", "--artifact-url", "--output"],
                optional: ["--format"]
            )
            let format = try outputFormat(options)
            let verified = try TrustedReleaseVerifier().verify(
                releaseDirectory: fileURL(options["--release-dir"]!),
                expectedTeamIdentifier: options["--team-id"]!,
                cancellation: cancellation
            )
            let formula = try HomebrewFormulaRenderer.render(
                HomebrewFormulaRequest(
                    manifest: verified.manifest,
                    artifactURL: options["--artifact-url"]!
                )
            )
            let output = fileURL(options["--output"]!)
            guard try DistributionFileSystem.isDirectoryNonSymlink(
                output.deletingLastPathComponent().resolvingSymlinksInPath()
            ) else {
                throw DistributionError.invalidArguments("Homebrew formula output parent must be a non-symlink directory.")
            }
            try DistributionFileSystem.writeNewFile(Data(formula.utf8), to: output, mode: 0o644)
            if format == .json {
                return ToolResult(
                    output: try jsonLine(
                        HomebrewFormulaCommandOutput(
                            manifest: verified.manifest,
                            outputFile: output.path
                        )
                    ),
                    exitCode: 0
                )
            }
            return ToolResult(
                output: "Homebrew formula: \(output.path)\nArchive SHA-256: \(verified.manifest.archive.sha256)\nStatus: passed\n",
                exitCode: 0
            )
        case "build":
            let options = try parse(values, required: ["--source-root", "--output-dir", "--expected-commit"])
            let report = try DistributionCleanBuilder().build(
                sourceRoot: fileURL(options["--source-root"]!),
                outputDirectory: fileURL(options["--output-dir"]!),
                expectedCommit: options["--expected-commit"]!,
                cancellation: cancellation
            )
            return blockedResult(report: report, outputDirectory: options["--output-dir"]!)
        case "assemble":
            let required = [
                "--hostwright-binary", "--hostwright-control-binary",
                "--hostwright-containerization-helper-binary", "--hostwright-dist-binary",
                "--hostwrightd-binary", "--containerization-asset-root",
                "--example-manifest", "--license", "--readme",
                "--output-dir", "--version", "--source-commit", "--source-dirty", "--architecture"
            ]
            let options = try parse(values, required: required)
            guard options["--source-dirty"] == "true" || options["--source-dirty"] == "false" else {
                throw DistributionError.invalidArguments("assemble --source-dirty supports only true or false.")
            }
            guard options["--source-dirty"] == "true" else {
                throw DistributionError.invalidArguments(
                    "assemble is local-integration-only and requires --source-dirty true; use build for clean-source evidence."
                )
            }
            let report = try DistributionAssembler().assemble(
                DistributionAssemblyRequest(
                    hostwrightBinary: fileURL(options["--hostwright-binary"]!),
                    hostwrightControlBinary: fileURL(options["--hostwright-control-binary"]!),
                    hostwrightContainerizationHelperBinary: fileURL(
                        options["--hostwright-containerization-helper-binary"]!
                    ),
                    hostwrightDistributionBinary: fileURL(options["--hostwright-dist-binary"]!),
                    hostwrightDaemonBinary: fileURL(options["--hostwrightd-binary"]!),
                    containerizationAssets: try DistributionContainerizationAssets.load(
                        root: fileURL(options["--containerization-asset-root"]!),
                        cancellation: cancellation
                    ),
                    exampleManifestFile: fileURL(options["--example-manifest"]!),
                    licenseFile: fileURL(options["--license"]!),
                    readmeFile: fileURL(options["--readme"]!),
                    outputDirectory: fileURL(options["--output-dir"]!),
                    packageVersion: options["--version"]!,
                    sourceCommit: options["--source-commit"]!,
                    sourceDirty: options["--source-dirty"] == "true",
                    architecture: options["--architecture"]!,
                    inputStageIdentifier: "prebuilt-validation",
                    inputStageDetail: "Validated and executed explicit prebuilt inputs for local integration; this is not clean release-build evidence."
                ),
                cancellation: cancellation
            )
            return blockedResult(report: report, outputDirectory: options["--output-dir"]!)
        case "verify":
            let options = try parse(values, required: ["--distribution-dir"])
            let report = try DistributionVerifier().verifyAndCleanup(
                distributionDirectory: fileURL(options["--distribution-dir"]!),
                cancellation: cancellation
            )
            return ToolResult(
                output: "Verified unsigned distribution artifact\nCommit: \(report.manifest.sourceCommit)\nArchive: \(report.archive.fileName)\nStatus: \(report.evidence.status.rawValue)\n",
                exitCode: 0
            )
        case "install", "upgrade", "repair":
            return try lifecycleMutation(
                command: command,
                arguments: values,
                cancellation: cancellation
            )
        case "package-apply":
            let options = try parse(
                values,
                required: [
                    "--staged-root", "--prefix", "--package-id",
                    "--package-version", "--team-id", "--output"
                ]
            )
            try requireJSONOutput(options)
            let result = try DistributionPackageLifecycle().apply(
                stagedRoot: fileURL(options["--staged-root"]!),
                prefix: fileURL(options["--prefix"]!),
                packageIdentifier: options["--package-id"]!,
                packageVersion: options["--package-version"]!,
                teamIdentifier: options["--team-id"]!,
                cancellation: cancellation
            )
            return ToolResult(output: try jsonLine(result), exitCode: 0)
        case "package-preflight":
            let options = try parse(
                values,
                required: [
                    "--candidate-manifest", "--prefix", "--package-id",
                    "--package-version", "--output"
                ]
            )
            try requireJSONOutput(options)
            let result = try DistributionPackageLifecycle().preflight(
                candidateManifest: fileURL(options["--candidate-manifest"]!),
                prefix: fileURL(options["--prefix"]!),
                packageIdentifier: options["--package-id"]!,
                packageVersion: options["--package-version"]!,
                cancellation: cancellation
            )
            return ToolResult(output: try jsonLine(result), exitCode: 0)
        case "package-uninstall":
            let options = try parse(
                values,
                required: ["--prefix", "--data-policy", "--output"],
                optional: ["--confirmation"]
            )
            try requireJSONOutput(options)
            guard options["--data-policy"]
                == DistributionUninstallDataPolicy.preserve.rawValue else {
                throw DistributionError.invalidArguments(
                    DistributionPackagePolicy.removeDataUnsupportedMessage
                )
            }
            guard options["--confirmation"] == nil else {
                throw DistributionError.invalidArguments(
                    DistributionPackagePolicy.preserveConfirmationUnsupportedMessage
                )
            }
            let result = try DistributionPackageLifecycle().uninstall(
                prefix: fileURL(options["--prefix"]!),
                dataPolicy: .preserve,
                confirmationToken: nil,
                cancellation: cancellation
            )
            return ToolResult(output: try jsonLine(result), exitCode: 0)
        case "status":
            let options = try parse(
                values,
                required: ["--prefix", "--output"]
            )
            try requireJSONOutput(options)
            let inspection = try DistributionInstalledLifecycle().inspect(
                prefix: fileURL(options["--prefix"]!)
            )
            return ToolResult(output: try jsonLine(inspection), exitCode: 0)
        case "adopt-legacy":
            let options = try parse(
                values,
                required: ["--prefix", "--output"],
                optional: ["--state-db"]
            )
            try requireJSONOutput(options)
            let status = try DistributionInstalledLifecycle().adoptLegacyInstallation(
                prefix: fileURL(options["--prefix"]!),
                stateDatabasePath: options["--state-db"],
                cancellation: cancellation
            )
            return ToolResult(
                output: try jsonLine(DistributionLegacyAdoptionOutput(status: status)),
                exitCode: 0
            )
        case "recover":
            let options = try parse(
                values,
                required: ["--prefix", "--output"]
            )
            try requireJSONOutput(options)
            let result = try DistributionInstalledLifecycle().recover(
                prefix: fileURL(options["--prefix"]!),
                cancellation: cancellation
            )
            return ToolResult(output: try jsonLine(result), exitCode: 0)
        case "rollback":
            let options = try parse(
                values,
                required: ["--prefix", "--output"]
            )
            try requireJSONOutput(options)
            let status = try DistributionInstalledLifecycle().rollback(
                prefix: fileURL(options["--prefix"]!),
                cancellation: cancellation
            )
            return ToolResult(
                output: try jsonLine(
                    DistributionLifecycleMutationOutput(operation: .rollback, status: status)
                ),
                exitCode: 0
            )
        case "uninstall-plan":
            let options = try parse(
                values,
                required: ["--prefix", "--data-policy", "--output"]
            )
            try requireJSONOutput(options)
            guard let policy = DistributionUninstallDataPolicy(rawValue: options["--data-policy"]!) else {
                throw DistributionError.invalidArguments(
                    "uninstall-plan --data-policy supports only preserve or remove."
                )
            }
            let plan = try DistributionInstalledLifecycle().uninstallPlan(
                prefix: fileURL(options["--prefix"]!),
                dataPolicy: policy,
                cancellation: cancellation
            )
            return ToolResult(output: try jsonLine(plan), exitCode: 0)
        case "uninstall":
            let options = try parse(
                values,
                required: ["--prefix", "--data-policy", "--output"],
                optional: ["--confirmation"]
            )
            try requireJSONOutput(options)
            guard let policy = DistributionUninstallDataPolicy(rawValue: options["--data-policy"]!) else {
                throw DistributionError.invalidArguments(
                    "uninstall --data-policy supports only preserve or remove."
                )
            }
            let result = try DistributionInstalledLifecycle().uninstall(
                prefix: fileURL(options["--prefix"]!),
                dataPolicy: policy,
                confirmationToken: options["--confirmation"],
                cancellation: cancellation
            )
            return ToolResult(output: try jsonLine(result), exitCode: 0)
        case "lifecycle":
            let options = try parse(
                values,
                required: ["--baseline-dir", "--candidate-dir", "--prefix", "--report"]
            )
            let report = try DistributionLifecycleRunner().run(
                baselineDirectory: fileURL(options["--baseline-dir"]!),
                candidateDirectory: fileURL(options["--candidate-dir"]!),
                prefix: fileURL(options["--prefix"]!),
                reportURL: fileURL(options["--report"]!),
                cancellation: cancellation
            )
            return ToolResult(
                output: "Distribution lifecycle report: \(options["--report"]!)\nStatus: \(report.evidence.status.rawValue)\nStages: \(report.stages.count)/4\nCleanup: \(report.evidence.cleanup.status.rawValue)\n",
                error: "HW-DIST-002: Unsigned distribution lifecycle passed locally, but signing, notarization, Gatekeeper, and installer publication remain blocked.\n",
                exitCode: 69
            )
        case "--help", "help":
            guard values.isEmpty else {
                throw DistributionError.invalidArguments("help does not accept arguments.")
            }
            return ToolResult(output: helpText, exitCode: 0)
        default:
            throw DistributionError.invalidArguments("Unsupported hostwright-dist command \(command).")
        }
    }

    private static func parse(
        _ arguments: [String],
        required: [String],
        optional: [String] = []
    ) throws -> [String: String] {
        let allowed = Set(required + optional)
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard allowed.contains(flag), values[flag] == nil, index + 1 < arguments.count else {
                throw DistributionError.invalidArguments("Invalid, duplicate, or unsupported distribution argument \(flag).")
            }
            let value = arguments[index + 1]
            guard !value.isEmpty, !value.hasPrefix("-") else {
                throw DistributionError.invalidArguments("Distribution argument \(flag) requires a non-flag value.")
            }
            values[flag] = value
            index += 2
        }
        let missing = required.filter { values[$0] == nil }
        guard missing.isEmpty else {
            throw DistributionError.invalidArguments("Missing required distribution arguments: \(missing.joined(separator: ", ")).")
        }
        return values
    }

    private static func lifecycleMutation(
        command: String,
        arguments: [String],
        cancellation: SecureSubprocessCancellation
    ) throws -> ToolResult {
        let options = try parse(
            arguments,
            required: ["--prefix", "--output"],
            optional: [
                "--state-db", "--trusted-release-dir", "--team-id",
                "--developer-distribution-dir"
            ]
        )
        try requireJSONOutput(options)
        let hasTrusted = options["--trusted-release-dir"] != nil
        let hasDeveloper = options["--developer-distribution-dir"] != nil
        guard hasTrusted != hasDeveloper else {
            throw DistributionError.invalidArguments(
                "\(command) requires exactly one of --trusted-release-dir or --developer-distribution-dir."
            )
        }
        guard hasTrusted == (options["--team-id"] != nil) else {
            throw DistributionError.invalidArguments(
                "--team-id is required only with --trusted-release-dir."
            )
        }

        let prefix = fileURL(options["--prefix"]!)
        let extraction = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-dist-lifecycle-extract-\(UUID().uuidString)",
            isDirectory: true
        )
        var extractionRemoved = false
        defer {
            if !extractionRemoved, DistributionFileSystem.entryExists(extraction) {
                try? DistributionFileSystem.removeOwnedTemporaryItem(extraction)
            }
        }
        let lifecycle = DistributionInstalledLifecycle()
        let operation = DistributionLifecycleOperation(rawValue: command)!
        let statePath = options["--state-db"]
        let status: DistributionInstallationStatus
        if let releaseDirectory = options["--trusted-release-dir"] {
            let artifact = try TrustedReleaseVerifier().verifyForInstallation(
                releaseDirectory: fileURL(releaseDirectory),
                expectedTeamIdentifier: options["--team-id"]!,
                extractionDirectory: extraction,
                cancellation: cancellation
            )
            status = try lifecycle.install(
                artifact: artifact,
                prefix: prefix,
                stateDatabasePath: statePath,
                requiredOperation: operation,
                cancellation: cancellation
            )
        } else {
            let artifact = try DistributionVerifier().verify(
                distributionDirectory: fileURL(options["--developer-distribution-dir"]!),
                extractionDirectory: extraction,
                cancellation: cancellation
            )
            status = try lifecycle.install(
                artifact: artifact,
                prefix: prefix,
                stateDatabasePath: statePath,
                requiredOperation: operation,
                cancellation: cancellation
            )
        }
        let cleanup = DistributionPostCommitCleanup.removeOwnedTemporaryItem(extraction)
        extractionRemoved = true
        let cleanupWarning = cleanup.status == .pending
            ? "HW-DIST-W001: committed lifecycle mutation completed, but verified temporary extraction cleanup remains pending.\n"
            : ""
        return ToolResult(
            output: try jsonLine(
                DistributionLifecycleMutationOutput(
                    operation: operation,
                    status: status,
                    cleanup: cleanup
                )
            ),
            error: cleanupWarning,
            exitCode: 0
        )
    }

    private static func requireJSONOutput(_ options: [String: String]) throws {
        guard options["--output"] == "json" else {
            throw DistributionError.invalidArguments("Lifecycle commands currently require --output json.")
        }
    }

    private static func outputFormat(_ options: [String: String]) throws -> ToolOutputFormat {
        guard let value = options["--format"] else { return .text }
        guard let format = ToolOutputFormat(rawValue: value) else {
            throw DistributionError.invalidArguments("--format supports only text or json.")
        }
        return format
    }

    private static func jsonLine<T: Encodable>(_ value: T) throws -> String {
        guard let text = String(data: try DistributionJSON.encode(value), encoding: .utf8) else {
            throw DistributionError.lifecycleFailed("structured lifecycle output was not UTF-8")
        }
        return text
    }

    private static func blockedResult(
        report: DistributionBuildReport,
        outputDirectory: String
    ) -> ToolResult {
        ToolResult(
            output: "Unsigned distribution output: \(outputDirectory)\nArchive: \(report.archive.fileName)\nSource: \(report.manifest.sourceCommit)\nStatus: \(report.evidence.status.rawValue)\n",
            error: "HW-DIST-002: Artifact assembly passed, but signing, notarization, Gatekeeper, and installer publication remain blocked.\n",
            exitCode: 69
        )
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func errorExitCode(_ error: DistributionError) -> Int32 {
        switch error {
        case .invalidArguments, .unsafePath, .existingOutput:
            return 64
        case .dirtySource, .sourceCommitMismatch, .checksumMismatch, .invalidManifest, .invalidArtifact:
            return 65
        case .installOwnershipMismatch:
            return 71
        case .downgradeRefused, .versionConflict:
            return 65
        case .commandFailed, .commandTimedOut, .commandCancelled,
             .commandOutputLimitExceeded, .commandProcessTreeViolation:
            return 69
        case .lifecycleFailed:
            return 72
        }
    }

    private static func writeError(_ error: DistributionError, exitCode: Int32) {
        if requestsJSONOutput(CommandLine.arguments) {
            let payload = DistributionToolErrorOutput(
                code: "HW-DIST-001",
                message: error.description,
                exitCode: exitCode
            )
            if let data = try? DistributionJSON.encode(payload) {
                FileHandle.standardError.write(data)
                return
            }
        }
        FileHandle.standardError.write(Data("HW-DIST-001: \(error.description)\n".utf8))
    }

    private static func writeUnexpectedError() {
        if requestsJSONOutput(CommandLine.arguments) {
            let payload = DistributionToolErrorOutput(
                code: "HW-DIST-001",
                message: "Unexpected distribution-tool failure.",
                exitCode: 72
            )
            if let data = try? DistributionJSON.encode(payload) {
                FileHandle.standardError.write(data)
                return
            }
        }
        FileHandle.standardError.write(
            Data("HW-DIST-001: Unexpected distribution-tool failure.\n".utf8)
        )
    }

    private static func requestsJSONOutput(_ arguments: [String]) -> Bool {
        guard arguments.count >= 2 else { return false }
        let command = arguments[1]
        let structuredReleaseCommands = ["release", "verify-release", "homebrew-formula"]
        let outputFlag = structuredReleaseCommands.contains(command) ? "--format" : "--output"
        return zip(arguments, arguments.dropFirst()).contains { flag, value in
            flag == outputFlag && value == "json"
        }
    }

    private static let helpText = """
    hostwright-dist trusted and developer distribution tool

    Usage:
      hostwright-dist release --source-root <path> --output-dir <path> --expected-commit <40-hex> --expected-version <semver> --release-tag <v-semver> --application-identity <SHA-1> --installer-identity <SHA-1> --team-id <10-char> --notary-keychain-profile <name> [--format text|json]
      hostwright-dist verify-release --release-dir <path> --team-id <10-char> [--format text|json]
      hostwright-dist homebrew-formula --release-dir <path> --team-id <10-char> --artifact-url <immutable-https-url> --output <Formula/hostwright.rb> [--format text|json]
      HOSTWRIGHT_CONTAINERIZATION_ASSET_ROOT=<verified-root> hostwright-dist build --source-root <path> --output-dir <path> --expected-commit <40-hex>
      hostwright-dist --version
      hostwright-dist assemble --hostwright-binary <path> --hostwright-control-binary <path> --hostwright-containerization-helper-binary <path> --hostwright-dist-binary <path> --hostwrightd-binary <path> --containerization-asset-root <verified-root> --example-manifest <path> --license <path> --readme <path> --output-dir <path> --version <semver> --source-commit <40-hex> --source-dirty <true|false> --architecture arm64
      hostwright-dist verify --distribution-dir <path>
      hostwright-dist install --trusted-release-dir <path> --team-id <10-char> --prefix <path> [--state-db <path>] --output json
      hostwright-dist install --developer-distribution-dir <path> --prefix <path> [--state-db <path>] --output json
      hostwright-dist upgrade --trusted-release-dir <path> --team-id <10-char> --prefix <path> [--state-db <path>] --output json
      hostwright-dist repair --trusted-release-dir <path> --team-id <10-char> --prefix <path> [--state-db <path>] --output json
      hostwright-dist package-preflight --candidate-manifest <path> --prefix /usr/local --package-id dev.hostwright.cli --package-version <version> --output json
      hostwright-dist package-apply --staged-root '/Library/Application Support/Hostwright/InstallerPayload' --prefix /usr/local --package-id dev.hostwright.cli --package-version <version> --team-id <10-char> --output json
      hostwright-dist package-uninstall --prefix /usr/local --data-policy preserve --output json
      hostwright-dist status --prefix <path> --output json
      hostwright-dist adopt-legacy --prefix <path> [--state-db <path>] --output json
      hostwright-dist recover --prefix <path> --output json
      hostwright-dist rollback --prefix <path> --output json
      hostwright-dist uninstall-plan --prefix <path> --data-policy <preserve|remove> --output json
      hostwright-dist uninstall --prefix <path> --data-policy preserve --output json
      hostwright-dist uninstall --prefix <path> --data-policy remove --confirmation <plan-token> --output json
      hostwright-dist lifecycle --baseline-dir <path> --candidate-dir <path> --prefix <hostwright-dist-* temp-path> --report <path>

    `release` requires exact Developer ID identities and a preconfigured notarytool
    Keychain profile. It never accepts passwords, private keys, or tokens in argv.
    It builds twice, signs, notarizes, staples the pkg, verifies Gatekeeper, and emits
    signed release evidence. The tool never creates tags or publishes artifacts.
    """ + "\n"
}

private final class DistributionSignalCancellation {
    let cancellation: SecureSubprocessCancellation
    private let sources: [DispatchSourceSignal]

    init() {
        let cancellation = SecureSubprocessCancellation()
        self.cancellation = cancellation
        let queue = DispatchQueue(label: "dev.hostwright.distribution.signals")
        sources = [SIGINT, SIGTERM].map { signalNumber in
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [cancellation] in
                if cancellation.isCancelled {
                    Darwin.signal(signalNumber, SIG_DFL)
                    Darwin.raise(signalNumber)
                } else {
                    cancellation.cancel()
                }
            }
            source.resume()
            return source
        }
    }

    deinit {
        for (source, signalNumber) in zip(sources, [SIGINT, SIGTERM]) {
            source.cancel()
            Darwin.signal(signalNumber, SIG_DFL)
        }
    }
}

private struct ToolResult {
    let output: String
    let error: String
    let exitCode: Int32

    init(output: String = "", error: String = "", exitCode: Int32) {
        self.output = output
        self.error = error
        self.exitCode = exitCode
    }
}

private enum ToolOutputFormat: String {
    case text
    case json
}

private struct DistributionLifecycleMutationOutput: Encodable {
    let schemaVersion = 1
    let kind = "distributionLifecycleMutation"
    let operation: DistributionLifecycleOperation
    let status: DistributionInstallationStatus
    let cleanup: DistributionTemporaryCleanupReport

    init(
        operation: DistributionLifecycleOperation,
        status: DistributionInstallationStatus,
        cleanup: DistributionTemporaryCleanupReport = DistributionTemporaryCleanupReport(
            status: .complete,
            pendingPaths: []
        )
    ) {
        self.operation = operation
        self.status = status
        self.cleanup = cleanup
    }
}

private struct DistributionToolErrorOutput: Encodable {
    let schemaVersion = 1
    let kind = "distributionToolError"
    let code: String
    let message: String
    let exitCode: Int32
}

private struct DistributionLegacyAdoptionOutput: Encodable {
    let schemaVersion = 1
    let kind = "distributionLegacyAdoption"
    let status: DistributionInstallationStatus
}
