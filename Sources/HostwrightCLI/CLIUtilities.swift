import Foundation
import HostwrightCore
import HostwrightHealth
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
            image: image,
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: ports,
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
                    "reason": RuntimeRedactionPolicy.default.redact(action.reason),
                    "executionAvailability": action.executionAvailability.rawValue
                ]
            }
        ])
    }

    static func doctor(_ report: DoctorReport) -> String {
        render([
            "kind": "doctor",
            "hasFailures": report.hasFailures,
            "checks": report.checks.map { check in
                [
                    "identifier": check.identifier.rawValue,
                    "status": check.status.rawValue,
                    "message": RuntimeRedactionPolicy.default.redact(check.message)
                ]
            }
        ])
    }

    static func events(stateDatabasePath: String, projectName: String?, events: [EventRecord]) -> String {
        render([
            "kind": "events",
            "stateDatabasePath": stateDatabasePath,
            "project": projectName as Any,
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
                "adapter": observed.adapterMetadata?.adapterName as Any
            ].compactNilValues(),
            "planHash": plan.planHash,
            "services": manifest.services.sorted { $0.name < $1.name }.map { service in
                let observedService = observedByName[service.name]
                return [
                    "name": service.name,
                    "desiredImage": service.image as Any,
                    "observed": observedService.map { observed in
                        [
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
