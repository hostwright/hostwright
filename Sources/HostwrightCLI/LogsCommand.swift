import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct LogsCommandRunner {
    let serviceName: String
    let manifestPath: String
    let tail: Int
    let stateDatabasePath: String?
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        do {
            let manifestText = try environment.readTextFile(manifestPath)
            let manifest = try ManifestValidator.validated(manifestText)
            let mapping = ManifestRuntimeMapper.map(manifest)
            guard let desired = mapping.desiredState.services.first(where: { $0.identity.serviceName == serviceName }) else {
                return failure(code: .commandUsage, message: "logs requires a service declared in \(manifestPath).")
            }

            let observationDesiredState: DesiredRuntimeState
            if let stateDatabasePath {
                let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
                try configuration.validate()
                let store = SQLiteStateStore(configuration: configuration)
                try store.migrate()
                observationDesiredState = try hostwrightDesiredStateWithOwnershipHints(
                    mapping.desiredState,
                    store: store,
                    projectID: "project-\(mapping.desiredState.projectName)"
                )
            } else {
                observationDesiredState = mapping.desiredState
            }

            let adapter = environment.runtimeAdapter()
            let observed = try hostwrightWaitForAsync {
                try await adapter.observe(desiredState: observationDesiredState)
            }
            let observedMatches = observed.services.filter { $0.identity == desired.identity }
            guard observedMatches.count == 1, let observedService = observedMatches.first else {
                return failure(code: .runtimeUnavailable, message: "logs requires an observed Hostwright-managed service. \(desired.identity.displayName) was not observed.")
            }

            let result = try hostwrightWaitForAsync {
                try await adapter.logs(for: observedService, tail: tail)
            }

            if let stateDatabasePath {
                try recordLogsRead(
                    stateDatabasePath: stateDatabasePath,
                    manifest: manifest,
                    manifestText: manifestText,
                    projectName: mapping.desiredState.projectName,
                    serviceName: serviceName,
                    resourceIdentifier: observedService.resourceIdentifier,
                    observed: observed,
                    lineLimit: result.lineLimit
                )
            }

            return CLIRunResult(
                standardOutput: """
                Hostwright logs
                Service: \(desired.identity.displayName)
                Resource: \(observedService.resourceIdentifier)
                Tail: \(result.lineLimit)

                \(RuntimeRedactionPolicy.default.redact(result.text))
                """
            )
        } catch let error as ManifestParseError {
            return CLIRunResult(standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n", exitCode: CLIExitCode.validation.rawValue)
        } catch let error as StateStoreError {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        } catch {
            return failure(code: .runtimeUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        }
    }

    private func recordLogsRead(
        stateDatabasePath: String,
        manifest: HostwrightManifest,
        manifestText: String,
        projectName: String,
        serviceName: String,
        resourceIdentifier: String,
        observed: ObservedRuntimeState,
        lineLimit: Int
    ) throws {
        let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
        try configuration.validate()
        let store = SQLiteStateStore(configuration: configuration)
        try store.migrate()
        let timestamp = hostwrightTimestamp()
        let projectID = "project-\(projectName)"
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: manifestPath,
            manifestHash: hostwrightStableHash(manifestText),
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: timestamp
        )
        try store.events.append([
            EventRecord(
                id: hostwrightUniqueID(prefix: "event-logs"),
                timestamp: timestamp,
                severity: .info,
                type: "logs.read",
                source: "hostwright-cli",
                projectID: projectID,
                serviceName: serviceName,
                runtimeAdapter: observed.adapterMetadata?.adapterName,
                message: "Read last \(lineLimit) log line(s) for \(projectName)/\(serviceName).",
                payloadJSONRedacted: #"{"resourceIdentifier":"\#(resourceIdentifier)","tail":\#(lineLimit)}"#
            )
        ])
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        return CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: exitCode.rawValue)
    }
}
