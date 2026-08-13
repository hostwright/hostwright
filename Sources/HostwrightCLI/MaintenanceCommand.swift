import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightState

struct MaintenanceCommandRunner {
    let options: MaintenanceCLIOptions
    let stateStoreConfiguration: StateStoreConfiguration
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        switch options.action {
        case .preview(let manifestPath, let rawActions, let at):
            let text = try environment.readTextFile(manifestPath)
            let manifest = try ManifestValidator.validated(text)
            let actions = rawActions.compactMap(HostwrightMaintenanceActionClass.init(rawValue:))
            let instant = try at.map { value -> Date in
                guard let date = ISO8601DateFormatter().date(from: value) else {
                    throw HostwrightDiagnostic(code: .commandUsage, message: "Maintenance preview timestamp is invalid.")
                }
                return date
            } ?? Date()
            let decision = MaintenanceWindowEvaluator.evaluate(
                policy: manifest.maintenance,
                actions: actions,
                now: instant
            )
            if options.output == .json {
                return CLIRunResult(standardOutput: try json(PreviewEnvelope(
                    schemaVersion: 1,
                    manifestPath: URL(fileURLWithPath: manifestPath).standardizedFileURL.path,
                    evaluatedAt: ISO8601DateFormatter().string(from: instant),
                    decision: decision
                )))
            }
            return CLIRunResult(standardOutput: renderPreview(decision, at: instant))

        case .status(let projectID):
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            let records: [MaintenanceDeferralRecord]
            if let projectID {
                records = try store.maintenanceDeferrals.latest(projectID: projectID).map { [$0] } ?? []
            } else {
                let history = try store.maintenanceDeferrals.history()
                records = Dictionary(grouping: history, by: \.projectID)
                    .values.compactMap(\.last)
                    .sorted { $0.projectID < $1.projectID }
            }
            return try renderRecords(records, heading: "Hostwright maintenance deferrals")

        case .cancel(let projectID, let confirmationToken):
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            guard let record = try store.maintenanceDeferrals.cancel(
                projectID: projectID,
                expectedConfirmationToken: confirmationToken,
                updatedAt: timestamp()
            ) else {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "The maintenance deferral token, project, or current pending state no longer matches. Nothing was cancelled."
                )
            }
            return try renderRecords([record], heading: "Hostwright maintenance deferral cancelled")

        case .override(let projectID, let confirmationToken, let reason):
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            guard let record = try store.maintenanceDeferrals.authorizeOverride(
                projectID: projectID,
                expectedConfirmationToken: confirmationToken,
                reasonRedacted: reason,
                updatedAt: timestamp()
            ) else {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "The maintenance deferral token, project, or current pending state no longer matches. No override was authorized."
                )
            }
            return try renderRecords([record], heading: "Hostwright emergency maintenance override authorized")
        }
    }

    private func renderPreview(
        _ decision: MaintenanceAdmissionDecision,
        at: Date
    ) -> String {
        var lines = [
            "Hostwright maintenance preview",
            "Evaluated: \(ISO8601DateFormatter().string(from: at))",
            "Decision: \(decision.admitted ? "admitted" : "deferred") (\(decision.reason.rawValue))",
            "Actions: \(decision.actionClasses.map(\.rawValue).joined(separator: ", "))",
            "Policy SHA-256: \(decision.policySHA256)"
        ]
        if let active = decision.activeWindow {
            lines.append("Active window: \(active.windowID) \(active.startsAt)...\(active.endsAt)")
        }
        if let next = decision.nextWindow {
            lines.append("Next window: \(next.windowID) \(next.startsAt)...\(next.endsAt)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func renderRecords(
        _ records: [MaintenanceDeferralRecord],
        heading: String
    ) throws -> CLIRunResult {
        if options.output == .json {
            return CLIRunResult(standardOutput: try json(StatusEnvelope(
                schemaVersion: 1,
                stateDatabasePath: stateStoreConfiguration.databasePath,
                maintenanceDeferrals: records
            )))
        }
        var lines = [heading, "State DB: \(stateStoreConfiguration.databasePath)", ""]
        if records.isEmpty {
            lines.append("- none")
        } else {
            lines += records.map { record in
                "- \(record.projectID): \(record.state.rawValue) actions=\(record.actionClasses.map(\.rawValue).joined(separator: ",")) plan=\(record.planSHA256) deadline=\(record.deadlineAt) token=\(record.confirmationToken)"
            }
        }
        lines.append("")
        return CLIRunResult(standardOutput: lines.joined(separator: "\n"))
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostwrightDiagnostic(code: .fileIOFailed, message: "Maintenance JSON encoding failed.")
        }
        return text + "\n"
    }
}

private struct PreviewEnvelope: Encodable {
    let schemaVersion: Int
    let manifestPath: String
    let evaluatedAt: String
    let decision: MaintenanceAdmissionDecision
}

private struct StatusEnvelope: Encodable {
    let schemaVersion: Int
    let stateDatabasePath: String
    let maintenanceDeferrals: [MaintenanceDeferralRecord]
}
