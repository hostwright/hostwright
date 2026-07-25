import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct EventsCommandRunner {
    let stateStoreConfiguration: StateStoreConfiguration
    let projectName: String?
    let filters: EventFilters
    let output: CLIOutputFormat

    func run() -> CLIRunResult {
        do {
            let stateDatabasePath = stateStoreConfiguration.databasePath
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            let projectID = projectName.map { "project-\($0)" }
            var events = try store.events.loadAll()
                .filter { event in
                    guard let projectID else { return true }
                    if event.projectID == projectID { return true }
                    guard event.projectID == nil,
                          event.type.hasPrefix("image.trust."),
                          let data = event.payloadJSONRedacted.data(
                              using: .utf8
                          ),
                          let object = try? JSONSerialization.jsonObject(
                              with: data
                          ) as? [String: Any] else {
                        return false
                    }
                    return object["projectID"] as? String == projectID
                }
                .filter { event in filters.type == nil || event.type == filters.type }
                .filter { event in filters.serviceName == nil || event.serviceName == filters.serviceName }
                .filter { event in filters.severity == nil || event.severity == filters.severity }
                .map { $0.redacted() }

            if filters.sort == .descending {
                events.reverse()
            }
            if let limit = filters.limit, events.count > limit {
                events = Array(events.prefix(limit))
            }

            if output == .json {
                return CLIRunResult(standardOutput: CLIJSON.events(stateDatabasePath: stateDatabasePath, projectName: projectName, filters: filters, events: events))
            }

            var lines = [
                "Hostwright events",
                "State DB: \(stateDatabasePath)"
            ]
            if let projectName {
                lines.append("Project: \(projectName)")
            }
            if filters != EventFilters() {
                lines.append("Sort: \(filters.sort.rawValue)")
                if let type = filters.type {
                    lines.append("Type: \(type)")
                }
                if let serviceName = filters.serviceName {
                    lines.append("Service: \(serviceName)")
                }
                if let severity = filters.severity {
                    lines.append("Severity: \(severity.rawValue)")
                }
                if let limit = filters.limit {
                    lines.append("Limit: \(limit)")
                }
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
