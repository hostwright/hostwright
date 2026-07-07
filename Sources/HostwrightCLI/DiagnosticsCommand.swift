import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

struct DiagnosticsCommandRunner {
    let stateDatabasePath: String
    let bundlePath: String
    let projectName: String?
    let manifestPath: String?
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        do {
            guard !environment.fileExists(bundlePath) else {
                return failure(code: .fileAlreadyExists, message: "\(bundlePath) already exists. diagnostics will not overwrite it.")
            }

            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()
            let store = SQLiteStateStore(configuration: configuration)
            let manifestSummary = try loadManifestSummary()
            let projectID = projectName.map { "project-\($0)" }
            let export = try store.diagnostics.loadExport(
                query: DiagnosticsExportQuery(
                    projectID: projectID,
                    manifest: manifestSummary,
                    generatedAt: hostwrightTimestamp()
                )
            )
            let bundleText = try export.jsonString()
            do {
                try environment.writeTextFile(bundlePath, bundleText)
            } catch {
                return failure(code: .fileIOFailed, message: "failed to write diagnostics bundle \(bundlePath): \(RuntimeRedactionPolicy.default.redact(String(describing: error)))")
            }
            return CLIRunResult(
                standardOutput: """
                Hostwright diagnostics
                Bundle: \(bundlePath)
                Telemetry: \(export.telemetryPolicy)
                Events: \(export.events.count)
                Operations: \(export.operations.count)
                Operation groups: \(export.operationGroups.count)
                Health results: \(export.healthResults.count)
                Observed snapshots: \(export.observedSnapshots.count)

                """
            )
        } catch let error as ManifestParseError {
            return CLIRunResult(standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n", exitCode: CLIExitCode.validation.rawValue)
        } catch let diagnostic as HostwrightDiagnostic {
            return failure(code: diagnostic.code, message: diagnostic.message)
        } catch let error as StateStoreError {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        } catch {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        }
    }

    private func loadManifestSummary() throws -> DiagnosticsManifestSummary? {
        guard let path = manifestPath else {
            return nil
        }
        let text: String
        do {
            text = try environment.readTextFile(path)
        } catch {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "failed to read diagnostics manifest \(path): \(RuntimeRedactionPolicy.default.redact(String(describing: error)))"
            )
        }
        let manifest = try ManifestValidator.validated(text)
        return DiagnosticsManifestSummary(
            path: path,
            projectName: manifest.project,
            serviceNames: manifest.services.map(\.name).sorted(),
            manifestHash: hostwrightStableHash(text)
        )
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        return CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: exitCode.rawValue)
    }
}
