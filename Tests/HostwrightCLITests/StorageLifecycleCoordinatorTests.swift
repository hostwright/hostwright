import CryptoKit
import Foundation
import HostwrightCore
@testable import HostwrightCLI
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import HostwrightStorage
import XCTest

final class StorageLifecycleCoordinatorTests: XCTestCase {
    func testRuntimeQuiescenceRefusesRunningHolderBeforeFence()
        throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerRoot = root.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let down = try fixture(
            capacity: "1MiB",
            command: .down,
            providerRoot: providerRoot
        )
        let node = try XCTUnwrap(down.compiled.plan.nodes.first)
        let ownership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: node.resourceUUID,
            projectUUID:
                down.preparation.projectResourceUUID,
            resourceGeneration: node.resourceGeneration,
            projectGeneration:
                down.preparation.projectGeneration,
            providerID: down.preparation.providerID,
            providerGeneration:
                down.preparation.providerGeneration,
            fencingToken: node.fencingToken
        )
        func inventory(
            _ lifecycle: RuntimeInventoryLifecycleState
        ) throws -> RuntimeInventory {
            try RuntimeInventoryBuilder.build(
                machine: RuntimeInventoryMachine(
                    state: .running,
                    operatingSystem: "macOS 26.0",
                    architecture: "arm64",
                    runtimeVersion: "1.1.0",
                    services: []
                ),
                containers: [
                    RuntimeInventoryContainer(
                        runtimeID: "runtime-holder",
                        name: "managed-holder",
                        imageReference: "example.invalid/local@sha256:" +
                            String(repeating: "a", count: 64),
                        lifecycle: lifecycle,
                        health: RuntimeInventoryHealth(
                            availability: .notConfigured
                        ),
                        labels: [
                            RuntimeInventoryLabel(
                                key:
                                    RuntimeManagedResourceIdentity
                                        .managedLabel,
                                value: "true"
                            ),
                        ],
                        ownership: ownership,
                        initConfiguration:
                            RuntimeInventoryInitConfiguration(
                                executable: "/bin/true",
                                arguments: [],
                                environment: []
                            ),
                        ports: [],
                        mounts: [],
                        networks: [],
                        services: []
                    ),
                ],
                images: [],
                networks: [],
                volumes: []
            )
        }

        XCTAssertThrowsError(
            try lifecycleStorageQuiescenceProof(
                inventory: inventory(.running),
                preparation: down.preparation,
                compiled: down.compiled
            )
        )
        let proof = try lifecycleStorageQuiescenceProof(
            inventory: inventory(.stopped),
            preparation: down.preparation,
            compiled: down.compiled
        )
        XCTAssertTrue(
            proof.workloadUUIDs.contains(node.resourceUUID)
        )
    }

    func testInterruptedCreateRepairsOnlyExactProviderMetadata()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerRoot = root.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let provider = try LocalStorageProvider(
            rootURL: providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024
        )
        let store = SQLiteStateStore(
            path: root.appendingPathComponent("state.sqlite3").path
        )
        try store.migrate()
        let projectID = "project-storage-repair"
        let projectUUID = HostwrightResourceUUID.legacy(
            kind: "project",
            identifier: projectID
        )
        let volumeID = HostwrightResourceUUID.legacy(
            kind: "volume",
            identifier: "\(projectUUID):data"
        )
        let operationID = HostwrightResourceUUID.legacy(
            kind: "storage-volume-operation",
            identifier: "repair-create"
        )
        let fence = HostwrightResourceUUID.legacy(
            kind: "storage-volume-fence",
            identifier: operationID
        )
        let dataPath = providerRoot
            .appendingPathComponent("volumes", isDirectory: true)
            .appendingPathComponent(volumeID, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .standardizedFileURL.path
        let intent = StorageVolumeOperationIntent(
            schemaVersion: 1,
            action: "create",
            name: "data",
            volumeID: volumeID,
            projectID: projectID,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerID:
                LocalStorageProviderContract.providerID,
            topologyNodeID:
                StorageLifecycleCoordinator.topologyNodeID,
            generation: 1,
            fencingToken: fence,
            capacityBytes: 1_048_576,
            reclaimPolicy: .delete,
            accessMode: .readWriteOnce,
            expectedDataPath: dataPath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let intentJSON = try XCTUnwrap(
            String(
                data: try encoder.encode(intent),
                encoding: .utf8
            )
        )
        let now = hostwrightTimestamp()
        let group = OperationGroupRecord(
            id: operationID,
            operationID: operationID,
            groupKind: "storage-volume",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "create",
            status: .active,
            groupIdempotencyKey: sha256("repair-create"),
            planHash: sha256("repair-plan"),
            checkpoint: "provider-effect-requested",
            lockOwner: "hostwright-cli",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 86_400,
                to: now
            ),
            rollbackAvailable: true,
            manualRecoveryHintRedacted:
                "Observe the exact volume before recovery.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted: #"{"resource":"volume"}"#,
            fencingToken: fence,
            intentJSONRedacted: intentJSON,
            compensationJSONRedacted:
                #"["delete-created-volume"]"#,
            verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(
                group,
                currentTimestamp: now
            ).acquired
        )
        try store.operationGroups.finish(
            groupID: operationID,
            status: .interrupted,
            checkpoint: "provider-effect-requested",
            manualRecoveryHintRedacted:
                "Observe the exact volume before recovery.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"result":"interrupted"}"#
        )
        let client = try StorageProviderClient(
            provider: provider
        )
        let created: LocalStorageMutationResult =
            try await client.invoke(
                operation: .create,
                mutationContext:
                    StorageProviderMutationContext(
                        projectUUID:
                            UUID(uuidString: projectUUID)!,
                        projectGeneration: 1,
                        resourceUUID:
                            UUID(uuidString: volumeID)!,
                        resourceGeneration: 1,
                        fencingToken:
                            UUID(uuidString: fence)!
                    ),
                idempotencyKey: group.groupIdempotencyKey,
                payload: LocalStorageCreatePayload(
                    name: "data",
                    capacityBytes: 1_048_576,
                    retention: .deleteWhenUnused
                ),
                result: LocalStorageMutationResult.self
            )
        XCTAssertEqual(created.volume?.dataPath, dataPath)

        let state = StorageStateRepository(store: store)
        let storedGroup = try XCTUnwrap(
            try store.operationGroups.loadAll().first {
                $0.id == operationID
            }
        )
        XCTAssertEqual(
            try store.operationGroups.loadAll().count,
            1
        )
        XCTAssertEqual(storedGroup.groupKind, "storage-volume")
        XCTAssertEqual(storedGroup.plannedActionType, "create")
        XCTAssertEqual(storedGroup.status, .interrupted)
        XCTAssertEqual(storedGroup.projectID, intent.projectID)
        XCTAssertEqual(
            storedGroup.fencingToken,
            intent.fencingToken
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                StorageVolumeOperationIntent.self,
                from: Data(
                    storedGroup.intentJSONRedacted.utf8
                )
            ),
            intent
        )
        let observed = try XCTUnwrap(
            try provider.list().volumes.first {
                $0.volumeID == volumeID
            }
        )
        XCTAssertEqual(observed.name, intent.name)
        XCTAssertEqual(observed.providerID, intent.providerID)
        XCTAssertEqual(
            observed.projectID,
            intent.projectResourceUUID
        )
        XCTAssertEqual(
            observed.projectGeneration,
            intent.projectGeneration
        )
        XCTAssertEqual(observed.generation, Int(intent.generation))
        XCTAssertEqual(
            observed.fencingToken,
            intent.fencingToken
        )
        XCTAssertEqual(
            observed.capacityBytes,
            intent.capacityBytes
        )
        XCTAssertEqual(observed.retention, .deleteWhenUnused)
        XCTAssertEqual(
            observed.dataPath,
            intent.expectedDataPath
        )
        XCTAssertTrue(observed.attachments.isEmpty)
        XCTAssertTrue(
            StorageLifecycleCoordinator
                .exactCreateObservation(
                    observed,
                    matches: intent
                )
        )
        XCTAssertTrue(
            try provider.list().ambiguousVolumeIDs.isEmpty
        )
        XCTAssertNil(try state.loadVolume(id: volumeID))
        let repaired = try StorageLifecycleCoordinator
            .repairRecoverableCreateMetadata(
                observation: try provider.list(),
                store: store,
                state: state
            )

        XCTAssertEqual(repaired, [volumeID])
        let record = try XCTUnwrap(
            try state.loadVolume(id: volumeID)
        )
        XCTAssertEqual(record.projectID, projectID)
        XCTAssertEqual(record.fencingToken, fence)
        XCTAssertEqual(record.reclaimPolicy, .delete)
        XCTAssertEqual(
            try state.loadQuota(
                id: HostwrightResourceUUID.legacy(
                    kind: "storage-quota",
                    identifier: volumeID
                )
            )?.byteLimit,
            1_048_576
        )
        XCTAssertEqual(
            try store.operationGroups.load(id: operationID)?
                .status,
            .succeeded
        )
        XCTAssertTrue(
            try StorageLifecycleCoordinator
                .repairRecoverableCreateMetadata(
                    observation: try provider.list(),
                    store: store,
                    state: state
                )
                .isEmpty
        )
    }

    func testMetadataRepairDoesNotStealActiveCreateOperation()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try LocalStorageProvider(
            rootURL: root.appendingPathComponent(
                "provider",
                isDirectory: true
            )
        )
        let store = SQLiteStateStore(
            path: root.appendingPathComponent("state.sqlite3").path
        )
        try store.migrate()
        let projectID = "repair-active"
        let projectUUID =
            "10000000-0000-4000-8000-000000000099"
        let volumeID =
            "20000000-0000-4000-8000-000000000099"
        let fence =
            "30000000-0000-4000-8000-000000000099"
        let operationID =
            "40000000-0000-4000-8000-000000000099"
        let now = hostwrightTimestamp()
        let dataPath = root
            .appendingPathComponent("provider/volumes")
            .appendingPathComponent(volumeID)
            .appendingPathComponent("data")
            .standardizedFileURL.path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let intentJSON = try XCTUnwrap(
            String(
                data: try encoder.encode(
                    StorageVolumeOperationIntent(
                schemaVersion: 1,
                action: "create",
                name: "data",
                volumeID: volumeID,
                projectID: projectID,
                projectResourceUUID: projectUUID,
                projectGeneration: 1,
                providerID:
                    LocalStorageProviderContract.providerID,
                topologyNodeID:
                    StorageLifecycleCoordinator.topologyNodeID,
                generation: 1,
                fencingToken: fence,
                capacityBytes: 1_048_576,
                reclaimPolicy: .delete,
                accessMode: .readWriteOnce,
                expectedDataPath: dataPath
                    )
                ),
                encoding: .utf8
            )
        )
        let group = OperationGroupRecord(
            id: operationID,
            operationID: operationID,
            groupKind: "storage-volume",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "create",
            status: .active,
            groupIdempotencyKey:
                String(repeating: "a", count: 64),
            planHash: String(repeating: "b", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "active-owner",
            lockExpiresAt: "2035-01-01T00:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "active",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: intentJSON,
            compensationJSONRedacted:
                #"["delete-created-volume"]"#,
            verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(
                group,
                currentTimestamp: now
            ).acquired
        )
        let client = try StorageProviderClient(
            provider: provider
        )
        let _: LocalStorageMutationResult =
            try await client.invoke(
                operation: .create,
                mutationContext:
                    StorageProviderMutationContext(
                        projectUUID:
                            UUID(uuidString: projectUUID)!,
                        projectGeneration: 1,
                        resourceUUID:
                            UUID(uuidString: volumeID)!,
                        resourceGeneration: 1,
                        fencingToken:
                            UUID(uuidString: fence)!
                    ),
                idempotencyKey: group.groupIdempotencyKey,
                payload: LocalStorageCreatePayload(
                    name: "data",
                    capacityBytes: 1_048_576,
                    retention: .deleteWhenUnused
                ),
                result: LocalStorageMutationResult.self
            )

        let state = StorageStateRepository(store: store)
        XCTAssertTrue(
            try StorageLifecycleCoordinator
                .repairRecoverableCreateMetadata(
                    observation: try provider.list(),
                    store: store,
                    state: state
                )
                .isEmpty
        )
        XCTAssertNil(try state.loadVolume(id: volumeID))
        XCTAssertEqual(
            try store.operationGroups.load(id: operationID)?
                .status,
            .active
        )
    }

    func testCapacityRefusalOccursBeforeProviderMutation()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerRoot = root.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let provider = try LocalStorageProvider(
            rootURL: providerRoot,
            totalCapacityBytes: 512 * 1_024
        )
        let store = SQLiteStateStore(
            path: root.appendingPathComponent("state.sqlite3").path
        )
        try store.migrate()
        let environment = testEnvironment(
            provider: provider,
            providerRoot: providerRoot
        )
        let input = try fixture(
            capacity: "1MiB",
            command: .up,
            providerRoot: providerRoot
        )

        do {
            _ = try await StorageLifecycleCoordinator
                .reconcileNamedVolumes(
                    manifest: input.manifest,
                    preparation: input.preparation,
                    compiled: input.compiled,
                    planSHA256:
                        input.compiled.plan.planSHA256,
                    timeoutSeconds: 30,
                    store: store,
                    environment: environment
                )
            XCTFail("Expected capacity refusal.")
        } catch let diagnostic as HostwrightDiagnostic {
            XCTAssertEqual(diagnostic.code, .storageUnavailable)
            XCTAssertTrue(
                diagnostic.message.contains("bytes-exhausted")
            )
        }
        XCTAssertTrue(try provider.list().volumes.isEmpty)
        let group = try XCTUnwrap(
            try store.operationGroups.loadProject(
                projectID: input.preparation.projectID
            ).first
        )
        let admission = try XCTUnwrap(
            try StorageStateRepository(store: store)
                .latestCapacityAdmission(
                    operationID: group.operationID
                )
        )
        XCTAssertEqual(admission.result.disposition, .reject)
        XCTAssertEqual(
            admission.result.reason,
            .bytesExhausted
        )
    }

    func testNamedVolumeCreateAttachExpandDetachAndReplayConverge()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerRoot = root.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let provider = try LocalStorageProvider(
            rootURL: providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024
        )
        let store = SQLiteStateStore(
            path: root.appendingPathComponent("state.sqlite3").path
        )
        try store.migrate()
        let environment = testEnvironment(
            provider: provider,
            providerRoot: providerRoot
        )

        let first = try fixture(
            capacity: "1MiB",
            command: .up,
            providerRoot: providerRoot
        )
        let created = try await StorageLifecycleCoordinator
            .reconcileNamedVolumes(
                manifest: first.manifest,
                preparation: first.preparation,
                compiled: first.compiled,
                planSHA256:
                    first.compiled.plan.planSHA256,
                timeoutSeconds: 30,
                store: store,
                environment: environment
            )
        XCTAssertEqual(created.volumesByName["data"]?.capacityBytes, 1_048_576)
        XCTAssertEqual(created.newlyAttachedIDs.count, 1)
        let durableFile = URL(
            fileURLWithPath:
                first.sources["data"]!
        ).appendingPathComponent("durable.txt")
        try Data("persistent".utf8).write(
            to: durableFile,
            options: .atomic
        )
        let state = StorageStateRepository(store: store)
        let volume = try XCTUnwrap(
            try state.loadVolumes(
                projectID: first.preparation.projectID
            ).first
        )
        let initialQuota = try XCTUnwrap(
            try state.loadQuota(
                id: HostwrightResourceUUID.legacy(
                    kind: "storage-quota",
                    identifier: volume.id
                )
            )
        )
        XCTAssertEqual(initialQuota.byteLimit, 1_048_576)
        XCTAssertEqual(initialQuota.enforcementMode, .logical)
        let initialCapacity = try XCTUnwrap(
            try state.latestCapacitySample(
                providerID:
                    LocalStorageProviderContract.providerID,
                topologyNodeID: "local-apple-silicon"
            )
        )
        XCTAssertEqual(
            initialCapacity.sample.providerID,
            LocalStorageProviderContract.providerID
        )
        XCTAssertEqual(
            try state.latestCapacityAdmission(
                operationID: volume.operationGroupID
            )?.result.disposition,
            .admit
        )
        let initialAttachments = try state.loadAttachments(
            volumeID: volume.id
        )
        XCTAssertEqual(
            initialAttachments.map(\.checkpoint),
            [.attachedCommitted]
        )
        let initialAttachment = try XCTUnwrap(
            initialAttachments.first
        )
        XCTAssertEqual(
            try state.latestCapacityAdmission(
                operationID: initialAttachment.operationID
            )?.action,
            .attach
        )

        let replayed = try await StorageLifecycleCoordinator
            .reconcileNamedVolumes(
                manifest: first.manifest,
                preparation: first.preparation,
                compiled: first.compiled,
                planSHA256:
                    first.compiled.plan.planSHA256,
                timeoutSeconds: 30,
                store: store,
                environment: environment
            )
        XCTAssertTrue(replayed.newlyAttachedIDs.isEmpty)

        let expanded = try fixture(
            capacity: "2MiB",
            command: .up,
            providerRoot: providerRoot
        )
        let expansion = try await StorageLifecycleCoordinator
            .reconcileNamedVolumes(
                manifest: expanded.manifest,
                preparation: expanded.preparation,
                compiled: expanded.compiled,
                planSHA256:
                    expanded.compiled.plan.planSHA256,
                timeoutSeconds: 30,
                store: store,
                environment: environment
            )
        XCTAssertEqual(
            expansion.volumesByName["data"]?.capacityBytes,
            2_097_152
        )
        let expandedVolume = try XCTUnwrap(
            expansion.volumesByName["data"]
        )
        let expandedQuota = try XCTUnwrap(
            try state.loadQuota(id: initialQuota.id)
        )
        XCTAssertEqual(expandedQuota.byteLimit, 2_097_152)
        XCTAssertEqual(
            expandedQuota.generation,
            expandedVolume.generation
        )
        XCTAssertEqual(
            try state.latestCapacityAdmission(
                operationID: expandedVolume.operationGroupID
            )?.result.disposition,
            .admit
        )
        XCTAssertEqual(
            try String(contentsOf: durableFile, encoding: .utf8),
            "persistent"
        )

        let down = try fixture(
            capacity: "2MiB",
            command: .down,
            providerRoot: providerRoot
        )
        try await StorageLifecycleCoordinator.detachNamedVolumes(
            preparation: down.preparation,
            compiled: down.compiled,
            planSHA256: down.compiled.plan.planSHA256,
            timeoutSeconds: 30,
            quiescenceProof: try StorageRuntimeQuiescenceProof(
                observationSHA256: sha256("down-quiesced"),
                workloadUUIDs: Set(
                    down.compiled.plan.nodes.map(\.resourceUUID)
                )
            ),
            store: store,
            environment: environment
        )
        XCTAssertEqual(
            try state.loadAttachments(
                volumeID: volume.id
            ).map(\.checkpoint),
            [.detachedCommitted]
        )
        XCTAssertTrue(
            try provider.inspect(
                volumeID: volume.id
            ).attachments.isEmpty
        )
        XCTAssertEqual(
            try String(contentsOf: durableFile, encoding: .utf8),
            "persistent"
        )
    }

    func testDeletedNamedVolumeRecreatesWithAdvancedFenceAndQuota()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerRoot = root.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let provider = try LocalStorageProvider(
            rootURL: providerRoot,
            totalCapacityBytes: 16 * 1_024 * 1_024
        )
        let statePath = root
            .appendingPathComponent("state.sqlite3")
            .path
        let store = SQLiteStateStore(path: statePath)
        try store.migrate()
        let environment = testEnvironment(
            provider: provider,
            providerRoot: providerRoot
        )
        let up = try fixture(
            capacity: "1MiB",
            command: .up,
            providerRoot: providerRoot,
            reclaimPolicy: .delete
        )
        let created = try await StorageLifecycleCoordinator
            .reconcileNamedVolumes(
                manifest: up.manifest,
                preparation: up.preparation,
                compiled: up.compiled,
                planSHA256: up.compiled.plan.planSHA256,
                timeoutSeconds: 30,
                store: store,
                environment: environment
            )
        let original = try XCTUnwrap(
            created.volumesByName["data"]
        )
        let down = try fixture(
            capacity: "1MiB",
            command: .down,
            providerRoot: providerRoot,
            reclaimPolicy: .delete
        )
        try await StorageLifecycleCoordinator
            .detachNamedVolumes(
                preparation: down.preparation,
                compiled: down.compiled,
                planSHA256:
                    down.compiled.plan.planSHA256,
                timeoutSeconds: 30,
                quiescenceProof:
                    try StorageRuntimeQuiescenceProof(
                        observationSHA256:
                            sha256("delete-quiesced"),
                        workloadUUIDs: Set(
                            down.compiled.plan.nodes.map(
                                \.resourceUUID
                            )
                        )
                    ),
                store: store,
                environment: environment
            )
        let client = try StorageProviderClient(
            provider: provider
        )
        let coordinator =
            StorageReclaimCommandCoordinator(
                options: StorageCLIOptions(
                    action: .inspect(
                        volumeID: original.id
                    ),
                    stateDatabasePath: statePath,
                    timeoutSeconds: 30,
                    output: .json
                ),
                environment: environment
            )
        _ = try await coordinator.applyPolicy(
            volumeID: original.id,
            authorizedLifecyclePlanSHA256:
                down.compiled.plan.planSHA256,
            client: client
        )
        let repository = StorageStateRepository(
            store: store
        )
        let deleted = try XCTUnwrap(
            try repository.loadVolume(id: original.id)
        )
        XCTAssertEqual(deleted.lifecycleState, .deleted)
        XCTAssertTrue(try provider.list().volumes.isEmpty)
        let releasedQuota = try XCTUnwrap(
            try repository.loadQuota(
                id: HostwrightResourceUUID.legacy(
                    kind: "storage-quota",
                    identifier: original.id
                )
            )
        )
        XCTAssertEqual(
            releasedQuota.lifecycleState,
            .released
        )
        XCTAssertEqual(
            releasedQuota.generation,
            deleted.generation
        )

        let recreated = try await StorageLifecycleCoordinator
            .reconcileNamedVolumes(
                manifest: up.manifest,
                preparation: up.preparation,
                compiled: up.compiled,
                planSHA256: up.compiled.plan.planSHA256,
                timeoutSeconds: 30,
                store: store,
                environment: environment
            )
        let replacement = try XCTUnwrap(
            recreated.volumesByName["data"]
        )
        XCTAssertEqual(
            replacement.generation,
            deleted.generation + 1
        )
        XCTAssertNotEqual(
            replacement.fencingToken,
            deleted.fencingToken
        )
        XCTAssertEqual(
            replacement.lifecycleState,
            .available
        )
        XCTAssertEqual(
            try provider.inspect(
                volumeID: replacement.id
            ).generation,
            Int(replacement.generation)
        )
        let activeQuota = try XCTUnwrap(
            try repository.loadQuota(
                id: releasedQuota.id
            )
        )
        XCTAssertEqual(activeQuota.lifecycleState, .active)
        XCTAssertEqual(
            activeQuota.generation,
            replacement.generation
        )
    }

    private struct Fixture {
        let manifest: HostwrightManifest
        let preparation: LifecycleCommandPreparation
        let compiled: LifecycleCompiledCommand
        let sources: [String: String]
    }

    private func fixture(
        capacity: String,
        command: LifecycleCommand,
        providerRoot: URL,
        reclaimPolicy:
            HostwrightVolumeReclaimPolicy = .retain
    ) throws -> Fixture {
        let projectName = "storage-test"
        let projectID = "project-\(projectName)"
        let projectUUID = HostwrightResourceUUID.legacy(
            kind: "project",
            identifier: projectID
        )
        let manifest = HostwrightManifest(
            version: 2,
            project: projectName,
            imagePolicy: nil,
            imageTrust: nil,
            imageSBOM: nil,
            volumes: [
                "data": HostwrightVolumeDeclaration(
                    capacity: capacity,
                    reclaimPolicy: reclaimPolicy
                ),
            ],
            services: [
                HostwrightService(
                    name: "api",
                    image: "example.invalid/api@sha256:" +
                        String(repeating: "a", count: 64),
                    mounts: [
                        HostwrightMountSpec.legacy(
                            "data:/var/lib/api"
                        )!,
                    ]
                ),
            ]
        )
        let sources = StorageLifecycleCoordinator.namedVolumeSources(
            manifest: manifest,
            projectResourceUUID: projectUUID,
            providerRootURL: providerRoot
        )
        let mapping = ManifestRuntimeMapper.map(
            manifest,
            namedVolumeSources: sources
        )
        let service = try XCTUnwrap(
            mapping.desiredState.services.first
        )
        let resourceUUID = HostwrightResourceUUID.legacy(
            kind: "service",
            identifier:
                "\(projectID):\(service.identity.displayName)"
        )
        let fence = HostwrightResourceUUID.legacy(
            kind: "storage-test-plan-fence",
            identifier: "\(command.rawValue):\(capacity)"
        )
        let node = try LifecyclePlanNode(
            key: "\(command.rawValue)-api",
            action: command == .down ? .stop : .create,
            serviceName: service.identity.displayName,
            resourceIdentifier:
                service.identity.managedResourceIdentifier,
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            fencingToken: fence,
            desiredSpecificationJSONRedacted: "{}"
        )
        let digest = sha256("\(command.rawValue):\(capacity)")
        let capability = String(repeating: "c", count: 64)
        let plan = try LifecyclePlan(
            command: command,
            projectID: projectID,
            projectName: projectName,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            manifestSHA256: digest,
            observationSHA256:
                String(repeating: "b", count: 64),
            capabilitySHA256: capability,
            nodes: [node]
        )
        let compiled = LifecycleCompiledCommand(
            plan: plan,
            desiredServicesByNodeKey: [node.key: service],
            localImageRequirements: []
        )
        let preparation = LifecycleCommandPreparation(
            manifestSHA256: digest,
            manifestBaseDirectory: "/private/tmp",
            mappingIssues: mapping.issues,
            desiredState: mapping.desiredState,
            observedState: ObservedRuntimeState(
                projectName: projectName,
                services: []
            ),
            observationSHA256:
                String(repeating: "b", count: 64),
            projectID: projectID,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            capabilitySHA256: capability,
            planFencingToken: fence
        )
        return Fixture(
            manifest: manifest,
            preparation: preparation,
            compiled: compiled,
            sources: sources
        )
    }

    private func testEnvironment(
        provider: LocalStorageProvider,
        providerRoot: URL
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: {
                FileManager.default.fileExists(atPath: $0)
            },
            readTextFile: {
                try String(contentsOfFile: $0, encoding: .utf8)
            },
            writeTextFile: { path, text in
                try text.write(
                    toFile: path,
                    atomically: true,
                    encoding: .utf8
                )
            },
            executablePath: { _ in nil },
            storageProvider: { provider },
            storageProviderRootURL: { providerRoot },
            swiftVersion: { "Swift test" },
            platformSnapshot: {
                PlatformSnapshot(
                    macOSMajorVersion: 26,
                    architecture: "arm64"
                )
            },
            operatingSystemDescription: { "macOS test" }
        )
    }

    private func temporaryRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.path
        let canonical = raw.hasPrefix("/var/")
            ? "/private\(raw)"
            : raw
        let root = URL(
            fileURLWithPath: canonical,
            isDirectory: true
        ).appendingPathComponent(
            "hostwright-storage-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
