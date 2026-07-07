import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct EventsCommandRunner {
    let stateDatabasePath: String
    let projectName: String?
    let output: CLIOutputFormat

    func run() -> CLIRunResult {
        do {
            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()
            let store = SQLiteStateStore(configuration: configuration)
            let projectID = projectName.map { "project-\($0)" }
            let events = try store.events.loadAll()
                .filter { event in projectID == nil || event.projectID == projectID }
                .map { $0.redacted() }

            if output == .json {
                return CLIRunResult(standardOutput: CLIJSON.events(stateDatabasePath: stateDatabasePath, projectName: projectName, events: events))
            }

            var lines = [
                "Hostwright events",
                "State DB: \(stateDatabasePath)"
            ]
            if let projectName {
                lines.append("Project: \(projectName)")
            }
            lines.append("")

            if events.isEmpty {
                lines.append("- none")
            } else {
                lines += events.map { event in
                    "- \(event.timestamp) [\(event.severity.rawValue)] \(event.type) \(event.serviceName ?? "project"): \(RuntimeRedactionPolicy.default.redact(event.message))"
                }
            }
            lines.append("")
            return CLIRunResult(standardOutput: lines.joined(separator: "\n"))
        } catch {
            let exitCode = CLIExitCode.stateUnavailable
            let message = RuntimeRedactionPolicy.default.redact(String(describing: error))
            if output == .json {
                return CLIRunResult(standardError: CLIJSON.error(code: .stateStoreUnavailable, message: message, exitCode: exitCode), exitCode: exitCode.rawValue)
            }
            return CLIRunResult(standardError: "\(HostwrightErrorCode.stateStoreUnavailable.rawValue): \(message)\n", exitCode: exitCode.rawValue)
        }
    }
}
