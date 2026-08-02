import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct RestartBudgetCommandRunner {
    let options: RestartBudgetCLIOptions
    let stateStoreConfiguration: StateStoreConfiguration

    func run() throws -> CLIRunResult {
        let store = SQLiteStateStore(configuration: stateStoreConfiguration)
        switch options.action {
        case .status(let projectID):
            let states = try projectID.map {
                try store.restartPolicies.loadProject(projectID: $0)
            } ?? store.restartPolicies.loadAll()
            let projectUsage = try projectUsage(states: states, store: store)
            return CLIRunResult(
                standardOutput: options.output == .json
                    ? try renderJSON(states: states, released: nil, projectUsage: projectUsage)
                    : renderText(states: states, released: nil, projectUsage: projectUsage)
            )
        case .release(let projectID, let serviceName, let holdToken):
            let timestamp = ISO8601DateFormatter().string(from: Date())
            guard let released = try store.restartPolicies.releaseHold(
                projectID: projectID,
                serviceName: serviceName,
                expectedHoldToken: holdToken,
                timestamp: timestamp,
                historyID: UUID().uuidString.lowercased(),
                eventID: UUID().uuidString.lowercased()
            ) else {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "The restart hold token, workload identity, or current held generation no longer matches. Nothing was released."
                )
            }
            let projectUsage = try projectUsage(states: [released], store: store)
            return CLIRunResult(
                standardOutput: options.output == .json
                    ? try renderJSON(states: [released], released: released, projectUsage: projectUsage)
                    : renderText(states: [released], released: released, projectUsage: projectUsage)
            )
        }
    }

    private func projectUsage(
        states: [RestartPolicyStateRecord],
        store: SQLiteStateStore
    ) throws -> [String: Int] {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        var usage: [String: Int] = [:]
        for state in states where usage[state.projectID] == nil {
            let since = formatter.string(
                from: now.addingTimeInterval(-TimeInterval(state.projectWindowSeconds))
            )
            usage[state.projectID] = try store.restartAttempts.admittedCount(
                projectID: state.projectID,
                since: since
            )
        }
        return usage
    }

    private func renderText(
        states: [RestartPolicyStateRecord],
        released: RestartPolicyStateRecord?,
        projectUsage: [String: Int]
    ) -> String {
        var lines = [
            released == nil ? "Hostwright restart budgets" : "Hostwright restart hold released",
            "State DB: \(stateStoreConfiguration.databasePath)",
            ""
        ]
        if states.isEmpty {
            lines.append("- none")
        } else {
            lines += states.map { state in
                let hold = state.holdToken.map { " hold=\($0)" } ?? ""
                return "- \(state.projectID)/\(state.serviceName): \(state.status.rawValue) attempts=\(state.attemptCount)/\(state.maxAttempts) projectAttempts=\(projectUsage[state.projectID] ?? 0)/\(state.projectMaxAttempts) projectWindow=\(state.projectWindowSeconds)s releaseGeneration=\(state.releaseGeneration)\(hold)"
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func renderJSON(
        states: [RestartPolicyStateRecord],
        released: RestartPolicyStateRecord?,
        projectUsage: [String: Int]
    ) throws -> String {
        let records: [[String: Any]] = states.map { state in
            var value: [String: Any] = [
                "attemptCount": state.attemptCount,
                "backoffSeconds": state.backoffSeconds,
                "maxAttempts": state.maxAttempts,
                "policySHA256": state.policySHA256,
                "priority": state.priority,
                "projectID": state.projectID,
                "projectAttemptCount": projectUsage[state.projectID] ?? 0,
                "projectMaxAttempts": state.projectMaxAttempts,
                "projectWindowSeconds": state.projectWindowSeconds,
                "reasonClass": state.reasonClass.rawValue,
                "releaseGeneration": state.releaseGeneration,
                "serviceName": state.serviceName,
                "status": state.status.rawValue,
                "windowSeconds": state.windowSeconds
            ]
            if let holdToken = state.holdToken { value["holdToken"] = holdToken }
            if let backoffUntil = state.backoffUntil { value["backoffUntil"] = backoffUntil }
            return value
        }
        let object: [String: Any] = [
            "schemaVersion": 1,
            "stateDatabasePath": stateStoreConfiguration.databasePath,
            "released": released != nil,
            "restartBudgets": records
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostwrightDiagnostic(code: .fileIOFailed, message: "Restart budget JSON encoding failed.")
        }
        return text + "\n"
    }
}
