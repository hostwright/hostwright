import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct EventsCommandRunner {
    let stateDatabasePath: String
    let projectName: String?

    func run() -> CLIRunResult {
        do {
            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()
            let store = SQLiteStateStore(configuration: configuration)
            try store.migrate()
            let projectID = projectName.map { "project-\($0)" }
            let events = try store.events.loadAll()
                .filter { event in projectID == nil || event.projectID == projectID }
                .map { $0.redacted() }

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
            return CLIRunResult(standardError: "\(HostwrightErrorCode.stateStoreUnavailable.rawValue): \(RuntimeRedactionPolicy.default.redact(String(describing: error)))\n", exitCode: 1)
        }
    }
}
