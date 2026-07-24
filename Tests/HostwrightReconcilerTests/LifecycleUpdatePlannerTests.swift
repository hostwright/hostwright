import XCTest
@testable import HostwrightCore
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightSecrets

final class LifecycleUpdatePlannerTests: XCTestCase {
    func testRollingPlanIsDeterministicAndRetainsOldRevisionUntilPromotion() throws {
        let previous = replicas(
            serviceName: "web",
            count: 3,
            image: "local/web@sha256:old",
            policy: RuntimeUpdatePolicy(
                strategy: .rolling,
                maxSurge: 1,
                maxUnavailable: 0,
                progressDeadlineSeconds: 120
            )
        )
        let desired = replicas(
            serviceName: "web",
            count: 3,
            image: "local/web@sha256:new",
            policy: previous[0].updatePolicy
        )
        let resources = resourceMap(for: desired)

        let first = try LifecycleUpdatePlanner().plan(
            previous: state(previous),
            desired: state(desired.reversed()),
            resources: resources,
            fencingToken: fence
        )
        let second = try LifecycleUpdatePlanner().plan(
            previous: state(previous.reversed()),
            desired: state(desired),
            resources: resources,
            fencingToken: fence
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.servicePlans.count, 1)
        XCTAssertEqual(first.servicePlans[0].mode, .rolling)
        XCTAssertEqual(first.servicePlans[0].modeReason, .requestedRolling)
        XCTAssertFalse(first.servicePlans[0].availabilityImpact.requiresDowntime)
        XCTAssertEqual(first.servicePlans[0].availabilityImpact.maximumTemporaryCapacity, 4)
        XCTAssertTrue(
            first.nodes.allSatisfy { node in
                let deadlines = node.preconditions.filter {
                    $0.kind == "progress-deadline-seconds"
                }
                return deadlines.count == 1 &&
                    deadlines[0].expectedValue == "120"
            }
        )

        for service in desired {
            let promote = try XCTUnwrap(
                first.nodes.first { $0.key == key(service, "promote") }
            )
            let quiesce = try XCTUnwrap(
                first.nodes.first { $0.key == key(service, "quiesce") }
            )
            let retire = try XCTUnwrap(
                first.nodes.first { $0.key == key(service, "retire") }
            )
            XCTAssertEqual(promote.compensation?.action, .stop)
            XCTAssertEqual(quiesce.dependencies, [promote.key])
            XCTAssertEqual(quiesce.action, .stop)
            XCTAssertEqual(quiesce.compensation?.action, .start)
            XCTAssertEqual(retire.dependencies, [quiesce.key])
            XCTAssertEqual(retire.action, .retire)
            XCTAssertEqual(retire.compensation?.action, .create)
            XCTAssertTrue(
                retire.preconditions.contains {
                    $0.kind == "candidate-promoted" && $0.expectedValue == "true"
                }
            )
            XCTAssertTrue(
                retire.preconditions.contains {
                    $0.kind == "old-revision-verified-healthy" &&
                        $0.expectedValue ==
                            (try? LifecycleRevisionCodec.revisionSHA256(
                                for: previous[service.replicaIndex]
                            ))
                }
            )
        }
        let secondPrepare = try XCTUnwrap(
            first.nodes.first { $0.key == key(desired[1], "prepare") }
        )
        XCTAssertTrue(secondPrepare.dependencies.contains(key(desired[0], "retire")))
    }

    func testRollingSurgeStopsExactOldResourceBeforeRetireAndCompensatesInReverse() throws {
        let policy = RuntimeUpdatePolicy(
            strategy: .rolling,
            maxSurge: 1,
            maxUnavailable: 0,
            progressDeadlineSeconds: 120
        )
        let previous = service(
            "web",
            image: "local/web@sha256:old",
            policy: policy
        )
        let desired = service(
            "web",
            image: "local/web@sha256:new",
            policy: policy
        )
        let resource = try XCTUnwrap(resourceMap(for: [desired])[desired.identity])
        let plan = try LifecycleUpdatePlanner().plan(
            previous: state([previous]),
            desired: state([desired]),
            resources: [desired.identity: resource],
            fencingToken: fence
        )

        let promote = try XCTUnwrap(
            plan.nodes.first { $0.key == key(desired, "promote") }
        )
        let stopOld = try XCTUnwrap(
            plan.nodes.first { $0.key == key(desired, "quiesce") }
        )
        let retire = try XCTUnwrap(
            plan.nodes.first { $0.key == key(desired, "retire") }
        )

        XCTAssertEqual(stopOld.action, .stop)
        XCTAssertEqual(stopOld.resourceIdentifier, resource.currentResourceIdentifier)
        XCTAssertEqual(stopOld.resourceUUID, resource.currentResourceUUID)
        XCTAssertEqual(stopOld.resourceGeneration, resource.currentGeneration)
        XCTAssertEqual(stopOld.dependencies, [promote.key])
        XCTAssertEqual(stopOld.compensation?.action, .start)
        XCTAssertTrue(
            stopOld.postconditions.contains {
                $0.kind == "lifecycle" &&
                    $0.subject == previous.identity.displayName &&
                    $0.expectedValue == "stopped"
            }
        )
        XCTAssertEqual(retire.dependencies, [stopOld.key])
        XCTAssertEqual(retire.resourceIdentifier, resource.currentResourceIdentifier)
        XCTAssertEqual(retire.resourceUUID, resource.currentResourceUUID)
        XCTAssertEqual(retire.compensation?.action, .create)
        XCTAssertEqual(
            [stopOld, retire].reversed().compactMap { $0.compensation?.action },
            [.create, .start]
        )
        XCTAssertLessThan(
            try XCTUnwrap(plan.nodes.firstIndex { $0.key == promote.key }),
            try XCTUnwrap(plan.nodes.firstIndex { $0.key == stopOld.key })
        )
        XCTAssertLessThan(
            try XCTUnwrap(plan.nodes.firstIndex { $0.key == stopOld.key }),
            try XCTUnwrap(plan.nodes.firstIndex { $0.key == retire.key })
        )
    }

    func testZeroSurgeBoundsUnavailableReplicasAndKeepsStoppedOldResource() throws {
        let policy = RuntimeUpdatePolicy(
            strategy: .rolling,
            maxSurge: 0,
            maxUnavailable: 1,
            progressDeadlineSeconds: 90
        )
        let previous = replicas(
            serviceName: "api",
            count: 3,
            image: "local/api@sha256:old",
            policy: policy
        )
        let desired = replicas(
            serviceName: "api",
            count: 3,
            image: "local/api@sha256:new",
            policy: policy
        )

        let plan = try LifecycleUpdatePlanner().plan(
            previous: state(previous),
            desired: state(desired),
            resources: resourceMap(for: desired),
            fencingToken: fence
        )

        let secondQuiesce = try XCTUnwrap(
            plan.nodes.first { $0.key == key(desired[1], "quiesce") }
        )
        XCTAssertTrue(secondQuiesce.dependencies.contains(key(desired[0], "promote")))
        XCTAssertEqual(secondQuiesce.compensation?.action, .start)

        for service in desired {
            let create = try XCTUnwrap(
                plan.nodes.first { $0.key == key(service, "create") }
            )
            XCTAssertTrue(create.dependencies.contains(key(service, "quiesce")))
            let retire = try XCTUnwrap(
                plan.nodes.first { $0.key == key(service, "retire") }
            )
            XCTAssertTrue(retire.dependencies.contains(key(service, "promote")))
        }
        XCTAssertEqual(plan.servicePlans[0].availabilityImpact.minimumAvailable, 2)
        XCTAssertFalse(plan.servicePlans[0].availabilityImpact.requiresDowntime)
    }

    func testFixedHostPortSelectsExplicitRecreateImpactAndQuiescesAllFirst() throws {
        let policy = RuntimeUpdatePolicy(
            strategy: .rolling,
            maxSurge: 1,
            maxUnavailable: 0,
            progressDeadlineSeconds: 120
        )
        let port = RuntimePortMapping(hostPort: 8080, containerPort: 80)
        let previous = replicas(
            serviceName: "web",
            count: 2,
            image: "local/web@sha256:old",
            policy: policy,
            ports: [port]
        )
        let desired = replicas(
            serviceName: "web",
            count: 2,
            image: "local/web@sha256:new",
            policy: policy,
            ports: [port]
        )

        let plan = try LifecycleUpdatePlanner().plan(
            previous: state(previous),
            desired: state(desired),
            resources: resourceMap(for: desired),
            fencingToken: fence
        )

        let servicePlan = try XCTUnwrap(plan.servicePlans.first)
        XCTAssertEqual(servicePlan.mode, .recreate)
        XCTAssertEqual(servicePlan.modeReason, .exclusiveHostPort)
        XCTAssertTrue(servicePlan.availabilityImpact.requiresDowntime)
        XCTAssertEqual(servicePlan.availabilityImpact.minimumAvailable, 0)
        XCTAssertTrue(servicePlan.availabilityImpact.summary.contains("fixed host ports"))
        let allQuiesce = Set(desired.map { key($0, "quiesce") })
        for service in desired {
            let create = try XCTUnwrap(
                plan.nodes.first { $0.key == key(service, "create") }
            )
            XCTAssertTrue(allQuiesce.isSubset(of: Set(create.dependencies)))
        }
    }

    func testChangedDependencyRevisionIsPromotedBeforeDependentPrepare() throws {
        let policy = RuntimeUpdatePolicy(
            strategy: .rolling,
            maxSurge: 1,
            maxUnavailable: 0,
            progressDeadlineSeconds: 120
        )
        let oldDB = service(
            "db",
            image: "local/db@sha256:old",
            policy: policy
        )
        let newDB = service(
            "db",
            image: "local/db@sha256:new",
            policy: policy
        )
        let dependency = RuntimeServiceDependency(
            serviceName: "db",
            condition: .ready
        )
        let oldWeb = service(
            "web",
            image: "local/web@sha256:old",
            policy: policy,
            dependencies: [dependency]
        )
        let newWeb = service(
            "web",
            image: "local/web@sha256:new",
            policy: policy,
            dependencies: [dependency]
        )
        let desired = [newWeb, newDB]

        let plan = try LifecycleUpdatePlanner().plan(
            previous: state([oldWeb, oldDB]),
            desired: state(desired),
            resources: resourceMap(for: desired),
            fencingToken: fence
        )

        let prepareWeb = try XCTUnwrap(
            plan.nodes.first { $0.key == key(newWeb, "prepare") }
        )
        XCTAssertTrue(prepareWeb.dependencies.contains(key(newDB, "promote")))
        XCTAssertTrue(
            prepareWeb.preconditions.contains {
                $0.kind == "dependency-ready" &&
                    $0.subject == "demo/db" &&
                    $0.expectedValue == "true"
            }
        )
        XCTAssertLessThan(
            try XCTUnwrap(plan.nodes.firstIndex { $0.key == key(newDB, "promote") }),
            try XCTUnwrap(plan.nodes.firstIndex { $0.key == key(newWeb, "prepare") })
        )
    }

    func testResumeSkipsExactlyCheckpointedIdempotencyKeys() throws {
        let old = service("web", image: "local/web@sha256:old")
        let new = service("web", image: "local/web@sha256:new")
        let plan = try LifecycleUpdatePlanner().plan(
            previous: state([old]),
            desired: state([new]),
            resources: resourceMap(for: [new]),
            fencingToken: fence
        )
        let completed = Set(plan.nodes.prefix(4).map(\.idempotencyKey))

        let resumed = plan.resume(completedNodeIdempotencyKeys: completed)

        XCTAssertEqual(resumed.satisfiedNodeKeys, plan.nodes.prefix(4).map(\.key).sorted())
        XCTAssertFalse(
            resumed.pendingNodes.contains {
                completed.contains($0.idempotencyKey)
            }
        )
        XCTAssertEqual(
            resumed.pendingNodes.map(\.idempotencyKey),
            Array(plan.nodes.dropFirst(4)).map(\.idempotencyKey)
        )
    }

    func testRevisionRecordRedactsResolvedSecretValuesDeterministically() throws {
        let reference = try HostwrightSecretReference(
            service: "hostwright",
            account: "database"
        )
        let first = service(
            "web",
            image: "local/web@sha256:new",
            environment: [
                RuntimeEnvironmentValue(
                    name: "DATABASE_PASSWORD",
                    value: "resolved-secret-one",
                    isSensitive: true,
                    secretReference: reference
                )
            ]
        )
        let second = service(
            "web",
            image: "local/web@sha256:new",
            environment: [
                RuntimeEnvironmentValue(
                    name: "DATABASE_PASSWORD",
                    value: "resolved-secret-two",
                    isSensitive: true,
                    secretReference: reference
                )
            ]
        )

        let firstJSON = try LifecycleRevisionCodec.redactedDesiredJSON(for: first)
        let secondJSON = try LifecycleRevisionCodec.redactedDesiredJSON(for: second)

        XCTAssertEqual(firstJSON, secondJSON)
        XCTAssertFalse(firstJSON.contains("resolved-secret"))
        XCTAssertFalse(firstJSON.contains(reference.rawValue))
        XCTAssertTrue(firstJSON.contains("[REDACTED]"))
        XCTAssertEqual(
            try LifecycleRevisionCodec.revisionSHA256(for: first),
            try LifecycleRevisionCodec.revisionSHA256(for: second)
        )

        let otherReference = try HostwrightSecretReference(
            service: "hostwright",
            account: "database-next"
        )
        let changedReference = service(
            "web",
            image: "local/web@sha256:new",
            environment: [
                RuntimeEnvironmentValue(
                    name: "DATABASE_PASSWORD",
                    value: "resolved-secret-one",
                    isSensitive: true,
                    secretReference: otherReference
                )
            ]
        )
        XCTAssertNotEqual(
            try LifecycleRevisionCodec.revisionSHA256(for: first),
            try LifecycleRevisionCodec.revisionSHA256(for: changedReference)
        )

        let decoded = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(firstJSON)
        let decodedEntry = try XCTUnwrap(decoded.environment.first)
        XCTAssertEqual(
            decodedEntry.value,
            RuntimeRedactionPolicy.default.replacement
        )
        XCTAssertTrue(decodedEntry.isSensitive)
        XCTAssertNil(decodedEntry.secretReference)
        XCTAssertFalse(decoded.environment.description.contains("resolved-secret"))
        XCTAssertFalse(decoded.environment.description.contains(reference.rawValue))
    }

    func testRevisionCodecRoundTripPreservesEveryNonSecretExecutableField() throws {
        let original = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "worker",
                instanceName: "replica-2"
            ),
            logicalServiceName: "worker",
            replicaIndex: 2,
            image: "local/worker@sha256:1234",
            platformOperatingSystem: "linux",
            platformArchitecture: "amd64",
            cpuCount: 4,
            memoryBytes: 3_221_225_472,
            userID: 1_001,
            groupID: 1_002,
            workingDirectory: "/srv/worker",
            entrypoint: ["/usr/bin/env"],
            command: ["worker", "--serve"],
            initProcess: true,
            dependencies: [
                RuntimeServiceDependency(serviceName: "cache", condition: .started),
                RuntimeServiceDependency(serviceName: "db", condition: .ready)
            ],
            environment: [
                RuntimeEnvironmentValue(name: "MODE", value: "production"),
                RuntimeEnvironmentValue(name: "WORKERS", value: "4")
            ],
            labels: ["com.example.role": "worker", "tier": "backend"],
            ports: [
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 9000,
                    protocolName: .tcp,
                    bindAddress: nil
                ),
                RuntimePortMapping(
                    hostPort: 8443,
                    containerPort: 9443,
                    protocolName: .udp,
                    bindAddress: "127.0.0.1"
                )
            ],
            mounts: [
                RuntimeMountReference(
                    source: "/tmp/cache",
                    target: "/cache",
                    access: .readWrite
                ),
                RuntimeMountReference(
                    source: "/tmp/config",
                    target: "/config",
                    access: .readOnly
                )
            ],
            healthCheck: RuntimeHealthCheckSpec(
                command: ["/bin/health"],
                intervalSeconds: 11,
                timeoutSeconds: 7
            ),
            probes: RuntimeProbeSet(
                startup: RuntimeProbeConfiguration(
                    action: .exec(
                        RuntimeProbeExecAction(command: ["/bin/startup"])
                    ),
                    startPeriodSeconds: 2,
                    intervalSeconds: 3,
                    timeoutSeconds: 4,
                    successThreshold: 1,
                    failureThreshold: 5
                ),
                readiness: RuntimeProbeConfiguration(
                    action: .http(
                        RuntimeProbeHTTPAction(port: 9000, path: "/ready")
                    ),
                    startPeriodSeconds: 6,
                    intervalSeconds: 7,
                    timeoutSeconds: 8,
                    successThreshold: 2,
                    failureThreshold: 3
                ),
                liveness: RuntimeProbeConfiguration(
                    action: .tcp(RuntimeProbeTCPAction(port: 9000)),
                    startPeriodSeconds: 9,
                    intervalSeconds: 10,
                    timeoutSeconds: 11,
                    successThreshold: 1,
                    failureThreshold: 4
                )
            ),
            restartPolicy: .unlessStopped,
            updatePolicy: RuntimeUpdatePolicy(
                strategy: .recreate,
                maxSurge: 0,
                maxUnavailable: 1,
                progressDeadlineSeconds: 123
            ),
            hooks: RuntimeLifecycleHooks(
                postStart: ["/bin/post-start"],
                preStop: ["/bin/pre-stop"]
            ),
            rosetta: true,
            virtualization: false,
            readOnlyRootFilesystem: true,
            sharedMemoryBytes: 67_108_864
        )

        let encoded = try LifecycleRevisionCodec.redactedDesiredJSON(for: original)
        let decoded = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(
            try LifecycleRevisionCodec.redactedDesiredJSON(for: decoded),
            encoded
        )
        XCTAssertEqual(
            try LifecycleRevisionCodec.revisionSHA256(for: decoded),
            try LifecycleRevisionCodec.revisionSHA256(for: original)
        )
    }

    func testRevisionCodecRejectsMalformedUnknownMissingAndWrongTypedData() throws {
        let reference = try HostwrightSecretReference(
            service: "hostwright",
            account: "token"
        )
        let service = service(
            "web",
            image: "local/web@sha256:new",
            environment: [
                RuntimeEnvironmentValue(
                    name: "TOKEN",
                    value: "resolved-value",
                    isSensitive: true,
                    secretReference: reference
                )
            ]
        )
        let valid = try LifecycleRevisionCodec.redactedDesiredJSON(for: service)

        XCTAssertEqual(
            try failure(from: "{"),
            .invalidJSON
        )
        XCTAssertEqual(
            try failure(from: " \(valid)"),
            .nonCanonicalJSON
        )
        XCTAssertEqual(
            try failure(from: mutate(valid) { $0["future"] = true }),
            .unknownField("future")
        )
        XCTAssertEqual(
            try failure(from: mutate(valid) { $0.removeValue(forKey: "image") }),
            .missingField("image")
        )
        XCTAssertEqual(
            try failure(from: mutate(valid) { $0["replicaIndex"] = "zero" }),
            .invalidField("replicaIndex")
        )
        XCTAssertEqual(
            try failure(
                from: mutate(valid) {
                    var identity = try XCTUnwrap($0["identity"] as? [String: Any])
                    identity["future"] = true
                    $0["identity"] = identity
                }
            ),
            .unknownField("identity.future")
        )
        XCTAssertEqual(
            try failure(
                from: mutate(valid) {
                    var environment = try XCTUnwrap(
                        $0["environment"] as? [[String: Any]]
                    )
                    environment[0]["value"] = "not-redacted"
                    $0["environment"] = environment
                }
            ),
            .invalidField("environment.value")
        )
        XCTAssertEqual(
            try failure(
                from: mutate(valid) {
                    var environment = try XCTUnwrap(
                        $0["environment"] as? [[String: Any]]
                    )
                    environment[0].removeValue(forKey: "referenceDigest")
                    $0["environment"] = environment
                }
            ),
            .invalidField("environment.reference")
        )
    }

    func testInvalidResourceGenerationFailsBeforePlanNodesAreReturned() throws {
        let old = service("web", image: "local/web@sha256:old")
        let new = service("web", image: "local/web@sha256:new")
        let currentUUID = resourceUUID(new, suffix: "current")
        let invalid = LifecycleUpdateResourceIdentity(
            identity: new.identity,
            currentResourceIdentifier: "hostwright-demo-web-old",
            currentResourceUUID: currentUUID,
            currentGeneration: 2,
            candidateResourceIdentifier: "hostwright-demo-web-new",
            candidateResourceUUID: resourceUUID(new, suffix: "candidate"),
            candidateGeneration: 4
        )

        XCTAssertThrowsError(
            try LifecycleUpdatePlanner().plan(
                previous: state([old]),
                desired: state([new]),
                resources: [new.identity: invalid],
                fencingToken: fence
            )
        ) { error in
            XCTAssertEqual(
                error as? LifecycleUpdatePlanningError,
                .invalidResourceIdentity(new.identity.displayName)
            )
        }
    }

    private var fence: String {
        HostwrightResourceUUID.legacy(
            kind: "update-fence",
            identifier: "phase04"
        )
    }

    private func state<S: Sequence>(
        _ services: S
    ) -> DesiredRuntimeState where S.Element == DesiredRuntimeService {
        DesiredRuntimeState(projectName: "demo", services: Array(services))
    }

    private func replicas(
        serviceName: String,
        count: Int,
        image: String,
        policy: RuntimeUpdatePolicy,
        ports: [RuntimePortMapping] = []
    ) -> [DesiredRuntimeService] {
        (0..<count).map {
            service(
                serviceName,
                replicaIndex: $0,
                image: image,
                policy: policy,
                ports: ports
            )
        }
    }

    private func service(
        _ name: String,
        replicaIndex: Int = 0,
        image: String,
        policy: RuntimeUpdatePolicy = RuntimeUpdatePolicy(),
        dependencies: [RuntimeServiceDependency] = [],
        environment: [RuntimeEnvironmentValue] = [],
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks(),
        ports: [RuntimePortMapping] = []
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: name,
                instanceName: replicaIndex == 0 ? nil : "replica-\(replicaIndex)"
            ),
            logicalServiceName: name,
            replicaIndex: replicaIndex,
            image: image,
            dependencies: dependencies,
            environment: environment,
            ports: ports,
            probes: RuntimeProbeSet(
                startup: RuntimeProbeConfiguration(
                    action: .exec(RuntimeProbeExecAction(command: ["/bin/ready"]))
                ),
                readiness: RuntimeProbeConfiguration(
                    action: .tcp(RuntimeProbeTCPAction(port: 8080))
                )
            ),
            updatePolicy: policy,
            hooks: hooks,
            virtualization: false
        )
    }

    private func resourceMap(
        for services: [DesiredRuntimeService]
    ) -> [RuntimeServiceIdentity: LifecycleUpdateResourceIdentity] {
        Dictionary(
            uniqueKeysWithValues: services.map { service in
                (
                    service.identity,
                    LifecycleUpdateResourceIdentity(
                        identity: service.identity,
                        currentResourceIdentifier:
                            "\(service.identity.managedResourceIdentifier)-old",
                        currentResourceUUID: resourceUUID(service, suffix: "current"),
                        currentGeneration: 1,
                        candidateResourceIdentifier:
                            "\(service.identity.managedResourceIdentifier)-candidate",
                        candidateResourceUUID: resourceUUID(service, suffix: "candidate"),
                        candidateGeneration: 2
                    )
                )
            }
        )
    }

    private func resourceUUID(
        _ service: DesiredRuntimeService,
        suffix: String
    ) -> String {
        HostwrightResourceUUID.legacy(
            kind: "service-revision",
            identifier: "\(service.identity.displayName):\(suffix)"
        )
    }

    private func key(
        _ service: DesiredRuntimeService,
        _ phase: String
    ) -> String {
        "update-\(service.logicalServiceName)-r\(service.replicaIndex)-\(phase)"
    }

    private func failure(
        from json: String
    ) throws -> LifecycleRevisionCodecError {
        do {
            _ = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(json)
            XCTFail("Expected revision decoding to fail.")
            return .invalidJSON
        } catch let error as LifecycleRevisionCodecError {
            return error
        }
    }

    private func mutate(
        _ json: String,
        _ body: (inout [String: Any]) throws -> Void
    ) throws -> String {
        let data = try XCTUnwrap(json.data(using: .utf8))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try body(&object)
        let mutated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try XCTUnwrap(String(data: mutated, encoding: .utf8))
    }
}
