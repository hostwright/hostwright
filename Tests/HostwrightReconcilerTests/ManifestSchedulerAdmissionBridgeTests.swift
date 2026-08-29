import XCTest
@testable import HostwrightManifest
@testable import HostwrightPolicy
@testable import HostwrightReconciler
@testable import HostwrightScheduler
@testable import HostwrightControlPlane

final class ManifestSchedulerAdmissionBridgeTests: XCTestCase {
    private static let executableResources = HostwrightResources(
        requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
        limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
    )

    func testMissingResourcesCannotBecomeZeroChargeAdmission() {
        let manifest = HostwrightManifest(
            version: 3,
            project: "demo",
            services: [HostwrightService(name: "api", image: "local/demo:latest")]
        )

        XCTAssertThrowsError(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: manifest,
                subjectID: "owner"
            )
        ) { error in
            let admissionError = error as? ManifestSchedulerAdmissionError
            XCTAssertTrue(admissionError?.stableKey.contains("resources") == true)
        }
    }

    func testRequestsDrivePlacementAndLimitsRemainRuntimeEnforcementInput() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:latest",
            platform: HostwrightPlatform(architecture: .amd64),
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 2, memory: "1GiB")
            ),
            scheduling: HostwrightSchedulingPolicy(priority: 7),
            restart: HostwrightRestart(
                policy: "unless-stopped",
                maxAttempts: 3,
                priority: 99
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])

        let admission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: manifest,
                subjectID: "owner"
            ).first
        )

        XCTAssertEqual(admission.workload.request.values, [
            "cpu": 1,
            "memory": 512 * 1_024 * 1_024
        ])
        XCTAssertEqual(admission.workload.requirements.limit?.values, [
            "cpu": 2,
            "memory": 1_024 * 1_024 * 1_024
        ])
        XCTAssertEqual(admission.workload.priority, 7)
        XCTAssertEqual(admission.workload.requirements.requiredArchitectures, ["amd64"])
        XCTAssertEqual(admission.runtimeHardLimits.cpuCount, 2)
        XCTAssertEqual(admission.runtimeHardLimits.memoryBytes, 1_024 * 1_024 * 1_024)
    }

    func testSignedSchedulingPriorityIsPreservedAndRestartPriorityIsSeparate() throws {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(priority: -7),
            restart: HostwrightRestart(
                policy: "unless-stopped",
                maxAttempts: 1,
                priority: 99
            )
        )
        let admission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: HostwrightManifest(version: 3, project: "demo", services: [service]),
                subjectID: "owner"
            ).first
        )

        XCTAssertEqual(admission.workload.priority, -7)
        XCTAssertEqual(admission.workload.preemptionEligibility, .nonPreempting)
        XCTAssertEqual(service.restart?.priority, 99)
    }

    func testSchedulingPolicyMapsToNativeSchedulerRequirements() throws {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                requiredAffinity: [
                    HostwrightSchedulingSelector(
                        key: "zone", operator: .in, values: ["east"]
                    )
                ],
                requiredAntiAffinity: [
                    HostwrightSchedulingSelector(
                        key: "tier", operator: .in, values: ["batch"]
                    )
                ],
                topologySpread: [
                    HostwrightTopologySpread(
                        topologyKey: "zone",
                        maxSkew: 1,
                        whenUnsatisfiable: .scheduleAnyway
                    )
                ],
                tolerations: [
                    HostwrightSchedulingToleration(
                        key: "dedicated",
                        value: "batch",
                        effect: .noSchedule,
                        operator: .equals
                    )
                ]
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])

        let admission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: manifest,
                subjectID: "owner"
            ).first
        )

        XCTAssertTrue(admission.workload.requirements.affinity.requiredLabels.isEmpty)
        XCTAssertTrue(admission.workload.requirements.affinity.forbiddenLabels.isEmpty)
        XCTAssertEqual(
            admission.workload.requirements.affinity.requiredSelectors,
            [try SchedulerLabelSelector(key: "zone", operator: .in, values: ["east"])]
        )
        XCTAssertEqual(
            admission.workload.requirements.affinity.forbiddenSelectors,
            [try SchedulerLabelSelector(key: "tier", operator: .in, values: ["batch"])]
        )
        XCTAssertEqual(admission.workload.requirements.tolerations.count, 1)
        XCTAssertEqual(
            admission.workload.requirements.affinity.topologySpreads,
            [
                try SchedulerHardTopologySpread(
                    topologyKey: "zone",
                    maxSkew: 1,
                    whenUnsatisfiable: .scheduleAnyway,
                    groupID: "demo/worker"
                )
            ]
        )
        XCTAssertEqual(admission.workload.topology.spreadKey, "zone")
        XCTAssertEqual(admission.workload.topology.groupID, "demo/worker")
    }

    func testRequiredNotInPreservesNativeSelectorSemantics() throws {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                requiredAffinity: [
                    HostwrightSchedulingSelector(
                        key: "zone", operator: .notIn, values: ["west"]
                    )
                ]
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])

        let admission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: manifest,
                subjectID: "owner"
            ).first
        )

        XCTAssertTrue(admission.workload.requirements.affinity.requiredLabels.isEmpty)
        XCTAssertTrue(admission.workload.requirements.affinity.forbiddenLabels.isEmpty)
        XCTAssertEqual(
            admission.workload.requirements.affinity.requiredSelectors,
            [try SchedulerLabelSelector(key: "zone", operator: .notIn, values: ["west"])]
        )

        let evaluator = HardPlacementFilterEvaluator()
        let east = try snapshot(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!,
            labels: ["zone": "east"]
        )
        let west = try snapshot(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000022")!,
            labels: ["zone": "west"]
        )
        let missing = try snapshot(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000023")!
        )
        XCTAssertTrue(
            evaluator.evaluate(
                workload: admission.workload.requirements,
                on: east
            ).passed
        )
        let westResult = evaluator.evaluate(
            workload: admission.workload.requirements,
            on: west
        )
        XCTAssertFalse(westResult.passed)
        XCTAssertTrue(
            westResult.reasons.contains { $0.code == .requiredLabelMismatch }
        )
        XCTAssertFalse(
            evaluator.evaluate(
                workload: admission.workload.requirements,
                on: missing
            ).passed
        )
    }

    func testSelectorCrossProductMapsToNativeSchedulerSemantics() throws {
        let selectors: [HostwrightSchedulingSelector] = [
            HostwrightSchedulingSelector(key: "zone", operator: .in, values: ["east", "west"]),
            HostwrightSchedulingSelector(key: "zone", operator: .notIn, values: ["east", "west"]),
            HostwrightSchedulingSelector(key: "zone", operator: .exists),
            HostwrightSchedulingSelector(key: "zone", operator: .doesNotExist)
        ]

        for selector in selectors {
            let service = HostwrightService(
                name: "worker",
                image: "example.invalid/worker:latest",
                resources: Self.executableResources,
                scheduling: HostwrightSchedulingPolicy(requiredAffinity: [selector])
            )
            let admission = try XCTUnwrap(
                try ManifestSchedulerAdmissionBridge.map(
                    manifest: HostwrightManifest(version: 3, project: "demo", services: [service]),
                    subjectID: "owner"
                ).first
            )
            let mapped = try XCTUnwrap(
                admission.workload.requirements.affinity.requiredSelectors.first
            )
            XCTAssertEqual(mapped.key, selector.key)
            XCTAssertEqual(mapped.operator.rawValue, selector.operator.rawValue)
            XCTAssertEqual(mapped.values, selector.values.sorted())
            XCTAssertTrue(admission.workload.requirements.affinity.requiredLabels.isEmpty)
        }

        let antiAffinity = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                requiredAntiAffinity: [
                    HostwrightSchedulingSelector(
                        key: "zone", operator: .notIn, values: ["east", "west"]
                    )
                ]
            )
        )
        let antiAdmission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: HostwrightManifest(version: 3, project: "demo", services: [antiAffinity]),
                subjectID: "owner"
            ).first
        )
        XCTAssertEqual(
            antiAdmission.workload.requirements.affinity.forbiddenSelectors,
            [try SchedulerLabelSelector(key: "zone", operator: .notIn, values: ["east", "west"])]
        )
    }

    func testWeightedPreferredSelectorCrossProductPreservesOperatorsAndWeights() throws {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                preferredAffinity: [
                    HostwrightSchedulingPreference(
                        weight: 7,
                        match: HostwrightSchedulingSelector(
                            key: "zone",
                            operator: .in,
                            values: ["east", "west"]
                        )
                    ),
                    HostwrightSchedulingPreference(
                        weight: 8,
                        match: HostwrightSchedulingSelector(
                            key: "region",
                            operator: .exists
                        )
                    )
                ],
                preferredAntiAffinity: [
                    HostwrightSchedulingPreference(
                        weight: 9,
                        match: HostwrightSchedulingSelector(
                            key: "tier",
                            operator: .notIn,
                            values: ["batch"]
                        )
                    ),
                    HostwrightSchedulingPreference(
                        weight: 10,
                        match: HostwrightSchedulingSelector(
                            key: "dedicated",
                            operator: .doesNotExist
                        )
                    )
                ]
            )
        )
        let admission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: HostwrightManifest(
                    version: 3,
                    project: "demo",
                    services: [service]
                ),
                subjectID: "owner"
            ).first
        )

        let preferredAffinity = Dictionary(
            uniqueKeysWithValues: admission.workload.topology.preferredAffinity.map {
                ($0.selector.key, $0)
            }
        )
        XCTAssertEqual(preferredAffinity["zone"]?.weight, 7)
        XCTAssertEqual(preferredAffinity["zone"]?.selector.operator, .in)
        XCTAssertEqual(preferredAffinity["zone"]?.selector.values, ["east", "west"])
        XCTAssertEqual(preferredAffinity["region"]?.weight, 8)
        XCTAssertEqual(preferredAffinity["region"]?.selector.operator, .exists)
        XCTAssertEqual(preferredAffinity["region"]?.selector.values, [])

        let preferredAntiAffinity = Dictionary(
            uniqueKeysWithValues: admission.workload.topology.preferredAntiAffinity.map {
                ($0.selector.key, $0)
            }
        )
        XCTAssertEqual(preferredAntiAffinity["tier"]?.weight, 9)
        XCTAssertEqual(preferredAntiAffinity["tier"]?.selector.operator, .notIn)
        XCTAssertEqual(preferredAntiAffinity["tier"]?.selector.values, ["batch"])
        XCTAssertEqual(preferredAntiAffinity["dedicated"]?.weight, 10)
        XCTAssertEqual(preferredAntiAffinity["dedicated"]?.selector.operator, .doesNotExist)
        XCTAssertEqual(preferredAntiAffinity["dedicated"]?.selector.values, [])
    }

    func testPreemptionPolicyMapsToExplicitWorkloadOptIn() throws {
        let disabled = HostwrightService(
            name: "disabled",
            image: "example.invalid/disabled:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(preemption: .disabled)
        )
        let eligible = HostwrightService(
            name: "eligible",
            image: "example.invalid/eligible:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(preemption: .lowerPriority)
        )
        let admissions = try ManifestSchedulerAdmissionBridge.map(
            manifest: HostwrightManifest(
                version: 3,
                project: "demo",
                services: [disabled, eligible]
            ),
            subjectID: "owner"
        )

        XCTAssertEqual(
            admissions.first(where: { $0.serviceName == "disabled" })?.workload.preemptionEligibility,
            .nonPreempting
        )
        XCTAssertEqual(
            admissions.first(where: { $0.serviceName == "eligible" })?.workload.preemptionEligibility,
            .eligible
        )
    }

    func testInvalidSelectorValueCombinationHasStableManifestReason() {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                requiredAffinity: [
                    HostwrightSchedulingSelector(
                        key: "zone", operator: .exists, values: ["east"]
                    )
                ]
            )
        )

        XCTAssertThrowsError(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: HostwrightManifest(version: 3, project: "demo", services: [service]),
                subjectID: "owner"
            )
        ) { error in
            XCTAssertEqual(
                (error as? ManifestSchedulerAdmissionError)?.stableKey,
                "invalid-manifest:$:Service 'worker' scheduling.requiredAffinity exists and does-not-exist must not declare values."
            )
        }
    }

    func testWeightedSelectorBoundsFailBeforeProjectionWithStableReason() {
        for weight in [0, 101] {
            let service = HostwrightService(
                name: "worker",
                image: "example.invalid/worker:latest",
                resources: Self.executableResources,
                scheduling: HostwrightSchedulingPolicy(
                    preferredAffinity: [
                        HostwrightSchedulingPreference(
                            weight: weight,
                            match: HostwrightSchedulingSelector(
                                key: "zone",
                                operator: .in,
                                values: ["east"]
                            )
                        )
                    ]
                )
            )

            XCTAssertThrowsError(
                try ManifestSchedulerAdmissionBridge.map(
                    manifest: HostwrightManifest(
                        version: 3,
                        project: "demo",
                        services: [service]
                    ),
                    subjectID: "owner"
                )
            ) { error in
                XCTAssertEqual(
                    (error as? ManifestSchedulerAdmissionError)?.stableKey,
                    "invalid-manifest:$:Service 'worker' scheduling.preferredAffinity weight must be between 1 and 100."
                )
            }
        }
    }

    func testProviderAndAcceleratorClaimsMapToSchedulerAndRemainRuntimeBlocked() throws {
        let service = HostwrightService(
            name: "gpu",
            image: "example.invalid/gpu:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                provider: "provider-a",
                acceleratorClaims: [HostwrightAcceleratorClaim(name: "metal.gpu", count: 2)]
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])

        let admission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: manifest,
                subjectID: "owner"
            ).first
        )
        XCTAssertEqual(admission.workload.requirements.requiredProvider, "provider-a")
        XCTAssertEqual(admission.workload.requirements.acceleratorRequirements.values, ["metal.gpu": 2])
        let filterResult = HardPlacementFilterEvaluator().evaluate(
            workload: admission.workload.requirements,
            on: try snapshot(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000031")!,
                provider: "provider-b",
                accelerators: ["metal.gpu": 1]
            )
        )
        XCTAssertFalse(filterResult.passed)
        XCTAssertTrue(filterResult.reasons.contains { $0.code == .providerMismatch })
        XCTAssertTrue(filterResult.reasons.contains { $0.code == .acceleratorUnavailable })
        XCTAssertEqual(
            admission.runtimeAdmissionBlockers,
            [.acceleratorClaimsUnsupported, .providerClaimUnsupported]
        )
        XCTAssertThrowsError(try admission.requireRuntimeAdmission()) { error in
            XCTAssertEqual(
                (error as? ManifestSchedulerAdmissionError)?.stableKey,
                "unsupported-runtime-claims:scheduling.acceleratorClaims,scheduling.provider"
            )
        }
        XCTAssertThrowsError(
            try ManifestSchedulerAdmissionBridge.admit(
                manifest: manifest,
                subjectID: "owner"
            )
        ) { error in
            XCTAssertEqual(
                (error as? ManifestSchedulerAdmissionError)?.stableKey,
                "unsupported-runtime-claims:scheduling.acceleratorClaims,scheduling.provider"
            )
        }
    }

    func testDoNotScheduleTopologySpreadUsesNativeHardFilter() throws {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                topologySpread: [
                    HostwrightTopologySpread(
                        topologyKey: "zone",
                        maxSkew: 1,
                        whenUnsatisfiable: .doNotSchedule
                    )
                ]
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])
        let admission = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: manifest,
                subjectID: "owner"
            ).first
        )
        let eastID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let westID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let east = try node(id: eastID, zone: "east")
        let west = try node(id: westID, zone: "west")
        XCTAssertEqual(
            admission.workload.requirements.affinity.topologySpreads.map(\.whenUnsatisfiable),
            [.doNotSchedule]
        )
        let context = try HardTopologySpreadContext(
            nodeTopologyDomains: [
                eastID: ["zone": "east"],
                westID: ["zone": "west"]
            ],
            observations: [
                try HardTopologySpreadObservation(
                    workloadID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
                    nodeID: eastID,
                    groupID: "demo/worker"
                ),
                try HardTopologySpreadObservation(
                    workloadID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
                    nodeID: eastID,
                    groupID: "demo/worker"
                )
            ]
        )
        let evaluator = HardPlacementFilterEvaluator()
        let eastResult = evaluator.evaluate(
            workload: admission.workload.requirements,
            on: east.snapshot,
            topologyContext: context
        )
        XCTAssertFalse(eastResult.passed)
        XCTAssertTrue(
            eastResult.reasons.contains {
                $0.stableDetailKey.hasPrefix("topology-spread:zone:max-skew:1")
            }
        )

        let westResult = evaluator.evaluate(
            workload: admission.workload.requirements,
            on: west.snapshot,
            topologyContext: context
        )
        XCTAssertTrue(westResult.passed)

        let softService = HostwrightService(
            name: "soft",
            image: "example.invalid/soft:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                topologySpread: [
                    HostwrightTopologySpread(
                        topologyKey: "zone",
                        maxSkew: 1,
                        whenUnsatisfiable: .scheduleAnyway
                    )
                ]
            )
        )
        let soft = try XCTUnwrap(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: HostwrightManifest(version: 3, project: "demo", services: [softService]),
                subjectID: "owner"
            ).first
        )
        XCTAssertEqual(
            soft.workload.requirements.affinity.topologySpreads.map(\.whenUnsatisfiable),
            [.scheduleAnyway]
        )
        XCTAssertTrue(
            evaluator.evaluate(
                workload: soft.workload.requirements,
                on: east.snapshot,
                topologyContext: context
            ).passed
        )
    }

    func testProfileCeilingsAndPermissionsFailBeforeAdmission() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:latest",
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 2, memory: "1GiB")
            ),
            scheduling: HostwrightSchedulingPolicy(
                provider: "provider-b",
                acceleratorClaims: [HostwrightAcceleratorClaim(name: "neural")]
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])
        let profile = WorkloadProfile(
            identifier: "bounded",
            filesystem: FilesystemProfile(readOnlyRoot: true, denyHostRoot: true),
            network: NetworkProfile(mode: .isolated),
            resources: ResourceProfile(cpu: 1, memoryMiB: 512),
            secrets: SecretsProfile(),
            images: ImagesProfile(requireDigest: false, requireSignature: false),
            runtime: RuntimeProfile(allowedProviders: ["provider-a"]),
            hostAccess: HostAccessProfile(allowed: false),
            observability: ObservabilityProfile(logs: false, metrics: false, traces: false),
            accelerators: AcceleratorsProfile(allowed: ["gpu"]),
            syscalls: SyscallProfile(defaultDeny: false)
        )
        let resolution = WorkloadProfileResolution(
            profile: profile,
            profileSHA256: "profile",
            inheritance: ["bounded"],
            sourceDigests: ["profile"]
        )

        XCTAssertThrowsError(
            try ManifestSchedulerAdmissionBridge.map(
                manifest: manifest,
                subjectID: "owner",
                profileResolution: resolution
            )
        ) { error in
            XCTAssertEqual(
                error as? ManifestSchedulerAdmissionError,
                .profileViolation([
                    "accelerators.allowed",
                    "resources.cpu",
                    "resources.memoryMiB",
                    "runtime.allowedProviders"
                ])
            )
        }
    }

    func testDisruptionBudgetMapsMaxUnavailableAndMinAvailableWithStableIdentity() throws {
        let maxService = HostwrightService(
            name: "api",
            image: "example.invalid/api:latest",
            replicas: 3,
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                disruption: HostwrightDisruptionPolicy(maxUnavailable: 1)
            )
        )
        let minService = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            replicas: 4,
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                disruption: HostwrightDisruptionPolicy(minAvailable: 2)
            )
        )
        let admissions = try ManifestSchedulerAdmissionBridge.map(
            manifest: HostwrightManifest(
                version: 3,
                project: "demo",
                services: [maxService, minService]
            ),
            subjectID: "owner"
        )

        let maxBudget = try XCTUnwrap(
            admissions.first(where: { $0.serviceName == "api" })?.disruptionBudget
        )
        XCTAssertEqual(maxBudget.budgetID, "demo/api")
        XCTAssertEqual(maxBudget.projectID, "demo")
        XCTAssertEqual(maxBudget.remainingVictimCount, 1)
        XCTAssertEqual(maxBudget.remainingDisruptionCostBasisPoints, 2_000)

        let minBudget = try XCTUnwrap(
            admissions.first(where: { $0.serviceName == "worker" })?.disruptionBudget
        )
        XCTAssertEqual(minBudget.budgetID, "demo/worker")
        XCTAssertEqual(minBudget.remainingVictimCount, 2)
        XCTAssertEqual(minBudget.remainingDisruptionCostBasisPoints, 4_000)
    }

    func testUnsupportedRuntimeHardLimitsAndClaimsFailClosed() throws {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB", disk: "1GiB", process: 1),
                limits: HostwrightResourceSet(cpus: 1, memory: "1GiB", disk: "2GiB", process: 2)
            ),
            scheduling: HostwrightSchedulingPolicy(
                provider: "provider-a",
                acceleratorClaims: [HostwrightAcceleratorClaim(name: "gpu")]
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])

        XCTAssertThrowsError(
            try ManifestSchedulerAdmissionBridge.map(manifest: manifest, subjectID: "owner")
        ) { error in
            XCTAssertEqual(
                error as? ManifestSchedulerAdmissionError,
                .unsupportedRuntimeLimits([
                    "resources.limits.disk",
                    "resources.limits.process"
                ])
            )
        }
    }

    func testConflictingDisruptionBoundsFailBeforeAdmission() throws {
        let service = HostwrightService(
            name: "worker",
            image: "example.invalid/worker:latest",
            resources: Self.executableResources,
            scheduling: HostwrightSchedulingPolicy(
                disruption: HostwrightDisruptionPolicy(
                    maxUnavailable: 1,
                    minAvailable: 1
                )
            )
        )
        let manifest = HostwrightManifest(version: 3, project: "demo", services: [service])

        XCTAssertThrowsError(
            try ManifestSchedulerAdmissionBridge.map(manifest: manifest, subjectID: "owner")
        ) { error in
            XCTAssertEqual(
                (error as? ManifestSchedulerAdmissionError)?.stableKey,
                "invalid-manifest:$:Service 'worker' scheduling.disruption must declare maxUnavailable or minAvailable, not both."
            )
        }
    }

    func testDisruptionBoundsOutsideReplicaRangeFailBeforeProjection() {
        let invalidPolicies = [
            HostwrightSchedulingPolicy(
                disruption: HostwrightDisruptionPolicy(maxUnavailable: 4)
            ),
            HostwrightSchedulingPolicy(
                disruption: HostwrightDisruptionPolicy(minAvailable: -1)
            )
        ]
        let expectedReasons = [
            "invalid-manifest:$:Service 'worker' scheduling.disruption.maxUnavailable must be between 0 and replicas.",
            "invalid-manifest:$:Service 'worker' scheduling.disruption.minAvailable must be between 0 and replicas."
        ]

        for (policy, expectedReason) in zip(invalidPolicies, expectedReasons) {
            let service = HostwrightService(
                name: "worker",
                image: "example.invalid/worker:latest",
                replicas: 3,
                resources: Self.executableResources,
                scheduling: policy
            )

            XCTAssertThrowsError(
                try ManifestSchedulerAdmissionBridge.map(
                    manifest: HostwrightManifest(
                        version: 3,
                        project: "demo",
                        services: [service]
                    ),
                    subjectID: "owner"
                )
            ) { error in
                XCTAssertEqual(
                    (error as? ManifestSchedulerAdmissionError)?.stableKey,
                    expectedReason
                )
            }
        }
    }

    private func snapshot(
        id: UUID,
        labels: [String: String] = [:],
        provider: String = "provider-a",
        accelerators: [String: Int64] = [:]
    ) throws -> NodePlacementSnapshot {
        try NodePlacementSnapshot(
            nodeID: id,
            capacity: try ResourceVector([
                "cpu": 64,
                "memory": 64 * 1_024 * 1_024 * 1_024
            ]),
            allocation: .zero,
            architecture: "arm64",
            runtime: "linux-vm",
            provider: provider,
            labels: labels,
            acceleratorAvailability: try ResourceVector(accelerators)
        )
    }

    private func node(id: UUID, zone: String) throws -> SchedulerNode {
        try SchedulerNode(
            snapshot: try snapshot(id: id),
            topologyDomains: ["zone": zone]
        )
    }
}
