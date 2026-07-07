import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct StatusCommandRunner {
    let manifestPath: String
    let stateDatabasePath: String?
    let output: CLIOutputFormat
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        guard environment.fileExists(manifestPath) else {
            if output == .json {
                return CLIRunResult(standardOutput: CLIJSON.statusManifestMissing(manifestPath: manifestPath))
            }
            return CLIRunResult(
                standardOutput: """
                Hostwright status
                Manifest: \(manifestPath) not found
                Runtime: not observed

                """
            )
        }

        do {
            let manifestText = try environment.readTextFile(manifestPath)
            let manifest = try ManifestValidator.validated(manifestText)
            guard let stateDatabasePath else {
                return manifestOnlyStatus(manifest)
            }

            let configuration = StateStoreConfiguration(explicitDatabasePath: stateDatabasePath)
            try configuration.validate()
            let store = SQLiteStateStore(configuration: configuration)
            try store.migrate()

            let mapping = ManifestRuntimeMapper.map(manifest)
            let adapter = environment.runtimeAdapter()
            let observed = try hostwrightWaitForAsync {
                try await adapter.observe(desiredState: mapping.desiredState)
            }
            let timestamp = hostwrightTimestamp()
            let projectName = mapping.desiredState.projectName
            let projectID = "project-\(projectName)"
            let restartPolicyStates = try hostwrightRestartPolicyStateMap(store: store, projectID: projectID, projectName: projectName)
            let observedForPlanning = try hostwrightPlanningObservedState(
                observed: observed,
                desiredState: mapping.desiredState,
                store: store,
                projectID: projectID,
                currentTimestamp: timestamp
            )
            let plan = ReconciliationPlanner().plan(
                manifest: manifest,
                observedState: observedForPlanning,
                restartPolicyStates: restartPolicyStates,
                currentTimestamp: timestamp
            )

            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: manifestPath,
                manifestHash: hostwrightStableHash(manifestText),
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: timestamp
            )
            try store.observedStates.saveSnapshot(
                snapshotID: hostwrightUniqueID(prefix: "status-snapshot"),
                projectID: projectID,
                observedState: observedForPlanning,
                runtimeAdapter: observed.adapterMetadata?.adapterName ?? "runtime-adapter",
                parserVersion: "status-observation-v1",
                rawOutputHash: nil,
                redactedSummary: PlanRenderer.render(plan, mode: .compact),
                observedAt: timestamp
            )
            try store.events.append([
                EventRecord(
                    id: hostwrightUniqueID(prefix: "event-status"),
                    timestamp: timestamp,
                    severity: .info,
                    type: "status.observed",
                    source: "hostwright-cli",
                    projectID: projectID,
                    serviceName: nil,
                    runtimeAdapter: observed.adapterMetadata?.adapterName,
                    message: "Status observed \(observed.services.count) runtime service(s).",
                    payloadJSONRedacted: #"{"planHash":"\#(plan.planHash)"}"#
                )
            ])

            if output == .json {
                return CLIRunResult(
                    standardOutput: CLIJSON.statusObserved(
                        manifestPath: manifestPath,
                        stateDatabasePath: stateDatabasePath,
                        manifest: manifest,
                        observed: observedForPlanning,
                        plan: plan
                    )
                )
            }
            return CLIRunResult(standardOutput: render(manifest: manifest, observed: observedForPlanning, plan: plan, stateDatabasePath: stateDatabasePath))
        } catch let error as ManifestParseError {
            if output == .json {
                return CLIRunResult(standardError: CLIJSON.manifestError(issues: error.issues, exitCode: .validation), exitCode: CLIExitCode.validation.rawValue)
            }
            return CLIRunResult(standardError: error.issues.map(\.rendered).joined(separator: "\n") + "\n", exitCode: CLIExitCode.validation.rawValue)
        } catch let error as StateStoreError {
            return failure(code: .stateStoreUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        } catch {
            return failure(code: .runtimeUnavailable, message: RuntimeRedactionPolicy.default.redact(String(describing: error)))
        }
    }

    private func manifestOnlyStatus(_ manifest: HostwrightManifest) -> CLIRunResult {
        if output == .json {
            return CLIRunResult(standardOutput: CLIJSON.statusManifestOnly(manifestPath: manifestPath, manifest: manifest))
        }
        return CLIRunResult(
            standardOutput: """
            Hostwright status
            Manifest: \(manifestPath) valid
            Project: \(manifest.project ?? "<missing>")
            Declared services: \(manifest.services.map(\.name).joined(separator: ", "))
            Runtime: not observed; pass --state-db <path> to record live status.

            """
        )
    }

    private func render(manifest: HostwrightManifest, observed: ObservedRuntimeState, plan: ReconciliationPlan, stateDatabasePath: String) -> String {
        let observedByName = Dictionary(uniqueKeysWithValues: observed.services.map { ($0.identity.serviceName, $0) })
        var lines = [
            "Hostwright status",
            "Manifest: \(manifestPath) valid",
            "Project: \(manifest.project ?? "<missing>")",
            "State DB: \(stateDatabasePath)",
            "Runtime: observed through \(observed.adapterMetadata?.adapterName ?? "runtime-adapter")",
            "Plan hash: \(plan.planHash)",
            ""
        ]

        lines.append("Services:")
        for service in manifest.services.sorted(by: { $0.name < $1.name }) {
            if let observed = observedByName[service.name] {
                let ports = observed.ports.map { port in
                    "\((port.bindAddress ?? "localhost")):\(port.hostPort.map(String.init) ?? "?")->\(port.containerPort)/\(port.protocolName.rawValue)"
                }.joined(separator: ", ")
                lines.append("- \(service.name): desired image=\(service.image ?? "<missing>") observed image=\(observed.image ?? "<unknown>") lifecycle=\(observed.lifecycleState.rawValue) health=\(observed.healthState.rawValue) ports=\(ports.isEmpty ? "none" : ports)")
            } else {
                lines.append("- \(service.name): desired image=\(service.image ?? "<missing>") observed=missing")
            }
        }

        lines.append("")
        lines.append("Drift:")
        if plan.drift.isEmpty {
            lines.append("- none")
        } else {
            lines += plan.drift.map { drift in
                "- [\(drift.severity.rawValue)] \(drift.kind.rawValue): \(drift.identity?.displayName ?? "project") - \(drift.reason)"
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        if output == .json {
            return CLIRunResult(standardError: CLIJSON.error(code: code, message: message, exitCode: exitCode), exitCode: exitCode.rawValue)
        }
        return CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: exitCode.rawValue)
    }
}
