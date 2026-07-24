import Foundation
import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets
import Testing
@testable import HostwrightCLI

@Suite
struct LifecycleCommandRunnerTests {
    @Test
    func dryRunCompilesSharedSagaPlanNormalizesBindsAndNeverPersistsSecrets() throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-phase04-bind-\(UUID().uuidString)",
                isDirectory: true
            )
        let bindDirectory = manifestDirectory.appendingPathComponent(
            "data",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bindDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }

        let reference = try HostwrightSecretReference(
            service: "hostwright-tests",
            account: "database-password"
        )
        let desired = service(
            environment: [
                RuntimeEnvironmentValue(
                    name: "DATABASE_PASSWORD",
                    value: reference.redactedDescription,
                    isSensitive: true,
                    secretReference: reference
                )
            ],
            mounts: [
                RuntimeMountReference(
                    source: "./data",
                    target: "/var/lib/data",
                    access: .unknown
                )
            ]
        )
        let preparation = try preparation(
            desired: [desired],
            manifestBaseDirectory: manifestDirectory.path
        )
        let driver = ScriptedLifecycleCommandDriver(preparation: preparation)
        let result = LifecycleCommandRunner(
            options: options(command: .up, dryRun: true, output: .json),
            driver: driver
        ).run()

        #expect(result.exitCode == 0)
        #expect(result.standardError.isEmpty)
        let plan = try JSONDecoder().decode(
            LifecyclePlan.self,
            from: Data(result.standardOutput.utf8)
        )
        #expect(plan.nodes.map(\.action) == [.create, .start])
        #expect(result.standardOutput.contains("[REDACTED]"))
        #expect(!result.standardOutput.contains(reference.rawValue))
        #expect(!result.standardOutput.contains(reference.account))
        #expect(driver.snapshot() == DriverSnapshot(imageChecks: 1))

        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .up, dryRun: true),
            preparation: preparation
        )
        let create = try #require(
            compiled.desiredServicesByNodeKey.values.first
        )
        #expect(create.mounts.first?.source == bindDirectory.path)
        #expect(create.mounts.first?.access == .readWrite)
        #expect(create.environment.first?.secretReference == reference)
    }

    @Test
    func desiredSpecificationSortsPortsByStableTypedFields() throws {
        let desired = service(
            ports: [
                RuntimePortMapping(
                    hostPort: 9000,
                    containerPort: 90,
                    protocolName: .udp,
                    bindAddress: "127.0.0.1"
                ),
                RuntimePortMapping(
                    hostPort: nil,
                    containerPort: 8080,
                    protocolName: .tcp,
                    bindAddress: nil
                ),
                RuntimePortMapping(
                    hostPort: 8000,
                    containerPort: 80,
                    protocolName: .tcp,
                    bindAddress: "127.0.0.1"
                )
            ]
        )
        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .up, dryRun: true),
            preparation: preparation(desired: [desired])
        )
        let create = try #require(
            compiled.plan.nodes.first { $0.action == .create }
        )
        let data = try #require(
            create.desiredSpecificationJSONRedacted.data(using: .utf8)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let ports = try #require(object["ports"] as? [[String: Any]])

        #expect(ports.count == 3)
        #expect(ports[0]["containerPort"] as? Int == 8080)
        #expect(ports[1]["hostPort"] as? Int == 8000)
        #expect(ports[2]["hostPort"] as? Int == 9000)
    }

    @Test
    func exactConfirmationRevalidatesThenExecutesOnce() throws {
        let preparation = try preparation(desired: [service()])
        let dryOptions = options(command: .up, dryRun: true)
        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: dryOptions,
            preparation: preparation
        )
        let driver = ScriptedLifecycleCommandDriver(preparation: preparation)

        let result = LifecycleCommandRunner(
            options: options(
                command: .up,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            ),
            driver: driver
        ).run()

        #expect(result.exitCode == 0)
        let expectedOutput = (
            [
                "Lifecycle succeeded: plan=\(compiled.plan.planSHA256) completed=\(compiled.plan.nodes.count)/\(compiled.plan.nodes.count) checkpoint=complete",
                "Resource outcomes:"
            ] + compiled.plan.nodes.map { node in
                "- outcome=completed project=demo service=api replica=0 resourceUUID=\(node.resourceUUID) node=\(node.key) action=\(node.action.rawValue) resourceIdentifier=\(node.resourceIdentifier!)"
            }
        ).joined(separator: "\n") + "\n"
        #expect(result.standardOutput == expectedOutput)
        #expect(result.standardError.isEmpty)
        #expect(
            driver.snapshot() ==
                DriverSnapshot(imageChecks: 1, revalidations: 1, executions: 1)
        )
    }

    @Test
    func partialSafeHoldRendersExactCanonicalResourceOutcomesAsJSON() throws {
        let preparation = try preparation(desired: [service()])
        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .up, dryRun: true),
            preparation: preparation
        )
        let completed = try #require(compiled.plan.nodes.first)
        let execution = LifecycleSagaExecutionResult(
            status: .safeHold,
            operationID: "11111111-1111-4111-8111-111111111111",
            groupID: "22222222-2222-4222-8222-222222222222",
            planSHA256: compiled.plan.planSHA256,
            checkpoint: "\(completed.key):safe-hold",
            completedNodeKeys: [completed.key],
            recoveryHintRedacted: "Preserve the exact safe-hold checkpoint."
        )
        let driver = ScriptedLifecycleCommandDriver(
            preparation: preparation,
            executionResult: execution
        )

        let result = LifecycleCommandRunner(
            options: options(
                command: .up,
                dryRun: false,
                confirmation: compiled.plan.planSHA256,
                output: .json
            ),
            driver: driver
        ).run()

        let resourceOutcomes = compiled.plan.nodes.map { node -> [String: Any] in
            [
                "action": node.action.rawValue,
                "node": node.key,
                "outcome": node.key == completed.key ? "completed" : "safe-hold",
                "project": "demo",
                "replica": 0,
                "resourceIdentifier": node.resourceIdentifier!,
                "resourceUUID": node.resourceUUID,
                "service": "api"
            ]
        }
        let expected = CLIJSON.render([
            "kind": "lifecycle-result",
            "status": "safe-hold",
            "operationID": execution.operationID,
            "groupID": execution.groupID,
            "planSHA256": execution.planSHA256,
            "checkpoint": execution.checkpoint,
            "completedNodeKeys": [completed.key],
            "nodeCount": compiled.plan.nodes.count,
            "resourceOutcomes": resourceOutcomes,
            "recoveryHint": execution.recoveryHintRedacted
        ])
        #expect(result.exitCode == CLIExitCode.partialFailure.rawValue)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == expected)
    }

    @Test
    func resourceOutcomeOrderIsDeterministicAcrossInputAndCompletionOrder() throws {
        let firstPreparation = try preparation(
            desired: [service(name: "worker"), service(name: "api")]
        )
        let secondPreparation = try preparation(
            desired: [service(name: "api"), service(name: "worker")]
        )
        let lifecycleOptions = options(command: .up, dryRun: true)
        let firstCompiled = try LifecycleCommandPlanCompiler().compile(
            options: lifecycleOptions,
            preparation: firstPreparation
        )
        let secondCompiled = try LifecycleCommandPlanCompiler().compile(
            options: lifecycleOptions,
            preparation: secondPreparation
        )
        #expect(firstCompiled.plan == secondCompiled.plan)
        let execution = LifecycleSagaExecutionResult(
            status: .succeeded,
            operationID: "33333333-3333-4333-8333-333333333333",
            groupID: "44444444-4444-4444-8444-444444444444",
            planSHA256: firstCompiled.plan.planSHA256,
            checkpoint: "complete",
            completedNodeKeys: Array(firstCompiled.plan.nodes.map(\.key).reversed()),
            recoveryHintRedacted: ""
        )
        let confirmedOptions = options(
            command: .up,
            dryRun: false,
            confirmation: firstCompiled.plan.planSHA256,
            output: .json
        )

        let first = LifecycleCommandRunner(
            options: confirmedOptions,
            driver: ScriptedLifecycleCommandDriver(
                preparation: firstPreparation,
                executionResult: execution
            )
        ).run()
        let second = LifecycleCommandRunner(
            options: confirmedOptions,
            driver: ScriptedLifecycleCommandDriver(
                preparation: secondPreparation,
                executionResult: execution
            )
        ).run()

        #expect(first.standardOutput == second.standardOutput)
        let object = try #require(
            JSONSerialization.jsonObject(
                with: Data(first.standardOutput.utf8)
            ) as? [String: Any]
        )
        #expect(
            object["completedNodeKeys"] as? [String] ==
                firstCompiled.plan.nodes.map(\.key)
        )
        let outcomes = try #require(
            object["resourceOutcomes"] as? [[String: Any]]
        )
        #expect(
            outcomes.compactMap { $0["node"] as? String } ==
                firstCompiled.plan.nodes.map(\.key)
        )
        #expect(
            outcomes.compactMap { $0["resourceUUID"] as? String } ==
                firstCompiled.plan.nodes.map(\.resourceUUID)
        )
    }

    @Test
    func confirmationMismatchHasZeroImageOrMutationEffects() throws {
        let preparation = try preparation(desired: [service()])
        let driver = ScriptedLifecycleCommandDriver(preparation: preparation)
        let result = LifecycleCommandRunner(
            options: options(
                command: .up,
                dryRun: false,
                confirmation: String(repeating: "f", count: 64)
            ),
            driver: driver
        ).run()

        #expect(result.exitCode == CLIExitCode.confirmationMismatch.rawValue)
        #expect(result.standardError.contains("HW-CLI-003"))
        #expect(driver.snapshot() == DriverSnapshot())
    }

    @Test
    func downPreservesAndRemoveDeletesOnlyExactOwnedResource() throws {
        let desired = service()
        let observed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            image: desired.image,
            lifecycleState: .running,
            healthState: .healthy
        )
        let binding = try resourceBinding(for: observed)
        let preparation = try preparation(
            desired: [desired],
            observed: [observed],
            bindings: [binding]
        )
        let compiler = LifecycleCommandPlanCompiler()

        let down = try compiler.compile(
            options: options(command: .down, dryRun: true),
            preparation: preparation
        )
        #expect(down.plan.nodes.map(\.action) == [.stop])
        #expect(down.localImageRequirements.isEmpty)
        #expect(down.plan.nodes.allSatisfy { $0.resourceUUID == binding.resourceUUID })

        let remove = try compiler.compile(
            options: options(command: .rm, dryRun: true),
            preparation: preparation
        )
        #expect(remove.plan.nodes.map(\.action) == [.stop, .delete])
        #expect(remove.plan.nodes.last?.dependencies == [remove.plan.nodes.first!.key])
        #expect(remove.plan.nodes.allSatisfy { $0.resourceUUID == binding.resourceUUID })
    }

    @Test
    func runningRestartDurablyOrdersStopThenStartBeforeHooksAndProbes() throws {
        let desired = service(
            probes: allProbes(),
            hooks: RuntimeLifecycleHooks(
                postStart: ["/bin/configure"],
                preStop: ["/bin/drain"]
            )
        )
        let observed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            image: desired.image,
            lifecycleState: .running,
            healthState: .healthy
        )
        let binding = try resourceBinding(for: observed)
        let prepared = try preparation(
            desired: [desired],
            observed: [observed],
            bindings: [binding]
        )

        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .restart, dryRun: true),
            preparation: prepared
        )

        #expect(
            compiled.plan.nodes.map(\.action) ==
                [
                    .runHook,
                    .stop,
                    .start,
                    .runHook,
                    .verify,
                    .verify,
                    .verify
                ]
        )
        #expect(
            compiled.plan.nodes.map(\.key) == [
                key("prestop", desired),
                key("stop", desired),
                key("start", desired),
                key("poststart", desired),
                key("verify-startup", desired),
                key("verify-ready", desired),
                key("verify-liveness", desired)
            ]
        )
        for index in 1..<compiled.plan.nodes.count {
            #expect(
                compiled.plan.nodes[index].dependencies ==
                    [compiled.plan.nodes[index - 1].key]
            )
        }
        #expect(
            compiled.plan.nodes.map { $0.postconditions.map(\.kind) } == [
                ["hook-completed"],
                ["lifecycle"],
                ["lifecycle"],
                ["hook-completed"],
                ["probe-startup"],
                ["probe-readiness"],
                ["probe-liveness"]
            ]
        )
        #expect(compiled.localImageRequirements.isEmpty)
    }

    @Test
    func stoppedRestartSkipsPreStopButRunsPostStartAfterActualStart() throws {
        let desired = service(
            hooks: RuntimeLifecycleHooks(
                postStart: ["/bin/configure"],
                preStop: ["/bin/drain"]
            )
        )
        let observed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            image: desired.image,
            lifecycleState: .stopped,
            healthState: .notConfigured
        )
        let binding = try resourceBinding(for: observed)
        let prepared = try preparation(
            desired: [desired],
            observed: [observed],
            bindings: [binding]
        )

        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .restart, dryRun: true),
            preparation: prepared
        )

        #expect(compiled.plan.nodes.map(\.action) == [.start, .runHook])
        #expect(
            compiled.plan.nodes.map(\.key) == [
                key("start", desired),
                key("poststart", desired)
            ]
        )
        #expect(
            compiled.plan.nodes[1].dependencies ==
                [compiled.plan.nodes[0].key]
        )
        #expect(!compiled.plan.nodes.contains { $0.key == key("prestop", desired) })
    }

    @Test
    func existingMutationWithoutUUIDOwnershipFailsClosed() throws {
        let desired = service()
        let observed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            lifecycleState: .running
        )
        let preparation = try preparation(
            desired: [desired],
            observed: [observed]
        )

        #expect(throws: MultiServiceReconciliationError.self) {
            try LifecycleCommandPlanCompiler().compile(
                options: options(command: .down, dryRun: true),
                preparation: preparation
            )
        }
    }

    @Test
    func startDoesNotCreateAMissingResource() throws {
        let preparation = try preparation(desired: [service()])

        #expect(
            throws: LifecycleCommandRunnerError.missingManagedResource(
                "demo/api"
            )
        ) {
            try LifecycleCommandPlanCompiler().compile(
                options: options(command: .start, dryRun: true),
                preparation: preparation
            )
        }
    }

    @Test
    func runUsesOneDeterministicEphemeralIdentityAndRequiresLocalImage() throws {
        let preparation = try preparation(desired: [service()])
        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(
                command: .run,
                dryRun: true,
                serviceNames: ["api"]
            ),
            preparation: preparation
        )

        #expect(compiled.plan.nodes.map(\.action) == [.create, .start])
        #expect(compiled.localImageRequirements.count == 1)
        let expectedSuffix = preparation.planFencingToken
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
        #expect(
            compiled.plan.nodes.allSatisfy {
                $0.serviceName == "demo/api/run-\(expectedSuffix)"
            }
        )
        #expect(
            compiled.plan.nodes[1].dependencies == [compiled.plan.nodes[0].key]
        )
        #expect(
            compiled.plan.nodes[1].postconditions == [
                LifecyclePlanCondition(
                    kind: "lifecycle",
                    subject: compiled.plan.nodes[1].resourceIdentifier ?? "",
                    expectedValue: RuntimeLifecycleState.exited.rawValue
                )
            ]
        )
    }

    @Test
    func namedVolumeFailsBeforeRuntimeMutation() throws {
        let namedVolumePreparation = try preparation(
            desired: [
                service(
                    mounts: [
                        RuntimeMountReference(
                            source: "database-data",
                            target: "/var/lib/data",
                            access: .readWrite
                        )
                    ]
                )
            ]
        )

        #expect(
            throws: LifecycleCommandRunnerError.unsupportedStorage(
                "database-data"
            )
        ) {
            try LifecycleCommandPlanCompiler().compile(
                options: options(command: .up, dryRun: true),
                preparation: namedVolumePreparation
            )
        }
    }

    @Test
    func missingRelativeAndAbsoluteBindSourcesFailBeforeMutation() throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-phase04-missing-bind-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }

        let missingRelative = manifestDirectory
            .appendingPathComponent("missing-relative")
            .path
        let missingAbsolute = manifestDirectory
            .appendingPathComponent("missing-absolute")
            .path

        for (source, expected) in [
            ("./missing-relative", missingRelative),
            (missingAbsolute, missingAbsolute)
        ] {
            let missingPreparation = try preparation(
                desired: [
                    service(
                        mounts: [
                            RuntimeMountReference(
                                source: source,
                                target: "/var/lib/data",
                                access: .readWrite
                            )
                        ]
                    )
                ],
                manifestBaseDirectory: manifestDirectory.path
            )

            #expect(
                throws: LifecycleCommandRunnerError.unsupportedStorage(expected)
            ) {
                try LifecycleCommandPlanCompiler().compile(
                    options: options(command: .up, dryRun: true),
                    preparation: missingPreparation
                )
            }
        }
    }

    @Test
    func existingAbsoluteBindSourceCompiles() throws {
        let bindSource = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-phase04-existing-bind-\(UUID().uuidString)"
            )
        try Data("bound".utf8).write(to: bindSource, options: .atomic)
        defer { try? FileManager.default.removeItem(at: bindSource) }

        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .up, dryRun: true),
            preparation: preparation(
                desired: [
                    service(
                        mounts: [
                            RuntimeMountReference(
                                source: bindSource.path,
                                target: "/var/lib/data",
                                access: .readOnly
                            )
                        ]
                    )
                ]
            )
        )

        let create = try #require(
            compiled.desiredServicesByNodeKey.values.first
        )
        #expect(create.mounts == [
            RuntimeMountReference(
                source: bindSource.path,
                target: "/var/lib/data",
                access: .readOnly
            )
        ])
    }

    @Test
    func updateCompilesRealRollingPlanFromVerifiedPreviousRevision() throws {
        let previous = service(
            image: "example.invalid/api@sha256:\(String(repeating: "1", count: 64))"
        )
        let desired = service(
            image: "example.invalid/api@sha256:\(String(repeating: "2", count: 64))"
        )
        let observed = ObservedRuntimeService(
            identity: previous.identity,
            resourceIdentifier: previous.identity.managedResourceIdentifier,
            image: previous.image,
            lifecycleState: .running,
            healthState: .healthy
        )
        let binding = try resourceBinding(for: observed)
        let prepared = try preparation(
            desired: [desired],
            previous: DesiredRuntimeState(
                projectName: "demo",
                services: [previous]
            ),
            observed: [observed],
            bindings: [binding]
        )

        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .update, dryRun: true),
            preparation: prepared
        )

        #expect(compiled.plan.command == .update)
        #expect(compiled.plan.nodes.contains { $0.action == .create })
        #expect(compiled.plan.nodes.contains { $0.action == .promote })
        #expect(compiled.plan.nodes.contains { $0.action == .retire })
        let create = try #require(
            compiled.plan.nodes.first { $0.action == .create }
        )
        #expect(create.resourceIdentifier != binding.resourceIdentifier)
        #expect(create.resourceGeneration == binding.resourceGeneration + 1)
        #expect(create.desiredSpecificationJSONRedacted.contains(desired.image))
        #expect(compiled.localImageRequirements.map(\.reference) == [desired.image])
        #expect(
            compiled.plan.nodes.allSatisfy {
                $0.fencingToken == prepared.planFencingToken
            }
        )
    }

    @Test
    func recreateAvailabilityImpactIsVisibleAndConfirmationBound() throws {
        let fixedPort = RuntimePortMapping(
            hostPort: 8080,
            containerPort: 8080,
            protocolName: .tcp,
            bindAddress: "127.0.0.1"
        )
        let previous = service(
            image: "example.invalid/api@sha256:\(String(repeating: "1", count: 64))",
            ports: [fixedPort]
        )
        let desired = service(
            image: "example.invalid/api@sha256:\(String(repeating: "2", count: 64))",
            ports: [fixedPort]
        )
        let observed = ObservedRuntimeService(
            identity: previous.identity,
            resourceIdentifier: previous.identity.managedResourceIdentifier,
            image: previous.image,
            lifecycleState: .running,
            healthState: .healthy,
            ports: [fixedPort]
        )
        let binding = try resourceBinding(for: observed)
        let prepared = try preparation(
            desired: [desired],
            previous: DesiredRuntimeState(
                projectName: "demo",
                services: [previous]
            ),
            observed: [observed],
            bindings: [binding]
        )
        let lifecycleOptions = options(command: .update, dryRun: true)
        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: lifecycleOptions,
            preparation: prepared
        )
        let impact = try #require(compiled.plan.availabilityImpacts.first)

        #expect(compiled.plan.availabilityImpacts.count == 1)
        #expect(impact.serviceName == "api")
        #expect(impact.mode == .recreate)
        #expect(impact.modeReason == .exclusiveHostPort)
        #expect(impact.desiredReplicas == 1)
        #expect(impact.minimumAvailable == 0)
        #expect(impact.maximumTemporaryCapacity == 1)
        #expect(impact.requiresDowntime)

        let text = LifecycleCommandRunner(
            options: lifecycleOptions,
            driver: ScriptedLifecycleCommandDriver(preparation: prepared)
        ).run()
        #expect(text.exitCode == 0)
        #expect(text.standardOutput.contains("Update availability impacts:"))
        #expect(
            text.standardOutput.contains(
                "service=api mode=recreate reason=exclusive-host-port"
            )
        )
        #expect(text.standardOutput.contains("requiresDowntime=true"))

        let json = LifecycleCommandRunner(
            options: options(command: .update, dryRun: true, output: .json),
            driver: ScriptedLifecycleCommandDriver(preparation: prepared)
        ).run()
        let decoded = try JSONDecoder().decode(
            LifecyclePlan.self,
            from: Data(json.standardOutput.utf8)
        )
        #expect(decoded.availabilityImpacts == [impact])

        let planWithoutImpact = try LifecyclePlan(
            command: compiled.plan.command,
            projectID: compiled.plan.projectID,
            projectName: compiled.plan.projectName,
            projectResourceUUID: compiled.plan.projectResourceUUID,
            projectGeneration: compiled.plan.projectGeneration,
            providerID: compiled.plan.providerID,
            providerGeneration: compiled.plan.providerGeneration,
            manifestSHA256: compiled.plan.manifestSHA256,
            observationSHA256: compiled.plan.observationSHA256,
            capabilitySHA256: compiled.plan.capabilitySHA256,
            parallelism: compiled.plan.parallelism,
            nodes: compiled.plan.nodes
        )
        #expect(planWithoutImpact.planSHA256 != compiled.plan.planSHA256)

        let mismatchDriver = ScriptedLifecycleCommandDriver(
            preparation: prepared
        )
        let mismatch = LifecycleCommandRunner(
            options: options(
                command: .update,
                dryRun: false,
                confirmation: planWithoutImpact.planSHA256
            ),
            driver: mismatchDriver
        ).run()
        #expect(mismatch.exitCode == CLIExitCode.confirmationMismatch.rawValue)
        #expect(mismatchDriver.snapshot() == DriverSnapshot())
    }

    @Test
    func upRepairsSupportedDesiredDriftThroughTheExistingUpdatePlanner() throws {
        let previous = service(
            image: "example.invalid/api@sha256:\(String(repeating: "1", count: 64))"
        )
        let desired = service(
            image: "example.invalid/api@sha256:\(String(repeating: "2", count: 64))"
        )
        let observed = ObservedRuntimeService(
            identity: previous.identity,
            resourceIdentifier: previous.identity.managedResourceIdentifier,
            image: previous.image,
            lifecycleState: .running,
            healthState: .healthy
        )
        let binding = try resourceBinding(for: observed)
        let prepared = try preparation(
            desired: [desired],
            previous: DesiredRuntimeState(
                projectName: "demo",
                services: [previous]
            ),
            observed: [observed],
            bindings: [binding]
        )

        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .up, dryRun: true),
            preparation: prepared
        )

        #expect(compiled.plan.command == .up)
        #expect(compiled.plan.nodes.contains { $0.action == .create })
        #expect(compiled.plan.nodes.contains { $0.action == .promote })
        #expect(compiled.plan.nodes.contains { $0.action == .retire })
        #expect(compiled.localImageRequirements.map(\.reference) == [desired.image])
    }

    @Test
    func failedImageEvidencePreventsRevalidationAndExecution() throws {
        let preparation = try preparation(desired: [service()])
        let driver = ScriptedLifecycleCommandDriver(
            preparation: preparation,
            imageEvidenceIsValid: false
        )
        let result = LifecycleCommandRunner(
            options: options(command: .up, dryRun: true),
            driver: driver
        ).run()

        #expect(result.exitCode == CLIExitCode.runtimeUnavailable.rawValue)
        #expect(result.standardError.contains("Local image evidence"))
        #expect(driver.snapshot() == DriverSnapshot(imageChecks: 1))
    }

    private func options(
        command: LifecycleCommandKind,
        dryRun: Bool,
        confirmation: String? = nil,
        serviceNames: [String] = [],
        output: CLIOutputFormat = .text
    ) -> LifecycleCLIOptions {
        LifecycleCLIOptions(
            command: command,
            manifestPath: "/tmp/hostwright-phase04/hostwright.yaml",
            serviceNames: serviceNames,
            confirmationPlanSHA256: confirmation,
            dryRun: dryRun,
            runtimeProvider: .appleCLI,
            timeoutSeconds: 60,
            parallelism: 4,
            output: output
        )
    }

    private func service(
        name: String = "api",
        image: String? = nil,
        environment: [RuntimeEnvironmentValue] = [],
        mounts: [RuntimeMountReference] = [],
        ports: [RuntimePortMapping] = [],
        probes: RuntimeProbeSet = RuntimeProbeSet(),
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks()
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: name
            ),
            image: image ??
                "example.invalid/\(name)@sha256:\(String(repeating: "1", count: 64))",
            environment: environment,
            ports: ports,
            mounts: mounts,
            probes: probes,
            hooks: hooks,
            virtualization: false
        )
    }

    private func allProbes() -> RuntimeProbeSet {
        RuntimeProbeSet(
            startup: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/startup"]))
            ),
            readiness: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/ready"]))
            ),
            liveness: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/live"]))
            )
        )
    }

    private func key(
        _ phase: String,
        _ service: DesiredRuntimeService
    ) -> String {
        "\(phase)-\(service.identity.managedResourceIdentifier)"
    }

    private func preparation(
        desired: [DesiredRuntimeService],
        previous: DesiredRuntimeState? = nil,
        observed: [ObservedRuntimeService] = [],
        bindings: [LifecycleResourceBinding] = [],
        manifestBaseDirectory: String = "/tmp/hostwright-phase04"
    ) throws -> LifecycleCommandPreparation {
        let capability = String(repeating: "c", count: 64)
        return LifecycleCommandPreparation(
            manifestSHA256: String(repeating: "a", count: 64),
            manifestBaseDirectory: manifestBaseDirectory,
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                services: desired
            ),
            previousDesiredState: previous,
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: observed,
                adapterMetadata: RuntimeAdapterMetadata(
                    providerID: .appleContainerCLI,
                    adapterName: "test-apple-cli",
                    adapterVersion: "1",
                    runtimeName: "container",
                    runtimeVersion: "1.1.0",
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation]
                ),
                capabilitySHA256: capability
            ),
            observationSHA256: String(repeating: "b", count: 64),
            projectID: "project-demo",
            projectResourceUUID: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-demo"
            ),
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            capabilitySHA256: capability,
            planFencingToken: HostwrightResourceUUID.legacy(
                kind: "phase04-test-fence",
                identifier: String(repeating: "c", count: 64)
            ),
            resourceBindings: bindings
        )
    }

    private func resourceBinding(
        for observed: ObservedRuntimeService
    ) throws -> LifecycleResourceBinding {
        try LifecycleResourceBinding(
            identity: observed.identity,
            resourceIdentifier: observed.resourceIdentifier,
            resourceUUID: HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: observed.identity.displayName
            ),
            resourceGeneration: 1,
            projectResourceUUID: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-demo"
            ),
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            currentFencingToken: HostwrightResourceUUID.legacy(
                kind: "current-fence",
                identifier: observed.identity.displayName
            )
        )
    }
}

private struct DriverSnapshot: Equatable {
    var preparations = 0
    var imageChecks = 0
    var revalidations = 0
    var executions = 0
}

private final class ScriptedLifecycleCommandDriver:
    LifecycleCommandDriving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let preparation: LifecycleCommandPreparation
    private let imageEvidenceIsValid: Bool
    private let executionResult: LifecycleSagaExecutionResult?
    private var counts = DriverSnapshot()

    init(
        preparation: LifecycleCommandPreparation,
        imageEvidenceIsValid: Bool = true,
        executionResult: LifecycleSagaExecutionResult? = nil
    ) {
        self.preparation = preparation
        self.imageEvidenceIsValid = imageEvidenceIsValid
        self.executionResult = executionResult
    }

    func prepare(options: LifecycleCLIOptions) throws -> LifecycleCommandPreparation {
        lock.withLock {
            counts.preparations += 1
        }
        return preparation
    }

    func localImageEvidence(
        for requirement: LifecycleLocalImageRequirement,
        preparation: LifecycleCommandPreparation
    ) throws -> RuntimeLocalImageEvidence {
        lock.withLock {
            counts.imageChecks += 1
        }
        return RuntimeLocalImageEvidence(
            reference: requirement.reference,
            descriptorDigest: "sha256:\(String(repeating: "d", count: 64))",
            variantDigest: "sha256:\(String(repeating: "e", count: 64))",
            architecture: imageEvidenceIsValid
                ? requirement.architecture
                : "wrong-architecture",
            operatingSystem: requirement.operatingSystem
        )
    }

    func revalidate(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws {
        lock.withLock {
            counts.revalidations += 1
        }
    }

    func execute(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws -> LifecycleSagaExecutionResult {
        lock.withLock {
            counts.executions += 1
        }
        return executionResult ?? LifecycleSagaExecutionResult(
            status: .succeeded,
            operationID: HostwrightResourceUUID.generate(),
            groupID: HostwrightResourceUUID.generate(),
            planSHA256: compiled.plan.planSHA256,
            checkpoint: "complete",
            completedNodeKeys: compiled.plan.nodes.map(\.key),
            recoveryHintRedacted: ""
        )
    }

    func snapshot() -> DriverSnapshot {
        lock.withLock {
            var value = counts
            value.preparations = 0
            return value
        }
    }
}
