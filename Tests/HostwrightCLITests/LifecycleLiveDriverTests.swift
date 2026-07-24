import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleLiveDriverTests: XCTestCase {
    func testCompletedDependencyUsesZeroExitStartBeforeDependentStart() throws {
        try withFixture(manifestOverride: completedDependencyManifest) { fixture in
            let result = try runConfirmedUp(fixture)

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(
                zip(snapshot.mutations, snapshot.completionRequirements)
                    .filter { $0.0 == .start }
                    .map(\.1),
                [true, false]
            )
            XCTAssertEqual(
                try fixture.store.operationGroupSteps.loadAll()
                    .filter { $0.plannedActionType == "completion-checkpoint" }
                    .map(\.status),
                [.started, .succeeded]
            )
        }
    }

    func testFailedCompletionExitCannotSatisfyDependencyOrRecoveryObservation() throws {
        try withFixture(manifestOverride: completedDependencyManifest) { fixture in
            try fixture.wait {
                await fixture.adapter.setCompletionStartFailure(true)
            }
            let result = try runConfirmedUp(fixture)

            XCTAssertNotEqual(result.exitCode, 0)
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(
                zip(snapshot.mutations, snapshot.completionRequirements)
                    .filter { $0.0 == .start }
                    .map(\.1),
                [true]
            )
            let group = try XCTUnwrap(
                fixture.store.operationGroups.loadAll().first
            )
            XCTAssertEqual(group.status, .failed)
            XCTAssertTrue(group.checkpoint.contains("ambiguous"))
            XCTAssertEqual(
                try fixture.store.operationGroupSteps.loadAll()
                    .filter { $0.plannedActionType == "completion-checkpoint" }
                    .map(\.status),
                [.started, .failed]
            )
        }
    }

    func testDryRunPreparationIsDeterministicAndMutationFree() throws {
        try withFixture { fixture in
            let options = fixture.options(command: .up, dryRun: true)
            let driver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: options
            )

            let first = try driver.prepare(options: options)
            let second = try driver.prepare(options: options)
            let compiler = LifecycleCommandPlanCompiler()
            let firstPlan = try compiler.compile(options: options, preparation: first)
            let secondPlan = try compiler.compile(options: options, preparation: second)

            XCTAssertEqual(first.planFencingToken, second.planFencingToken)
            XCTAssertEqual(first.observationSHA256, second.observationSHA256)
            XCTAssertEqual(first.capabilitySHA256, second.capabilitySHA256)
            XCTAssertEqual(firstPlan.plan.planSHA256, secondPlan.plan.planSHA256)
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertTrue(try fixture.store.operations.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.operationGroupSteps.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.ownership.loadAll().isEmpty)
        }
    }

    func testRevalidationRejectsChangedCapabilityAndObservationBeforeMutation() throws {
        try withFixture { fixture in
            let options = fixture.options(command: .up, dryRun: true)
            let driver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: options
            )
            let preparation = try driver.prepare(options: options)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: options,
                preparation: preparation
            )

            try fixture.wait {
                await fixture.adapter.replaceCapability(
                    lifecycleLiveCapability(build: "25F91")
                )
            }

            XCTAssertThrowsError(
                try driver.revalidate(
                    compiled: compiled,
                    preparation: preparation
                )
            ) { error in
                guard case LifecycleCommandRunnerError.confirmationMismatch = error else {
                    return XCTFail("Expected stale confirmation mismatch, got \(error)")
                }
            }
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.ownership.loadAll().isEmpty)
        }
    }

    func testExecuteRejectsManifestChangedAfterConfirmationBeforePersistenceOrMutation() throws {
        try withFixture { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let driver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try driver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            fixture.manifestSource.replace(
                fixture.manifestSource.value.replacingOccurrences(
                    of: "project: demo",
                    with: "project: changed"
                )
            )
            let confirmed = fixture.options(
                command: .up,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            )

            XCTAssertThrowsError(
                try LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: confirmed
                ).execute(
                    compiled: compiled,
                    preparation: preparation,
                    options: confirmed
                )
            ) { error in
                guard case LifecycleCommandRunnerError.confirmationMismatch =
                    error else {
                    return XCTFail("Expected manifest confirmation mismatch, got \(error)")
                }
            }
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.ownership.loadAll().isEmpty)
        }
    }

    func testProbeAndHookRuntimeLimitsFailBeforeAnyMutation() throws {
        let image = "registry.example/api@sha256:\(String(repeating: "a", count: 64))"
        let hookArguments = Array(repeating: "\"argument\"", count: 129)
            .joined(separator: ", ")
        let manifests = [
            """
            version: 2
            project: demo
            imagePolicy: require-digest
            services:
              api:
                image: \(image)
                hooks:
                  postStart:
                    exec: [\(hookArguments)]

            """,
            """
            version: 2
            project: demo
            imagePolicy: require-digest
            services:
              api:
                image: \(image)
                probes:
                  startup:
                    exec: ["/bin/true"]
                    timeout: 31s

            """
        ]

        for manifest in manifests {
            try withFixture(manifestOverride: manifest) { fixture in
                let dryOptions = fixture.options(command: .up, dryRun: true)
                let dryDriver = LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: dryOptions
                )
                let preparation = try dryDriver.prepare(options: dryOptions)
                let compiled = try LifecycleCommandPlanCompiler().compile(
                    options: dryOptions,
                    preparation: preparation
                )
                let confirmed = fixture.options(
                    command: .up,
                    dryRun: false,
                    confirmation: compiled.plan.planSHA256
                )
                let result = LifecycleCommandRunner(
                    options: confirmed,
                    driver: LifecycleLiveDriver(
                        environment: fixture.environment,
                        options: confirmed
                    )
                ).run()

                XCTAssertNotEqual(result.exitCode, 0)
                XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
                XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
                XCTAssertTrue(try fixture.store.ownership.loadAll().isEmpty)
            }
        }
    }

    func testRestartPolicyKeysAreReplicaScoped() {
        let first = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "worker",
            instanceName: "replica-1"
        )
        let second = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "worker",
            instanceName: "replica-2"
        )

        XCTAssertEqual(lifecycleRestartPolicyKey(for: first), "worker/replica-1")
        XCTAssertEqual(lifecycleRestartPolicyKey(for: second), "worker/replica-2")
        XCTAssertNotEqual(
            lifecycleRestartPolicyKey(for: first),
            lifecycleRestartPolicyKey(for: second)
        )
    }

    func testConfirmedCreatePersistsIntentAndExactOwnershipWithoutPersistingSecret() throws {
        let secretValue = "phase04-secret-\(UUID().uuidString)"
        let secretStore = RecordingLifecycleSecretStore(value: secretValue)
        try withFixture(secretStore: secretStore, includesSecret: true) { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let dryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let dryPreparation = try dryDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: dryPreparation
            )
            let confirmedOptions = fixture.options(
                command: .up,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            )
            let result = LifecycleCommandRunner(
                options: confirmedOptions,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: confirmedOptions
                )
            ).run()

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(snapshot.mutations, [.create, .start])
            XCTAssertTrue(snapshot.intentWasPresentBeforeEveryMutation)
            XCTAssertEqual(snapshot.createdSecretValues, [secretValue])
            XCTAssertEqual(secretStore.readCount, 2)

            let ownership = try XCTUnwrap(fixture.store.ownership.loadAll().first)
            let createNode = try XCTUnwrap(
                compiled.plan.nodes.first { $0.action == .create }
            )
            XCTAssertEqual(ownership.resourceUUID, createNode.resourceUUID)
            XCTAssertEqual(ownership.resourceGeneration, createNode.resourceGeneration)
            XCTAssertEqual(
                ownership.projectResourceUUID,
                compiled.plan.projectResourceUUID
            )
            XCTAssertEqual(
                ownership.runtimeAdapter,
                RuntimeProviderID.appleContainerCLI.rawValue
            )
            XCTAssertEqual(ownership.providerGeneration, 1)

            let groups = try fixture.store.operationGroups.loadAll()
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups.first?.planHash, compiled.plan.planSHA256)
            XCTAssertEqual(groups.first?.status, .succeeded)
            XCTAssertFalse(groups.first?.intentJSONRedacted.isEmpty ?? true)
            XCTAssertFalse(try fixture.stateBytesContain(secretValue))
        }
    }

    func testCompletedAutomaticCompensationRestoresHealthyDesiredState() throws {
        let secretValue = "phase04-recovery-secret-\(UUID().uuidString)"
        let secretStore = RecordingLifecycleSecretStore(value: secretValue)
        try withFixture(
            secretStore: secretStore,
            includesSecret: true
        ) { fixture in
            XCTAssertEqual(try runConfirmedUp(fixture).exitCode, 0)
            let healthyProject = try fixture.store.desiredStates.loadProject(
                id: fixture.projectID
            )
            let healthyServices = try fixture.store.desiredStates
                .loadDesiredServices(projectID: fixture.projectID)
            fixture.manifestSource.replace(
                fixture.manifestSource.value.replacingOccurrences(
                    of: "    image: registry.example/api@sha256:",
                    with:
                        "    labels:\n" +
                        "      phase: candidate\n" +
                        "    image: registry.example/api@sha256:"
                )
            )

            let dryOptions = fixture.options(command: .update, dryRun: true)
            let dryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try dryDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            XCTAssertNotEqual(
                compiled.plan.manifestSHA256,
                healthyProject.manifestHash
            )
            try fixture.wait {
                await fixture.adapter.failNextStart()
            }
            let confirmed = fixture.options(
                command: .update,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            )

            let result = try LifecycleLiveDriver(
                environment: fixture.environment,
                options: confirmed
            ).execute(
                compiled: compiled,
                preparation: preparation,
                options: confirmed
            )

            XCTAssertEqual(result.status, .compensated)
            XCTAssertEqual(
                try fixture.store.desiredStates.loadProject(
                    id: fixture.projectID
                ),
                healthyProject
            )
            XCTAssertEqual(
                try fixture.store.desiredStates.loadDesiredServices(
                    projectID: fixture.projectID
                ),
                healthyServices
            )
            let group = try XCTUnwrap(
                fixture.store.operationGroups.loadAll().first {
                    $0.planHash == compiled.plan.planSHA256
                }
            )
            XCTAssertEqual(group.status, .failed)
            XCTAssertEqual(group.checkpoint, "compensated")
            XCTAssertNotNil(
                try LifecyclePersistedIntentCodec
                    .decodeRecoveryStateJSONRedacted(
                        group.intentJSONRedacted
                    )
            )
            XCTAssertFalse(group.intentJSONRedacted.contains(secretValue))
            XCTAssertFalse(try fixture.stateBytesContain(secretValue))
        }
    }

    func testMissingSecretInLaterServiceFailsBeforeAnyProjectMutation() throws {
        let secretStore = FailingLifecycleSecretStore(
            diagnostic: "credential=must-not-leak"
        )
        let image = "registry.example/api@sha256:\(String(repeating: "a", count: 64))"
        let manifest = """
        version: 2
        project: demo
        imagePolicy: require-digest
        services:
          first:
            image: \(image)
          later:
            image: \(image)
            secretEnv:
              API_TOKEN: keychain://hostwright.tests/missing-token

        """
        try withFixture(
            secretStore: secretStore,
            manifestOverride: manifest
        ) { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let dryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try dryDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            let confirmedOptions = fixture.options(
                command: .up,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            )
            let result = LifecycleCommandRunner(
                options: confirmedOptions,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: confirmedOptions
                )
            ).run()

            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardError.contains("Configured secret"))
            XCTAssertFalse(result.standardError.contains("must-not-leak"))
            XCTAssertEqual(secretStore.readCount, 1)
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
        }
    }

    func testUnsupportedLaterServiceFailsBeforeAnyProjectMutation() throws {
        let image = "registry.example/api@sha256:\(String(repeating: "a", count: 64))"
        let manifest = """
        version: 2
        project: demo
        imagePolicy: require-digest
        services:
          first:
            image: \(image)
          later:
            image: \(image)
            ports:
              - "80:8080"

        """
        try withFixture(manifestOverride: manifest) { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let dryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try dryDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            let confirmedOptions = fixture.options(
                command: .up,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            )
            let result = LifecycleCommandRunner(
                options: confirmedOptions,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: confirmedOptions
                )
            ).run()

            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardError.contains("unprivileged host ports"))
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
        }
    }

    func testUnmanagedNameCollisionFailsBeforeMutation() throws {
        try withFixture(unmanagedCollision: true) { fixture in
            let options = fixture.options(command: .up, dryRun: true)
            let result = LifecycleCommandRunner(
                options: options,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: options
                )
            ).run()

            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(
                result.standardError.lowercased().contains("collision"),
                result.standardError
            )
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertTrue(try fixture.store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try fixture.store.ownership.loadAll().isEmpty)
        }
    }

    func testRemoveDeletesOnlyExactRuntimeAndOwnershipRecord() throws {
        try withFixture(existingManagedResource: true) { fixture in
            let targetBefore = try XCTUnwrap(
                fixture.store.ownership.loadAll().first {
                    $0.projectID == fixture.projectID
                }
            )
            let sentinelBefore = try XCTUnwrap(
                fixture.store.ownership.loadAll().first {
                    $0.serviceName == "keep"
                }
            )
            let dryOptions = fixture.options(command: .rm, dryRun: true)
            let dryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let dryPreparation = try dryDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: dryPreparation
            )
            let confirmedOptions = fixture.options(
                command: .rm,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            )
            let result = LifecycleCommandRunner(
                options: confirmedOptions,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: confirmedOptions
                )
            ).run()

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            let remaining = try fixture.store.ownership.loadAll()
            XCTAssertFalse(remaining.contains { $0.resourceUUID == targetBefore.resourceUUID })
            XCTAssertTrue(remaining.contains { $0 == sentinelBefore })
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(snapshot.mutations, [.stop, .remove])
            XCTAssertFalse(snapshot.resourceUUIDs.contains(targetBefore.resourceUUID))
            XCTAssertTrue(snapshot.resourceUUIDs.contains(sentinelBefore.resourceUUID))
        }
    }

    func testRemoveRefusesSuccessWhenRuntimeStillKeepsExactResourceUnderPriorFence() throws {
        try withFixture(existingManagedResource: true) { fixture in
            let targetBefore = try XCTUnwrap(
                fixture.store.ownership.loadAll().first {
                    $0.projectID == fixture.projectID
                }
            )
            let dryOptions = fixture.options(command: .rm, dryRun: true)
            let dryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let dryPreparation = try dryDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: dryPreparation
            )
            try fixture.wait {
                await fixture.adapter.setPreserveExistingOwnershipFenceOnMutation(
                    true
                )
                await fixture.adapter.setIgnoreRemoveMutation(true)
            }

            let confirmedOptions = fixture.options(
                command: .rm,
                dryRun: false,
                confirmation: compiled.plan.planSHA256
            )
            let result = LifecycleCommandRunner(
                options: confirmedOptions,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: confirmedOptions
                )
            ).run()

            XCTAssertNotEqual(result.exitCode, 0)
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(snapshot.mutations, [.stop, .remove])
            XCTAssertTrue(snapshot.resourceUUIDs.contains(targetBefore.resourceUUID))
            XCTAssertTrue(
                try fixture.store.ownership.loadAll().contains {
                    $0.resourceIdentifier == targetBefore.resourceIdentifier
                }
            )
        }
    }

    func testRunPersistsEphemeralOwnershipForExactNormalRemove() throws {
        try withFixture { fixture in
            let runDryOptions = fixture.options(command: .run, dryRun: true)
            let runDryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: runDryOptions
            )
            let runPreparation = try runDryDriver.prepare(options: runDryOptions)
            let runCompiled = try LifecycleCommandPlanCompiler().compile(
                options: runDryOptions,
                preparation: runPreparation
            )
            let runConfirmedOptions = fixture.options(
                command: .run,
                dryRun: false,
                confirmation: runCompiled.plan.planSHA256
            )
            let runResult = LifecycleCommandRunner(
                options: runConfirmedOptions,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: runConfirmedOptions
                )
            ).run()

            XCTAssertEqual(runResult.exitCode, 0, runResult.standardError)
            let runRecord = try XCTUnwrap(fixture.store.ownership.loadAll().first)
            let runServiceName = try XCTUnwrap(
                runCompiled.plan.nodes.first?.serviceName
            )
            XCTAssertTrue(
                runServiceName.range(
                    of: #"run-[a-f0-9]{12}$"#,
                    options: .regularExpression
                ) != nil
            )
            XCTAssertEqual(
                runRecord.resourceIdentifier,
                runCompiled.plan.nodes.first?.resourceIdentifier
            )

            let removeDryOptions = fixture.options(command: .rm, dryRun: true)
            let removeDryDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: removeDryOptions
            )
            let removePreparation = try removeDryDriver.prepare(
                options: removeDryOptions
            )
            XCTAssertEqual(
                removePreparation.resourceBindings.map(\.resourceUUID),
                [runRecord.resourceUUID]
            )
            let removeCompiled = try LifecycleCommandPlanCompiler().compile(
                options: removeDryOptions,
                preparation: removePreparation
            )
            XCTAssertEqual(
                removeCompiled.plan.nodes.map(\.action),
                [.delete]
            )
            XCTAssertTrue(
                removeCompiled.plan.nodes.allSatisfy {
                    $0.resourceUUID == runRecord.resourceUUID
                }
            )
            let removeConfirmedOptions = fixture.options(
                command: .rm,
                dryRun: false,
                confirmation: removeCompiled.plan.planSHA256
            )
            let removeResult = LifecycleCommandRunner(
                options: removeConfirmedOptions,
                driver: LifecycleLiveDriver(
                    environment: fixture.environment,
                    options: removeConfirmedOptions
                )
            ).run()

            XCTAssertEqual(removeResult.exitCode, 0, removeResult.standardError)
            XCTAssertTrue(try fixture.store.ownership.loadAll().isEmpty)
            XCTAssertEqual(
                try fixture.adapterSnapshot().mutations,
                [.create, .start, .remove]
            )
            XCTAssertTrue(try fixture.adapterSnapshot().resourceUUIDs.isEmpty)
        }
    }

    func testPersistedRecoveryResumeUsesExactInterruptedSaga() throws {
        try withFixture { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let liveDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try liveDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            try persistLifecycleProject(
                fixture: fixture,
                preparation: preparation
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: compiled.plan,
                status: .interrupted,
                completedNodeKeys: []
            )
            XCTAssertEqual(sourceGroup.planHash, compiled.plan.planSHA256)
            let persistedPlan = try LifecyclePersistedIntentCodec.decode(
                sourceGroup.intentJSONRedacted
            )
            XCTAssertEqual(persistedPlan.planSHA256, sourceGroup.planHash)
            XCTAssertTrue(
                persistedPlan.nodes.allSatisfy {
                    $0.fencingToken == sourceGroup.fencingToken
                }
            )

            let result = try LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: .resume,
                    groupID: sourceGroup.id,
                    confirmationPlanSHA256: compiled.plan.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 60
                )
            )
            XCTAssertEqual(result.status, .succeeded)
            XCTAssertEqual(result.groupID, sourceGroup.id)
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [.create, .start])
        }
    }

    func testPersistedRecoveryReclaimsExactExpiredActiveLeaseAfterReobservation() throws {
        try withFixture { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let liveDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try liveDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            try persistLifecycleProject(
                fixture: fixture,
                preparation: preparation
            )
            let node = try XCTUnwrap(compiled.plan.nodes.first)
            let groupID = HostwrightResourceUUID.legacy(
                kind: "expired-recovery-source-group",
                identifier: compiled.plan.planSHA256
            )
            let operationID = HostwrightResourceUUID.legacy(
                kind: "expired-recovery-source-operation",
                identifier: groupID
            )
            XCTAssertNotNil(
                try fixture.store.operationGroups.acquire(
                    OperationGroupRecord(
                        id: groupID,
                        operationID: operationID,
                        groupKind: "lifecycle-v1",
                        projectID: compiled.plan.projectID,
                        serviceName: nil,
                        plannedActionType: compiled.plan.command.rawValue,
                        status: .active,
                        groupIdempotencyKey: compiled.plan.planSHA256,
                        planHash: compiled.plan.planSHA256,
                        checkpoint: "\(node.key):effect-pending",
                        lockOwner: "terminated-recovery-test",
                        lockExpiresAt: "2000-01-01T00:10:00Z",
                        rollbackAvailable: true,
                        manualRecoveryHintRedacted: "",
                        createdAt: "2000-01-01T00:00:00Z",
                        updatedAt: "2000-01-01T00:00:00Z",
                        metadataJSONRedacted: "{}",
                        fencingToken: node.fencingToken,
                        intentJSONRedacted:
                            try LifecyclePersistedIntentCodec.encode(
                                compiled.plan
                            ),
                        compensationJSONRedacted: "[]",
                        verificationJSONRedacted:
                            #"{"checkpoint":"effect-pending"}"#
                    ),
                    currentTimestamp: "2000-01-01T00:00:00Z"
                ).acquired
            )
            try fixture.store.operationGroupSteps.append(
                OperationGroupStepRecord(
                    id: HostwrightResourceUUID.generate(),
                    groupID: groupID,
                    stepKey: node.key,
                    direction: .forward,
                    plannedActionType: node.action.rawValue,
                    serviceName: node.serviceName,
                    resourceIdentifier: node.resourceIdentifier,
                    stepIdempotencyKey:
                        "\(node.idempotencyKey):forward:1",
                    status: .started,
                    startedAt: "2000-01-01T00:00:00Z",
                    updatedAt: "2000-01-01T00:00:00Z",
                    finishedAt: nil,
                    lastErrorRedacted: nil,
                    manualRecoveryHintRedacted: "",
                    metadataJSONRedacted: #"{"attempt":1}"#
                ),
                expectedFencingToken: node.fencingToken
            )

            let result = try LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: .resume,
                    groupID: groupID,
                    confirmationPlanSHA256: compiled.plan.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 60
                )
            )

            XCTAssertEqual(result.status, .succeeded)
            XCTAssertEqual(
                try fixture.adapterSnapshot().mutations,
                [.create, .start]
            )
            let steps = try fixture.store.operationGroupSteps.load(
                groupID: groupID
            )
            XCTAssertEqual(
                steps.filter {
                    $0.stepKey == node.key && $0.status == .started
                }.count,
                2
            )
            XCTAssertEqual(
                steps.filter {
                    $0.stepKey == node.key && $0.status == .succeeded
                }.count,
                1
            )
        }
    }

    func testPersistedRecoveryTimeoutInterruptsBeforeMutationAndRemainsResumable()
        throws
    {
        try withFixture { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let liveDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try liveDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            try persistLifecycleProject(
                fixture: fixture,
                preparation: preparation
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: compiled.plan,
                status: .interrupted,
                completedNodeKeys: []
            )
            let driver = LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            )
            try fixture.wait {
                await fixture.adapter.setMutationDelayNanoseconds(
                    2_000_000_000
                )
            }

            let interrupted = try driver.execute(
                LifecyclePersistedRecoveryRequest(
                    action: .resume,
                    groupID: sourceGroup.id,
                    confirmationPlanSHA256: compiled.plan.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 1
                )
            )

            XCTAssertEqual(interrupted.status, .interrupted)
            XCTAssertTrue(interrupted.checkpoint.contains("cancelled"))
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertEqual(
                try XCTUnwrap(
                    fixture.store.operationGroups.load(id: sourceGroup.id)
                ).status,
                .interrupted
            )

            try fixture.wait {
                await fixture.adapter.setMutationDelayNanoseconds(0)
            }
            let resumed = try driver.execute(
                LifecyclePersistedRecoveryRequest(
                    action: .resume,
                    groupID: sourceGroup.id,
                    confirmationPlanSHA256: compiled.plan.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 60
                )
            )

            XCTAssertEqual(resumed.status, .succeeded)
            XCTAssertEqual(
                try fixture.adapterSnapshot().mutations,
                [.create, .start]
            )
        }
    }

    func testPersistedRollbackTimeoutInterruptsBeforeInverseAndRemainsResumable()
        throws
    {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(
                fixture: fixture,
                manifestSHA256: String(repeating: "c", count: 64)
            )
            let healthySnapshot = try XCTUnwrap(
                fixture.store.desiredStates.loadRecoverySnapshot(
                    projectID: fixture.projectID
                )
            )
            try seedCompletedUpdate(
                fixture: fixture,
                update: update
            )
            try fixture.store.desiredStates.saveManifestSnapshot(
                projectID: fixture.projectID,
                manifestPath: fixture.manifestPath,
                manifestHash: update.plan.manifestSHA256,
                desiredGeneration: update.plan.providerGeneration,
                manifest: HostwrightManifest(
                    project: "demo",
                    services: [
                        HostwrightService(
                            name: "api",
                            image: update.candidateDesired.image
                        )
                    ]
                ),
                timestamp: "2026-07-23T12:00:01Z",
                mutationProvider: update.plan.providerID.rawValue
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: update.completedNodeKeys,
                recoveryStateJSONRedacted:
                    try lifecycleRecoveryStateJSONRedacted(healthySnapshot)
            )
            let request = LifecyclePersistedRecoveryRequest(
                action: .rollback,
                groupID: sourceGroup.id,
                confirmationPlanSHA256: update.plan.planSHA256,
                stateStoreConfiguration: StateStoreConfiguration(
                    explicitDatabasePath: fixture.databasePath
                ),
                timeoutSeconds: 1
            )
            let driver = LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            )
            try fixture.wait {
                await fixture.adapter.setMutationDelayNanoseconds(
                    2_000_000_000
                )
            }

            let interrupted = try driver.execute(request)

            XCTAssertEqual(interrupted.status, .interrupted)
            XCTAssertTrue(interrupted.checkpoint.contains("cancelled"))
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
            XCTAssertEqual(
                try XCTUnwrap(
                    fixture.store.operationGroups.load(id: interrupted.groupID)
                ).status,
                .interrupted
            )

            try fixture.wait {
                await fixture.adapter.setMutationDelayNanoseconds(0)
            }
            let resumed = try driver.execute(
                LifecyclePersistedRecoveryRequest(
                    action: .resume,
                    groupID: interrupted.groupID,
                    confirmationPlanSHA256: interrupted.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 60
                )
            )

            XCTAssertEqual(resumed.status, .succeeded)
            XCTAssertEqual(
                try fixture.adapterSnapshot().mutations,
                [.create, .stop, .stop, .remove]
            )
            XCTAssertEqual(
                try fixture.store.desiredStates.loadProject(
                    id: fixture.projectID
                ),
                healthySnapshot.project
            )
            XCTAssertEqual(
                try fixture.store.desiredStates.loadDesiredServices(
                    projectID: fixture.projectID
                ),
                healthySnapshot.desiredServices
            )
        }
    }

    func testPersistedRecoveryRejectsConfirmationGroupAndStatusBeforeMutation() throws {
        try withFixture { fixture in
            let dryOptions = fixture.options(command: .up, dryRun: true)
            let liveDriver = LifecycleLiveDriver(
                environment: fixture.environment,
                options: dryOptions
            )
            let preparation = try liveDriver.prepare(options: dryOptions)
            let compiled = try LifecycleCommandPlanCompiler().compile(
                options: dryOptions,
                preparation: preparation
            )
            try persistLifecycleProject(
                fixture: fixture,
                preparation: preparation
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: compiled.plan,
                status: .failed,
                completedNodeKeys: []
            )
            let driver = LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            )
            let configuration = StateStoreConfiguration(
                explicitDatabasePath: fixture.databasePath
            )

            XCTAssertThrowsError(
                try driver.execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .resume,
                        groupID: sourceGroup.id,
                        confirmationPlanSHA256:
                            String(repeating: "f", count: 64),
                        stateStoreConfiguration: configuration,
                        timeoutSeconds: 60
                    )
                )
            ) {
                XCTAssertEqual(
                    $0 as? LifecyclePersistedRecoveryError,
                    .confirmationMismatch
                )
            }
            XCTAssertThrowsError(
                try driver.execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .resume,
                        groupID: HostwrightResourceUUID.generate(),
                        confirmationPlanSHA256: compiled.plan.planSHA256,
                        stateStoreConfiguration: configuration,
                        timeoutSeconds: 60
                    )
                )
            )
            XCTAssertThrowsError(
                try driver.execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .resume,
                        groupID: sourceGroup.id,
                        confirmationPlanSHA256: compiled.plan.planSHA256,
                        stateStoreConfiguration: configuration,
                        timeoutSeconds: 60
                    )
                )
            )
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
        }
    }

    func testPersistedRollbackRunsExactReverseOrderThroughSharedSaga() throws {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(fixture: fixture)
            try seedCompletedUpdate(
                fixture: fixture,
                update: update
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: update.completedNodeKeys
            )

            let result = try LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: .rollback,
                    groupID: sourceGroup.id,
                    confirmationPlanSHA256: update.plan.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 60
                )
            )
            XCTAssertEqual(result.status, .succeeded)
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(snapshot.mutations, [.create, .stop, .stop, .remove])
            XCTAssertEqual(
                snapshot.mutationResourceUUIDs,
                [
                    update.oldResourceUUID,
                    update.candidateResourceUUID,
                    update.candidateResourceUUID,
                    update.candidateResourceUUID
                ]
            )
            let sentinelResourceUUID = HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: "sentinel/keep"
            )
            XCTAssertEqual(
                Set(snapshot.resourceUUIDs),
                Set([update.oldResourceUUID, sentinelResourceUUID])
            )
            XCTAssertFalse(
                snapshot.resourceUUIDs.contains(update.candidateResourceUUID)
            )
        }
    }

    func testPersistedRollbackReobservesInterruptedEffectPendingAndCleansExactResource()
        throws
    {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(fixture: fixture)
            let create = try XCTUnwrap(
                update.plan.nodes.first {
                    $0.action == .create &&
                        $0.resourceUUID == update.candidateResourceUUID
                }
            )
            let start = try XCTUnwrap(
                update.plan.nodes.first {
                    $0.action == .start &&
                        $0.resourceUUID == update.candidateResourceUUID
                }
            )
            try seedRecoveryCandidate(
                fixture: fixture,
                update: update,
                lifecycle: .running
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .interrupted,
                completedNodeKeys: [create.key],
                terminalCheckpoint: "\(start.key):effect-pending"
            )
            try appendStartedRecoveryStep(
                store: fixture.store,
                group: sourceGroup,
                node: start
            )

            let result = try LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: .rollback,
                    groupID: sourceGroup.id,
                    confirmationPlanSHA256: update.plan.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 60
                )
            )

            XCTAssertEqual(result.status, .succeeded)
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(snapshot.mutations, [.stop, .remove])
            XCTAssertEqual(
                snapshot.mutationResourceUUIDs,
                [update.candidateResourceUUID, update.candidateResourceUUID]
            )
            XCTAssertFalse(
                snapshot.resourceUUIDs.contains(update.candidateResourceUUID)
            )
            XCTAssertTrue(snapshot.resourceUUIDs.contains(update.oldResourceUUID))
            XCTAssertFalse(
                try fixture.store.ownership.loadAll().contains {
                    $0.resourceUUID == update.candidateResourceUUID
                }
            )
        }
    }

    func testPersistedRollbackExcludesReobservedInterruptedNoEffect() throws {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(fixture: fixture)
            let create = try XCTUnwrap(
                update.plan.nodes.first {
                    $0.action == .create &&
                        $0.resourceUUID == update.candidateResourceUUID
                }
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .interrupted,
                completedNodeKeys: [],
                terminalCheckpoint: "\(create.key):effect-pending"
            )
            try appendStartedRecoveryStep(
                store: fixture.store,
                group: sourceGroup,
                node: create
            )

            let result = try LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            ).execute(
                LifecyclePersistedRecoveryRequest(
                    action: .rollback,
                    groupID: sourceGroup.id,
                    confirmationPlanSHA256: update.plan.planSHA256,
                    stateStoreConfiguration: StateStoreConfiguration(
                        explicitDatabasePath: fixture.databasePath
                    ),
                    timeoutSeconds: 60
                )
            )

            XCTAssertEqual(result.status, .succeeded)
            XCTAssertTrue(result.completedNodeKeys.isEmpty)
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
        }
    }

    func testCompletedCompensationRecoveryRestoresExactObservedResourceFence()
        throws
    {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(
                fixture: fixture,
                manifestSHA256: String(repeating: "c", count: 64)
            )
            let healthySnapshot = try XCTUnwrap(
                fixture.store.desiredStates.loadRecoverySnapshot(
                    projectID: fixture.projectID
                )
            )
            try fixture.store.desiredStates.saveManifestSnapshot(
                projectID: fixture.projectID,
                manifestPath: fixture.manifestPath,
                manifestHash: update.plan.manifestSHA256,
                desiredGeneration: update.plan.providerGeneration,
                manifest: HostwrightManifest(
                    project: "demo",
                    services: [
                        HostwrightService(
                            name: "api",
                            image: update.candidateDesired.image
                        )
                    ]
                ),
                timestamp: "2026-07-23T12:00:01Z",
                mutationProvider: update.plan.providerID.rawValue
            )
            XCTAssertNotEqual(
                try fixture.store.desiredStates.loadDesiredServices(
                    projectID: fixture.projectID
                ),
                healthySnapshot.desiredServices
            )
            let oldRecord = try XCTUnwrap(
                fixture.store.ownership.loadAll().first {
                    $0.resourceUUID == update.oldResourceUUID
                }
            )
            let operationFence = try XCTUnwrap(
                update.plan.nodes.first?.fencingToken
            )
            XCTAssertNotEqual(oldRecord.fencingToken, operationFence)
            XCTAssertNotNil(
                try fixture.store.ownership.advanceFencingToken(
                    resourceIdentifier: oldRecord.resourceIdentifier,
                    runtimeAdapter: oldRecord.runtimeAdapter,
                    expectedResourceUUID: oldRecord.resourceUUID,
                    expectedFencingToken: oldRecord.fencingToken,
                    newFencingToken: operationFence,
                    observedAt: "2026-07-23T12:00:01Z"
                )
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: [],
                terminalCheckpoint: "compensated",
                terminalMetadataJSONRedacted:
                    #"{"result":"compensated"}"#,
                recoveryStateJSONRedacted:
                    try lifecycleRecoveryStateJSONRedacted(healthySnapshot)
            )
            try fixture.wait {
                await fixture.adapter.setStrictOwnedHintFences(true)
            }
            let request = LifecyclePersistedRecoveryRequest(
                action: .rollback,
                groupID: sourceGroup.id,
                confirmationPlanSHA256: update.plan.planSHA256,
                stateStoreConfiguration: StateStoreConfiguration(
                    explicitDatabasePath: fixture.databasePath
                ),
                timeoutSeconds: 60
            )
            let driver = LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            )

            let result = try driver.execute(request)

            XCTAssertEqual(result.status, .alreadySucceeded)
            XCTAssertEqual(
                result.checkpoint,
                "compensated-projection-verified"
            )
            let restored = try XCTUnwrap(
                fixture.store.ownership.loadAll().first {
                    $0.resourceUUID == update.oldResourceUUID
                }
            )
            XCTAssertEqual(restored.fencingToken, oldRecord.fencingToken)
            XCTAssertEqual(
                try fixture.store.desiredStates.loadProject(
                    id: fixture.projectID
                ),
                healthySnapshot.project
            )
            XCTAssertEqual(
                try fixture.store.desiredStates.loadDesiredServices(
                    projectID: fixture.projectID
                ),
                healthySnapshot.desiredServices
            )
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])

            let repeated = try driver.execute(request)
            XCTAssertEqual(repeated.status, .alreadySucceeded)
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
        }
    }

    func testPersistedRollbackSafeHoldPreservesRecoveryDetailsInTextAndJSON()
        throws
    {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(
                fixture: fixture,
                preStopHook: ["/bin/drain"]
            )
            let hook = try XCTUnwrap(
                update.plan.nodes.first { $0.action == .runHook }
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: [hook.key]
            )
            let baseArguments = [
                "recovery", "rollback",
                "--group", sourceGroup.id,
                "--confirm-plan", update.plan.planSHA256,
                "--state-db", fixture.databasePath
            ]
            let expectedCommands = [
                "hostwright inspect --output json",
                "hostwright recovery --output json",
                "hostwright update --dry-run"
            ]

            let text = HostwrightCLI.run(
                arguments: baseArguments,
                environment: fixture.environment
            )
            XCTAssertEqual(
                text.exitCode,
                CLIExitCode.partialFailure.rawValue,
                text.standardError
            )
            XCTAssertTrue(
                text.standardError.contains("Affected nodes: \(hook.key)")
            )
            XCTAssertTrue(
                text.standardError.contains(
                    "Operator commands:\n" +
                        expectedCommands.map { "- \($0)" }.joined(separator: "\n")
                )
            )

            let json = HostwrightCLI.run(
                arguments: baseArguments + ["--output", "json"],
                environment: fixture.environment
            )
            XCTAssertEqual(
                json.exitCode,
                CLIExitCode.partialFailure.rawValue,
                json.standardError
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(json.standardError.utf8)
                ) as? [String: Any]
            )
            let expectedMessage = RuntimeRedactionPolicy.default.redact(
                "Hook \(hook.key) completed and its external effects cannot be inverted safely."
            ) + " Recovery remains in safe hold."
            XCTAssertEqual(
                object["message"] as? String,
                expectedMessage
            )
            XCTAssertEqual(
                object["affectedNodeKeys"] as? [String],
                [hook.key]
            )
            XCTAssertEqual(
                object["operatorCommands"] as? [String],
                expectedCommands
            )
        }
    }

    func testPersistedRollbackResumesWithoutDuplicateInverseAfterCancellation() throws {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(fixture: fixture)
            try seedCompletedUpdate(
                fixture: fixture,
                update: update
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: update.completedNodeKeys
            )
            try fixture.wait {
                await fixture.adapter.cancelBeforeMutation(at: 1)
            }
            let request = LifecyclePersistedRecoveryRequest(
                action: .rollback,
                groupID: sourceGroup.id,
                confirmationPlanSHA256: update.plan.planSHA256,
                stateStoreConfiguration: StateStoreConfiguration(
                    explicitDatabasePath: fixture.databasePath
                ),
                timeoutSeconds: 60
            )
            let driver = LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            )

            let interrupted = try driver.execute(request)
            XCTAssertEqual(interrupted.status, .interrupted)
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [.create])

            let resumed = try driver.execute(request)
            XCTAssertEqual(resumed.status, .succeeded)
            let snapshot = try fixture.adapterSnapshot()
            XCTAssertEqual(snapshot.mutations, [.create, .stop, .stop, .remove])
            XCTAssertEqual(
                snapshot.mutationResourceUUIDs.filter {
                    $0 == update.oldResourceUUID
                }.count,
                1
            )
            let sentinelResourceUUID = HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: "sentinel/keep"
            )
            XCTAssertEqual(
                Set(snapshot.resourceUUIDs),
                Set([update.oldResourceUUID, sentinelResourceUUID])
            )
            XCTAssertFalse(
                snapshot.resourceUUIDs.contains(update.candidateResourceUUID)
            )
        }
    }

    func testPersistedRollbackSafeHoldsForIrreversibleHookAndMissingOwnership() throws {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(
                fixture: fixture,
                preStopHook: ["/bin/drain"]
            )
            let hook = try XCTUnwrap(
                update.plan.nodes.first { $0.action == .runHook }
            )
            let hookGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: [hook.key]
            )
            let driver = LifecyclePersistedRecoveryDriver(
                environment: fixture.environment
            )
            let configuration = StateStoreConfiguration(
                explicitDatabasePath: fixture.databasePath
            )

            XCTAssertThrowsError(
                try driver.execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .rollback,
                        groupID: hookGroup.id,
                        confirmationPlanSHA256: update.plan.planSHA256,
                        stateStoreConfiguration: configuration,
                        timeoutSeconds: 60
                    )
                )
            ) {
                guard case .safeHold =
                    $0 as? LifecyclePersistedRecoveryError else {
                    return XCTFail("Expected irreversible-hook safe hold, got \($0)")
                }
            }
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
        }

        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(fixture: fixture)
            let create = try XCTUnwrap(
                update.plan.nodes.first {
                    $0.action == .create &&
                        $0.resourceUUID == update.candidateResourceUUID
                }
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: [create.key]
            )

            XCTAssertThrowsError(
                try LifecyclePersistedRecoveryDriver(
                    environment: fixture.environment
                ).execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .rollback,
                        groupID: sourceGroup.id,
                        confirmationPlanSHA256: update.plan.planSHA256,
                        stateStoreConfiguration: StateStoreConfiguration(
                            explicitDatabasePath: fixture.databasePath
                        ),
                        timeoutSeconds: 60
                    )
                )
            ) {
                guard case .safeHold =
                    $0 as? LifecyclePersistedRecoveryError else {
                    return XCTFail("Expected missing-ownership safe hold, got \($0)")
                }
            }
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
        }
    }

    func testPersistedRollbackDoesNotUseCrossProjectOwnershipAsProof() throws {
        try withFixture(existingManagedResource: true) { fixture in
            let update = try recoveryUpdateFixture(fixture: fixture)
            let create = try XCTUnwrap(
                update.plan.nodes.first {
                    $0.action == .create &&
                        $0.resourceUUID == update.candidateResourceUUID
                }
            )
            try fixture.store.desiredStates.saveManifestSnapshot(
                projectID: "project-foreign",
                manifestPath: nil,
                manifestHash: String(repeating: "f", count: 64),
                desiredGeneration: 1,
                manifest: HostwrightManifest(
                    project: "foreign",
                    services: [
                        HostwrightService(
                            name: "api",
                            image: update.candidateDesired.image
                        )
                    ]
                ),
                timestamp: "2026-07-23T12:00:00Z",
                mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
            )
            let foreignProject = try fixture.store.desiredStates.loadProject(
                id: "project-foreign"
            )
            try fixture.store.ownership.upsert(
                OwnershipRecord(
                    id: "ownership-foreign-candidate",
                    resourceIdentifier: update.candidateResourceIdentifier,
                    resourceType: "container",
                    projectID: foreignProject.id,
                    serviceName: "api",
                    runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                    createdAt: "2026-07-23T12:00:00Z",
                    observedAt: "2026-07-23T12:00:00Z",
                    cleanupEligible: true,
                    metadataJSONRedacted: "{}",
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    resourceUUID: update.candidateResourceUUID,
                    resourceGeneration: create.resourceGeneration,
                    projectResourceUUID: foreignProject.resourceUUID,
                    projectGeneration: foreignProject.providerGeneration,
                    providerGeneration: update.plan.providerGeneration,
                    fencingToken: create.fencingToken
                )
            )
            let sourceGroup = try persistLifecycleGroup(
                store: fixture.store,
                plan: update.plan,
                status: .failed,
                completedNodeKeys: [create.key]
            )

            XCTAssertThrowsError(
                try LifecyclePersistedRecoveryDriver(
                    environment: fixture.environment
                ).execute(
                    LifecyclePersistedRecoveryRequest(
                        action: .rollback,
                        groupID: sourceGroup.id,
                        confirmationPlanSHA256: update.plan.planSHA256,
                        stateStoreConfiguration: StateStoreConfiguration(
                            explicitDatabasePath: fixture.databasePath
                        ),
                        timeoutSeconds: 60
                    )
                )
            ) {
                guard case .safeHold =
                    $0 as? LifecyclePersistedRecoveryError else {
                    return XCTFail("Expected cross-project ownership safe hold, got \($0)")
                }
            }
            XCTAssertEqual(try fixture.store.operationGroups.loadAll().count, 1)
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, [])
        }
    }
}

private struct LifecycleRecoveryUpdateFixture {
    let plan: LifecyclePlan
    let oldDesired: DesiredRuntimeService
    let candidateDesired: DesiredRuntimeService
    let oldResourceIdentifier: String
    let oldResourceUUID: String
    let candidateResourceIdentifier: String
    let candidateResourceUUID: String
    let completedNodeKeys: Set<String>
}

private func recoveryUpdateFixture(
    fixture: LifecycleLiveDriverFixture,
    preStopHook: [String]? = nil,
    manifestSHA256: String = String(repeating: "a", count: 64)
) throws -> LifecycleRecoveryUpdateFixture {
    let oldRecord = try XCTUnwrap(
        fixture.store.ownership.loadAll().first {
            $0.projectID == fixture.projectID &&
                $0.serviceName == "api"
        }
    )
    let identity = RuntimeServiceIdentity(
        projectName: "demo",
        serviceName: "api"
    )
    let policy = RuntimeUpdatePolicy(
        strategy: .rolling,
        maxSurge: 1,
        maxUnavailable: 0,
        progressDeadlineSeconds: 120
    )
    let oldDesired = DesiredRuntimeService(
        identity: identity,
        image:
            "registry.example/api@sha256:\(String(repeating: "a", count: 64))",
        updatePolicy: policy,
        hooks: RuntimeLifecycleHooks(preStop: preStopHook),
        virtualization: false
    )
    let candidateDesired = DesiredRuntimeService(
        identity: identity,
        image:
            "registry.example/api@sha256:\(String(repeating: "b", count: 64))",
        updatePolicy: policy,
        virtualization: false
    )
    let candidateIdentity = RuntimeServiceIdentity(
        projectName: "demo",
        serviceName: "api",
        instanceName: "candidate-g2"
    )
    let candidateIdentifier = candidateIdentity.managedResourceIdentifier
    let candidateUUID = HostwrightResourceUUID.legacy(
        kind: "service-revision",
        identifier: "\(oldRecord.resourceUUID):2:candidate"
    )
    let project = try fixture.store.desiredStates.loadProject(
        id: fixture.projectID
    )
    let capability = lifecycleLiveCapability(build: "25F90")
    let observationSHA256 = String(repeating: "b", count: 64)
    let planFence = lifecyclePlanFence(
        command: .update,
        manifestSHA256: manifestSHA256,
        observationSHA256: observationSHA256,
        capabilitySHA256: capability.canonicalSHA256,
        projectID: fixture.projectID,
        providerID: .appleContainerCLI,
        providerGeneration: 1,
        selectedServices: ["api"],
        timeoutSeconds: policy.progressDeadlineSeconds,
        parallelism: 1,
        resourceBindings: [
            try LifecycleResourceBinding(
                record: oldRecord,
                identity: identity,
                providerID: .appleContainerCLI
            )
        ]
    )
    let update = try LifecycleUpdatePlanner().plan(
        previous: DesiredRuntimeState(
            projectName: "demo",
            services: [oldDesired]
        ),
        desired: DesiredRuntimeState(
            projectName: "demo",
            services: [candidateDesired]
        ),
        resources: [
            identity: LifecycleUpdateResourceIdentity(
                identity: identity,
                currentResourceIdentifier: oldRecord.resourceIdentifier,
                currentResourceUUID: oldRecord.resourceUUID,
                currentGeneration: oldRecord.resourceGeneration,
                candidateResourceIdentifier: candidateIdentifier,
                candidateResourceUUID: candidateUUID,
                candidateGeneration: oldRecord.resourceGeneration + 1
            )
        ],
        fencingToken: planFence
    )
    let plan = try LifecyclePlan(
        command: .update,
        projectID: fixture.projectID,
        projectName: "demo",
        projectResourceUUID: project.resourceUUID,
        projectGeneration: 1,
        providerID: .appleContainerCLI,
        providerGeneration: 1,
        manifestSHA256: manifestSHA256,
        observationSHA256: observationSHA256,
        capabilitySHA256: capability.canonicalSHA256,
        parallelism: 1,
        nodes: update.nodes
    )
    let completedActions: Set<LifecyclePlanAction> = [
        .create,
        .start,
        .promote,
        .retire
    ]
    return LifecycleRecoveryUpdateFixture(
        plan: plan,
        oldDesired: oldDesired,
        candidateDesired: candidateDesired,
        oldResourceIdentifier: oldRecord.resourceIdentifier,
        oldResourceUUID: oldRecord.resourceUUID,
        candidateResourceIdentifier: candidateIdentifier,
        candidateResourceUUID: candidateUUID,
        completedNodeKeys: Set(
            plan.nodes.filter {
                completedActions.contains($0.action)
            }.map(\.key)
        )
    )
}

private func seedCompletedUpdate(
    fixture: LifecycleLiveDriverFixture,
    update: LifecycleRecoveryUpdateFixture
) throws {
    let oldRecord = try XCTUnwrap(
        fixture.store.ownership.loadAll().first {
            $0.resourceUUID == update.oldResourceUUID
        }
    )
    XCTAssertTrue(
        try fixture.store.ownership.removeExact(
            resourceIdentifier: oldRecord.resourceIdentifier,
            runtimeAdapter: oldRecord.runtimeAdapter,
            expectedResourceUUID: oldRecord.resourceUUID,
            expectedFencingToken: oldRecord.fencingToken
        )
    )
    let candidateRecord = OwnershipRecord(
        id: "ownership-candidate",
        resourceIdentifier: update.candidateResourceIdentifier,
        resourceType: "container",
        projectID: fixture.projectID,
        serviceName: "api",
        runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
        createdAt: "2026-07-23T12:00:00Z",
        observedAt: "2026-07-23T12:00:00Z",
        cleanupEligible: true,
        metadataJSONRedacted: "{}",
        identityVersion: RuntimeManagedResourceIdentity.currentVersion,
        resourceUUID: update.candidateResourceUUID,
        resourceGeneration: 2,
        projectResourceUUID: oldRecord.projectResourceUUID,
        projectGeneration: oldRecord.projectGeneration,
        providerGeneration: oldRecord.providerGeneration,
        fencingToken: update.plan.nodes[0].fencingToken
    )
    try fixture.store.ownership.upsert(candidateRecord)
    let candidateProjectUUID = try XCTUnwrap(
        candidateRecord.projectResourceUUID
    )
    let candidateOwnership = RuntimeInventoryOwnershipEvidence(
        resourceUUID: candidateRecord.resourceUUID,
        projectUUID: candidateProjectUUID,
        resourceGeneration: candidateRecord.resourceGeneration,
        projectGeneration: candidateRecord.projectGeneration,
        providerID: .appleContainerCLI,
        providerGeneration: candidateRecord.providerGeneration,
        fencingToken: candidateRecord.fencingToken
    )
    try fixture.wait {
        await fixture.adapter.seedUpdateState(
            retiredResourceUUID: update.oldResourceUUID,
            candidate: update.candidateDesired,
            candidateResourceIdentifier: update.candidateResourceIdentifier,
            candidateOwnership: candidateOwnership
        )
    }
}

private func seedRecoveryCandidate(
    fixture: LifecycleLiveDriverFixture,
    update: LifecycleRecoveryUpdateFixture,
    lifecycle: RuntimeInventoryLifecycleState
) throws {
    let create = try XCTUnwrap(
        update.plan.nodes.first {
            $0.action == .create &&
                $0.resourceUUID == update.candidateResourceUUID
        }
    )
    let desired = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(
        create.desiredSpecificationJSONRedacted
    )
    let record = OwnershipRecord(
        id: "ownership-interrupted-candidate",
        resourceIdentifier: update.candidateResourceIdentifier,
        resourceType: "container",
        projectID: fixture.projectID,
        serviceName: "api",
        runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
        createdAt: "2026-07-23T12:00:00Z",
        observedAt: "2026-07-23T12:00:00Z",
        cleanupEligible: true,
        metadataJSONRedacted: "{}",
        identityVersion: RuntimeManagedResourceIdentity.currentVersion,
        resourceUUID: update.candidateResourceUUID,
        resourceGeneration: create.resourceGeneration,
        projectResourceUUID: update.plan.projectResourceUUID,
        projectGeneration: update.plan.projectGeneration,
        providerGeneration: update.plan.providerGeneration,
        fencingToken: create.fencingToken
    )
    try fixture.store.ownership.upsert(record)
    let ownership = RuntimeInventoryOwnershipEvidence(
        resourceUUID: record.resourceUUID,
        projectUUID: update.plan.projectResourceUUID,
        resourceGeneration: record.resourceGeneration,
        projectGeneration: update.plan.projectGeneration,
        providerID: update.plan.providerID,
        providerGeneration: update.plan.providerGeneration,
        fencingToken: create.fencingToken
    )
    try fixture.wait {
        await fixture.adapter.seedRecoveryResource(
            desired: desired,
            resourceIdentifier: update.candidateResourceIdentifier,
            lifecycle: lifecycle,
            ownership: ownership
        )
    }
}

private func appendStartedRecoveryStep(
    store: SQLiteStateStore,
    group: OperationGroupRecord,
    node: LifecyclePlanNode
) throws {
    let timestamp = "2026-07-23T12:00:01Z"
    try store.operationGroupSteps.append(
        OperationGroupStepRecord(
            id: HostwrightResourceUUID.generate(),
            groupID: group.id,
            stepKey: node.key,
            direction: .forward,
            plannedActionType: node.action.rawValue,
            serviceName: node.serviceName,
            resourceIdentifier: node.resourceIdentifier,
            stepIdempotencyKey: "\(node.idempotencyKey):forward:1",
            status: .started,
            startedAt: timestamp,
            updatedAt: timestamp,
            finishedAt: nil,
            lastErrorRedacted: nil,
            manualRecoveryHintRedacted:
                "Re-observe the exact owned effect before recovery.",
            metadataJSONRedacted:
                #"{"attempt":1,"checkpoint":"effect-pending"}"#
        )
    )
}

private func persistLifecycleProject(
    fixture: LifecycleLiveDriverFixture,
    preparation: LifecycleCommandPreparation
) throws {
    let manifest = try ManifestValidator.validated(
        fixture.manifestSource.value
    )
    try fixture.store.desiredStates.saveManifestSnapshot(
        projectID: preparation.projectID,
        manifestPath: fixture.manifestPath,
        manifestHash: preparation.manifestSHA256,
        desiredGeneration: preparation.providerGeneration,
        manifest: manifest,
        timestamp: "2026-07-23T12:00:00Z",
        mutationProvider: preparation.providerID.rawValue
    )
}

@discardableResult
private func persistLifecycleGroup(
    store: SQLiteStateStore,
    plan: LifecyclePlan,
    status: OperationGroupStatus,
    completedNodeKeys: Set<String>,
    terminalCheckpoint: String? = nil,
    terminalMetadataJSONRedacted: String = "{}",
    recoveryStateJSONRedacted: String? = nil
) throws -> OperationGroupRecord {
    let groupID = HostwrightResourceUUID.legacy(
        kind: "recovery-source-group",
        identifier: "\(plan.planSHA256):\(status.rawValue):\(completedNodeKeys.sorted())"
    )
    let operationID = HostwrightResourceUUID.legacy(
        kind: "recovery-source-operation",
        identifier: groupID
    )
    let timestamp = "2026-07-23T12:00:00Z"
    let record = OperationGroupRecord(
        id: groupID,
        operationID: operationID,
        groupKind: "lifecycle-v1",
        projectID: plan.projectID,
        serviceName: nil,
        plannedActionType: plan.command.rawValue,
        status: .active,
        groupIdempotencyKey: plan.planSHA256,
        planHash: plan.planSHA256,
        checkpoint: "intent-persisted",
        lockOwner: "recovery-test",
        lockExpiresAt: nil,
        rollbackAvailable: plan.nodes.contains {
            $0.compensation != nil
        },
        manualRecoveryHintRedacted: "",
        createdAt: timestamp,
        updatedAt: timestamp,
        metadataJSONRedacted: "{}",
        fencingToken: plan.nodes.first?.fencingToken,
        intentJSONRedacted: try LifecyclePersistedIntentCodec.encode(
            plan,
            recoveryStateJSONRedacted:
                recoveryStateJSONRedacted
        ),
        compensationJSONRedacted: "[]",
        verificationJSONRedacted: "{}"
    )
    let acquired = try store.operationGroups.acquire(record)
    _ = try XCTUnwrap(acquired.acquired)
    for node in plan.nodes where completedNodeKeys.contains(node.key) {
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: groupID,
                stepKey: node.key,
                direction: .forward,
                plannedActionType: node.action.rawValue,
                serviceName: node.serviceName,
                resourceIdentifier: node.resourceIdentifier,
                stepIdempotencyKey:
                    "\(node.idempotencyKey):forward:1",
                status: .succeeded,
                startedAt: timestamp,
                updatedAt: timestamp,
                finishedAt: timestamp,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: "",
                metadataJSONRedacted:
                    #"{"attempt":1,"planNodeIdempotencyKey":"\#(node.idempotencyKey)"}"#
            ),
            expectedFencingToken: record.fencingToken
        )
    }
    try store.operationGroups.finish(
        groupID: groupID,
        status: status,
        checkpoint: terminalCheckpoint ?? (
            status == .interrupted
                ? "interrupted-for-test"
                : "failed-for-test"
        ),
        manualRecoveryHintRedacted: "test recovery",
        updatedAt: timestamp,
        metadataJSONRedacted: terminalMetadataJSONRedacted
    )
    return try XCTUnwrap(store.operationGroups.load(id: groupID))
}

private struct LifecycleLiveAdapterSnapshot: Equatable, Sendable {
    let mutations: [PlannedRuntimeActionKind]
    let completionRequirements: [Bool]
    let mutationResourceUUIDs: [String]
    let intentWasPresentBeforeEveryMutation: Bool
    let createdSecretValues: [String]
    let resourceUUIDs: [String]
}

private struct LifecycleLiveTestResource: Sendable {
    let desired: DesiredRuntimeService
    let resourceIdentifier: String
    let runtimeID: String
    var lifecycle: RuntimeInventoryLifecycleState
    var ownership: RuntimeInventoryOwnershipEvidence?

    init(
        desired: DesiredRuntimeService,
        resourceIdentifier: String? = nil,
        runtimeID: String,
        lifecycle: RuntimeInventoryLifecycleState,
        ownership: RuntimeInventoryOwnershipEvidence?
    ) {
        self.desired = desired
        self.resourceIdentifier =
            resourceIdentifier ?? desired.identity.managedResourceIdentifier
        self.runtimeID = runtimeID
        self.lifecycle = lifecycle
        self.ownership = ownership
    }
}

private actor LifecycleLiveTestAdapter: RuntimeAdapter {
    private var providerSnapshot: RuntimeCapabilitySnapshot
    private var resources: [LifecycleLiveTestResource]
    private let imageEvidence: RuntimeLocalImageEvidence
    private let stateDatabasePath: String
    private var mutations: [PlannedRuntimeActionKind] = []
    private var completionRequirements: [Bool] = []
    private var mutationResourceUUIDs: [String] = []
    private var intentChecks: [Bool] = []
    private var createdSecretValues: [String] = []
    private var cancellationMutationIndex: Int?
    private var mutationDelayNanoseconds: UInt64 = 0
    private var completionStartFails = false
    private var shouldFailNextStart = false
    private var strictOwnedHintFences = false
    private var preserveExistingOwnershipFenceOnMutation = false
    private var ignoreRemoveMutation = false

    init(
        capability: RuntimeCapabilitySnapshot,
        resources: [LifecycleLiveTestResource],
        imageEvidence: RuntimeLocalImageEvidence,
        stateDatabasePath: String
    ) {
        providerSnapshot = capability
        self.resources = resources
        self.imageEvidence = imageEvidence
        self.stateDatabasePath = stateDatabasePath
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "LifecycleLiveTestAdapter",
            adapterVersion: "1.0.0",
            runtimeName: "container",
            runtimeVersion: "1.1.0",
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .cleanup]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation, .cleanup]
    }

    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        providerSnapshot
    }

    func inventory() async throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: [
                    RuntimeInventoryService(
                        identifier: "container-apiserver",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: try resources.map(container),
            images: [
                RuntimeInventoryImage(
                    runtimeID: imageEvidence.descriptorDigest,
                    descriptorDigest: imageEvidence.descriptorDigest,
                    references: [imageEvidence.reference],
                    variants: [
                        RuntimeInventoryImageVariant(
                            digest: imageEvidence.variantDigest,
                            architecture: imageEvidence.architecture,
                            operatingSystem: imageEvidence.operatingSystem
                        )
                    ],
                    labels: []
                )
            ],
            networks: [],
            volumes: []
        )
    }

    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        if strictOwnedHintFences {
            for hint in desiredState.ownedResourceHints {
                guard let ownership = hint.ownership,
                      resources.filter({
                          $0.resourceIdentifier == hint.resourceIdentifier &&
                              $0.ownership == ownership
                      }).count == 1 else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Runtime inventory did not match exact UUID-backed state ownership."
                    )
                }
            }
        }
        let desiredIdentities = Set(
            desiredState.services.map(\.identity) +
                desiredState.ownedResourceHints.map(\.identity)
        )
        return ObservedRuntimeState(
            projectName: desiredState.projectName,
            services: resources.compactMap { resource in
                guard desiredIdentities.contains(resource.desired.identity) else {
                    return nil
                }
                return ObservedRuntimeService(
                    identity: resource.desired.identity,
                    resourceIdentifier: resource.resourceIdentifier,
                    image: resource.desired.image,
                    lifecycleState: lifecycleState(resource.lifecycle),
                    healthState: .notConfigured
                )
            },
            adapterMetadata: await metadata(),
            capabilitySHA256: providerSnapshot.canonicalSHA256
        )
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(actions: [], capabilitySHA256: providerSnapshot.canonicalSHA256)
    }

    func logs(
        for service: ObservedRuntimeService,
        tail: Int
    ) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String { "1.1.0" }

    func runtimeReadiness() async throws -> RuntimeReadinessReport {
        RuntimeReadinessReport(
            runtimeName: "container",
            cliVersion: "1.1.0",
            serviceState: .running,
            serviceVersion: "1.1.0",
            serviceBuild: "test"
        )
    }

    func localImageEvidence(
        for imageReference: String
    ) async throws -> RuntimeLocalImageEvidence {
        guard imageReference == imageEvidence.reference else {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: 1,
                message: "image missing",
                standardError: ""
            )
        }
        return imageEvidence
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        guard confirmation?.confirmed == true,
              let context = confirmation?.context else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Missing lifecycle mutation context."
            )
        }
        let groups = try SQLiteStateStore(path: stateDatabasePath)
            .operationGroups.loadAll()
        intentChecks.append(
            groups.contains {
                $0.planHash == confirmation?.planHash &&
                    !$0.intentJSONRedacted.isEmpty &&
                    $0.intentJSONRedacted != "{}"
            }
        )
        if mutations.count == cancellationMutationIndex {
            cancellationMutationIndex = nil
            throw RuntimeAdapterError.commandCancelled(
                command: action.kind.rawValue,
                partialOutput: "",
                partialError: ""
            )
        }
        if mutationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: mutationDelayNanoseconds)
        }
        if action.kind == .start, shouldFailNextStart {
            shouldFailNextStart = false
            throw RuntimeAdapterError.commandFailed(
                exitStatus: 75,
                message: "injected candidate start failure",
                standardError: ""
            )
        }
        mutations.append(action.kind)
        completionRequirements.append(action.requiresProcessCompletion)
        mutationResourceUUIDs.append(context.resourceUUID)
        switch action.kind {
        case .create:
            guard let desired = action.desiredService else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "Create requires desired state."
                )
            }
            createdSecretValues.append(
                contentsOf: desired.environment.compactMap {
                    $0.isSensitive ? $0.value : nil
                }
            )
            resources.append(
                LifecycleLiveTestResource(
                    desired: desired,
                    resourceIdentifier: action.resourceIdentifier,
                    runtimeID: "created-\(context.resourceUUID)",
                    lifecycle: .created,
                    ownership: ownership(context)
                )
            )
        case .start:
            if action.requiresProcessCompletion {
                try updateResource(context: context) { $0.lifecycle = .exited }
                if completionStartFails {
                    throw RuntimeAdapterError.commandFailed(
                        exitStatus: 7,
                        message: "completion fixture failed",
                        standardError: "exit 7"
                    )
                }
            } else {
                try updateResource(context: context) { $0.lifecycle = .running }
            }
        case .stop:
            guard action.isDestructive else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "Lifecycle stop must be explicitly destructive."
                )
            }
            try updateResource(context: context) { $0.lifecycle = .stopped }
        case .restart:
            try updateResource(context: context) { $0.lifecycle = .running }
        case .remove:
            if ignoreRemoveMutation {
                break
            }
            guard let index = resources.firstIndex(where: {
                $0.ownership?.resourceUUID == context.resourceUUID &&
                    $0.resourceIdentifier == action.resourceIdentifier
            }) else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "Exact owned resource is absent."
                )
            }
            resources.remove(at: index)
        case .update, .noOp:
            break
        }
        return RuntimeEvent(
            identity: action.identity,
            message: action.summary,
            resourceIdentifier: action.resourceIdentifier
        )
    }

    func replaceCapability(_ snapshot: RuntimeCapabilitySnapshot) {
        providerSnapshot = snapshot
    }

    func addUnmanagedCollision() {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        resources.append(
            LifecycleLiveTestResource(
                desired: DesiredRuntimeService(
                    identity: identity,
                    image: imageEvidence.reference
                ),
                runtimeID: "unmanaged-collision",
                lifecycle: .running,
                ownership: nil
            )
        )
    }

    func snapshot() -> LifecycleLiveAdapterSnapshot {
        LifecycleLiveAdapterSnapshot(
            mutations: mutations,
            completionRequirements: completionRequirements,
            mutationResourceUUIDs: mutationResourceUUIDs,
            intentWasPresentBeforeEveryMutation: intentChecks.allSatisfy { $0 },
            createdSecretValues: createdSecretValues,
            resourceUUIDs: resources.compactMap(\.ownership?.resourceUUID).sorted()
        )
    }

    func seedUpdateState(
        retiredResourceUUID: String,
        candidate: DesiredRuntimeService,
        candidateResourceIdentifier: String,
        candidateOwnership: RuntimeInventoryOwnershipEvidence
    ) {
        resources.removeAll {
            $0.ownership?.resourceUUID == retiredResourceUUID
        }
        resources.append(
            LifecycleLiveTestResource(
                desired: candidate,
                resourceIdentifier: candidateResourceIdentifier,
                runtimeID: "candidate-\(candidateOwnership.resourceUUID)",
                lifecycle: .running,
                ownership: candidateOwnership
            )
        )
    }

    func seedRecoveryResource(
        desired: DesiredRuntimeService,
        resourceIdentifier: String,
        lifecycle: RuntimeInventoryLifecycleState,
        ownership: RuntimeInventoryOwnershipEvidence?
    ) {
        resources.removeAll {
            $0.ownership?.resourceUUID == ownership?.resourceUUID
        }
        resources.append(
            LifecycleLiveTestResource(
                desired: desired,
                resourceIdentifier: resourceIdentifier,
                runtimeID:
                    "recovery-\(ownership?.resourceUUID ?? resourceIdentifier)",
                lifecycle: lifecycle,
                ownership: ownership
            )
        )
    }

    func cancelBeforeMutation(at index: Int?) {
        cancellationMutationIndex = index
    }

    func setMutationDelayNanoseconds(_ value: UInt64) {
        mutationDelayNanoseconds = value
    }

    func setCompletionStartFailure(_ enabled: Bool) {
        completionStartFails = enabled
    }

    func failNextStart() {
        shouldFailNextStart = true
    }

    func setStrictOwnedHintFences(_ enabled: Bool) {
        strictOwnedHintFences = enabled
    }

    func setPreserveExistingOwnershipFenceOnMutation(_ enabled: Bool) {
        preserveExistingOwnershipFenceOnMutation = enabled
    }

    func setIgnoreRemoveMutation(_ enabled: Bool) {
        ignoreRemoveMutation = enabled
    }

    private func updateResource(
        context: RuntimeMutationContext,
        change: (inout LifecycleLiveTestResource) -> Void
    ) throws {
        guard let index = resources.firstIndex(where: {
            $0.ownership?.resourceUUID == context.resourceUUID
        }) else {
            throw RuntimeAdapterError.outputParseFailed("Resource is absent.")
        }
        change(&resources[index])
        if !preserveExistingOwnershipFenceOnMutation ||
            resources[index].ownership == nil {
            resources[index].ownership = ownership(context)
        }
    }

    private func ownership(
        _ context: RuntimeMutationContext
    ) -> RuntimeInventoryOwnershipEvidence {
        RuntimeInventoryOwnershipEvidence(
            resourceUUID: context.resourceUUID,
            projectUUID: context.projectResourceUUID,
            resourceGeneration: context.resourceGeneration,
            projectGeneration: context.projectGeneration,
            providerID: context.providerID,
            providerGeneration: context.providerGeneration,
            fencingToken: context.fencingToken
        )
    }

    private func container(
        _ resource: LifecycleLiveTestResource
    ) throws -> RuntimeInventoryContainer {
        let labels: [RuntimeInventoryLabel]
        if let ownership = resource.ownership {
            let context = RuntimeMutationContext(
                providerID: ownership.providerID,
                capabilitySHA256: providerSnapshot.canonicalSHA256,
                operationID: "lifecycle-live-test-inventory",
                resourceUUID: ownership.resourceUUID,
                resourceGeneration: ownership.resourceGeneration,
                projectResourceUUID: ownership.projectUUID,
                projectGeneration: ownership.projectGeneration,
                providerGeneration: ownership.providerGeneration,
                fencingToken: ownership.fencingToken
            )
            labels = try RuntimeManagedResourceIdentity.labels(
                for: resource.desired.identity,
                context: context
            ).map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
        } else {
            labels = []
        }
        return RuntimeInventoryContainer(
            runtimeID: resource.runtimeID,
            name: resource.resourceIdentifier,
            imageReference: resource.desired.image,
            lifecycle: resource.lifecycle,
            health: RuntimeInventoryHealth(availability: .notConfigured),
            labels: labels,
            ownership: resource.ownership,
            initConfiguration: RuntimeInventoryInitConfiguration(
                executable: "/bin/service",
                arguments: [],
                environment: []
            ),
            ports: [],
            mounts: [],
            networks: [],
            services: []
        )
    }

    private func lifecycleState(
        _ state: RuntimeInventoryLifecycleState
    ) -> RuntimeLifecycleState {
        switch state {
        case .unknown: .unknown
        case .missing: .missing
        case .created: .created
        case .running: .running
        case .stopped: .stopped
        case .exited: .exited
        case .failed: .failed
        }
    }
}

private final class RecordingLifecycleSecretStore:
    SecretStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let value: String
    private var reads = 0

    init(value: String) {
        self.value = value
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func readString(reference: HostwrightSecretReference) throws -> String {
        lock.withLock {
            reads += 1
            return value
        }
    }
}

private final class FailingLifecycleSecretStore:
    SecretStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let diagnostic: String
    private var reads = 0

    init(diagnostic: String) {
        self.diagnostic = diagnostic
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func readString(reference: HostwrightSecretReference) throws -> String {
        lock.withLock { reads += 1 }
        throw FailingLifecycleSecretError.unavailable(diagnostic)
    }
}

private enum FailingLifecycleSecretError: Error {
    case unavailable(String)
}

private struct LifecycleLiveDriverFixture {
    let directory: URL
    let manifestPath: String
    let databasePath: String
    let projectID = "project-demo"
    let store: SQLiteStateStore
    let adapter: LifecycleLiveTestAdapter
    let environment: CLIEnvironment
    let manifestSource: LifecycleMutableManifestSource

    init(
        directory: URL,
        secretStore: (any SecretStore)?,
        includesSecret: Bool,
        unmanagedCollision: Bool,
        existingManagedResource: Bool,
        manifestOverride: String?
    ) throws {
        self.directory = directory
        manifestPath = directory.appendingPathComponent("hostwright.yaml").path
        databasePath = directory.appendingPathComponent("state.sqlite").path
        store = SQLiteStateStore(path: databasePath)
        try store.migrate()

        let image = "registry.example/api@sha256:\(String(repeating: "a", count: 64))"
        let manifest: String
        if let manifestOverride {
            manifest = manifestOverride
        } else if includesSecret {
            manifest = """
            version: 2
            project: demo
            imagePolicy: require-digest
            services:
              api:
                image: \(image)
                secretEnv:
                  API_TOKEN: keychain://hostwright.tests/api-token

            """
        } else {
            manifest = """
            version: 2
            project: demo
            imagePolicy: require-digest
            services:
              api:
                image: \(image)

            """
        }
        let manifestSource = LifecycleMutableManifestSource(manifest)
        self.manifestSource = manifestSource

        var resources: [LifecycleLiveTestResource] = []
        if existingManagedResource {
            let parsed = try ManifestValidator.validated(manifest)
            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: manifestPath,
                manifestHash: String(repeating: "a", count: 64),
                desiredGeneration: 1,
                manifest: parsed,
                timestamp: "2026-07-23T12:00:00Z",
                mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
            )
            let project = try store.desiredStates.loadProject(id: projectID)
            let identity = RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api"
            )
            let target = try addOwnership(
                store: store,
                id: "ownership-api",
                projectID: projectID,
                serviceName: "api",
                resourceIdentifier: identity.managedResourceIdentifier,
                resourceUUID: HostwrightResourceUUID.legacy(
                    kind: "service",
                    identifier: identity.displayName
                ),
                projectResourceUUID: project.resourceUUID,
                fencingToken: HostwrightResourceUUID.legacy(
                    kind: "resource-fence",
                    identifier: identity.displayName
                )
            )
            resources.append(
                LifecycleLiveTestResource(
                    desired: DesiredRuntimeService(identity: identity, image: image),
                    runtimeID: "managed-api",
                    lifecycle: .running,
                    ownership: target
                )
            )

            let sentinelIdentity = RuntimeServiceIdentity(
                projectName: "sentinel",
                serviceName: "keep"
            )
            let sentinel = try addOwnership(
                store: store,
                id: "ownership-sentinel",
                projectID: projectID,
                serviceName: "keep",
                resourceIdentifier: sentinelIdentity.managedResourceIdentifier,
                resourceUUID: HostwrightResourceUUID.legacy(
                    kind: "service",
                    identifier: sentinelIdentity.displayName
                ),
                projectResourceUUID: project.resourceUUID,
                fencingToken: HostwrightResourceUUID.legacy(
                    kind: "resource-fence",
                    identifier: sentinelIdentity.displayName
                )
            )
            resources.append(
                LifecycleLiveTestResource(
                    desired: DesiredRuntimeService(
                        identity: sentinelIdentity,
                        image: image
                    ),
                    runtimeID: "sentinel-keep",
                    lifecycle: .running,
                    ownership: sentinel
                )
            )
        } else if unmanagedCollision {
            let identity = RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api"
            )
            resources.append(
                LifecycleLiveTestResource(
                    desired: DesiredRuntimeService(identity: identity, image: image),
                    runtimeID: "unmanaged-collision",
                    lifecycle: .running,
                    ownership: nil
                )
            )
        }

        let imageEvidence = RuntimeLocalImageEvidence(
            reference: image,
            descriptorDigest: "sha256:\(String(repeating: "b", count: 64))",
            variantDigest: "sha256:\(String(repeating: "c", count: 64))",
            architecture: "arm64",
            operatingSystem: "linux"
        )
        adapter = LifecycleLiveTestAdapter(
            capability: lifecycleLiveCapability(build: "25F90"),
            resources: resources,
            imageEvidence: imageEvidence,
            stateDatabasePath: databasePath
        )
        let resolution = try HostwrightLocalPathResolver.resolve(
            explicitStateDatabasePath: databasePath,
            homeDirectory: directory.path,
            environment: [:]
        )
        let adapter = adapter
        let manifestFilePath = manifestPath
        environment = CLIEnvironment(
            fileExists: { $0 == manifestFilePath },
            readTextFile: { path in
                guard path == manifestFilePath else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return manifestSource.value
            },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            localPathResolution: { _ in resolution },
            runtimeAdapter: { adapter },
            runtimeAdapterForProvider: { providerID in
                guard providerID == .appleContainerCLI else {
                    throw RuntimeProviderSelectionError.providerUnavailable(providerID)
                }
                return adapter
            },
            runtimeProviderProbes: {
                [
                    .available(try! await adapter.capabilitySnapshot()),
                    .unavailable(
                        .appleContainerization,
                        reason: .helperHandshakeUnavailable
                    )
                ]
            },
            secretStore: {
                secretStore ?? UnavailableKeychainSecretStore()
            },
            swiftVersion: { "Swift test" },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS 26.0" },
            doctorSystemSnapshot: { .unavailable() }
        )
    }

    func options(
        command: LifecycleCommandKind,
        dryRun: Bool,
        confirmation: String? = nil
    ) -> LifecycleCLIOptions {
        LifecycleCLIOptions(
            command: command,
            manifestPath: manifestPath,
            stateDatabasePath: databasePath,
            confirmationPlanSHA256: confirmation,
            dryRun: dryRun,
            runtimeProvider: .appleCLI,
            timeoutSeconds: 60,
            parallelism: 2,
            output: .json
        )
    }

    func adapterSnapshot() throws -> LifecycleLiveAdapterSnapshot {
        try wait { await adapter.snapshot() }
    }

    func wait<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        try hostwrightWaitForAsync(operation)
    }

    func stateBytesContain(_ text: String) throws -> Bool {
        let needle = Data(text.utf8)
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databasePath + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if try Data(contentsOf: url).range(of: needle) != nil {
                return true
            }
        }
        return false
    }
}

private final class LifecycleMutableManifestSource: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String

    init(_ text: String) {
        self.text = text
    }

    var value: String {
        lock.withLock { text }
    }

    func replace(_ value: String) {
        lock.withLock { text = value }
    }
}

private let completedDependencyManifest = """
version: 2
project: demo
imagePolicy: require-digest
services:
  prepare:
    image: registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    command: ["/bin/true"]
  worker:
    image: registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    dependsOn:
      prepare: completed

"""

private func runConfirmedUp(
    _ fixture: LifecycleLiveDriverFixture
) throws -> CLIRunResult {
    let dryOptions = fixture.options(command: .up, dryRun: true)
    let dryDriver = LifecycleLiveDriver(
        environment: fixture.environment,
        options: dryOptions
    )
    let preparation = try dryDriver.prepare(options: dryOptions)
    let compiled = try LifecycleCommandPlanCompiler().compile(
        options: dryOptions,
        preparation: preparation
    )
    let confirmed = fixture.options(
        command: .up,
        dryRun: false,
        confirmation: compiled.plan.planSHA256
    )
    return LifecycleCommandRunner(
        options: confirmed,
        driver: LifecycleLiveDriver(
            environment: fixture.environment,
            options: confirmed
        )
    ).run()
}

private func withFixture(
    secretStore: (any SecretStore)? = nil,
    includesSecret: Bool = false,
    unmanagedCollision: Bool = false,
    existingManagedResource: Bool = false,
    manifestOverride: String? = nil,
    _ body: (LifecycleLiveDriverFixture) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hostwright-lifecycle-live-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(
        try LifecycleLiveDriverFixture(
            directory: directory,
            secretStore: secretStore,
            includesSecret: includesSecret,
            unmanagedCollision: unmanagedCollision,
            existingManagedResource: existingManagedResource,
            manifestOverride: manifestOverride
        )
    )
}

private func addOwnership(
    store: SQLiteStateStore,
    id: String,
    projectID: String,
    serviceName: String,
    resourceIdentifier: String,
    resourceUUID: String,
    projectResourceUUID: String,
    fencingToken: String
) throws -> RuntimeInventoryOwnershipEvidence {
    let record = OwnershipRecord(
        id: id,
        resourceIdentifier: resourceIdentifier,
        resourceType: "container",
        projectID: projectID,
        serviceName: serviceName,
        runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
        createdAt: "2026-07-23T12:00:00Z",
        observedAt: "2026-07-23T12:00:00Z",
        cleanupEligible: true,
        metadataJSONRedacted: "{}",
        identityVersion: RuntimeManagedResourceIdentity.currentVersion,
        resourceUUID: resourceUUID,
        resourceGeneration: 1,
        projectResourceUUID: projectResourceUUID,
        projectGeneration: 1,
        providerGeneration: 1,
        fencingToken: fencingToken
    )
    try store.ownership.upsert(record)
    return RuntimeInventoryOwnershipEvidence(
        resourceUUID: resourceUUID,
        projectUUID: projectResourceUUID,
        resourceGeneration: 1,
        projectGeneration: 1,
        providerID: .appleContainerCLI,
        providerGeneration: 1,
        fencingToken: fencingToken
    )
}

private func lifecycleLiveCapability(
    build: String
) -> RuntimeCapabilitySnapshot {
    RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: .appleContainerCLI,
            components: [
                RuntimeProviderComponent(
                    identifier: .appleContainerCLI,
                    version: "1.1.0",
                    build: "109",
                    fingerprint: "099d8db0"
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerAPIService,
                    version: "1.1.0",
                    build: "109",
                    fingerprint: "099d8db0"
                )
            ],
            minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
            supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: RuntimeProviderMacOSVersion(
                major: 26,
                minor: 0,
                patch: 0
            ),
            macOSBuild: build,
            architecture: .arm64
        ),
        features: RuntimeProviderFeature.knownValues.map {
            RuntimeProviderFeatureStatus(
                feature: $0,
                state: .available,
                reason: .implemented
            )
        }
    )
}
