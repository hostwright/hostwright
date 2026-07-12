import Foundation
import HostwrightCore
import HostwrightHealth
import HostwrightImport
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

func hostwrightWaitForAsync<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = CLIAsyncResultBox<T>()

    Task.detached {
        do {
            box.result = Result.success(try await operation())
        } catch {
            box.result = Result.failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()
    return try box.result!.get()
}

final class CLIAsyncResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

func hostwrightStableHash(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

func hostwrightTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func hostwrightTimestampAdding(seconds: Int, to timestamp: String) -> String {
    let formatter = ISO8601DateFormatter()
    let date = formatter.date(from: timestamp) ?? Date()
    return formatter.string(from: date.addingTimeInterval(TimeInterval(seconds)))
}

func hostwrightUniqueID(prefix: String) -> String {
    "\(prefix)-\(UUID().uuidString)"
}

func hostwrightRestartPolicyStateMap(
    store: SQLiteStateStore,
    projectID: String,
    projectName: String
) throws -> [RuntimeServiceIdentity: RestartPolicyStateRecord] {
    let states = try store.restartPolicies.loadProject(projectID: projectID)
    return Dictionary(states.map { state in
        (
            RuntimeServiceIdentity(projectName: projectName, serviceName: state.serviceName),
            state
        )
    }, uniquingKeysWith: { first, _ in first })
}

func hostwrightDesiredStateWithOwnershipHints(
    _ desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    projectID: String
) throws -> DesiredRuntimeState {
    DesiredRuntimeState(
        projectName: desiredState.projectName,
        services: desiredState.services,
        ownedResourceHints: try store.ownership.runtimeHints(
            projectID: projectID,
            projectName: desiredState.projectName
        )
    )
}

func hostwrightPlanningObservedState(
    observed: ObservedRuntimeState,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    projectID: String,
    currentTimestamp: String
) throws -> ObservedRuntimeState {
    let desiredByIdentity = Dictionary(uniqueKeysWithValues: desiredState.services.map { ($0.identity, $0) })
    let services = try observed.services.map { service in
        guard let desired = desiredByIdentity[service.identity] else {
            return service
        }
        guard let healthCheck = desired.healthCheck else {
            return service.healthState == .unhealthy ? service.withHealthState(.unknown) : service
        }

        if let latest = try hostwrightFreshHealthResult(
            store: store,
            projectID: projectID,
            serviceName: service.identity.serviceName,
            healthCheck: healthCheck,
            currentTimestamp: currentTimestamp
        ) {
            return service.withHealthState(hostwrightRuntimeHealthState(from: latest.status, fallback: service.healthState))
        }

        guard service.healthState == .unhealthy else {
            return service
        }
        return service.withHealthState(.unknown)
    }

    return ObservedRuntimeState(
        projectName: observed.projectName,
        services: services,
        adapterMetadata: observed.adapterMetadata
    )
}

func hostwrightFreshHealthResult(
    store: SQLiteStateStore,
    projectID: String,
    serviceName: String,
    healthCheck: RuntimeHealthCheckSpec,
    currentTimestamp: String
) throws -> HealthCheckResultRecord? {
    guard let latest = try store.healthResults.latest(projectID: projectID, serviceName: serviceName),
          hostwrightIsFreshHealthResult(latest, intervalSeconds: healthCheck.intervalSeconds, currentTimestamp: currentTimestamp) else {
        return nil
    }
    return latest
}

private func hostwrightRuntimeHealthState(
    from status: RuntimeHealthCheckStatus,
    fallback: RuntimeHealthState
) -> RuntimeHealthState {
    switch status {
    case .healthy:
        return .healthy
    case .unhealthy:
        return .unhealthy
    case .unknown:
        return .unknown
    case .skipped, .notConfigured:
        return fallback
    }
}

private func hostwrightIsFreshHealthResult(
    _ result: HealthCheckResultRecord,
    intervalSeconds: Int,
    currentTimestamp: String
) -> Bool {
    let formatter = ISO8601DateFormatter()
    guard let checkedAt = formatter.date(from: result.checkedAt),
          let current = formatter.date(from: currentTimestamp),
          checkedAt <= current else {
        return false
    }
    return checkedAt.addingTimeInterval(TimeInterval(intervalSeconds)) >= current
}

private extension ObservedRuntimeService {
    func withHealthState(_ healthState: RuntimeHealthState) -> ObservedRuntimeService {
        ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: resourceIdentifier,
            image: image,
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: ports,
            networks: networks,
            mounts: mounts,
            observedAt: observedAt
        )
    }
}

enum CLIJSON {
    static func render(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }

    static func error(code: HostwrightErrorCode, message: String, exitCode: CLIExitCode) -> String {
        render([
            "kind": "error",
            "code": code.rawValue,
            "exitCode": Int(exitCode.rawValue),
            "message": RuntimeRedactionPolicy.default.redact(message)
        ])
    }

    static func manifestError(issues: [ManifestIssue], exitCode: CLIExitCode) -> String {
        render([
            "kind": "error",
            "code": (issues.first?.code ?? .manifestValidationFailed).rawValue,
            "exitCode": Int(exitCode.rawValue),
            "issues": issues.map { issue in
                [
                    "code": issue.code.rawValue,
                    "message": RuntimeRedactionPolicy.default.redact(issue.message),
                    "line": issue.line as Any
                ].compactNilValues()
            }
        ])
    }

    static func stackImport(path: String, result: StackImportResult) -> String {
        render([
            "kind": "stackImport",
            "sourcePath": path,
            "succeeded": result.succeeded,
            "manifest": result.manifestText as Any,
            "warnings": result.warnings.map(stackImportDiagnostic)
        ])
    }

    static func stackImportError(path: String, result: StackImportResult, exitCode: CLIExitCode) -> String {
        render([
            "kind": "error",
            "code": (result.errors.first?.code ?? .manifestUnsupportedFeature).rawValue,
            "exitCode": Int(exitCode.rawValue),
            "sourcePath": path,
            "issues": result.errors.map(stackImportDiagnostic)
        ])
    }

    static func plan(_ plan: ReconciliationPlan) -> String {
        render([
            "kind": "plan",
            "project": plan.projectName,
            "planHash": plan.planHash,
            "observationConnected": plan.observationConnected,
            "mutatesRuntime": plan.mutatesRuntime,
            "execution": "unavailable unless one createMissingService, startManagedService, or restartManagedService action is explicitly confirmed",
            "issues": plan.issues.map { issue in
                [
                    "kind": issue.kind.rawValue,
                    "severity": issue.severity.rawValue,
                    "identity": issue.identity?.displayName as Any,
                    "message": RuntimeRedactionPolicy.default.redact(issue.message)
                ].compactNilValues()
            },
            "drift": plan.drift.map { drift in
                [
                    "kind": drift.kind.rawValue,
                    "severity": drift.severity.rawValue,
                    "identity": drift.identity?.displayName as Any,
                    "reason": RuntimeRedactionPolicy.default.redact(drift.reason)
                ].compactNilValues()
            },
            "actions": plan.actions.map { action in
                [
                    "kind": action.kind.rawValue,
                    "identity": action.identity.displayName,
                    "resourceIdentifier": action.resourceIdentifier,
                    "reason": RuntimeRedactionPolicy.default.redact(action.reason),
                    "executionAvailability": action.executionAvailability.rawValue
                ]
            }
        ])
    }

    private static func stackImportDiagnostic(_ diagnostic: StackImportDiagnostic) -> [String: Any] {
        [
            "code": diagnostic.code.rawValue,
            "severity": diagnostic.severity.rawValue,
            "message": RuntimeRedactionPolicy.default.redact(diagnostic.message),
            "line": diagnostic.line as Any,
            "policyReasonCode": diagnostic.policyReasonCode as Any
        ].compactNilValues()
    }

    static func doctor(_ report: DoctorReport) -> String {
        var object: [String: Any] = [
            "kind": "doctor",
            "hasFailures": report.hasFailures,
            "checks": report.checks.map { check in
                [
                    "identifier": check.identifier.rawValue,
                    "status": check.status.rawValue,
                    "message": RuntimeRedactionPolicy.default.redact(check.message)
                ]
            }
        ]
        if let resourceReport = report.resourceReport {
            object["resourceReport"] = Self.resourceReport(resourceReport)
        }
        return render(object)
    }

    private static func resourceReport(_ report: ResourceIntelligenceReport) -> [String: Any] {
        [
            "measurementMethod": report.measurementMethod.rawValue,
            "hardware": [
                "architecture": report.hardware.architecture,
                "activeProcessorCount": report.hardware.activeProcessorCount as Any,
                "physicalMemoryBytes": report.hardware.physicalMemoryBytes as Any,
                "unifiedMemoryNote": report.hardware.unifiedMemoryNote
            ].compactNilValues(),
            "operatingSystem": [
                "description": report.operatingSystem.description,
                "macOSMajorVersion": report.operatingSystem.macOSMajorVersion
            ],
            "appleContainer": [
                "executablePath": report.appleContainer.executablePath as Any,
                "version": report.appleContainer.version as Any,
                "versionObservation": resourceObservation(report.appleContainer.versionObservation)
            ].compactNilValues(),
            "workloadProfile": [
                "identifier": report.workloadProfile.identifier,
                "name": report.workloadProfile.name,
                "notes": report.workloadProfile.notes
            ],
            "memoryPressure": resourceObservation(report.memoryPressure),
            "bootLatency": resourceObservation(report.bootLatency),
            "pollingOverhead": resourceObservation(report.pollingOverhead),
            "sleepWake": resourceObservation(report.sleepWake),
            "battery": resourceObservation(report.battery),
            "thermal": resourceObservation(report.thermal),
            "architectureWarnings": report.architectureWarnings.map { warning in
                [
                    "imageReference": warning.imageReference,
                    "reportedArchitecture": warning.reportedArchitecture,
                    "message": RuntimeRedactionPolicy.default.redact(warning.message)
                ]
            },
            "limits": report.limits
        ]
    }

    private static func resourceObservation(_ observation: ResourceObservation) -> [String: Any] {
        [
            "status": observation.status.rawValue,
            "value": observation.value as Any,
            "unit": observation.unit as Any,
            "method": observation.method.rawValue,
            "note": observation.note
        ].compactNilValues()
    }

    static func events(stateDatabasePath: String, projectName: String?, filters: EventFilters, events: [EventRecord]) -> String {
        render([
            "kind": "events",
            "stateDatabasePath": stateDatabasePath,
            "project": projectName as Any,
            "filters": [
                "type": filters.type as Any,
                "serviceName": filters.serviceName as Any,
                "severity": filters.severity?.rawValue as Any,
                "limit": filters.limit as Any,
                "sort": filters.sort.rawValue
            ].compactNilValues(),
            "events": events.map { event in
                [
                    "id": event.id,
                    "timestamp": event.timestamp,
                    "severity": event.severity.rawValue,
                    "type": event.type,
                    "source": event.source,
                    "projectID": event.projectID as Any,
                    "serviceName": event.serviceName as Any,
                    "runtimeAdapter": event.runtimeAdapter as Any,
                    "message": RuntimeRedactionPolicy.default.redact(event.message),
                    "payloadJSONRedacted": RuntimeRedactionPolicy.default.redact(event.payloadJSONRedacted)
                ].compactNilValues()
            }
        ].compactNilValues())
    }

    static func recovery(stateDatabasePath: String, projectName: String?, records: [RecoveryRecord]) -> String {
        render([
            "kind": "recovery",
            "stateDatabasePath": stateDatabasePath,
            "project": projectName as Any,
            "operationGroups": records.map { record in
                let group = record.group
                let mode = recoveryMode(for: group)
                return [
                    "id": group.id,
                    "operationID": group.operationID,
                    "groupKind": group.groupKind,
                    "projectID": group.projectID as Any,
                    "serviceName": group.serviceName as Any,
                    "plannedActionType": group.plannedActionType,
                    "status": group.status.rawValue,
                    "checkpoint": group.checkpoint,
                    "planHash": group.planHash,
                    "rollbackAvailable": group.rollbackAvailable,
                    "recovery": [
                        "automatic": mode.automatic,
                        "manual": mode.manual,
                        "rollback": mode.rollback
                    ],
                    "manualRecoveryHint": RuntimeRedactionPolicy.default.redact(group.manualRecoveryHintRedacted),
                    "steps": record.steps.map { step in
                        [
                            "id": step.id,
                            "stepKey": step.stepKey,
                            "direction": step.direction.rawValue,
                            "plannedActionType": step.plannedActionType,
                            "serviceName": step.serviceName as Any,
                            "resourceIdentifier": step.resourceIdentifier as Any,
                            "status": step.status.rawValue,
                            "startedAt": step.startedAt as Any,
                            "updatedAt": step.updatedAt,
                            "finishedAt": step.finishedAt as Any,
                            "lastErrorRedacted": step.lastErrorRedacted as Any,
                            "manualRecoveryHint": RuntimeRedactionPolicy.default.redact(step.manualRecoveryHintRedacted)
                        ].compactNilValues()
                    }
                ].compactNilValues()
            }
        ].compactNilValues())
    }

    static func statusManifestMissing(manifestPath: String) -> String {
        render([
            "kind": "status",
            "manifest": [
                "path": manifestPath,
                "valid": false,
                "exists": false
            ],
            "runtime": [
                "observed": false
            ]
        ])
    }

    static func statusManifestOnly(manifestPath: String, manifest: HostwrightManifest) -> String {
        render([
            "kind": "status",
            "manifest": [
                "path": manifestPath,
                "valid": true,
                "exists": true
            ],
            "project": manifest.project as Any,
            "declaredServices": manifest.services.map(\.name).sorted(),
            "runtime": [
                "observed": false
            ]
        ].compactNilValues())
    }

    static func statusObserved(
        manifestPath: String,
        stateDatabasePath: String,
        manifest: HostwrightManifest,
        observed: ObservedRuntimeState,
        plan: ReconciliationPlan
    ) -> String {
        let observedByName = Dictionary(uniqueKeysWithValues: observed.services.map { ($0.identity.serviceName, $0) })
        return render([
            "kind": "status",
            "manifest": [
                "path": manifestPath,
                "valid": true,
                "exists": true
            ],
            "project": manifest.project as Any,
            "stateDatabasePath": stateDatabasePath,
            "runtime": [
                "observed": true,
                "adapter": observed.adapterMetadata?.adapterName as Any,
                "runtimeName": observed.adapterMetadata?.runtimeName as Any,
                "runtimeVersion": observed.adapterMetadata?.runtimeVersion as Any,
                "parser": "status-observation-v1"
            ].compactNilValues(),
            "telemetryPolicy": "local-only; no upload",
            "planHash": plan.planHash,
            "services": manifest.services.sorted { $0.name < $1.name }.map { service in
                let observedService = observedByName[service.name]
                return [
                    "name": service.name,
                    "desiredImage": service.image as Any,
                    "observed": observedService.map { observed in
                        [
                            "resourceIdentifier": observed.resourceIdentifier,
                            "image": observed.image as Any,
                            "lifecycle": observed.lifecycleState.rawValue,
                            "health": observed.healthState.rawValue,
                            "ports": observed.ports.map { port in
                                [
                                    "bindAddress": port.bindAddress as Any,
                                    "hostPort": port.hostPort as Any,
                                    "containerPort": port.containerPort,
                                    "protocol": port.protocolName.rawValue
                                ].compactNilValues()
                            },
                            "networks": observed.networks.map { network in
                                [
                                    "name": network.name,
                                    "kind": network.kind as Any,
                                    "address": network.address as Any,
                                    "gateway": network.gateway as Any,
                                    "interface": network.interfaceName as Any,
                                    "hostname": network.hostname as Any,
                                    "ipv4Address": network.ipv4Address as Any,
                                    "ipv4Gateway": network.ipv4Gateway as Any,
                                    "ipv6Address": network.ipv6Address as Any,
                                    "macAddress": network.macAddress as Any,
                                    "mtu": network.mtu as Any
                                ].compactNilValues()
                            }
                        ].compactNilValues()
                    } as Any
                ].compactNilValues()
            },
            "drift": plan.drift.map { drift in
                [
                    "kind": drift.kind.rawValue,
                    "severity": drift.severity.rawValue,
                    "identity": drift.identity?.displayName as Any,
                    "reason": RuntimeRedactionPolicy.default.redact(drift.reason)
                ].compactNilValues()
            },
            "actions": plan.actions.map { action in
                [
                    "kind": action.kind.rawValue,
                    "identity": action.identity.displayName,
                    "resourceIdentifier": action.resourceIdentifier,
                    "reason": RuntimeRedactionPolicy.default.redact(action.reason),
                    "executionAvailability": action.executionAvailability.rawValue
                ]
            }
        ].compactNilValues())
    }
}

private extension Dictionary where Key == String, Value == Any {
    func compactNilValues() -> [String: Any] {
        var compacted: [String: Any] = [:]
        for (key, value) in self {
            if let unwrapped = unwrapOptional(value) {
                compacted[key] = unwrapped
            }
        }
        return compacted
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        return mirror.children.first?.value
    }
}
