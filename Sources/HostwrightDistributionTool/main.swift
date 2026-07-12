import Darwin
import Foundation
import HostwrightDistribution

@main
enum HostwrightDistributionCLI {
    static func main() {
        do {
            let result = try run(Array(CommandLine.arguments.dropFirst()))
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

    private static func run(_ arguments: [String]) throws -> ToolResult {
        guard let command = arguments.first else {
            return ToolResult(output: helpText, exitCode: 0)
        }
        let values = Array(arguments.dropFirst())
        switch command {
        case "build":
            let options = try parse(values, required: ["--source-root", "--output-dir", "--expected-commit"])
            let report = try DistributionCleanBuilder().build(
                sourceRoot: fileURL(options["--source-root"]!),
                outputDirectory: fileURL(options["--output-dir"]!),
                expectedCommit: options["--expected-commit"]!
            )
            return blockedResult(report: report, outputDirectory: options["--output-dir"]!)
        case "assemble":
            let required = [
                "--hostwright-binary", "--hostwrightd-binary", "--license", "--readme",
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
                    hostwrightDaemonBinary: fileURL(options["--hostwrightd-binary"]!),
                    licenseFile: fileURL(options["--license"]!),
                    readmeFile: fileURL(options["--readme"]!),
                    outputDirectory: fileURL(options["--output-dir"]!),
                    packageVersion: options["--version"]!,
                    sourceCommit: options["--source-commit"]!,
                    sourceDirty: options["--source-dirty"] == "true",
                    architecture: options["--architecture"]!,
                    inputStageIdentifier: "prebuilt-validation",
                    inputStageDetail: "Validated and executed explicit prebuilt inputs for local integration; this is not clean release-build evidence."
                )
            )
            return blockedResult(report: report, outputDirectory: options["--output-dir"]!)
        case "verify":
            let options = try parse(values, required: ["--distribution-dir"])
            let report = try DistributionVerifier().verifyAndCleanup(
                distributionDirectory: fileURL(options["--distribution-dir"]!)
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
                reportURL: fileURL(options["--report"]!)
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
        case .commandFailed, .commandTimedOut:
            return 69
        case .lifecycleFailed:
            return 72
        }
    }

    private static let helpText = """
    hostwright-dist developer distribution evidence tool

    Usage:
      hostwright-dist build --source-root <path> --output-dir <path> --expected-commit <40-hex>
      hostwright-dist assemble --hostwright-binary <path> --hostwrightd-binary <path> --license <path> --readme <path> --output-dir <path> --version <semver> --source-commit <40-hex> --source-dirty <true|false> --architecture arm64
      hostwright-dist verify --distribution-dir <path>
      hostwright-dist lifecycle --baseline-dir <path> --candidate-dir <path> --prefix <hostwright-dist-* temp-path> --report <path>

    The tool creates local unsigned evidence only. It never signs, notarizes, staples,
    invokes Gatekeeper acceptance, builds a pkg, installs outside an explicit temporary
    prefix, creates release tags, or publishes artifacts.
    """ + "\n"
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
