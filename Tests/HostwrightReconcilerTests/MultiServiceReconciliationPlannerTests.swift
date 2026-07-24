import XCTest
@testable import HostwrightReconciler
@testable import HostwrightRuntime

final class MultiServiceReconciliationPlannerTests: XCTestCase {
    func testMissingDependencyFailsBeforeProducingMutationNodes() throws {
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ]
        )

        XCTAssertThrowsError(
            try planner().plan(
                desired: state([web]),
                observed: observation([])
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .missingDependency(service: "web", dependency: "db")
            )
        }
    }

    func testDependencyCycleFailsBeforeProducingMutationNodes() throws {
        let api = service(
            "api",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .started)
            ]
        )
        let db = service(
            "db",
            dependencies: [
                RuntimeServiceDependency(serviceName: "api", condition: .ready)
            ]
        )

        XCTAssertThrowsError(
            try planner().plan(
                desired: state([db, api]),
                observed: observation([])
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .dependencyCycle(["api", "db"])
            )
        }
    }

    func testReplicaIdentityMustMatchDeterministicReplicaIndex() throws {
        let invalid = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "web",
                instanceName: "custom-replica"
            ),
            logicalServiceName: "web",
            replicaIndex: 0,
            image: "example.invalid/web@sha256:" + String(repeating: "a", count: 64)
        )

        XCTAssertThrowsError(
            try planner().plan(
                desired: state([invalid]),
                observed: observation([])
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .invalidReplicaSet("web")
            )
        }
    }

    func testReadyAndStartedGatesProduceStableBoundedWaves() throws {
        let cache = service("cache")
        let db = service(
            "db",
            healthCheck: RuntimeHealthCheckSpec(command: ["/bin/check"])
        )
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .ready),
                RuntimeServiceDependency(serviceName: "cache", condition: .started)
            ]
        )
        let desired = state([web, db, cache])

        let first = try MultiServiceReconciliationPlanner(parallelism: 32).plan(
            desired: desired,
            observed: observation([])
        )
        let second = try MultiServiceReconciliationPlanner(parallelism: 32).plan(
            desired: state([cache, web, db]),
            observed: observation([])
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.waves.map(\.nodes.count), [3, 2, 1, 1])
        XCTAssertTrue(first.waves.allSatisfy(\.requiresReobservationAfter))

        let startWeb = try XCTUnwrap(
            first.nodes.first { $0.key == nodeKey("start", web) }
        )
        XCTAssertEqual(
            startWeb.dependencies,
            [
                nodeKey("create", web),
                nodeKey("start", cache),
                nodeKey("verify-ready", db)
            ].sorted()
        )
        XCTAssertEqual(
            startWeb.preconditions.map(\.kind),
            ["dependency-ready", "dependency-started"]
        )

        let verifyDB = try XCTUnwrap(
            first.nodes.first { $0.key == nodeKey("verify-ready", db) }
        )
        XCTAssertEqual(verifyDB.action, .verify)
        XCTAssertEqual(verifyDB.dependencies, [nodeKey("start", db)])
        XCTAssertEqual(verifyDB.postconditions.map(\.kind), ["dependency-ready"])

        let bounded = try MultiServiceReconciliationPlanner(parallelism: 2).plan(
            desired: desired,
            observed: observation([])
        )
        XCTAssertTrue(bounded.waves.allSatisfy { $0.nodes.count <= 2 })
        XCTAssertEqual(Set(bounded.nodes.map(\.key)), Set(first.nodes.map(\.key)))
    }

    func testStartedServiceWithoutHookOrTypedProbesAddsNoSyntheticVerification() throws {
        let web = service("web")

        let plan = try planner().plan(
            desired: state([web]),
            observed: observation([])
        )

        XCTAssertEqual(
            plan.nodes.map(\.key),
            [nodeKey("create", web), nodeKey("start", web)]
        )
        XCTAssertFalse(plan.nodes.contains { $0.action == .runHook })
        XCTAssertFalse(plan.nodes.contains { $0.action == .verify })
    }

    func testPostStartAndConfiguredProbesFormDeterministicStartupChain() throws {
        let web = service(
            "web",
            probes: allProbes(),
            hooks: RuntimeLifecycleHooks(postStart: ["/bin/configure"]),
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
        )

        let first = try planner().plan(
            desired: state([web]),
            observed: observation([])
        )
        let second = try planner().plan(
            desired: state([web]),
            observed: observation([])
        )

        XCTAssertEqual(first, second)
        let expectedKeys = [
            "create",
            "start",
            "poststart",
            "verify-startup",
            "verify-liveness",
            "verify-ready"
        ].map { nodeKey($0, web) }
        XCTAssertEqual(first.nodes.map(\.key), expectedKeys)

        let postStart = try XCTUnwrap(
            first.nodes.first { $0.key == nodeKey("poststart", web) }
        )
        XCTAssertEqual(postStart.action, .runHook)
        XCTAssertEqual(postStart.dependencies, [nodeKey("start", web)])
        XCTAssertEqual(
            postStart.postconditions,
            [condition("hook-completed", web, "postStart")]
        )

        let startup = try XCTUnwrap(
            first.nodes.first { $0.key == nodeKey("verify-startup", web) }
        )
        XCTAssertEqual(startup.dependencies, [postStart.key])
        XCTAssertEqual(
            startup.postconditions,
            [condition("probe-startup", web, "succeeded")]
        )

        let readiness = try XCTUnwrap(
            first.nodes.first { $0.key == nodeKey("verify-ready", web) }
        )
        let liveness = try XCTUnwrap(
            first.nodes.first { $0.key == nodeKey("verify-liveness", web) }
        )
        XCTAssertEqual(readiness.dependencies, [liveness.key])
        XCTAssertEqual(
            readiness.postconditions,
            [condition("probe-readiness", web, "ready")]
        )

        XCTAssertEqual(liveness.dependencies, [startup.key])
        XCTAssertFalse(liveness.dependencies.contains(readiness.key))
        XCTAssertEqual(
            liveness.postconditions,
            [condition("probe-liveness", web, "healthy")]
        )
    }

    func testConfiguredReadinessIsTheOnlyDirectDependencyGate() throws {
        let db = service(
            "db",
            probes: allProbes(),
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
        )
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ]
        )

        let plan = try planner().plan(
            desired: state([web, db]),
            observed: observation([])
        )

        let startWeb = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("start", web) }
        )
        XCTAssertTrue(startWeb.dependencies.contains(nodeKey("verify-ready", db)))
        XCTAssertFalse(startWeb.dependencies.contains(nodeKey("verify-liveness", db)))
        let readiness = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("verify-ready", db) }
        )
        XCTAssertEqual(
            readiness.postconditions,
            [condition("probe-readiness", db, "ready")]
        )
    }

    func testAlreadyRunningServiceSchedulesTypedProbesAndUsesTypedReadinessGate() throws {
        let db = service(
            "db",
            probes: allProbes(),
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
        )
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ]
        )
        let desired = state(
            [db, web],
            hints: [ownershipHint(db, index: 0)]
        )

        let plan = try planner().plan(
            desired: desired,
            observed: observation([
                observed(db, lifecycle: .running, health: .healthy)
            ])
        )

        XCTAssertFalse(plan.nodes.contains { $0.key == nodeKey("start", db) })
        let startup = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("verify-startup", db) }
        )
        let liveness = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("verify-liveness", db) }
        )
        let readiness = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("verify-ready", db) }
        )
        let startWeb = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("start", web) }
        )

        XCTAssertTrue(startup.dependencies.isEmpty)
        XCTAssertEqual(liveness.dependencies, [startup.key])
        XCTAssertFalse(liveness.dependencies.contains(readiness.key))
        XCTAssertEqual(readiness.dependencies, [liveness.key])
        XCTAssertEqual(
            readiness.postconditions,
            [condition("probe-readiness", db, "ready")]
        )
        XCTAssertTrue(startWeb.dependencies.contains(readiness.key))
        XCTAssertFalse(startWeb.dependencies.contains(liveness.key))
    }

    func testRemoveRunsOnlyPreStopBeforeStoppingAndDeletingRunningResource() throws {
        let web = service(
            "web",
            probes: allProbes(),
            hooks: RuntimeLifecycleHooks(
                postStart: ["/bin/configure"],
                preStop: ["/bin/drain"]
            ),
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
        )

        let plan = try planner().plan(
            desired: ownedState([web]),
            observed: observation([
                observed(web, lifecycle: .running, health: .healthy)
            ]),
            mode: .remove
        )

        XCTAssertEqual(
            Set(plan.nodes.map(\.key)),
            [
                nodeKey("prestop", web),
                nodeKey("stop", web),
                nodeKey("delete", web)
            ]
        )
        let preStop = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("prestop", web) }
        )
        let stop = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("stop", web) }
        )
        let delete = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("delete", web) }
        )
        XCTAssertEqual(preStop.action, .runHook)
        XCTAssertEqual(
            preStop.postconditions,
            [condition("hook-completed", web, "preStop")]
        )
        XCTAssertEqual(stop.dependencies, [preStop.key])
        XCTAssertEqual(delete.dependencies, [stop.key])
        XCTAssertFalse(plan.nodes.contains { $0.action == .verify })
    }

    func testAlreadyStoppedRemovalDoesNotRunPreStop() throws {
        let web = service(
            "web",
            hooks: RuntimeLifecycleHooks(preStop: ["/bin/drain"])
        )

        let plan = try planner().plan(
            desired: ownedState([web]),
            observed: observation([
                observed(web, lifecycle: .stopped, health: .notConfigured)
            ]),
            mode: .remove
        )

        XCTAssertEqual(plan.nodes.map(\.key), [nodeKey("delete", web)])
        XCTAssertFalse(plan.nodes.contains { $0.action == .runHook })
    }

    func testDependencyPreStopWaitsForDependentStop() throws {
        let db = service(
            "db",
            hooks: RuntimeLifecycleHooks(preStop: ["/bin/drain-db"])
        )
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ],
            hooks: RuntimeLifecycleHooks(preStop: ["/bin/drain-web"])
        )
        let desired = ownedState([db, web])

        let plan = try planner().plan(
            desired: desired,
            observed: observation([
                observed(db, lifecycle: .running, health: .healthy),
                observed(web, lifecycle: .running, health: .healthy)
            ]),
            mode: .down
        )

        let preStopDB = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("prestop", db) }
        )
        let stopWeb = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("stop", web) }
        )
        XCTAssertEqual(preStopDB.dependencies, [stopWeb.key])
        XCTAssertEqual(
            plan.waves.map { $0.nodes.map(\.key) },
            [
                [nodeKey("prestop", web)],
                [nodeKey("stop", web)],
                [nodeKey("prestop", db)],
                [nodeKey("stop", db)]
            ]
        )
    }

    func testCompletedGateIsExplicitAndBlocksDependentStart() throws {
        let worker = service("worker")
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "worker", condition: .completed)
            ]
        )
        let desired = ownedState([worker, web])
        let observedWorker = observed(worker, lifecycle: .running, health: .notConfigured)

        let plan = try planner().plan(
            desired: desired,
            observed: observation([observedWorker])
        )

        let verifyWorker = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("verify-completed", worker) }
        )
        let startWeb = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("start", web) }
        )
        XCTAssertEqual(verifyWorker.action, .verify)
        XCTAssertEqual(verifyWorker.postconditions.map(\.expectedValue), ["true"])
        XCTAssertTrue(startWeb.dependencies.contains(verifyWorker.key))
    }

    func testCompletedDependencyUsesCompletionAwareStartPostcondition() throws {
        let worker = service("worker")
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "worker", condition: .completed)
            ]
        )

        let plan = try planner().plan(
            desired: ownedState([worker, web]),
            observed: observation([])
        )

        let startWorker = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("start", worker) }
        )
        let startWeb = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("start", web) }
        )
        let verifyWorker = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("verify-completed", worker) }
        )
        XCTAssertEqual(
            startWorker.postconditions,
            [condition("lifecycle", worker, RuntimeLifecycleState.exited.rawValue)]
        )
        XCTAssertEqual(
            startWeb.postconditions,
            [condition("lifecycle", web, RuntimeLifecycleState.running.rawValue)]
        )
        XCTAssertEqual(verifyWorker.dependencies, [startWorker.key])
        XCTAssertTrue(startWeb.dependencies.contains(verifyWorker.key))
    }

    func testExitedDependencyStillRequiresExplicitCompletionVerification() throws {
        let worker = service("worker")
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "worker", condition: .completed)
            ]
        )
        let desired = ownedState([worker, web])

        let plan = try planner().plan(
            desired: desired,
            observed: observation([
                observed(worker, lifecycle: .exited, health: .notConfigured)
            ])
        )

        XCTAssertTrue(
            plan.nodes.contains { $0.key == nodeKey("verify-completed", worker) }
        )
        XCTAssertFalse(plan.nodes.contains { $0.key == nodeKey("start", worker) })
    }

    func testConvergedThreeServiceStateProducesZeroEffects() throws {
        let cache = service("cache")
        let db = service("db")
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "cache", condition: .started),
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ]
        )
        let desired = ownedState([web, cache, db])
        let observedState = observation([
            observed(web, lifecycle: .running, health: .notConfigured),
            observed(db, lifecycle: .running, health: .notConfigured),
            observed(cache, lifecycle: .running, health: .notConfigured)
        ])

        let first = try planner().plan(desired: desired, observed: observedState)
        let second = try planner().plan(desired: desired, observed: observedState)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.waves.isEmpty)
        XCTAssertTrue(first.nodes.isEmpty)
        XCTAssertFalse(first.mutatesRuntime)
    }

    func testUpFailsClosedWhenDesiredRevisionChangedInsteadOfIgnoringDrift() throws {
        let previous = service("web", command: ["/bin/web", "--old"])
        let desired = service("web", command: ["/bin/web", "--new"])

        XCTAssertThrowsError(
            try planner().plan(
                desired: ownedState([desired]),
                observed: observation([
                    observed(previous, lifecycle: .running, health: .notConfigured)
                ]),
                previousDesired: ownedState([previous])
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .desiredSpecificationDriftRequiresUpdate([
                    desired.identity.displayName
                ])
            )
        }
    }

    func testUpFailsClosedWhenObservedSupportedSpecificationHasDrifted() throws {
        let desired = service(
            "web",
            ports: [
                RuntimePortMapping(hostPort: 8080, containerPort: 8080)
            ],
            mounts: [
                RuntimeMountReference(
                    source: "/tmp/demo",
                    target: "/data",
                    access: .readOnly
                )
            ]
        )
        let drifted = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            image: desired.image,
            lifecycleState: .running,
            healthState: .notConfigured,
            ports: [
                RuntimePortMapping(hostPort: 9090, containerPort: 8080)
            ],
            mounts: desired.mounts
        )

        XCTAssertThrowsError(
            try planner().plan(
                desired: ownedState([desired]),
                observed: observation([drifted]),
                previousDesired: ownedState([desired])
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .desiredSpecificationDriftRequiresUpdate([
                    desired.identity.displayName
                ])
            )
        }
    }

    func testUpCreatesMissingResourceDirectlyAtChangedRevision() throws {
        let previous = service("web", command: ["/bin/web", "--old"])
        let desired = service("web", command: ["/bin/web", "--new"])

        let plan = try planner().plan(
            desired: ownedState([desired]),
            observed: observation([]),
            previousDesired: ownedState([previous])
        )

        XCTAssertEqual(
            plan.nodes.map(\.key),
            [nodeKey("create", desired), nodeKey("start", desired)]
        )
        XCTAssertTrue(
            plan.nodes.allSatisfy { $0.desiredService == desired }
        )
    }

    func testUnmanagedIdentifierCollisionFailsBeforeCreate() throws {
        let web = service("web")

        XCTAssertThrowsError(
            try planner().plan(
                desired: state([web]),
                observed: observation([]),
                unmanagedResourceIdentifiers: [web.identity.managedResourceIdentifier]
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .unmanagedResourceCollision(web.identity.managedResourceIdentifier)
            )
        }
    }

    func testObservedExpectedIdentifierMarkedUnmanagedFailsClosed() throws {
        let web = service("web")

        XCTAssertThrowsError(
            try planner().plan(
                desired: ownedState([web]),
                observed: observation([
                    observed(web, lifecycle: .running, health: .notConfigured)
                ]),
                unmanagedResourceIdentifiers: [web.identity.managedResourceIdentifier]
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .unmanagedResourceCollision(web.identity.managedResourceIdentifier)
            )
        }
    }

    func testObservedDesiredNameWithoutExactOwnershipIsUnmanagedCollision() throws {
        let web = service("web")

        XCTAssertThrowsError(
            try planner().plan(
                desired: state([web]),
                observed: observation([
                    observed(web, lifecycle: .stopped, health: .notConfigured)
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .unmanagedResourceCollision(web.identity.managedResourceIdentifier)
            )
        }
    }

    func testRemoveAcceptsUpdatedResourceIdentifierWithExactOwnershipHint() throws {
        let web = service("web")
        let updatedIdentifier =
            "\(web.identity.managedResourceIdentifier)-generation-2"
        let baseHint = ownershipHint(web, index: 0)
        let hint = RuntimeOwnedResourceHint(
            resourceIdentifier: updatedIdentifier,
            identity: web.identity,
            identityVersion: baseHint.identityVersion,
            ownership: baseHint.ownership
        )
        let observedWeb = ObservedRuntimeService(
            identity: web.identity,
            resourceIdentifier: updatedIdentifier,
            image: web.image,
            lifecycleState: .running,
            healthState: .healthy,
            ports: web.ports,
            mounts: web.mounts
        )

        let plan = try planner().plan(
            desired: state([web], hints: [hint]),
            observed: observation([observedWeb]),
            previousDesired: state([web], hints: [hint]),
            mode: .remove
        )

        XCTAssertEqual(
            Set(plan.nodes.map(\.resourceIdentifier)),
            [updatedIdentifier]
        )
        XCTAssertEqual(
            Set(plan.nodes.map(\.action)),
            [.stop, .delete]
        )
    }

    func testDownStopsDependentsBeforeDependencies() throws {
        let db = service("db")
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ]
        )
        let desired = ownedState([db, web])

        let plan = try planner().plan(
            desired: desired,
            observed: observation([
                observed(db, lifecycle: .running, health: .healthy),
                observed(web, lifecycle: .running, health: .healthy)
            ]),
            mode: .down
        )

        let stopDB = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("stop", db) }
        )
        XCTAssertEqual(stopDB.dependencies, [nodeKey("stop", web)])
        XCTAssertEqual(
            plan.waves.map { $0.nodes.map(\.key) },
            [[nodeKey("stop", web)], [nodeKey("stop", db)]]
        )
    }

    func testDownUsesCurrentDependenciesWhenPreviousRevisionLacksDependent() throws {
        let db = service("db")
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ]
        )
        let current = ownedState([db, web])
        let previous = ownedState([db])

        let plan = try planner().plan(
            desired: current,
            observed: observation([
                observed(db, lifecycle: .running, health: .healthy),
                observed(web, lifecycle: .running, health: .healthy)
            ]),
            previousDesired: previous,
            mode: .down
        )

        let stopDB = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("stop", db) }
        )
        XCTAssertEqual(stopDB.dependencies, [nodeKey("stop", web)])
        XCTAssertEqual(
            plan.waves.map { $0.nodes.map(\.key) },
            [[nodeKey("stop", web)], [nodeKey("stop", db)]]
        )
    }

    func testRemoveDeletesDependentsBeforeDependencies() throws {
        let db = service("db")
        let web = service(
            "web",
            dependencies: [
                RuntimeServiceDependency(serviceName: "db", condition: .started)
            ]
        )
        let desired = ownedState([db, web])

        let plan = try planner().plan(
            desired: desired,
            observed: observation([
                observed(web, lifecycle: .stopped, health: .notConfigured),
                observed(db, lifecycle: .stopped, health: .notConfigured)
            ]),
            mode: .remove
        )

        let deleteDB = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("delete", db) }
        )
        XCTAssertEqual(deleteDB.dependencies, [nodeKey("delete", web)])
        XCTAssertEqual(
            plan.waves.map { $0.nodes.map(\.key) },
            [[nodeKey("delete", web)], [nodeKey("delete", db)]]
        )
    }

    func testScaleDownDeletesOnlyRemovedOwnedReplicaAfterConvergence() throws {
        let primary = service("web", replicaIndex: 0)
        let second = service("web", replicaIndex: 1)
        let current = ownedState([primary])
        let previous = ownedState([primary, second])

        let plan = try planner().plan(
            desired: current,
            observed: observation([
                observed(primary, lifecycle: .running, health: .notConfigured),
                observed(second, lifecycle: .running, health: .notConfigured)
            ]),
            previousDesired: previous
        )

        XCTAssertEqual(
            Set(plan.nodes.map(\.key)),
            [nodeKey("stop", second), nodeKey("delete", second)]
        )
        XCTAssertFalse(plan.nodes.contains { $0.identity == primary.identity })
        let deleteSecond = try XCTUnwrap(
            plan.nodes.first { $0.key == nodeKey("delete", second) }
        )
        XCTAssertEqual(deleteSecond.dependencies, [nodeKey("stop", second)])
    }

    func testInferredOwnedScaleDownTargetIsNotReportedAsUntouched() throws {
        let primary = service("web", replicaIndex: 0)
        let second = service("web", replicaIndex: 1)
        let desired = state(
            [primary],
            hints: [
                ownershipHint(primary, index: 0),
                ownershipHint(second, index: 1)
            ]
        )

        let plan = try planner().plan(
            desired: desired,
            observed: observation([
                observed(primary, lifecycle: .running, health: .notConfigured),
                observed(second, lifecycle: .running, health: .notConfigured)
            ])
        )

        XCTAssertTrue(plan.untouchedObservedResourceIdentifiers.isEmpty)
        XCTAssertTrue(plan.nodes.contains { $0.key == nodeKey("delete", second) })
    }

    func testUnrelatedObservedServiceIsReportedAndNeverMutated() throws {
        let web = service("web")
        let sentinel = service("sentinel")
        let sentinelObserved = observed(
            sentinel,
            lifecycle: .running,
            health: .notConfigured
        )

        let plan = try planner().plan(
            desired: state([web]),
            observed: observation([sentinelObserved])
        )

        XCTAssertEqual(
            plan.untouchedObservedResourceIdentifiers,
            [sentinel.identity.managedResourceIdentifier]
        )
        XCTAssertFalse(plan.nodes.contains { $0.identity == sentinel.identity })
    }

    func testDuplicateObservedIdentityFailsClosed() throws {
        let web = service("web")
        let first = observed(web, lifecycle: .running, health: .notConfigured)
        let duplicate = ObservedRuntimeService(
            identity: web.identity,
            resourceIdentifier: web.identity.managedResourceIdentifier + "-duplicate",
            lifecycleState: .running,
            healthState: .notConfigured
        )

        XCTAssertThrowsError(
            try planner().plan(
                desired: ownedState([web]),
                observed: observation([first, duplicate])
            )
        ) { error in
            XCTAssertEqual(
                error as? MultiServiceReconciliationError,
                .duplicateObservedIdentity(web.identity.displayName)
            )
        }
    }

    func testInvalidParallelismIsRejectedAtConstruction() {
        XCTAssertThrowsError(try MultiServiceReconciliationPlanner(parallelism: 0)) {
            XCTAssertEqual(
                $0 as? MultiServiceReconciliationError,
                .invalidParallelism(0)
            )
        }
        XCTAssertThrowsError(
            try MultiServiceReconciliationPlanner(
                parallelism: MultiServiceReconciliationPlanner.maximumParallelism + 1
            )
        ) {
            XCTAssertEqual(
                $0 as? MultiServiceReconciliationError,
                .invalidParallelism(33)
            )
        }
    }

    private func planner() throws -> MultiServiceReconciliationPlanner {
        try MultiServiceReconciliationPlanner()
    }

    private func service(
        _ name: String,
        replicaIndex: Int = 0,
        dependencies: [RuntimeServiceDependency] = [],
        healthCheck: RuntimeHealthCheckSpec? = nil,
        probes: RuntimeProbeSet = RuntimeProbeSet(),
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks(),
        ports: [RuntimePortMapping] = [],
        mounts: [RuntimeMountReference] = [],
        command: [String] = []
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: name,
                instanceName: replicaIndex == 0 ? nil : "replica-\(replicaIndex)"
            ),
            logicalServiceName: name,
            replicaIndex: replicaIndex,
            image: "example.invalid/\(name)@sha256:" + String(repeating: "a", count: 64),
            command: command,
            dependencies: dependencies,
            ports: ports,
            mounts: mounts,
            healthCheck: healthCheck,
            probes: probes,
            hooks: hooks
        )
    }

    private func allProbes() -> RuntimeProbeSet {
        RuntimeProbeSet(
            startup: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/startup"]))
            ),
            readiness: RuntimeProbeConfiguration(
                action: .tcp(RuntimeProbeTCPAction(port: 8080))
            ),
            liveness: RuntimeProbeConfiguration(
                action: .http(RuntimeProbeHTTPAction(port: 8080, path: "/health"))
            )
        )
    }

    private func state(
        _ services: [DesiredRuntimeService],
        hints: [RuntimeOwnedResourceHint] = []
    ) -> DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: services,
            ownedResourceHints: hints
        )
    }

    private func ownedState(
        _ services: [DesiredRuntimeService]
    ) -> DesiredRuntimeState {
        state(services, hints: services.enumerated().map { index, service in
            ownershipHint(service, index: index)
        })
    }

    private func ownershipHint(
        _ service: DesiredRuntimeService,
        index: Int
    ) -> RuntimeOwnedResourceHint {
        let suffix = String(format: "%012d", index + 1)
        return RuntimeOwnedResourceHint(
            resourceIdentifier: service.identity.managedResourceIdentifier,
            identity: service.identity,
            identityVersion: RuntimeManagedResourceIdentity.currentVersion,
            ownership: RuntimeInventoryOwnershipEvidence(
                resourceUUID: "10000000-0000-4000-8000-\(suffix)",
                projectUUID: "20000000-0000-4000-8000-000000000001",
                resourceGeneration: 1,
                projectGeneration: 1,
                providerID: .appleContainerCLI,
                providerGeneration: 1,
                fencingToken: "30000000-0000-4000-8000-\(suffix)"
            )
        )
    }

    private func observed(
        _ service: DesiredRuntimeService,
        lifecycle: RuntimeLifecycleState,
        health: RuntimeHealthState
    ) -> ObservedRuntimeService {
        ObservedRuntimeService(
            identity: service.identity,
            resourceIdentifier: service.identity.managedResourceIdentifier,
            image: service.image,
            lifecycleState: lifecycle,
            healthState: health,
            ports: service.ports,
            mounts: service.mounts
        )
    }

    private func observation(
        _ services: [ObservedRuntimeService]
    ) -> ObservedRuntimeState {
        ObservedRuntimeState(projectName: "demo", services: services)
    }

    private func nodeKey(
        _ action: String,
        _ service: DesiredRuntimeService
    ) -> String {
        "\(action)-\(service.identity.managedResourceIdentifier)"
    }

    private func condition(
        _ kind: String,
        _ service: DesiredRuntimeService,
        _ expectedValue: String
    ) -> LifecyclePlanCondition {
        LifecyclePlanCondition(
            kind: kind,
            subject: service.identity.managedResourceIdentifier,
            expectedValue: expectedValue
        )
    }
}
