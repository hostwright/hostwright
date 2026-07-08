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

    func testAdvisorySchedulerProducesDeterministicLocalRecommendations() {
        let desired = desiredState(
            services: [
                desiredService(name: "api"),
                desiredService(name: "worker")
            ]
        )
        let input = AdvisorySchedulingInput(
            desiredState: desired,
            observedState: observedState([]),
            resourceReport: resourceReport(physicalMemoryBytes: gibibytes(16)),
            resourceRequests: [
                identity(serviceName: "api"): advisoryRequest(memoryGiB: 1, workloadClass: .interactiveService),
                identity(serviceName: "worker"): advisoryRequest(memoryGiB: 2, workloadClass: .backgroundWorker)
            ]
        )

        let first = AdvisoryScheduler().evaluate(input)
        let second = AdvisoryScheduler().evaluate(input)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.advisoryOnly)
        XCTAssertFalse(first.hasBlockers)
        XCTAssertEqual(first.recommendations.map { $0.identity.serviceName }, ["api", "worker"])
        XCTAssertTrue(first.recommendations.allSatisfy { $0.status == .recommended })
        XCTAssertTrue(first.recommendations.allSatisfy { recommendation in
            recommendation.reasons.contains { $0.reasonCode == .memoryWithinAdvisoryBudget }
        })
    }

    func testAdvisorySchedulerBlocksPolicyPortConflicts() throws {
        let desired = desiredState(
            services: [
                desiredService(
                    name: "api",
                    ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080, bindAddress: "127.0.0.1")]
                )
            ]
        )
        let observed = observedState([
            observed(
                serviceName: "other",
                ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080, bindAddress: "0.0.0.0")]
            )
        ])

        let report = AdvisoryScheduler().evaluate(
            AdvisorySchedulingInput(
                desiredState: desired,
                observedState: observed,
                resourceReport: resourceReport(physicalMemoryBytes: gibibytes(16)),
                resourceRequests: [identity(serviceName: "api"): advisoryRequest(memoryGiB: 1)]
            )
        )

        let recommendation = try XCTUnwrap(report.recommendations.first)
        XCTAssertEqual(recommendation.status, .blocked)
        XCTAssertTrue(recommendation.reasons.contains {
            $0.reasonCode == .policyBlocker &&
                $0.policyReasonCode == .observedHostPortConflict
        })
    }

    func testAdvisorySchedulerBlocksOvercommitAndUnsupportedAccelerators() {
        let desired = desiredState(
            services: [
                desiredService(name: "api"),
                desiredService(name: "worker")
            ]
        )
        let configuration = AdvisorySchedulingConfiguration(advisoryMemoryBudgetPercent: 50)

        let report = AdvisoryScheduler().evaluate(
            AdvisorySchedulingInput(
                desiredState: desired,
                observedState: observedState([]),
                resourceReport: resourceReport(physicalMemoryBytes: gibibytes(8)),
                resourceRequests: [
                    identity(serviceName: "api"): advisoryRequest(memoryGiB: 3, workloadClass: .interactiveService),
                    identity(serviceName: "worker"): advisoryRequest(memoryGiB: 3, workloadClass: .localAI, acceleratorRequirements: ["Apple GPU"])
                ],
                configuration: configuration
            )
        )

        XCTAssertTrue(report.hasBlockers)
        XCTAssertEqual(report.recommendations.map(\.status), [.blocked, .blocked])
        XCTAssertTrue(recommendation(named: "api", in: report).reasons.contains { $0.reasonCode == .memoryOvercommit })
        let worker = recommendation(named: "worker", in: report)
        XCTAssertTrue(worker.reasons.contains { $0.reasonCode == .memoryOvercommit })
        XCTAssertTrue(worker.reasons.contains { $0.reasonCode == .acceleratorUnsupported })
    }

    func testAdvisorySchedulerIgnoresStaleResourceRequestsOutsideDesiredStateForOvercommit() {
        let desired = desiredState(services: [desiredService(name: "api")])

        let report = AdvisoryScheduler().evaluate(
            AdvisorySchedulingInput(
                desiredState: desired,
                observedState: observedState([]),
                resourceReport: resourceReport(physicalMemoryBytes: gibibytes(8)),
                resourceRequests: [
                    identity(serviceName: "api"): advisoryRequest(memoryGiB: 1, workloadClass: .interactiveService),
                    identity(serviceName: "stale"): advisoryRequest(memoryGiB: 7, workloadClass: .batchJob)
                ],
                configuration: AdvisorySchedulingConfiguration(advisoryMemoryBudgetPercent: 50)
            )
        )

        let recommendation = recommendation(named: "api", in: report)
        XCTAssertEqual(report.totalDeclaredMemoryBytes, gibibytes(1))
        XCTAssertEqual(recommendation.status, .recommended)
        XCTAssertFalse(recommendation.reasons.contains { $0.reasonCode == .memoryOvercommit })
    }

    func testAdvisorySchedulerBlocksInvalidMemoryRequests() {
        let desired = desiredState(
            services: [
                desiredService(name: "zero"),
                desiredService(name: "negative")
            ]
        )

        let report = AdvisoryScheduler().evaluate(
            AdvisorySchedulingInput(
                desiredState: desired,
                observedState: observedState([]),
                resourceReport: resourceReport(physicalMemoryBytes: gibibytes(8)),
                resourceRequests: [
                    identity(serviceName: "zero"): AdvisoryResourceRequest(
                        memoryBytes: 0,
                        workloadClass: .interactiveService
                    ),
                    identity(serviceName: "negative"): AdvisoryResourceRequest(
                        memoryBytes: -1,
                        workloadClass: .backgroundWorker
                    )
                ]
            )
        )

        XCTAssertEqual(report.totalDeclaredMemoryBytes, 0)
        XCTAssertEqual(report.recommendations.map(\.status), [.blocked, .blocked])
        XCTAssertTrue(recommendation(named: "zero", in: report).reasons.contains { $0.reasonCode == .memoryRequestInvalid })
        XCTAssertTrue(recommendation(named: "negative", in: report).reasons.contains { $0.reasonCode == .memoryRequestInvalid })
    }

    func testAdvisorySchedulerScoresFairnessWarningsDeterministically() {
        let desired = desiredState(
            services: [
                desiredService(name: "api"),
                desiredService(name: "batch-a"),
                desiredService(name: "batch-b"),
                desiredService(name: "batch-c")
            ]
        )
        let configuration = AdvisorySchedulingConfiguration(fairnessWarningThresholdPerClass: 1)

        let report = AdvisoryScheduler().evaluate(
            AdvisorySchedulingInput(
                desiredState: desired,
                observedState: observedState([]),
                resourceReport: resourceReport(physicalMemoryBytes: gibibytes(32)),
                resourceRequests: [
                    identity(serviceName: "api"): advisoryRequest(memoryGiB: 1, workloadClass: .interactiveService),
                    identity(serviceName: "batch-a"): advisoryRequest(memoryGiB: 1, workloadClass: .batchJob),
                    identity(serviceName: "batch-b"): advisoryRequest(memoryGiB: 1, workloadClass: .batchJob),
                    identity(serviceName: "batch-c"): advisoryRequest(memoryGiB: 1, workloadClass: .batchJob)
                ],
                configuration: configuration
            )
        )

        XCTAssertFalse(report.hasBlockers)
        XCTAssertEqual(report.recommendations.first?.identity.serviceName, "api")
        let batch = recommendation(named: "batch-a", in: report)
        XCTAssertEqual(batch.status, .recommended)
        XCTAssertLessThan(batch.score, recommendation(named: "api", in: report).score)
        XCTAssertTrue(batch.reasons.contains { $0.reasonCode == .workloadClassFairnessPenalty })
    }

    func testAdvisorySchedulerFailsClosedForRemotePlacementAndMissingMemoryFacts() {
        let desired = desiredState(services: [desiredService(name: "api")])

        let report = AdvisoryScheduler().evaluate(
            AdvisorySchedulingInput(
                desiredState: desired,
                observedState: observedState([]),
                resourceReport: resourceReport(physicalMemoryBytes: nil),
                resourceRequests: [
                    identity(serviceName: "api"): advisoryRequest(
                        memoryGiB: 1,
                        workloadClass: .interactiveService,
                        requiresRemotePlacement: true
                    )
                ]
            )
        )

        let recommendation = recommendation(named: "api", in: report)
        XCTAssertEqual(recommendation.status, .blocked)
        XCTAssertTrue(recommendation.reasons.contains { $0.reasonCode == .memoryBudgetUnavailable })
        XCTAssertTrue(recommendation.reasons.contains { $0.reasonCode == .remotePlacementUnsupported })
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

    private func advisoryRequest(
        memoryGiB: Int?,
        workloadClass: AdvisoryWorkloadClass = .unknown,
        acceleratorRequirements: [String] = [],
        requiresRemotePlacement: Bool = false
    ) -> AdvisoryResourceRequest {
        AdvisoryResourceRequest(
            memoryBytes: memoryGiB.map(gibibytes),
            workloadClass: workloadClass,
            acceleratorRequirements: acceleratorRequirements,
            requiresRemotePlacement: requiresRemotePlacement
        )
    }

    private func resourceReport(
        physicalMemoryBytes: Int?,
        thermalState: ResourcePressureLevel = .nominal
    ) -> ResourceIntelligenceReport {
        ResourceIntelligenceReport(
            snapshot: ResourceIntelligenceSnapshot(
                method: .fixture,
                operatingSystemDescription: "macOS 26.5",
                platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
                physicalMemoryBytes: physicalMemoryBytes,
                activeProcessorCount: 12,
                thermalState: thermalState,
                appleContainerExecutablePath: "/usr/local/bin/container",
                appleContainerVersion: "container 1.0.0",
                workloadProfile: .localContainersGeneral
            )
        )
    }

    private func recommendation(named serviceName: String, in report: AdvisorySchedulingReport) -> AdvisorySchedulingRecommendation {
        guard let recommendation = report.recommendations.first(where: { $0.identity.serviceName == serviceName }) else {
            XCTFail("Missing recommendation for \(serviceName)")
            return report.recommendations[0]
        }
        return recommendation
    }

    private func gibibytes(_ value: Int) -> Int {
        value * 1_073_741_824
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
             .acceleratorUnsupported:
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
