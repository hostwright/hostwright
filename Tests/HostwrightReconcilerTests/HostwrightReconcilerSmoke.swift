import XCTest
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightReconciler
@testable import HostwrightSecrets
@testable import HostwrightState

final class HostwrightReconcilerTests: XCTestCase {
    func testMissingDesiredServiceCreatesDeterministicCreateAction() {
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desiredState(), observedState: ObservedRuntimeState(projectName: "demo", services: []))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.createMissingService])
        XCTAssertEqual(plan.drift.map(\.kind), [.missingDesiredService])
        XCTAssertEqual(plan.actions[0].executionAvailability, .availableForCreateMissingService)
        XCTAssertFalse(plan.mutatesRuntime)
    }

    func testStoppedAndExitedServicesCreateStartProposalWithoutExecution() {
        let stopped = observed(lifecycleState: .stopped)
        let exited = observed(serviceName: "worker", lifecycleState: .exited)
        let desired = desiredState(services: [desiredService(), desiredService(name: "worker")])

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([exited, stopped]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.proposeStartStoppedService, .proposeStartStoppedService])
        XCTAssertTrue(plan.actions.allSatisfy { $0.executionAvailability == .unavailable })
    }

    func testRestartPolicyAllowsManagedStartForStoppedService() {
        let desired = desiredState(services: [desiredService(restartPolicy: .onFailure)])
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([observed(lifecycleState: .created)]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.proposeStartStoppedService])
        XCTAssertEqual(plan.actions[0].executionAvailability, .availableForStartManagedService)
        XCTAssertTrue(plan.actions[0].reason.contains("restart policy allows"))
    }

    func testCrashLoopRestartStateBlocksManagedStart() {
        let desired = desiredState(services: [desiredService(restartPolicy: .onFailure)])
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desired,
                observedState: observedState([observed(lifecycleState: .exited)]),
                restartPolicyStates: [identity(): restartState(status: .crashLoopBlocked, attemptCount: 3, maxAttempts: 3)],
                currentTimestamp: "2026-07-01T00:00:00Z"
            )
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.proposeStartStoppedService])
        XCTAssertEqual(plan.actions[0].executionAvailability, .unavailable)
        XCTAssertTrue(plan.actions[0].reason.contains("crash-loop protection"))
        XCTAssertTrue(plan.issues.contains { $0.kind == .restartPolicyBlocked })
    }

    func testOperatorHoldAndManualDisableBlockManagedStart() {
        for status in [RestartPolicyStateStatus.operatorHold, .manualDisabled] {
            let desired = desiredState(services: [desiredService(restartPolicy: .unlessStopped)])
            let plan = ReconciliationPlanner().reconcile(
                PlanningInput(
                    desiredState: desired,
                    observedState: observedState([observed(lifecycleState: .stopped)]),
                    restartPolicyStates: [identity(): restartState(status: status)],
                    currentTimestamp: "2026-07-01T00:00:00Z"
                )
            )

            XCTAssertEqual(plan.actions[0].executionAvailability, .unavailable, status.rawValue)
            XCTAssertTrue(plan.issues.contains { $0.kind == .restartPolicyBlocked }, status.rawValue)
        }
    }

    func testElapsedRestartBackoffAllowsOneManagedStart() {
        let desired = desiredState(services: [desiredService(restartPolicy: .onFailure)])
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desired,
                observedState: observedState([observed(lifecycleState: .created)]),
                restartPolicyStates: [
                    identity(): restartState(
                        status: .backingOff,
                        attemptCount: 1,
                        backoffUntil: "2026-07-01T00:00:30Z"
                    )
                ],
                currentTimestamp: "2026-07-01T00:00:31Z"
            )
        )

        XCTAssertEqual(plan.actions[0].executionAvailability, .availableForStartManagedService)
        XCTAssertFalse(plan.issues.contains { $0.kind == .restartPolicyBlocked })
    }

    func testFailedServiceCreatesInvestigationActionWithoutExecution() {
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desiredState(), observedState: observedState([observed(lifecycleState: .failed)]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.investigateFailedService])
        XCTAssertEqual(plan.drift.map(\.severity), [.error])
    }

    func testUnhealthyServiceCreatesHealthAction() {
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desiredState(), observedState: observedState([observed(healthState: .unhealthy)]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.investigateUnhealthyService])
        XCTAssertEqual(plan.drift.map(\.kind), [.unhealthyService])
    }

    func testUnhealthyRunningServiceCanPlanManagedRestartWhenPolicyAllowsIt() {
        let desired = desiredState(services: [desiredService(restartPolicy: .onFailure)])
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([observed(healthState: .unhealthy)]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.restartManagedService])
        XCTAssertEqual(plan.actions[0].executionAvailability, .availableForRestartManagedService)
        XCTAssertTrue(plan.actions[0].reason.contains("confirmed managed restart"))
        XCTAssertEqual(plan.drift.map(\.kind), [.unhealthyService])
    }

    func testUnhealthyNonRunningServiceDoesNotPlanManagedRestart() {
        let desired = desiredState(services: [desiredService(restartPolicy: .onFailure)])
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([observed(lifecycleState: .exited, healthState: .unhealthy)]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.proposeStartStoppedService, .investigateUnhealthyService])
        XCTAssertEqual(plan.actions[0].executionAvailability, .availableForStartManagedService)
        XCTAssertFalse(plan.actions.contains { $0.kind == .restartManagedService })
    }

    func testCrashLoopStateBlocksManagedRestartForUnhealthyRunningService() {
        let desired = desiredState(services: [desiredService(restartPolicy: .onFailure)])
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desired,
                observedState: observedState([observed(healthState: .unhealthy)]),
                restartPolicyStates: [identity(): restartState(status: .crashLoopBlocked, attemptCount: 3, maxAttempts: 3)],
                currentTimestamp: "2026-07-01T00:00:00Z"
            )
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.restartManagedService])
        XCTAssertEqual(plan.actions[0].executionAvailability, .unavailable)
        XCTAssertTrue(plan.actions[0].reason.contains("crash-loop protection"))
        XCTAssertTrue(plan.issues.contains { $0.kind == .restartPolicyBlocked })
    }

    func testUnmanagedObservedServiceCreatesFlagAction() {
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desiredState(),
                observedState: observedState([observed(serviceName: "sidecar")])
            )
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.flagUnmanagedService, .createMissingService])
        XCTAssertTrue(plan.actions.contains { $0.identity.serviceName == "sidecar" })
    }

    func testImageMismatchCreatesReplaceForImageDriftAction() {
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desiredState(),
                observedState: observedState([observed(image: "ghcr.io/example/web:old")])
            )
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.replaceForImageDrift])
        XCTAssertEqual(plan.drift.map(\.kind), [.imageMismatch])
    }

    func testPortMismatchCreatesPortDriftAction() {
        let desired = desiredState(services: [desiredService(ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)])])
        let observedService = observed(ports: [RuntimePortMapping(hostPort: 9090, containerPort: 8080)])

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([observedService]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.reconcilePortDrift])
        XCTAssertEqual(plan.drift.map(\.kind), [.portMismatch])
    }

    func testMountMismatchCreatesMountDriftAction() {
        let desired = desiredState(services: [desiredService(mounts: [RuntimeMountReference(source: "./data", target: "/data", access: .readWrite)])])
        let observedService = observed(mounts: [RuntimeMountReference(source: "./other", target: "/data", access: .readWrite)])

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([observedService]))
        )

        XCTAssertEqual(plan.actions.map(\.kind), [.reconcileMountDrift])
        XCTAssertEqual(plan.drift.map(\.kind), [.mountMismatch])
    }

    func testDuplicateObservedIdentitiesProduceBlockerIssue() {
        let duplicateA = observed()
        let duplicateB = observed()

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desiredState(), observedState: observedState([duplicateA, duplicateB]))
        )

        XCTAssertTrue(plan.includesBlockers)
        XCTAssertEqual(plan.issues.map(\.kind), [.duplicateObservedIdentity])
        XCTAssertEqual(plan.drift.map(\.kind), [.duplicateObservedIdentity])
        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testUnsupportedUnknownObservedStateFailsClosed() {
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desiredState(), observedState: observedState([observed(lifecycleState: .unknown)]))
        )

        XCTAssertTrue(plan.issues.contains { $0.kind == .unsupportedObservedState })
        XCTAssertTrue(plan.drift.contains { $0.kind == .unsupportedObservedState })
        XCTAssertFalse(plan.mutatesRuntime)
    }

    func testObservationUnavailableIsHonestAndNonMutating() {
        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desiredState(), observedState: nil)
        )

        XCTAssertFalse(plan.observationConnected)
        XCTAssertTrue(plan.issues.contains { $0.kind == .observationUnavailable })
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertFalse(plan.mutatesRuntime)
    }

    func testPolicyDetectsDuplicateDesiredHostPorts() {
        let desired = desiredState(
            services: [
                desiredService(name: "api", ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]),
                desiredService(name: "admin", ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)])
            ]
        )

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: nil)
        )

        XCTAssertTrue(plan.includesBlockers)
        XCTAssertTrue(plan.issues.contains { $0.kind == .duplicateDesiredHostPort })
    }

    func testPolicyDetectsObservedHostPortConflictBeforeMutation() {
        let desired = desiredState(
            services: [
                desiredService(name: "api", ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080, bindAddress: "127.0.0.1")])
            ]
        )
        let observed = observedState([
            observed(
                serviceName: "api",
                ports: [RuntimePortMapping(hostPort: 8081, containerPort: 8080, bindAddress: "127.0.0.1")]
            ),
            observed(
                serviceName: "admin",
                ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080, bindAddress: "0.0.0.0")]
            )
        ])

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observed)
        )

        XCTAssertTrue(plan.includesBlockers)
        XCTAssertTrue(plan.issues.contains { $0.kind == .hostPortConflict && $0.severity == .blocker })
        XCTAssertFalse(plan.mutatesRuntime)
    }

    func testPolicyDetectsUnsafeExposureAndPrivilegedPort() {
        let desired = desiredState(
            services: [
                desiredService(ports: [RuntimePortMapping(hostPort: 80, containerPort: 8080, bindAddress: "0.0.0.0")])
            ]
        )

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: nil)
        )

        XCTAssertTrue(plan.issues.contains { $0.kind == .unsafeExposure && $0.severity == .blocker })
        XCTAssertTrue(plan.issues.contains { $0.kind == .privilegedHostPort && $0.severity == .warning })
    }

    func testPolicyDetectsUnsafeVolumeReference() {
        for source in ["/", "//", "/./", "/data/..", "../data"] {
            let desired = desiredState(
                services: [
                    desiredService(mounts: [RuntimeMountReference(source: source, target: "/host", access: .readOnly)])
                ]
            )

            let plan = ReconciliationPlanner().reconcile(
                PlanningInput(desiredState: desired, observedState: nil)
            )

            XCTAssertTrue(plan.issues.contains { $0.kind == .unsafeVolumePath }, source)
        }
    }

    func testSecretLikeEnvValuesAreRedactedInPlanOutput() {
        let desired = desiredState(
            services: [
                desiredService(environment: [RuntimeEnvironmentValue(name: "API_TOKEN", value: "token=super-secret", isSensitive: true)])
            ]
        )

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: nil)
        )
        let rendered = PlanRenderer.render(plan)

        XCTAssertTrue(plan.issues.contains { $0.kind == .secretRedacted })
        XCTAssertTrue(rendered.contains("API_TOKEN"))
        XCTAssertFalse(rendered.contains("super-secret"))
    }

    func testManifestMappingIncludesSupportedSubsetAndPolicyIssues() throws {
        let manifest = HostwrightManifest(
            project: "demo",
            services: [
                HostwrightService(
                    name: "web",
                    image: "ghcr.io/example/web:latest",
                    command: ["serve"],
                    env: ["APP_ENV": "development"],
                    secretEnv: ["API_TOKEN": try HostwrightSecretReference.parse("keychain://hostwright.api/api-token")],
                    ports: ["8080:8080"],
                    volumes: ["./data:/data:rw"]
                )
            ]
        )

        let mapping = ManifestRuntimeMapper.map(manifest)
        let environment = mapping.desiredState.services[0].environment
        XCTAssertEqual(environment.first { $0.name == "APP_ENV" }?.value, "development")
        let secret = try XCTUnwrap(environment.first { $0.name == "API_TOKEN" })
        XCTAssertTrue(secret.isSensitive)
        XCTAssertEqual(secret.secretReference?.rawValue, "keychain://hostwright.api/api-token")
        XCTAssertEqual(secret.value, "keychain://[REDACTED]")
        XCTAssertEqual(mapping.desiredState.services[0].ports[0].bindAddress, "127.0.0.1")

        let plan = ReconciliationPlanner().plan(manifest: manifest)

        XCTAssertEqual(plan.projectName, "demo")
        XCTAssertTrue(plan.issues.contains { $0.kind == .secretRedacted })
        XCTAssertFalse(PlanRenderer.render(plan).contains("hostwright.api"))
        XCTAssertFalse(PlanRenderer.render(plan).contains("api-token"))
    }

    func testDeterministicPlanHashAndOrdering() {
        let desired = desiredState(
            services: [
                desiredService(name: "api", ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]),
                desiredService(name: "worker")
            ]
        )
        let observedA = observed(serviceName: "worker", image: "ghcr.io/example/worker:old")
        let observedB = observed(serviceName: "api", ports: [RuntimePortMapping(hostPort: 9090, containerPort: 8080)])

        let first = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([observedA, observedB]))
        )
        let second = ReconciliationPlanner().reconcile(
            PlanningInput(desiredState: desired, observedState: observedState([observedB, observedA]))
        )

        XCTAssertEqual(first.planHash, second.planHash)
        XCTAssertEqual(first.actions.map(\.orderingKey), second.actions.map(\.orderingKey))
    }

    func testRuntimePlanCompatibilityStillCreatesMissingAction() {
        let plan = ReconciliationPlanner().plan(desired: desiredState(), observed: ObservedRuntimeState(projectName: "demo", services: []))

        XCTAssertEqual(plan.actions.map(\.kind), [.create])
        XCTAssertFalse(plan.includesDestructiveAction)
    }

    private func identity(projectName: String = "demo", serviceName: String = "web") -> RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: projectName, serviceName: serviceName)
    }

    private func desiredState(services: [DesiredRuntimeService]? = nil) -> DesiredRuntimeState {
        DesiredRuntimeState(projectName: "demo", services: services ?? [desiredService()])
    }

    private func desiredService(
        name: String = "web",
        image: String? = nil,
        environment: [RuntimeEnvironmentValue] = [],
        ports: [RuntimePortMapping] = [],
        mounts: [RuntimeMountReference] = [],
        restartPolicy: RuntimeRestartPolicy = .no
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: identity(serviceName: name),
            image: image ?? "ghcr.io/example/\(name):latest",
            environment: environment,
            ports: ports,
            mounts: mounts,
            restartPolicy: restartPolicy
        )
    }

    private func observedState(_ services: [ObservedRuntimeService]) -> ObservedRuntimeState {
        ObservedRuntimeState(projectName: "demo", services: services)
    }

    private func observed(
        serviceName: String = "web",
        image: String? = nil,
        lifecycleState: RuntimeLifecycleState = .running,
        healthState: RuntimeHealthState = .healthy,
        ports: [RuntimePortMapping] = [],
        mounts: [RuntimeMountReference] = []
    ) -> ObservedRuntimeService {
        ObservedRuntimeService(
            identity: identity(serviceName: serviceName),
            image: image ?? "ghcr.io/example/\(serviceName):latest",
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: ports,
            mounts: mounts
        )
    }

    private func restartState(
        status: RestartPolicyStateStatus,
        attemptCount: Int = 0,
        maxAttempts: Int = 3,
        backoffUntil: String? = nil
    ) -> RestartPolicyStateRecord {
        RestartPolicyStateRecord(
            id: "restart-\(status.rawValue)",
            projectID: "project-demo",
            serviceName: "web",
            policy: .onFailure,
            status: status,
            attemptCount: attemptCount,
            maxAttempts: maxAttempts,
            backoffSeconds: 60,
            backoffUntil: backoffUntil,
            updatedAt: "2026-07-01T00:00:00Z",
            metadataJSONRedacted: "{}"
        )
    }
}
