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
            FileHandle.standardError.write(Data("HW-DIST-001: \(error.description)\n".utf8))
            exit(errorExitCode(error))
        } catch {
            FileHandle.standardError.write(Data("HW-DIST-001: Unexpected distribution-tool failure.\n".utf8))
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
        case "release":
            let options = try parse(values, required: [
                "--source-root", "--output-dir", "--expected-commit", "--expected-version",
                "--release-tag", "--application-identity", "--installer-identity",
                "--team-id", "--notary-keychain-profile"
            ])
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
            return ToolResult(
                output: "Trusted release output: \(options["--output-dir"]!)\nArchive: \(report.manifest.archive.fileName)\nPackage: \(report.manifest.package.fileName)\nStatus: \(report.evidence.status.rawValue)\n",
                exitCode: 0
            )
        case "verify-release":
            let options = try parse(values, required: ["--release-dir", "--team-id"])
            let result = try TrustedReleaseVerifier().verify(
                releaseDirectory: fileURL(options["--release-dir"]!),
                expectedTeamIdentifier: options["--team-id"]!,
                cancellation: cancellation
            )
            return ToolResult(
                output: "Verified trusted release\nVersion: \(result.manifest.packageVersion)\nCommit: \(result.manifest.sourceCommit)\nTeam: \(result.manifest.applicationSigner.teamIdentifier)\nStatus: passed\n",
                exitCode: 0
            )
        case "homebrew-formula":
            let options = try parse(
                values,
                required: ["--release-dir", "--team-id", "--artifact-url", "--output"]
            )
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
                "--hostwright-binary", "--hostwright-control-binary", "--hostwrightd-binary", "--example-manifest", "--license", "--readme",
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
                    hostwrightDaemonBinary: fileURL(options["--hostwrightd-binary"]!),
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

    private static func parse(_ arguments: [String], required: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard required.contains(flag), values[flag] == nil, index + 1 < arguments.count else {
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
        case .commandFailed, .commandTimedOut, .commandCancelled,
             .commandOutputLimitExceeded, .commandProcessTreeViolation:
            return 69
        case .lifecycleFailed:
            return 72
        }
    }

    private static let helpText = """
    hostwright-dist trusted and developer distribution tool

    Usage:
      hostwright-dist release --source-root <path> --output-dir <path> --expected-commit <40-hex> --expected-version <semver> --release-tag <v-semver> --application-identity <SHA-1> --installer-identity <SHA-1> --team-id <10-char> --notary-keychain-profile <name>
      hostwright-dist verify-release --release-dir <path> --team-id <10-char>
      hostwright-dist homebrew-formula --release-dir <path> --team-id <10-char> --artifact-url <immutable-https-url> --output <Formula/hostwright.rb>
      hostwright-dist build --source-root <path> --output-dir <path> --expected-commit <40-hex>
      hostwright-dist assemble --hostwright-binary <path> --hostwright-control-binary <path> --hostwrightd-binary <path> --example-manifest <path> --license <path> --readme <path> --output-dir <path> --version <semver> --source-commit <40-hex> --source-dirty <true|false> --architecture arm64
      hostwright-dist verify --distribution-dir <path>
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
