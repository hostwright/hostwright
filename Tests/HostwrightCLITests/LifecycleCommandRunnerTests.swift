import CryptoKit
import Foundation
import HostwrightCore
import HostwrightDaemonCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState
import Testing
@testable import HostwrightCLI

@Suite
struct LifecycleCommandRunnerTests {
    @Test
    func imageLockingAndMountNormalizationPreserveNetworkIntent() throws {
        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-phase07-network-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: manifestDirectory.appendingPathComponent(
                "data",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }

        let projectUUID = HostwrightResourceUUID.legacy(
            kind: "project",
            identifier: "project-demo"
        )
        let networkIdentity = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: projectUUID
        )
        let desiredNetwork = DesiredRuntimeNetwork(
            identity: networkIdentity,
            mode: .nat
        )
        let attachment = try RuntimeDesiredNetworkAttachment(
            network: networkIdentity,
            aliases: ["api"]
        )
        let preparation = try preparation(
            desired: [
                service(
                    networks: [attachment],
                    mounts: [
                        RuntimeMountReference(
                            source: "./data",
                            target: "/data",
                            access: .unknown
                        )
                    ]
                )
            ],
            networks: [desiredNetwork],
            manifestBaseDirectory: manifestDirectory.path
        )
        let options = options(command: .up, dryRun: true)
        let compiler = LifecycleCommandPlanCompiler()
        let initial = try compiler.compile(
            options: options,
            preparation: preparation
        )
        let normalized = try #require(
            initial.desiredServicesByNodeKey.values.first
        )
        #expect(normalized.networks == [attachment])

        let bound = try LifecycleImageLockBinder.bind(
            preparation: preparation,
            initialCompiled: initial,
            options: options
        ) { requirement, _ in
            RuntimeLocalImageEvidence(
                reference: requirement.reference,
                descriptorDigest:
                    "sha256:\(String(repeating: "1", count: 64))",
                variantDigest:
                    "sha256:\(String(repeating: "e", count: 64))",
                architecture: requirement.architecture,
                operatingSystem: requirement.operatingSystem
            )
        }

        #expect(bound.desiredState.networks == [desiredNetwork])
        #expect(bound.desiredState.services.first?.networks == [attachment])
    }

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
        let plan = try reviewedPlan(preparation: preparation)
        let driver = ScriptedLifecycleCommandDriver(preparation: preparation)

        let result = LifecycleCommandRunner(
            options: options(
                command: .up,
                dryRun: false,
                confirmation: plan.planSHA256
            ),
            driver: driver
        ).run()

        #expect(result.exitCode == 0)
        let expectedOutput = (
            [
                "Lifecycle succeeded: plan=\(plan.planSHA256) completed=\(plan.nodes.count)/\(plan.nodes.count) checkpoint=complete",
                "Resource outcomes:"
            ] + plan.nodes.map { node in
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
    func unattendedReconciliationUsesTheExactSharedPlanAndSagaOnce() async throws {
        let manifest = "version: 2\nproject: demo\nservices:\n  api:\n    image: example.invalid/api:latest\n"
        let prepared = try preparation(desired: [service()])
        let driver = ScriptedLifecycleCommandDriver(preparation: prepared)
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in manifest },
            makeDriver: { _ in driver }
        )
        let result = try await reconciler.reconcile(
            request: try makeDaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: SHA256.hash(data: Data(manifest.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined(),
                stateDatabasePath: "/private/tmp/state.sqlite",
                projectID: "project-demo",
                maximumParallelism: 4
            )
        )

        #expect(result.status == .mutated)
        #expect(result.reasonCode == .mutationVerified)
        #expect(result.nodeCount == result.completedNodeCount)
        #expect(result.nodeCount == 2)
        #expect(
            driver.snapshot() == DriverSnapshot(
                imageChecks: 1,
                revalidations: 1,
                executions: 1
            )
        )
    }

    @Test
    func repeatedLifecycleGroupReusesOnlyExactPlanScopedImageLockEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-p08-image-lock-repeat-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        let lock = try RuntimeImageDigestLock(
            requestedReference: "registry.example/team/api:stable",
            resolvedReference:
                "registry.example/team/api@sha256:\(String(repeating: "d", count: 64))",
            descriptorDigest: "sha256:\(String(repeating: "d", count: 64))",
            variantDigest: "sha256:\(String(repeating: "e", count: 64))",
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "c", count: 64)
        )
        let desired = service(image: lock.resolvedReference, imageLock: lock)
        let prepared = try preparation(desired: [desired])
        let compiled = try LifecycleCommandPlanCompiler().compile(
            options: options(command: .up, dryRun: true),
            preparation: prepared
        )
        try store.desiredStates.saveManifestSnapshot(
            projectID: prepared.projectID,
            manifestPath: "/private/tmp/hostwright.yaml",
            manifestHash: prepared.manifestSHA256,
            desiredGeneration: 1,
            manifest: HostwrightManifest(
                project: "demo",
                services: [
                    HostwrightService(name: "api", image: lock.resolvedReference)
                ]
            ),
            timestamp: "2026-08-01T00:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
        )
        let firstGroup = HostwrightResourceUUID.generate()
        let secondGroup = HostwrightResourceUUID.generate()

        try lifecyclePersistDesiredImageLocks(
            plan: compiled.plan,
            desiredServicesByNodeKey: compiled.desiredServicesByNodeKey,
            groupID: firstGroup,
            store: store,
            timestamp: "2026-08-01T00:00:01Z"
        )
        try lifecyclePersistDesiredImageLocks(
            plan: compiled.plan,
            desiredServicesByNodeKey: compiled.desiredServicesByNodeKey,
            groupID: secondGroup,
            store: store,
            timestamp: "2026-08-01T00:00:02Z"
        )

        let records = try store.imageDigestLocks.load(projectID: prepared.projectID)
        #expect(records.count == 1)
        #expect(records[0].operationGroupID == firstGroup)
        #expect(records[0].lock == lock)
    }

    @Test
    func unattendedReconciliationPreservesPostAdmissionFailureAsInterruptedMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-p08-restart-admission-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("state.sqlite").path
        let store = SQLiteStateStore(path: databasePath)
        try store.migrate()
        let manifest = "version: 2\nproject: demo\nservices:\n  api:\n    image: example.invalid/api:latest\n"
        let prepared = try preparation(desired: [service()])
        let driver = ScriptedLifecycleCommandDriver(
            preparation: prepared,
            executionHook: { compiled, _ in
                let groupID = HostwrightResourceUUID.legacy(
                    kind: "lifecycle-group",
                    identifier: compiled.plan.planSHA256
                )
                let operationID = HostwrightResourceUUID.legacy(
                    kind: "lifecycle-operation",
                    identifier: compiled.plan.planSHA256
                )
                let acquisition = try store.operationGroups.acquire(
                    OperationGroupRecord(
                        id: groupID,
                        operationID: operationID,
                        groupKind: "lifecycle",
                        projectID: nil,
                        serviceName: "api",
                        plannedActionType: "up",
                        status: .active,
                        groupIdempotencyKey: "lifecycle:\(compiled.plan.planSHA256)",
                        planHash: compiled.plan.planSHA256,
                        checkpoint: "effect-ambiguous",
                        lockOwner: "hostwright-cli",
                        lockExpiresAt: nil,
                        rollbackAvailable: true,
                        manualRecoveryHintRedacted: "inspect exact lifecycle evidence",
                        createdAt: "2026-08-01T12:00:00Z",
                        updatedAt: "2026-08-01T12:00:00Z",
                        metadataJSONRedacted: "{}",
                        fencingToken: HostwrightResourceUUID.generate()
                    )
                )
                let group = try #require(acquisition.acquired)
                let node = try #require(
                    compiled.plan.nodes.first { $0.action.mutatesRuntime }
                )
                try store.operationGroupSteps.append(
                    OperationGroupStepRecord(
                        id: HostwrightResourceUUID.generate(),
                        groupID: groupID,
                        stepKey: node.key,
                        direction: .forward,
                        plannedActionType: node.action.rawValue,
                        serviceName: node.serviceName,
                        resourceIdentifier: node.resourceIdentifier,
                        stepIdempotencyKey: "\(node.idempotencyKey):forward:1",
                        status: .started,
                        startedAt: "2026-08-01T12:00:00Z",
                        updatedAt: "2026-08-01T12:00:00Z",
                        finishedAt: nil,
                        lastErrorRedacted: nil,
                        manualRecoveryHintRedacted: "",
                        metadataJSONRedacted: #"{"attempt":1}"#
                    ),
                    expectedFencingToken: group.fencingToken
                )
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message: "ambiguous provider result"
                )
            }
        )
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in manifest },
            makeDriver: { _ in driver }
        )

        let result = try await reconciler.reconcile(
            request: try makeDaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: SHA256.hash(data: Data(manifest.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined(),
                stateDatabasePath: databasePath,
                projectID: "project-demo",
                maximumParallelism: 4
            )
        )

        #expect(result.status == .interrupted)
        #expect(result.reasonCode == .interrupted)
        #expect(result.runtimeMutationAttempted)
        #expect(result.checkpoint == "effect-ambiguous")
        #expect(result.groupID == HostwrightResourceUUID.legacy(
            kind: "lifecycle-group",
            identifier: result.planSHA256
        ))
    }

    @Test
    func unattendedReconciliationReportsAnEmptySharedDAGAsConverged() async throws {
        let manifest = "version: 2\nproject: demo\nservices:\n  api:\n    image: example.invalid/api:latest\n"
        let desired = service()
        let observed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            image: desired.image,
            lifecycleState: .running,
            healthState: .healthy
        )
        let prepared = try preparation(
            desired: [desired],
            observed: [observed],
            bindings: [try resourceBinding(for: observed)]
        )
        let driver = ScriptedLifecycleCommandDriver(preparation: prepared)
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in manifest },
            makeDriver: { _ in driver }
        )
        let result = try await reconciler.reconcile(
            request: try makeDaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: SHA256.hash(data: Data(manifest.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined(),
                stateDatabasePath: "/private/tmp/state.sqlite",
                projectID: "project-demo",
                maximumParallelism: 4
            )
        )

        #expect(result.status == .converged)
        #expect(result.nodeCount == 0)
        #expect(driver.snapshot().executions == 0)
    }

    @Test
    func unattendedReconciliationDefersAnEmptyBudgetSelectionWithoutExecution() async throws {
        let manifest = "version: 2\nproject: demo\nservices:\n  api:\n    image: example.invalid/api:latest\n"
        let driver = ScriptedLifecycleCommandDriver(
            preparation: try preparation(desired: [service()])
        )
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in manifest },
            makeDriver: { _ in driver }
        )
        let result = try await reconciler.reconcile(
            request: try makeDaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: SHA256.hash(data: Data(manifest.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined(),
                stateDatabasePath: "/private/tmp/state.sqlite",
                projectID: "project-demo",
                maximumParallelism: 4,
                selectedServiceNames: []
            )
        )

        #expect(result.status == .deferred)
        #expect(result.reasonCode == .restartBudgetDeferred)
        #expect(result.checkpoint == "restart-budget-deferred")
        #expect(!result.runtimeMutationAttempted)
        #expect(driver.snapshot().executions == 0)
    }

    @Test
    func unattendedReconciliationReportsVerificationOnlyDAGAsConverged() async throws {
        let manifest = "version: 2\nproject: demo\nservices:\n  api:\n    image: example.invalid/api:latest\n"
        let desired = service(probes: allProbes())
        let observed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier: desired.identity.managedResourceIdentifier,
            image: desired.image,
            lifecycleState: .running,
            healthState: .healthy
        )
        let prepared = try preparation(
            desired: [desired],
            observed: [observed],
            bindings: [try resourceBinding(for: observed)]
        )
        let driver = ScriptedLifecycleCommandDriver(preparation: prepared)
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in manifest },
            makeDriver: { _ in driver }
        )
        let result = try await reconciler.reconcile(
            request: try makeDaemonReconciliationRequest(
                manifestPath: "/private/tmp/hostwright.yaml",
                manifestSHA256: SHA256.hash(data: Data(manifest.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined(),
                stateDatabasePath: "/private/tmp/state.sqlite",
                projectID: "project-demo",
                maximumParallelism: 4
            )
        )

        #expect(result.status == .converged)
        #expect(result.reasonCode == .converged)
        #expect(result.nodeCount > 0)
        #expect(result.nodeCount == result.completedNodeCount)
        #expect(driver.snapshot().executions == 1)
    }

    @Test
    func unattendedReconciliationRejectsChangedManifestBytesBeforePlanning() async throws {
        let approved = "version: 2\nproject: demo\nservices:\n  api:\n    image: approved\n"
        let changed = approved.replacingOccurrences(of: "approved", with: "changed")
        let driver = ScriptedLifecycleCommandDriver(
            preparation: try preparation(desired: [service()])
        )
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in changed },
            makeDriver: { _ in driver }
        )
        do {
            _ = try await reconciler.reconcile(
                request: try makeDaemonReconciliationRequest(
                    manifestPath: "/private/tmp/hostwright.yaml",
                    manifestSHA256: SHA256.hash(data: Data(approved.utf8))
                        .map { String(format: "%02x", $0) }
                        .joined(),
                    stateDatabasePath: "/private/tmp/state.sqlite",
                    projectID: "project-demo",
                    maximumParallelism: 4
                )
            )
            Issue.record("Expected exact manifest confirmation refusal.")
        } catch let diagnostic as HostwrightDiagnostic {
            #expect(diagnostic.code == .confirmationMismatch)
        }
        #expect(driver.snapshot().executions == 0)
    }

    @Test
    func unattendedReconciliationRejectsChangedPolicyTargetBeforeExecution() async throws {
        let manifest = "version: 2\nproject: demo\nservices:\n  api:\n    image: approved\n"
        let manifestPath = "/private/tmp/hostwright.yaml"
        let policyPath = "/private/tmp/hostwright-policy.pem"
        let manifestDigest = SHA256.hash(data: Data(manifest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let approvedPolicy = "approved-policy"
        let changedPolicy = "changed-policy"
        let approvedPolicyDigest = SHA256.hash(data: Data(approvedPolicy.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let changedPolicyDigest = SHA256.hash(data: Data(changedPolicy.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let manifestTarget = try DaemonConfigurationTarget(
            kind: .manifest,
            path: manifestPath,
            contentSHA256: manifestDigest,
            byteCount: manifest.utf8.count,
            device: 1,
            inode: 1
        )
        let policyTarget = try DaemonConfigurationTarget(
            kind: .policy,
            path: policyPath,
            contentSHA256: approvedPolicyDigest,
            byteCount: approvedPolicy.utf8.count,
            device: 2,
            inode: 2
        )
        let targets = [manifestTarget, policyTarget]
        let request = try DaemonReconciliationRequest(
            manifestPath: manifestPath,
            manifestSHA256: manifestDigest,
            configurationSetSHA256: DaemonConfigurationSetDigest.sha256(targets),
            configurationTargets: targets,
            stateDatabasePath: "/private/tmp/state.sqlite",
            projectID: "project-demo",
            maximumParallelism: 4
        )
        let driver = ScriptedLifecycleCommandDriver(
            preparation: try preparation(desired: [service()])
        )
        let policyReads = LockedReadCounter()
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in manifest },
            readConfiguration: { path, _, _ in
                if path == manifestPath {
                    return DaemonConfigurationSnapshot(target: manifestTarget, text: manifest)
                }
                if policyReads.increment() == 1 {
                    return DaemonConfigurationSnapshot(target: policyTarget, text: approvedPolicy)
                }
                let changedTarget = try DaemonConfigurationTarget(
                    kind: .policy,
                    path: policyPath,
                    contentSHA256: changedPolicyDigest,
                    byteCount: changedPolicy.utf8.count,
                    device: 3,
                    inode: 3
                )
                return DaemonConfigurationSnapshot(target: changedTarget, text: changedPolicy)
            },
            makeDriver: { _ in driver }
        )

        do {
            _ = try await reconciler.reconcile(request: request)
            Issue.record("Expected policy target confirmation refusal.")
        } catch let diagnostic as HostwrightDiagnostic {
            #expect(diagnostic.code == .confirmationMismatch)
        }
        #expect(policyReads.value == 2)
        #expect(driver.snapshot().executions == 0)
    }

    @Test
    func unattendedReconciliationHonorsCancellationBeforePlanning() async throws {
        let manifest = "version: 2\nproject: demo\nservices:\n  api:\n    image: approved\n"
        let driver = ScriptedLifecycleCommandDriver(
            preparation: try preparation(desired: [service()])
        )
        let reconciler = UnattendedLifecycleReconciler(
            readManifest: { _ in manifest },
            makeDriver: { _ in driver }
        )
        let request = try makeDaemonReconciliationRequest(
            manifestPath: "/private/tmp/hostwright.yaml",
            manifestSHA256: SHA256.hash(data: Data(manifest.utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            stateDatabasePath: "/private/tmp/state.sqlite",
            projectID: "project-demo",
            maximumParallelism: 4
        )
        let task = Task {
            try await reconciler.reconcile(request: request)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation.")
        } catch is CancellationError {
        }
        #expect(driver.snapshot().executions == 0)
    }

    @Test
    func partialSafeHoldRendersExactCanonicalResourceOutcomesAsJSON() throws {
        let preparation = try preparation(desired: [service()])
        let plan = try reviewedPlan(preparation: preparation)
        let completed = try #require(plan.nodes.first)
        let execution = LifecycleSagaExecutionResult(
            status: .safeHold,
            operationID: "11111111-1111-4111-8111-111111111111",
            groupID: "22222222-2222-4222-8222-222222222222",
            planSHA256: plan.planSHA256,
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
                confirmation: plan.planSHA256,
                output: .json
            ),
            driver: driver
        ).run()

        let resourceOutcomes = plan.nodes.map { node -> [String: Any] in
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
            "nodeCount": plan.nodes.count,
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
        let firstPlan = try reviewedPlan(preparation: firstPreparation)
        let secondPlan = try reviewedPlan(preparation: secondPreparation)
        #expect(firstPlan == secondPlan)
        let execution = LifecycleSagaExecutionResult(
            status: .succeeded,
            operationID: "33333333-3333-4333-8333-333333333333",
            groupID: "44444444-4444-4444-8444-444444444444",
            planSHA256: firstPlan.planSHA256,
            checkpoint: "complete",
            completedNodeKeys: Array(firstPlan.nodes.map(\.key).reversed()),
            recoveryHintRedacted: ""
        )
        let confirmedOptions = options(
            command: .up,
            dryRun: false,
            confirmation: firstPlan.planSHA256,
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
                firstPlan.nodes.map(\.key)
        )
        let outcomes = try #require(
            object["resourceOutcomes"] as? [[String: Any]]
        )
        #expect(
            outcomes.compactMap { $0["node"] as? String } ==
                firstPlan.nodes.map(\.key)
        )
        #expect(
            outcomes.compactMap { $0["resourceUUID"] as? String } ==
                firstPlan.nodes.map(\.resourceUUID)
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
        #expect(driver.snapshot() == DriverSnapshot(imageChecks: 1))
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
    func resolvedNamedVolumeCompilesBeforeProviderPathExists()
        throws
    {
        let source =
            "/private/tmp/hostwright-local/volumes/"
            + "11111111-1111-4111-8111-111111111111/data"
        let compiled = try LifecycleCommandPlanCompiler()
            .compile(
                options: options(
                    command: .up,
                    dryRun: true
                ),
                preparation: try preparation(
                    desired: [
                        service(
                            mounts: [
                                RuntimeMountReference(
                                    source: source,
                                    target: "/var/lib/data",
                                    kind: .volume,
                                    access: .readWrite
                                ),
                            ]
                        ),
                    ]
                )
            )
        let create = try #require(
            compiled.desiredServicesByNodeKey.values
                .first
        )
        #expect(
            create.mounts == [
                RuntimeMountReference(
                    source: source,
                    target: "/var/lib/data",
                    kind: .bind,
                    access: .readWrite
                ),
            ]
        )
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
        #expect(mismatchDriver.snapshot() == DriverSnapshot(imageChecks: 2))
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

    @Test
    func dryRunBindsMutableTagToExactDescriptorAndPlatformVariant() throws {
        let requested = "registry.example/team/api:stable"
        let preparation = try preparation(
            desired: [service(image: requested)]
        )
        let driver = ScriptedLifecycleCommandDriver(
            preparation: preparation,
            descriptorBody: "d",
            variantBody: "e"
        )
        let result = LifecycleCommandRunner(
            options: options(command: .up, dryRun: true, output: .json),
            driver: driver
        ).run()

        #expect(result.exitCode == 0)
        let plan = try JSONDecoder().decode(
            LifecyclePlan.self,
            from: Data(result.standardOutput.utf8)
        )
        let create = try #require(
            plan.nodes.first { $0.action == .create }
        )
        let desired = try LifecycleRevisionCodec.decodeRedactedDesiredJSON(
            create.desiredSpecificationJSONRedacted
        )
        #expect(desired.imageLock?.requestedReference == requested)
        #expect(
            desired.imageLock?.descriptorDigest ==
                "sha256:\(String(repeating: "d", count: 64))"
        )
        #expect(
            desired.imageLock?.variantDigest ==
                "sha256:\(String(repeating: "e", count: 64))"
        )
        #expect(desired.image == desired.imageLock?.resolvedReference)
        #expect(driver.snapshot() == DriverSnapshot(imageChecks: 1))
    }

    @Test
    func movedTagProducesANewPlanAndRefusesTheReviewedConfirmation() throws {
        let preparation = try preparation(
            desired: [service(image: "registry.example/team/api:stable")]
        )
        let dryDriver = ScriptedLifecycleCommandDriver(
            preparation: preparation,
            descriptorBody: "d"
        )
        let dry = LifecycleCommandRunner(
            options: options(command: .up, dryRun: true, output: .json),
            driver: dryDriver
        ).run()
        let reviewed = try JSONDecoder().decode(
            LifecyclePlan.self,
            from: Data(dry.standardOutput.utf8)
        )

        let movedDriver = ScriptedLifecycleCommandDriver(
            preparation: preparation,
            descriptorBody: "f"
        )
        let confirmed = LifecycleCommandRunner(
            options: options(
                command: .up,
                dryRun: false,
                confirmation: reviewed.planSHA256
            ),
            driver: movedDriver
        ).run()

        #expect(confirmed.exitCode == CLIExitCode.confirmationMismatch.rawValue)
        #expect(confirmed.standardError.contains("does not match"))
        #expect(
            movedDriver.snapshot() ==
                DriverSnapshot(imageChecks: 1)
        )
    }

    @Test
    func updatePreservesPriorTagLockWhileResolvingTheDesiredTagAgain() throws {
        let requested = "registry.example/team/api:stable"
        let priorLock = try RuntimeImageDigestLock(
            requestedReference: requested,
            resolvedReference:
                "registry.example/team/api@sha256:\(String(repeating: "d", count: 64))",
            descriptorDigest: "sha256:\(String(repeating: "d", count: 64))",
            variantDigest: "sha256:\(String(repeating: "e", count: 64))",
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "c", count: 64)
        )
        let previous = service(
            image: priorLock.resolvedReference,
            imageLock: priorLock
        )
        let desired = service(image: requested)
        let observed = ObservedRuntimeService(
            identity: previous.identity,
            resourceIdentifier: previous.identity.managedResourceIdentifier,
            image: previous.image,
            lifecycleState: .running,
            healthState: .healthy
        )
        let prepared = try preparation(
            desired: [desired],
            previous: DesiredRuntimeState(
                projectName: "demo",
                services: [previous]
            ),
            observed: [observed],
            bindings: [try resourceBinding(for: observed)]
        )
        let driver = ScriptedLifecycleCommandDriver(
            preparation: prepared,
            descriptorBody: "f"
        )
        let result = LifecycleCommandRunner(
            options: options(command: .update, dryRun: true, output: .json),
            driver: driver
        ).run()

        #expect(result.exitCode == 0)
        let plan = try JSONDecoder().decode(
            LifecyclePlan.self,
            from: Data(result.standardOutput.utf8)
        )
        let created = try #require(
            plan.nodes.first { $0.action == .create }
        )
        let retired = try #require(
            plan.nodes.first { $0.action == .retire }
        )
        let desiredRevision = try LifecycleRevisionCodec
            .decodeRedactedDesiredJSON(
                created.desiredSpecificationJSONRedacted
            )
        let priorRevision = try LifecycleRevisionCodec
            .decodeRedactedDesiredJSON(
                retired.desiredSpecificationJSONRedacted
            )
        #expect(
            desiredRevision.imageLock?.descriptorDigest ==
                "sha256:\(String(repeating: "f", count: 64))"
        )
        #expect(priorRevision.imageLock == priorLock)
        #expect(driver.snapshot() == DriverSnapshot(imageChecks: 2))
    }

    @Test
    func updateRejectsLegacyMutablePriorRevisionWithoutAnImmutableLock() throws {
        let requested = "registry.example/team/api:stable"
        let previous = service(image: requested)
        let desired = service(
            image:
                "registry.example/team/api@sha256:\(String(repeating: "f", count: 64))"
        )
        let observed = ObservedRuntimeService(
            identity: previous.identity,
            resourceIdentifier: previous.identity.managedResourceIdentifier,
            image: requested,
            lifecycleState: .running,
            healthState: .healthy
        )
        let prepared = try preparation(
            desired: [desired],
            previous: DesiredRuntimeState(
                projectName: "demo",
                services: [previous]
            ),
            observed: [observed],
            bindings: [try resourceBinding(for: observed)]
        )
        let driver = ScriptedLifecycleCommandDriver(preparation: prepared)
        let result = LifecycleCommandRunner(
            options: options(command: .update, dryRun: true),
            driver: driver
        ).run()

        #expect(result.exitCode == CLIExitCode.runtimeUnavailable.rawValue)
        #expect(result.standardError.contains("Local image evidence"))
        #expect(driver.snapshot() == DriverSnapshot(imageChecks: 1))
    }

    private func reviewedPlan(
        preparation: LifecycleCommandPreparation,
        command: LifecycleCommandKind = .up
    ) throws -> LifecyclePlan {
        let result = LifecycleCommandRunner(
            options: options(command: command, dryRun: true, output: .json),
            driver: ScriptedLifecycleCommandDriver(preparation: preparation)
        ).run()
        guard result.exitCode == 0 else {
            throw LifecycleCommandRunnerError.invalidInput(result.standardError)
        }
        return try JSONDecoder().decode(
            LifecyclePlan.self,
            from: Data(result.standardOutput.utf8)
        )
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
        imageLock: RuntimeImageDigestLock? = nil,
        environment: [RuntimeEnvironmentValue] = [],
        networks: [RuntimeDesiredNetworkAttachment] = [],
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
            imageLock: imageLock,
            environment: environment,
            ports: ports,
            networks: networks,
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
        networks: [DesiredRuntimeNetwork] = [],
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
                networks: networks,
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

private func makeDaemonReconciliationRequest(
    manifestPath: String,
    manifestSHA256: String,
    stateDatabasePath: String,
    projectID: String,
    maximumParallelism: Int,
    selectedServiceNames: [String]? = nil
) throws -> DaemonReconciliationRequest {
    let normalizedPath = URL(fileURLWithPath: manifestPath).standardizedFileURL.path
    let target = try DaemonConfigurationTarget(
        kind: .manifest,
        path: normalizedPath,
        contentSHA256: manifestSHA256,
        byteCount: 0,
        device: 1,
        inode: 1
    )
    return try DaemonReconciliationRequest(
        manifestPath: normalizedPath,
        manifestSHA256: manifestSHA256,
        configurationSetSHA256: DaemonConfigurationSetDigest.sha256([target]),
        configurationTargets: [target],
        stateDatabasePath: stateDatabasePath,
        projectID: projectID,
        maximumParallelism: maximumParallelism,
        selectedServiceNames: selectedServiceNames
    )
}

private final class LockedReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
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
    private let descriptorBodyOverride: Character?
    private let variantBody: Character
    private let executionResult: LifecycleSagaExecutionResult?
    private let executionHook: ((LifecycleCompiledCommand, LifecycleCLIOptions) throws -> Void)?
    private var counts = DriverSnapshot()

    init(
        preparation: LifecycleCommandPreparation,
        imageEvidenceIsValid: Bool = true,
        descriptorBody: Character? = nil,
        variantBody: Character = "e",
        executionResult: LifecycleSagaExecutionResult? = nil,
        executionHook: ((LifecycleCompiledCommand, LifecycleCLIOptions) throws -> Void)? = nil
    ) {
        self.preparation = preparation
        self.imageEvidenceIsValid = imageEvidenceIsValid
        self.descriptorBodyOverride = descriptorBody
        self.variantBody = variantBody
        self.executionResult = executionResult
        self.executionHook = executionHook
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
        let descriptorBody = Self.pinnedDigestBody(in: requirement.reference) ??
            descriptorBodyOverride ??
            "d"
        return RuntimeLocalImageEvidence(
            reference: requirement.reference,
            descriptorDigest: "sha256:\(String(repeating: descriptorBody, count: 64))",
            variantDigest: "sha256:\(String(repeating: variantBody, count: 64))",
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
        try executionHook?(compiled, options)
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

    private static func pinnedDigestBody(in reference: String?) -> Character? {
        guard let reference,
              let marker = reference.range(of: "@sha256:") else {
            return nil
        }
        let digest = reference[marker.upperBound...]
        guard digest.count == 64,
              let first = digest.first,
              digest.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }
}
