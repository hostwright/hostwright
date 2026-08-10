import XCTest
@testable import HostwrightCore
@testable import HostwrightHealth
@testable import HostwrightManifest
@testable import HostwrightPolicy
@testable import HostwrightRuntime
@testable import HostwrightReconciler
@testable import HostwrightSecrets
@testable import HostwrightState

final class HostwrightReconcilerTests: XCTestCase {
    func testPhase08RestartBudgetBackoffHoldAndStableResetAreDeterministic() throws {
        let policy = RestartBudgetPolicy(
            service: HostwrightRestart(
                policy: "on-failure",
                maxAttempts: 2,
                window: 300,
                backoff: 10,
                maxBackoff: 30,
                jitter: 3,
                stableRun: 60,
                priority: 10
            ),
            project: HostwrightProjectRestartBudget(maxAttempts: 5, window: 300)
        )
        let initial = RestartPolicyEvaluator.preparedState(
            id: "restart-api",
            projectID: "project-demo",
            serviceName: "api",
            restartPolicy: .onFailure,
            policy: policy,
            observedLifecycle: .stopped,
            observedHealth: .unknown,
            previous: nil,
            projectCapacityAvailable: true,
            timestamp: "2026-08-01T12:00:00Z"
        )
        XCTAssertEqual(initial.status, .active)
        let first = RestartPolicyEvaluator.admittedAttempt(
            state: initial,
            projectAttemptNumber: 1,
            operationID: "11111111-1111-4111-8111-111111111111",
            failed: true,
            timestamp: "2026-08-01T12:00:00Z",
            historyID: "22222222-2222-4222-8222-222222222222"
        )
        let repeated = RestartPolicyEvaluator.admittedAttempt(
            state: initial,
            projectAttemptNumber: 1,
            operationID: "11111111-1111-4111-8111-111111111111",
            failed: true,
            timestamp: "2026-08-01T12:00:00Z",
            historyID: "22222222-2222-4222-8222-222222222222"
        )
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.state.attemptCount, 1)
        XCTAssertTrue((10...13).contains(first.state.backoffSeconds))

        let secondAdmission = RestartPolicyEvaluator.admittedAttempt(
            state: RestartPolicyEvaluator.preparedState(
                id: first.state.id,
                projectID: first.state.projectID,
                serviceName: first.state.serviceName,
                restartPolicy: .onFailure,
                policy: policy,
                observedLifecycle: .stopped,
                observedHealth: .unknown,
                previous: first.state,
                projectCapacityAvailable: true,
                timestamp: "2026-08-01T12:01:00Z"
            ),
            projectAttemptNumber: 2,
            operationID: nil,
            failed: true,
            timestamp: "2026-08-01T12:01:00Z",
            historyID: "33333333-3333-4333-8333-333333333333"
        )
        let held = RestartPolicyEvaluator.preparedState(
            id: secondAdmission.state.id,
            projectID: secondAdmission.state.projectID,
            serviceName: secondAdmission.state.serviceName,
            restartPolicy: .onFailure,
            policy: policy,
            observedLifecycle: .stopped,
            observedHealth: .unknown,
            previous: secondAdmission.state,
            projectCapacityAvailable: true,
            timestamp: "2026-08-01T12:02:00Z"
        )
        XCTAssertEqual(held.status, .crashLoopBlocked)
        XCTAssertEqual(held.holdToken?.count, 64)

        let stablePending = RestartPolicyEvaluator.preparedState(
            id: first.state.id,
            projectID: first.state.projectID,
            serviceName: first.state.serviceName,
            restartPolicy: .onFailure,
            policy: policy,
            observedLifecycle: .running,
            observedHealth: .healthy,
            previous: first.state,
            projectCapacityAvailable: true,
            timestamp: "2026-08-01T12:00:20Z"
        )
        XCTAssertEqual(stablePending.status, .stablePending)
        let reset = RestartPolicyEvaluator.preparedState(
            id: stablePending.id,
            projectID: stablePending.projectID,
            serviceName: stablePending.serviceName,
            restartPolicy: .onFailure,
            policy: policy,
            observedLifecycle: .running,
            observedHealth: .healthy,
            previous: stablePending,
            projectCapacityAvailable: true,
            timestamp: "2026-08-01T12:01:21Z"
        )
        XCTAssertEqual(reset.status, .active)
        XCTAssertEqual(reset.attemptCount, 0)
    }

    func testPhase08ProjectBudgetBlocksOnlyTheExcessCandidate() {
        let policy = RestartBudgetPolicy(service: HostwrightRestart(policy: "on-failure"), project: nil)
        let blocked = RestartPolicyEvaluator.preparedState(
            id: "restart-worker",
            projectID: "project-demo",
            serviceName: "worker",
            restartPolicy: .onFailure,
            policy: policy,
            observedLifecycle: .stopped,
            observedHealth: .unknown,
            previous: nil,
            projectCapacityAvailable: false,
            timestamp: "2026-08-01T12:00:00Z"
        )
        XCTAssertEqual(blocked.status, .projectBudgetBlocked)
        XCTAssertTrue(RestartPolicyEvaluator.decision(
            desired: desiredService(restartPolicy: .onFailure),
            state: blocked,
            currentTimestamp: "2026-08-01T12:00:00Z"
        ).isBlocked)
    }

    func testPhase08ReasonClassesAndAbsoluteBackoffTimeFailClosed() {
        let policy = RestartBudgetPolicy(
            service: HostwrightRestart(policy: "on-failure"),
            project: nil
        )
        let cases: [(RuntimeLifecycleState?, RuntimeHealthState?, Bool, RestartReasonClass)] = [
            (.stopped, .unknown, false, .processExit),
            (.running, .unhealthy, false, .healthFailure),
            (.failed, .unknown, false, .runtimeFailure),
            (.stopped, .unknown, true, .dependencyFailure),
            (.running, .unknown, false, .unknown)
        ]
        for (lifecycle, health, dependencyUnavailable, expected) in cases {
            let state = RestartPolicyEvaluator.preparedState(
                id: "restart-api",
                projectID: "project-demo",
                serviceName: "api",
                restartPolicy: .onFailure,
                policy: policy,
                observedLifecycle: lifecycle,
                observedHealth: health,
                dependencyUnavailable: dependencyUnavailable,
                previous: nil,
                projectCapacityAvailable: true,
                timestamp: "2026-08-01T12:00:00Z"
            )
            XCTAssertEqual(state.reasonClass, expected)
        }

        let decision = RestartPolicyEvaluator.decision(
            desired: desiredService(restartPolicy: .onFailure),
            state: restartState(
                status: .backingOff,
                attemptCount: 1,
                backoffUntil: "2026-08-01T12:30:00Z"
            ),
            currentTimestamp: "2026-08-01T14:00:00+02:00"
        )
        XCTAssertTrue(decision.isBlocked)
        XCTAssertEqual(decision.executionAvailability, .unavailable)
    }

    func testPhase08TenThousandFailuresKeepBackoffAndHistoryFieldsBounded() {
        let policy = RestartBudgetPolicy(
            service: HostwrightRestart(
                policy: "on-failure",
                maxAttempts: 100,
                window: 86_400,
                backoff: 1,
                maxBackoff: 86_400,
                jitter: 1,
                stableRun: 1,
                priority: 0
            ),
            project: HostwrightProjectRestartBudget(maxAttempts: 1_000, window: 86_400)
        )
        var state = RestartPolicyEvaluator.preparedState(
            id: "restart-load",
            projectID: "project-demo",
            serviceName: "api",
            restartPolicy: .onFailure,
            policy: policy,
            observedLifecycle: .stopped,
            observedHealth: .unknown,
            previous: nil,
            projectCapacityAvailable: true,
            timestamp: "2026-08-01T12:00:00Z"
        )
        for attempt in 1...10_000 {
            let result = RestartPolicyEvaluator.admittedAttempt(
                state: state,
                projectAttemptNumber: attempt,
                operationID: nil,
                failed: true,
                timestamp: "2026-08-01T12:00:00Z",
                historyID: "history-\(attempt)"
            )
            state = result.state
            XCTAssertLessThanOrEqual(state.backoffSeconds, 86_400)
            XCTAssertLessThanOrEqual(result.history.metadataJSONRedacted.utf8.count, 65_536)
        }
        XCTAssertEqual(state.attemptCount, 10_000)
        XCTAssertEqual(state.backoffSeconds, 86_400)
    }

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

    func testUnixSocketMismatchCreatesPortDriftAction() {
        let desiredSocket = RuntimeUnixSocketPublication(
            hostPath: "/tmp/hostwright/api.sock",
            containerPath: "/run/api.sock"
        )
        let observedSocket = RuntimeUnixSocketPublication(
            hostPath: "/tmp/hostwright/api.sock",
            containerPath: "/run/other.sock"
        )
        let desired = desiredState(
            services: [
                desiredService(
                    publishedSockets: [desiredSocket]
                )
            ]
        )
        let observedService = observed(
            publishedSockets: [observedSocket]
        )

        let plan = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desired,
                observedState: observedState([observedService])
            )
        )

        XCTAssertEqual(
            plan.actions.map(\.kind),
            [.reconcilePortDrift]
        )
        XCTAssertEqual(plan.drift.map(\.kind), [.portMismatch])
        XCTAssertTrue(
            plan.drift[0].stableDetailKey.contains(
                "desiredSockets="
            )
        )
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

    func testPlanningPolicyBridgesLocalPolicyEvaluatorWithoutChangingIssues() {
        let policy = PlanningPolicy.default
        let desired = desiredState(
            services: [
                desiredService(
                    name: "api",
                    environment: [RuntimeEnvironmentValue(name: "API_TOKEN", value: "token=super-secret", isSensitive: true)],
                    ports: [RuntimePortMapping(hostPort: 80, containerPort: 8080, bindAddress: "0.0.0.0")],
                    mounts: [RuntimeMountReference(source: "/", target: "/host", access: .readOnly)]
                ),
                desiredService(
                    name: "admin",
                    ports: [RuntimePortMapping(hostPort: 80, containerPort: 8080, bindAddress: "0.0.0.0")]
                )
            ]
        )
        let observed = observedState([
            observed(
                serviceName: "worker",
                ports: [RuntimePortMapping(hostPort: 80, containerPort: 8080, bindAddress: "127.0.0.1")]
            )
        ])

        let directPolicyFingerprints = LocalPolicyEvaluator(configuration: policy.localPolicyConfiguration)
            .evaluate(desiredState: desired, observedState: observed)
            .compactMap(policyIssueFingerprint)
        let planningPolicyFingerprints = policy
            .evaluate(desiredState: desired, observedState: observed)
            .map(planIssueFingerprint)

        XCTAssertEqual(planningPolicyFingerprints.sorted(), directPolicyFingerprints.sorted())
    }

    func testManifestMappingIncludesSupportedSubsetAndPolicyIssues() throws {
        let manifest = HostwrightManifest(
            project: "demo",
            services: [
                HostwrightService(
                    name: "web",
                    image: "ghcr.io/example/web:latest",
                    resources: HostwrightResources(
                        requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                        limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
                    ),
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

    func testCapabilityDigestIsBoundIntoTheObservedPlanHash() {
        let firstDigest = String(repeating: "a", count: 64)
        let secondDigest = String(repeating: "b", count: 64)
        let first = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desiredState(),
                observedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [],
                    capabilitySHA256: firstDigest
                )
            )
        )
        let second = ReconciliationPlanner().reconcile(
            PlanningInput(
                desiredState: desiredState(),
                observedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [],
                    capabilitySHA256: secondDigest
                )
            )
        )

        XCTAssertEqual(first.capabilitySHA256, firstDigest)
        XCTAssertEqual(second.capabilitySHA256, secondDigest)
        XCTAssertNotEqual(first.planHash, second.planHash)
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
        publishedSockets: [RuntimeUnixSocketPublication] = [],
        mounts: [RuntimeMountReference] = [],
        restartPolicy: RuntimeRestartPolicy = .no
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: identity(serviceName: name),
            image: image ?? "ghcr.io/example/\(name):latest",
            environment: environment,
            ports: ports,
            publishedSockets: publishedSockets,
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
        publishedSockets: [RuntimeUnixSocketPublication] = [],
        mounts: [RuntimeMountReference] = []
    ) -> ObservedRuntimeService {
        let identity = identity(serviceName: serviceName)
        return ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: identity.managedResourceIdentifier,
            image: image ?? "ghcr.io/example/\(serviceName):latest",
            lifecycleState: lifecycleState,
            healthState: healthState,
            ports: ports,
            publishedSockets: publishedSockets,
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

    private func planIssueFingerprint(_ issue: PlanIssue) -> String {
        [
            issue.kind.rawValue,
            issue.severity.rawValue,
            issue.identity?.displayName ?? "",
            issue.message,
            issue.stableDetailKey
        ].joined(separator: "|")
    }

    private func policyIssueFingerprint(_ decision: PolicyDecision) -> String? {
        guard let kind = planIssueKind(for: decision.reasonCode),
              let severity = planSeverity(for: decision.severity) else {
            return nil
        }

        return [
            kind.rawValue,
            severity.rawValue,
            decision.identity?.displayName ?? "",
            decision.message,
            decision.stableDetailKey
        ].joined(separator: "|")
    }

    private func planIssueKind(for reasonCode: PolicyReasonCode) -> PlanIssueKind? {
        switch reasonCode {
        case .invalidDesiredIdentity:
            return .invalidDesiredIdentity
        case .duplicateDesiredHostPort:
            return .duplicateDesiredHostPort
        case .observedHostPortConflict:
            return .hostPortConflict
        case .unsafeExposure:
            return .unsafeExposure
        case .privilegedHostPort:
            return .privilegedHostPort
        case .ambiguousMountReference:
            return .ambiguousVolumeReference
        case .unsafeMountSource:
            return .unsafeVolumePath
        case .secretValueRedacted:
            return .secretRedacted
        case .imageReferenceURLUnsupported,
             .imageDigestRequired,
             .imageDigestInvalid,
             .secretReferenceUnavailable,
             .cleanupIdentityBindingMismatch,
             .cleanupEligible,
             .cleanupNotEligible,
             .cleanupWrongResourceType,
             .cleanupWrongProject,
             .cleanupUnmanagedIdentifier,
             .cleanupMissingServiceName,
             .cleanupRuntimeAdapterUnavailable,
             .cleanupRuntimeAdapterMismatch,
             .cleanupStale,
             .cleanupAmbiguous,
             .cleanupObservedServiceMismatch,
             .cleanupRunning,
             .cleanupUnknownLifecycle,
             .cleanupMissingRuntimeResource,
             .cleanupFailedLifecycle,
             .cleanupUnownedObservedResource,
             .lifecycleSupported,
             .lifecycleUnsupported,
             .untrustedManifestUnsupportedField,
             .secureExposureUnsupported,
             .acceleratorUnsupported,
             .extensionDeclared,
             .extensionMissingIdentity,
             .extensionNoCapabilities,
             .extensionUnsupportedAPIVersion,
             .extensionUntrusted,
             .extensionBoundaryMissing,
             .extensionRuntimeMutationUnsupported,
             .extensionStateWriteUnsupported,
             .extensionNetworkingUnsupported,
             .extensionTunnelUnsupported,
             .extensionSecretResolutionUnsupported,
             .extensionAcceleratorUnsupported,
             .teamProfileDeclared,
             .teamProfileMissingIdentity,
             .teamProfileNotOptIn,
             .teamProfileUnsupportedVersion,
             .teamProfileInvalidKind,
             .teamProfileInvalidDisplayName,
             .teamProfileMissingRequiredGate,
             .teamProfileDuplicateGate,
             .teamProfileDuplicateRequirement,
             .teamRequirementDeclared,
             .teamApprovalMissingIdentity,
             .teamApprovalUnsupportedVersion,
             .teamApprovalInvalidKind,
             .teamApprovalRejected,
             .teamApprovalScopeMismatch,
             .teamApprovalInvalidTimestamp,
             .teamApprovalBindingMismatch,
             .teamApprovalRecorded:
            return nil
        }
    }

    private func planSeverity(for severity: PolicyDecisionSeverity) -> DriftSeverity? {
        switch severity {
        case .blocker:
            return .blocker
        case .warning:
            return .warning
        case .allow:
            return nil
        }
    }
}
