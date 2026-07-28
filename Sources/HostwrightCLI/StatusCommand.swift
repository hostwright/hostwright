import HostwrightCore
import HostwrightManifest
import HostwrightNetworking
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct StatusCommandRunner {
    let manifestPath: String
    let stateStoreConfiguration: StateStoreConfiguration
    let output: CLIOutputFormat
    let runtimeProvider: RuntimeProviderSelection
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        guard environment.fileExists(manifestPath) else {
            return failure(
                code: .manifestFileIOFailed,
                message: "Manifest file at \(RuntimeRedactionPolicy.default.redact(manifestPath)) does not exist."
            )
        }

        do {
            let manifestText = try hostwrightReadManifestText(path: manifestPath, environment: environment)
            let manifest = try ManifestValidator.validated(manifestText)
            let stateDatabasePath = stateStoreConfiguration.databasePath
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            try store.migrate()

            let mapping = ManifestRuntimeMapper.map(manifest)
            let projectName = mapping.desiredState.projectName
            let projectID = "project-\(projectName)"
            let selectedProvider = try hostwrightSelectRuntimeProvider(
                requested: runtimeProvider,
                store: store,
                projectID: projectID,
                requiredFeatures: [.observation],
                environment: environment
            )
            let observationDesiredState = try hostwrightDesiredStateWithOwnershipHints(
                mapping.desiredState,
                store: store,
                projectID: projectID,
                providerID: selectedProvider.selection.providerID
            )
            let adapter = selectedProvider.adapter
            let observed = try hostwrightWaitForAsync {
                try await adapter.observe(desiredState: observationDesiredState)
            }
            guard observed.adapterMetadata?.providerID == selectedProvider.selection.providerID,
                  observed.capabilitySHA256 == selectedProvider.selection.capabilitySHA256 else {
                throw RuntimeProviderSelectionError.staleCapability(
                    expectedSHA256: selectedProvider.selection.capabilitySHA256,
                    currentSHA256: observed.capabilitySHA256 ?? "missing"
                )
            }
            let timestamp = hostwrightTimestamp()
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
            let imageDigestLocks = try store.imageDigestLocks.loadCurrent(
                projectID: projectID
            )

            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: manifestPath,
                manifestHash: hostwrightStableHash(manifestText),
                desiredGeneration: 1,
                manifest: manifest,
                timestamp: timestamp
            )
            let project = try store.desiredStates.loadProject(id: projectID)
            let portReservations = try store.networkPorts.loadProject(
                projectUUID: project.resourceUUID
            )
            let networks = try store.networks.listNetworks(
                projectUUID: project.resourceUUID
            )
            let projectDNS = try store.projectDNS.load(
                id: HostwrightResourceUUID.legacy(
                    kind: "project-dns",
                    identifier: project.resourceUUID
                )
            )
            try store.observedStates.saveSnapshot(
                snapshotID: hostwrightUniqueID(prefix: "status-snapshot"),
                projectID: projectID,
                observedState: observedForPlanning,
                runtimeAdapter: selectedProvider.selection.providerID.rawValue,
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
                    runtimeAdapter: selectedProvider.selection.providerID.rawValue,
                    message: "Status observed \(observed.services.count) runtime service(s).",
                    payloadJSONRedacted: CLIJSON.codable([
                        "capabilitySHA256": plan.capabilitySHA256 ?? "unbound",
                        "planHash": plan.planHash
                    ])
                )
            ])

            if output == .json {
                return CLIRunResult(
                    standardOutput: CLIJSON.statusObserved(
                        manifestPath: manifestPath,
                        stateDatabasePath: stateDatabasePath,
                        manifest: manifest,
                        observed: observedForPlanning,
                        plan: plan,
                        imageDigestLocks: imageDigestLocks,
                        portReservations: portReservations,
                        networks: networks,
                        projectDNS: projectDNS
                    )
                )
            }
            return CLIRunResult(
                standardOutput: render(
                    manifest: manifest,
                    observed: observedForPlanning,
                    plan: plan,
                    imageDigestLocks: imageDigestLocks,
                    portReservations: portReservations,
                    networks: networks,
                    projectDNS: projectDNS,
                    stateDatabasePath: stateDatabasePath
                )
            )
        } catch let error as HostwrightDiagnostic {
            return failure(code: error.code, message: error.message)
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

    private func render(
        manifest: HostwrightManifest,
        observed: ObservedRuntimeState,
        plan: ReconciliationPlan,
        imageDigestLocks: [ImageDigestLockRecord],
        portReservations: [NetworkPortReservationRecord],
        networks: [NetworkStateResourceRecord],
        projectDNS: ProjectDNSStateRecord?,
        stateDatabasePath: String
    ) -> String {
        let observedByName = hostwrightObservedServicesByLogicalName(observed)
        var lines = [
            "Hostwright status",
            "Manifest: \(manifestPath) valid",
            "Project: \(manifest.project ?? "<missing>")",
            "State DB: \(stateDatabasePath)",
            "Runtime: observed through \(observed.adapterMetadata?.adapterName ?? "runtime-adapter")",
            "Runtime parser: status-observation-v1",
            "Capability digest: \(plan.capabilitySHA256 ?? "unbound")",
            "Telemetry: local-only; no upload",
            "Plan hash: \(plan.planHash)",
            ""
        ]

        lines.append("Services:")
        for service in manifest.services.sorted(by: { $0.name < $1.name }) {
            if let observedServices = observedByName[service.name],
               !observedServices.isEmpty {
                for observed in observedServices {
                    let ports = observed.ports.map { port in
                        "\((port.bindAddress ?? "localhost")):\(port.hostPort.map(String.init) ?? "?")->\(port.containerPort)/\(port.protocolName.rawValue)"
                    }.joined(separator: ", ")
                    let sockets = observed.publishedSockets.sorted {
                        ($0.hostPath, $0.containerPath, $0.mode.rawValue) <
                            ($1.hostPath, $1.containerPath, $1.mode.rawValue)
                    }.map {
                        "\($0.hostPath)->\($0.containerPath)/\($0.mode.rawValue)"
                    }.joined(separator: ", ")
                    let instance = observed.identity.instanceName.map { "[\($0)]" } ?? ""
                    lines.append("- \(service.name)\(instance): id=\(observed.resourceIdentifier) desired image=\(service.image ?? "<missing>") observed image=\(observed.image ?? "<unknown>") lifecycle=\(observed.lifecycleState.rawValue) health=\(observed.healthState.rawValue) ports=\(ports.isEmpty ? "none" : ports) sockets=\(sockets.isEmpty ? "none" : sockets)")
                }
            } else {
                lines.append("- \(service.name): desired image=\(service.image ?? "<missing>") observed=missing")
            }
        }

        lines.append("")
        lines.append("Image digest locks:")
        if imageDigestLocks.isEmpty {
            lines.append("- none")
        } else {
            lines += imageDigestLocks.map { record in
                "- \(record.serviceName)[\(record.replicaIndex)] \(record.stateKind.rawValue): requested=\(record.lock.requestedReference) resolved=\(record.lock.resolvedReference) variant=\(record.lock.variantDigest) provider=\(record.lock.providerID.rawValue) plan=\(record.planSHA256)"
            }
        }

        lines.append("")
        lines.append("Port reservations:")
        if portReservations.isEmpty {
            lines.append("- none")
        } else {
            lines += portReservations.map { record in
                "- \(record.serviceName): \(record.bindAddress):\(record.hostPort)->\(record.containerPort)/\(record.protocolName.rawValue) allocation=\(record.allocationKind.rawValue) state=\(record.lifecycleState.rawValue)"
            }
        }

        lines.append("")
        lines.append("Networks:")
        if networks.isEmpty {
            lines.append("- none")
        } else {
            lines += networks.sorted {
                ($0.name, $0.id) < ($1.name, $1.id)
            }.map { record in
                "- \(record.name): driver=\(record.driver.rawValue) ipv4=\(render(record.requestedIPv4)) observedIPv4=\(record.observedIPv4.joined(separator: ",")) ipv6=\(render(record.requestedIPv6)) observedIPv6=\(record.observedIPv6.joined(separator: ",")) state=\(record.lifecycleState.rawValue)"
            }
        }

        lines.append("")
        lines.append("Ingress:")
        if manifest.ingress.isEmpty {
            lines.append("- none")
        } else {
            for (name, listener) in manifest.ingress.sorted(
                by: { $0.key < $1.key }
            ) {
                lines.append(
                    "- \(name): \(listener.bindAddress):\(listener.port) exposure=\(listener.exposure.scope.rawValue)"
                )
                for route in listener.routes.sorted(
                    by: HostwrightIngressRoute.canonicalPrecedes
                ) {
                    let ready = readyBackendCount(
                        serviceName: route.targetService,
                        manifest: manifest,
                        observedByName: observedByName
                    )
                    lines.append(
                        "  - \(route.protocolName.rawValue) \(route.hostname)\(route.pathPrefix) methods=\(route.methods.sorted().joined(separator: ",")) target=\(route.targetService):\(route.targetPort) readyBackends=\(ready)"
                    )
                }
            }
        }
        if !manifest.ingress.isEmpty, let projectDNS {
            lines.append(
                "- state: generation=\(projectDNS.generation) lifecycle=\(projectDNS.lifecycleState.rawValue) finalizer=\(projectDNS.finalizerState.rawValue) desired=\(projectDNS.desiredSHA256) observed=\(projectDNS.observedSHA256 ?? "missing")"
            )
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

    private func readyBackendCount(
        serviceName: String,
        manifest: HostwrightManifest,
        observedByName: [String: [ObservedRuntimeService]]
    ) -> Int {
        let readinessConfigured = manifest.services.first {
            $0.name == serviceName
        }?.probes.readiness != nil
        return (observedByName[serviceName] ?? []).filter {
            $0.healthState == .healthy ||
                (
                    !readinessConfigured &&
                        $0.lifecycleState == .running &&
                        (
                            $0.healthState == .notConfigured ||
                                $0.healthState == .unknown
                        )
                )
        }.count
    }

    private func render(
        _ request: NetworkStateAddressRequest
    ) -> String {
        switch request {
        case .auto:
            return "auto"
        case .disabled:
            return "disabled"
        case .cidr(let value):
            return value
        }
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let exitCode = CLIExitCode.mapped(from: code)
        if output == .json {
            return CLIRunResult(standardError: CLIJSON.error(code: code, message: message, exitCode: exitCode), exitCode: exitCode.rawValue)
        }
        return CLIRunResult(standardError: "\(code.rawValue): \(message)\n", exitCode: exitCode.rawValue)
    }
}
