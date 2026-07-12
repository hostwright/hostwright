import Foundation
import HostwrightCore
import HostwrightHealth
import HostwrightRuntime

struct BenchmarkCommandRunner {
    let options: BenchmarkCLIOptions
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        guard options.confirmedLive,
              (3...10).contains(options.sampleCount),
              options.sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              options.sourceCommit != String(repeating: "0", count: 40),
              BenchmarkImageReferencePolicy.isSafe(options.image),
              !options.reportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !options.reportPath.hasPrefix("-"),
              AppleContainerVersionParser.isValidExpectedVersion(options.expectedContainerVersion),
              options.attendedSleepWakeSeconds.map({ (15...300).contains($0) }) ?? true else {
            return failure(
                code: .benchmarkInvalid,
                message: "Benchmark options failed the direct command validation gate before file or runtime access."
            )
        }
        guard !environment.fileExists(options.reportPath) else {
            return failure(
                code: .fileAlreadyExists,
                message: "Benchmark report already exists at \(options.reportPath); refusing to overwrite it."
            )
        }

        let session = BenchmarkSession(options: options, environment: environment)
        let report = session.execute()
        do {
            try BenchmarkLabReportParser.validate(report)
        } catch {
            return failure(
                code: .benchmarkFailed,
                message: "Benchmark report validation failed before write: \(error)"
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        guard let text = String(data: data, encoding: .utf8) else {
            return failure(code: .benchmarkFailed, message: "Benchmark report could not be encoded as UTF-8 JSON.")
        }
        try hostwrightWriteNewLocalText(
            path: options.reportPath,
            text: text + "\n",
            role: "benchmark report",
            environment: environment
        )

        let status = try evidenceStatus(report)
        let summary = "Benchmark report: \(options.reportPath)\nStatus: \(status.rawValue)\nIterations: \(report.iterations?.count ?? 0)/\(options.sampleCount)\nCleanup: \(report.evidence?.cleanup.status.rawValue ?? "unavailable")\n"
        switch status {
        case .passed:
            return CLIRunResult(standardOutput: summary)
        case .blocked:
            return CLIRunResult(
                standardOutput: summary,
                standardError: "\(HostwrightErrorCode.benchmarkBlocked.rawValue): Benchmark evidence is blocked; inspect the report blockers.\n",
                exitCode: CLIExitCode.runtimeUnavailable.rawValue
            )
        case .failed:
            return CLIRunResult(
                standardOutput: summary,
                standardError: "\(HostwrightErrorCode.benchmarkFailed.rawValue): Benchmark evidence failed; inspect the report failures and cleanup outcome.\n",
                exitCode: CLIExitCode.partialFailure.rawValue
            )
        }
    }

    private func evidenceStatus(_ report: BenchmarkLabReport) throws -> HostwrightEvidenceStatus {
        guard let status = report.evidence?.status else {
            throw HostwrightDiagnostic(code: .benchmarkFailed, message: "Live benchmark report omitted its evidence status.")
        }
        return status
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let redacted = RuntimeRedactionPolicy.default.redact(message)
        return CLIRunResult(
            standardError: "\(code.rawValue): \(redacted)\n",
            exitCode: CLIExitCode.mapped(from: code).rawValue
        )
    }
}

enum BenchmarkImageReferencePolicy {
    static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              !value.contains(where: { $0.isWhitespace }),
              !value.contains("://"),
              value.range(of: "^[A-Za-z0-9._/:@+-]+$", options: .regularExpression) != nil else {
            return false
        }

        let digestParts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard digestParts.count <= 2 else { return false }
        guard digestParts.count == 2 else { return true }
        return !digestParts[0].isEmpty &&
            String(digestParts[1]).range(
                of: "^sha256:[a-f0-9]{64}$",
                options: .regularExpression
            ) != nil
    }
}
