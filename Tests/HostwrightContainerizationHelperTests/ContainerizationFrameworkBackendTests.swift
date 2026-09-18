import ContainerizationError
import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import XCTest

@testable import HostwrightContainerizationHelper

final class ContainerizationFrameworkBackendTests: XCTestCase {
    func testSDKConfigurationUsesExplicitAllocationAndRejectsMissingOrInvalidLimits() throws {
        for (cpus, memory): (Int, UInt64) in [(1, 536_870_912), (2, 805_306_368)] {
            let configuration = try ContainerizationHelperSDKResourceConfiguration.make(cpuCount: cpus, memoryBytes: memory)
            XCTAssertEqual(configuration.cpus, cpus)
            XCTAssertEqual(configuration.memoryInBytes, memory)
        }
        for (cpus, memory): (Int?, UInt64?) in [(nil, nil), (nil, 536_870_912), (1, nil), (0, 1), (-1, 1), (1, 0), (Int.max, 1), (1, UInt64.max)] {
            XCTAssertThrowsError(try ContainerizationHelperSDKResourceConfiguration.make(cpuCount: cpus, memoryBytes: memory))
        }
    }

    func testAllocationPersistsAndObservesDistinctLimitsIncludingStoppedRecovery() async throws {
        for (cpus, memory): (Int, UInt64) in [(1, 536_870_912), (2, 805_306_368)] {
            let parent = try makePrivateParent()
            defer { try? FileManager.default.removeItem(at: parent) }
            let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state", isDirectory: true))
            let driver = RecordingContainerizationDriver()
            let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
            let context = mutationContext()
            let request = try createRequest(context: context, cpuCount: cpus, memoryBytes: memory)
            _ = try await backend.create(request, context: context)
            let persisted = try XCTUnwrap(store.loadRecords().first)
            XCTAssertEqual(persisted.cpuCount, cpus)
            XCTAssertEqual(persisted.memoryBytes, memory)
            XCTAssertEqual(persisted.allocationVerified, true)
            let allocation = RuntimeInventoryAllocation(cpuCount: cpus, memoryBytes: memory)
            let stopped = try await backend.observe(.init()).validatedInventory()
            XCTAssertEqual(stopped.containers.first?.allocation, allocation)
            let mutation = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier, resourceUUID: request.resourceUUID)
            _ = try await backend.start(mutation, context: context)
            let running = try await backend.observe(.init()).validatedInventory()
            XCTAssertEqual(running.containers.first?.allocation, allocation)
            let recovered = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: RecordingContainerizationDriver())
            let inventory = try await recovered.observe(.init()).validatedInventory()
            XCTAssertEqual(inventory.containers.first?.lifecycle, .stopped)
            XCTAssertEqual(inventory.containers.first?.allocation, allocation)
        }
    }

    func testInvalidAllocationRejectsBeforeDriverOrPersistenceMutation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state", isDirectory: true))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let context = mutationContext()
        for (cpus, memory): (Int?, UInt64?) in [(nil, nil), (1, nil), (nil, 1), (0, 1), (-1, 1), (1, 0), (Int.max, 1), (1, UInt64.max)] {
            let request = try createRequest(context: context, cpuCount: cpus, memoryBytes: memory)
            await XCTAssertThrowsErrorAsync { _ = try await backend.create(request, context: context) }
            XCTAssertTrue(try store.loadRecords().isEmpty)
        }
        let operations = await driver.operations()
        XCTAssertTrue(operations.isEmpty)
    }

    func testPersistenceRejectsMalformedAllocationRatherThanApplyingSDKDefaults() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state", isDirectory: true))
        let context = mutationContext()
        let request = try createRequest(context: context)
        try store.save(ContainerizationHelperPersistedRecord(request: request, context: context))
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: store.recordsURL.path).first)
        let url = store.recordsURL.appendingPathComponent(name)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cpuCount"] = 0
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try store.loadRecords()) { error in
            XCTAssertEqual(error as? ContainerizationHelperPersistenceError, .invalidRecord)
        }
    }

    func testSDKAllocationMismatchFailsCreateWithoutVerifiedEvidence() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state", isDirectory: true))
        let driver = RecordingContainerizationDriver(allocationOverride: RuntimeInventoryAllocation(cpuCount: 4, memoryBytes: 1_073_741_824))
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let context = mutationContext()
        let request = try createRequest(context: context)
        await XCTAssertThrowsErrorAsync { _ = try await backend.create(request, context: context) }
        let record = try XCTUnwrap(store.loadRecords().first)
        XCTAssertEqual(record.phase, .failed)
        XCTAssertNotEqual(record.allocationVerified, true)
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["resolve", "create", "stop"])
    }

    func testFailedStartAndRestartReadbackDiscardPriorVerifiedAllocation() async throws {
        for restarting in [false, true] {
            let parent = try makePrivateParent()
            defer { try? FileManager.default.removeItem(at: parent) }
            let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state", isDirectory: true))
            let driver = RecordingContainerizationDriver()
            let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
            let context = mutationContext()
            let request = try createRequest(context: context)
            _ = try await backend.create(request, context: context)
            let mutation = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier, resourceUUID: request.resourceUUID)
            if restarting { _ = try await backend.start(mutation, context: context) }
            await driver.mismatchNextStartOrRestart()
            await XCTAssertThrowsErrorAsync {
                if restarting { _ = try await backend.restart(mutation, context: context) }
                else { _ = try await backend.start(mutation, context: context) }
            }
            let record = try XCTUnwrap(store.loadRecords().first)
            XCTAssertEqual(record.phase, .stopped)
            XCTAssertEqual(record.allocationVerified, false)
            let observed = try await backend.observe(.init()).validatedInventory()
            XCTAssertNil(observed.containers.first?.allocation)
            let recovered = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: RecordingContainerizationDriver())
            let afterRecovery = try await recovered.observe(.init()).validatedInventory()
            XCTAssertNil(afterRecovery.containers.first?.allocation)
        }
    }

    func testLegacyRecordKeepsCleanupWithoutInventingAllocationOrStarting() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state", isDirectory: true))
        let context = mutationContext()
        let request = try createRequest(context: context, cpuCount: nil, memoryBytes: nil)
        var legacy = ContainerizationHelperPersistedRecord(request: request, context: context)
        legacy.phase = .stopped
        try store.save(legacy)
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let inventory = try await backend.observe(.init()).validatedInventory()
        XCTAssertNil(inventory.containers.first?.allocation)
        let mutation = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier, resourceUUID: request.resourceUUID)
        await XCTAssertThrowsErrorAsync { _ = try await backend.start(mutation, context: context) }
        let operations = await driver.operations()
        XCTAssertFalse(operations.contains("start"))
        _ = try await backend.delete(mutation, context: context)
        XCTAssertTrue(try store.loadRecords().isEmpty)
    }

    func testCapabilitySnapshotAdvertisesExactImplementedFeatureSet() throws {
        let snapshot = try ContainerizationHelperCapabilitySnapshot.make()

        XCTAssertEqual(
            Set(snapshot.features.filter { $0.state == .available }.map(\.feature)),
            Set([
                .observation,
                .lifecycle,
                .processControl,
                .streaming,
                .images,
                .networks,
                .cancellation,
                .timeouts,
                .errors,
                .cleanup
            ])
        )
        XCTAssertEqual(
            Set(snapshot.features.filter { $0.state == .unavailable }.map(\.feature)),
            Set([.storage])
        )
        XCTAssertTrue(
            snapshot.features.filter { $0.state == .available }
                .allSatisfy { $0.reason == .implemented }
        )
        XCTAssertTrue(
            snapshot.features.filter { $0.state == .unavailable }
                .allSatisfy { $0.reason == .notImplemented }
        )
    }

    func testNetworkContractAdvertisesExactContainerizationOperations() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: RecordingContainerizationDriver()
        )

        let capabilities = try await backend.networkCapabilities()
        XCTAssertEqual(capabilities.providerID, .appleContainerization)
        XCTAssertEqual(capabilities.modes, [.hostOnly, .nat])
        XCTAssertEqual(capabilities.ipv4AddressModes, [.cidr])
        XCTAssertEqual(capabilities.ipv6AddressModes, [.cidr, .disabled])
        XCTAssertEqual(capabilities.attachmentTiming, .containerCreateOnly)
        XCTAssertEqual(capabilities.status(for: .create)?.state, .available)
        XCTAssertEqual(capabilities.status(for: .inspect)?.state, .available)
        XCTAssertEqual(capabilities.status(for: .delete)?.state, .available)
        XCTAssertEqual(capabilities.status(for: .attach)?.state, .unavailable)
        XCTAssertEqual(capabilities.status(for: .detach)?.state, .unavailable)

        let identity = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: "22222222-2222-4222-8222-222222222222"
        )
        do {
            _ = try await backend.networkInspect(.init(identity: identity))
            XCTFail("Expected an absent managed network to be rejected.")
        } catch let error as ContainerizationHelperBackendError {
            guard case .rejected = error else {
                return XCTFail("Expected rejected, got \(error)")
            }
        }
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let observation = try await backend.observe(.init())
        XCTAssertEqual(observation.networks, [])
    }

    func testOwnedNetworkCreateInspectAndDeleteVerifyFence() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let identity = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: "22222222-2222-4222-8222-222222222222"
        )
        let context = networkMutationContext(identity: identity)
        let request = RuntimeNetworkCreateRequest(
            identity: identity,
            mode: .hostOnly,
            ipv4: .cidr("192.168.240.0/24"),
            ipv6: .cidr("fd00:7:1::/64"),
            labels: ["purpose": "gate-one"]
        )

        let created = try await backend.networkCreate(request, context: context)
        XCTAssertEqual(created.state, .present)
        XCTAssertEqual(created.observedNetwork?.kind, "vmnet:hostOnly")
        XCTAssertEqual(created.observedNetwork?.addresses.first, "192.168.240.0/24")
        XCTAssertEqual(created.observedNetwork?.ownership?.resourceUUID, identity.resourceUUID)
        XCTAssertEqual(created.observedNetwork?.ownership?.fencingToken, context.fencingToken)

        let idleWithNetworkOnly = await backend.shutdownIfIdle()
        XCTAssertFalse(idleWithNetworkOnly)
        let afterQuietIdle = await driver.operations()
        XCTAssertEqual(afterQuietIdle, ["network-create"])
        let inspected = try await backend.networkInspect(.init(identity: identity))
        XCTAssertEqual(inspected.observedNetwork, created.observedNetwork)

        let stale = networkMutationContext(
            identity: identity,
            fencingToken: "55555555-5555-4555-8555-555555555555"
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await backend.networkDelete(
                .init(identity: identity),
                context: stale
            )
        }
        let stillPresent = try await backend.networkInspect(.init(identity: identity))
        XCTAssertEqual(stillPresent.state, .present)

        let deleted = try await backend.networkDelete(
            .init(identity: identity),
            context: context
        )
        XCTAssertEqual(deleted.state, .missing)
        await XCTAssertThrowsErrorAsync {
            _ = try await backend.networkInspect(.init(identity: identity))
        }
        let networkOperations = await driver.operations()
        XCTAssertEqual(networkOperations, ["network-create", "network-delete"])
    }

    func testNetworkDeleteAcceptsExactPriorOwnershipWithFreshOperationFenceAndRejectsMismatch()
        async throws
    {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent(
                "state",
                isDirectory: true
            )
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let identity = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID:
                "22222222-2222-4222-8222-222222222222"
        )
        let createContext = networkMutationContext(
            identity: identity
        )
        let created = try await backend.networkCreate(
            RuntimeNetworkCreateRequest(
                identity: identity,
                mode: .hostOnly,
                ipv4: .cidr("192.168.240.0/24"),
                ipv6: .cidr("fd00:7:1::/64")
            ),
            context: createContext
        )
        let priorOwnership = try XCTUnwrap(
            created.observedNetwork?.ownership
        )
        let deleteContext = networkMutationContext(
            identity: identity,
            operationID: "network-operation-2",
            resourceGeneration:
                priorOwnership.resourceGeneration + 1,
            fencingToken:
                "66666666-6666-4666-8666-666666666666"
        )
        let mismatchedOwnership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: priorOwnership.resourceUUID,
            projectUUID: priorOwnership.projectUUID,
            resourceGeneration: priorOwnership.resourceGeneration,
            projectGeneration: priorOwnership.projectGeneration,
            providerID: priorOwnership.providerID,
            providerGeneration: priorOwnership.providerGeneration,
            fencingToken:
                "77777777-7777-4777-8777-777777777777"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await backend.networkDelete(
                RuntimeNetworkDeleteRequest(
                    identity: identity,
                    expectedOwnership: mismatchedOwnership
                ),
                context: deleteContext
            )
        }
        let rejectedOperations = await driver.operations()
        XCTAssertEqual(rejectedOperations, ["network-create"])

        let deleted = try await backend.networkDelete(
            RuntimeNetworkDeleteRequest(
                identity: identity,
                expectedOwnership: priorOwnership
            ),
            context: deleteContext
        )
        XCTAssertEqual(deleted.state, .missing)
        XCTAssertTrue(deleted.verified)
        let operations = await driver.operations()
        XCTAssertEqual(
            operations,
            ["network-create", "network-delete"]
        )
    }

    func testAutomaticIPv4NetworkCreateIsRejected() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let identity = try RuntimeNetworkIdentity(
            logicalName: "automatic",
            projectUUID: "22222222-2222-4222-8222-222222222222"
        )
        let context = networkMutationContext(identity: identity)
        do {
            _ = try await backend.networkCreate(
                RuntimeNetworkCreateRequest(
                    identity: identity,
                    mode: .nat,
                    ipv4: .automatic,
                    ipv6: .disabled
                ),
                context: context
            )
            XCTFail("Expected automatic IPv4 network creation to be unavailable.")
        } catch let ContainerizationHelperBackendError.unavailable(message) {
            XCTAssertEqual(
                message,
                "Containerization 0.35.0 VmnetNetwork does not expose a qualified automatic IPv4 subnet allocator."
            )
        } catch {
            XCTFail("Expected unavailable, got \(error)")
        }
    }

    func testDisabledIPv6NetworkCreateProducesVerifiedIPv4OnlyNetwork() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let identity = try RuntimeNetworkIdentity(
            logicalName: "ipv6-disabled",
            projectUUID: "22222222-2222-4222-8222-222222222222"
        )
        let context = networkMutationContext(identity: identity)

        let created = try await backend.networkCreate(
            RuntimeNetworkCreateRequest(
                identity: identity,
                mode: .nat,
                ipv4: .cidr("192.168.240.0/24"),
                ipv6: .disabled
            ),
            context: context
        )
        XCTAssertTrue(created.verified)
        XCTAssertFalse(
            try XCTUnwrap(created.observedNetwork).addresses.contains {
                $0.contains(":")
            }
        )
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["network-create"])
    }

    func testIPv6OnlyNetworkCreateIsRejectedBeforeDriverMutation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let identity = try RuntimeNetworkIdentity(
            logicalName: "ipv6-only",
            projectUUID: "22222222-2222-4222-8222-222222222222"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await backend.networkCreate(
                RuntimeNetworkCreateRequest(
                    identity: identity,
                    mode: .nat,
                    ipv4: .disabled,
                    ipv6: .cidr("fd00:7:4::/64")
                ),
                context: networkMutationContext(identity: identity)
            )
        }
        let operations = await driver.operations()
        XCTAssertEqual(operations, [])
    }

    func testCreateTimeNetworkAttachmentIsObservedAndBlocksNetworkDelete() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let identity = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: "22222222-2222-4222-8222-222222222222"
        )
        let networkContext = networkMutationContext(identity: identity)
        _ = try await backend.networkCreate(
            RuntimeNetworkCreateRequest(
                identity: identity,
                mode: .nat,
                ipv4: .cidr("192.168.240.0/24"),
                ipv6: .cidr("fd00:7:1::/64")
            ),
            context: networkContext
        )
        let attachment = try RuntimeDesiredNetworkAttachment(
            network: identity,
            aliases: ["api"]
        )
        let workloadContext = mutationContext()
        let create = try createRequest(
            context: workloadContext,
            networks: [attachment]
        )
        _ = try await backend.create(create, context: workloadContext)

        let inventory = try await backend.observe(.init()).validatedInventory()
        XCTAssertEqual(inventory.networks.count, 1)
        XCTAssertEqual(inventory.containers.count, 1)
        XCTAssertEqual(
            inventory.containers[0].networks.map(\.networkID),
            [identity.runtimeIdentifier]
        )
        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: create.resourceIdentifier,
            resourceUUID: create.resourceUUID
        )
        _ = try await backend.start(mutation, context: workloadContext)
        _ = try await backend.stop(mutation, context: workloadContext)
        _ = try await backend.start(mutation, context: workloadContext)
        let restartedInventory = try await backend.observe(.init()).validatedInventory()
        XCTAssertEqual(
            restartedInventory.containers[0].networks.map(\.networkID),
            [identity.runtimeIdentifier]
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await backend.networkDelete(
                .init(identity: identity),
                context: networkContext
            )
        }

        _ = try await backend.delete(
            ContainerizationHelperMutationPayload(
                resourceIdentifier: create.resourceIdentifier,
                resourceUUID: create.resourceUUID
            ),
            context: workloadContext
        )
        _ = try await backend.networkDelete(
            .init(identity: identity),
            context: networkContext
        )
        let operations = await driver.operations()
        XCTAssertEqual(
            operations,
            [
                "network-create", "resolve", "create", "images", "start", "stop", "start",
                "usage", "images", "delete", "network-delete"
            ]
        )
    }

    func testLifecyclePersistsOwnershipAndVerifiesEveryEffect() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(context: context)

        let created = try await backend.create(request, context: context)
        XCTAssertEqual(created.lifecycle, .stopped)
        XCTAssertEqual(try store.loadRecords().map(\.phase), [.stopped])

        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )
        let started = try await backend.start(mutation, context: context)
        XCTAssertEqual(started.lifecycle, .running)
        let stopped = try await backend.stop(mutation, context: context)
        XCTAssertEqual(stopped.lifecycle, .stopped)
        XCTAssertEqual(try store.loadRecords().map(\.phase), [.stopped])
        _ = try await backend.start(mutation, context: context)
        let restarted = try await backend.restart(mutation, context: context)
        XCTAssertEqual(restarted.lifecycle, .running)

        let observation = try await backend.observe(.init(includeResourceUsage: true))
        let inventory = try observation.validatedInventory()
        XCTAssertEqual(inventory.containers.count, 1)
        XCTAssertEqual(inventory.containers[0].lifecycle, .running)
        XCTAssertEqual(inventory.containers[0].ownership?.resourceUUID, context.resourceUUID)
        XCTAssertEqual(inventory.containers[0].usage?.cpuUsageMicroseconds, 10)

        let deleted = try await backend.delete(mutation, context: context)
        XCTAssertEqual(deleted.lifecycle, .missing)
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(
            operations,
            ["resolve", "create", "start", "stop", "start", "restart", "usage", "images", "delete"]
        )
    }

    func testExplicitNetworkPolicyIsRejectedBeforeRuntimeMutationWhenDriverCannotEnforce()
        async throws
    {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(
            context: context,
            networkPolicy: HostwrightServiceNetworkPolicy()
        )

        do {
            _ = try await backend.create(request, context: context)
            XCTFail("Expected unavailable guest policy enforcement.")
        } catch let ContainerizationHelperBackendError.unavailable(message) {
            XCTAssertEqual(
                message,
                "Containerization guest network-policy enforcement is unavailable"
            )
        } catch {
            XCTFail("Expected unavailable, got \(error)")
        }

        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(operations, [])
    }

    func testAvailableNetworkPolicyPersistsEvidenceAndRepairsRuleLoss()
        async throws
    {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver(
            networkPolicyAvailable: true
        )
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(
            context: context,
            networkPolicy: HostwrightServiceNetworkPolicy()
        )
        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )

        _ = try await backend.create(request, context: context)
        var record = try XCTUnwrap(store.loadRecords().first)
        XCTAssertEqual(record.networkPolicyGeneration, 1)
        XCTAssertEqual(
            record.networkPolicySHA256,
            String(repeating: "e", count: 64)
        )
        XCTAssertEqual(record.networkPolicyVerified, false)

        _ = try await backend.start(mutation, context: context)
        record = try XCTUnwrap(store.loadRecords().first)
        XCTAssertEqual(record.networkPolicyGeneration, 1)
        XCTAssertEqual(record.networkPolicyVerified, true)
        let firstApplyCount = await driver.policyApplyCount(
            resourceIdentifier: request.resourceIdentifier
        )
        XCTAssertGreaterThan(firstApplyCount, 0)

        await driver.simulatePolicyRuleLoss(
            resourceIdentifier: request.resourceIdentifier
        )
        _ = try await backend.restart(mutation, context: context)
        record = try XCTUnwrap(store.loadRecords().first)
        XCTAssertEqual(record.networkPolicyVerified, true)
        let repairedApplyCount = await driver.policyApplyCount(
            resourceIdentifier: request.resourceIdentifier
        )
        XCTAssertEqual(
            repairedApplyCount,
            firstApplyCount + 1
        )

        _ = try await backend.delete(mutation, context: context)
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let hasAppliedPolicy = await driver.hasAppliedPolicy(
            resourceIdentifier: request.resourceIdentifier
        )
        XCTAssertFalse(hasAppliedPolicy)
    }

    func testPolicyReconcileFailureAfterStartStopsResourceWithoutFalseSuccess()
        async throws
    {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver(
            networkPolicyAvailable: true,
            policyFailureCalls: [4]
        )
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(
            context: context,
            networkPolicy: HostwrightServiceNetworkPolicy()
        )
        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )

        _ = try await backend.create(request, context: context)
        await XCTAssertThrowsErrorAsync {
            _ = try await backend.start(mutation, context: context)
        }

        let record = try XCTUnwrap(store.loadRecords().first)
        XCTAssertEqual(record.phase, .stopped)
        XCTAssertEqual(record.failureCategory, "start-failed")
        let operations = await driver.operations()
        XCTAssertEqual(
            Array(operations.suffix(2)),
            ["policy-reconcile", "stop"]
        )
        let hasAppliedPolicy = await driver.hasAppliedPolicy(
            resourceIdentifier: request.resourceIdentifier
        )
        XCTAssertFalse(hasAppliedPolicy)
    }

    func testPolicyReconcileCancellationAfterStartStopsResourceWithoutFalseSuccess()
        async throws
    {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver(
            networkPolicyAvailable: true,
            policyCancellationCalls: [4]
        )
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(
            context: context,
            networkPolicy: HostwrightServiceNetworkPolicy()
        )
        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )

        _ = try await backend.create(request, context: context)
        await XCTAssertThrowsErrorAsync {
            _ = try await backend.start(mutation, context: context)
        }

        let record = try XCTUnwrap(store.loadRecords().first)
        XCTAssertEqual(record.phase, .stopped)
        XCTAssertEqual(record.failureCategory, "cancelled")
        let operations = await driver.operations()
        XCTAssertEqual(Array(operations.suffix(2)), ["policy-reconcile", "stop"])
        let hasAppliedPolicy = await driver.hasAppliedPolicy(
            resourceIdentifier: request.resourceIdentifier
        )
        XCTAssertFalse(hasAppliedPolicy)
    }

    func testLogSnapshotsAndCursorsPreserveCompleteAndEmptyLines() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: RecordingContainerizationDriver()
        )
        let context = mutationContext()
        let create = try createRequest(context: context)
        _ = try await backend.create(create, context: context)
        let writer = try store.logWriter(resourceIdentifier: create.resourceIdentifier)
        try writer.write(Data())

        let empty = try await backend.logs(
            ContainerizationHelperLogsRequest(
                resourceIdentifier: create.resourceIdentifier,
                lineLimit: 1,
                maximumBytes: RuntimeStreamEnvelope.maximumChunkBytes
            )
        )
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.cursorStart, 0)
        XCTAssertEqual(empty.cursorEnd, 0)
        XCTAssertEqual(empty.atCurrentEnd, true)

        try writer.write(Data("a\nb\n".utf8))

        let snapshot = try await backend.logs(
            ContainerizationHelperLogsRequest(
                resourceIdentifier: create.resourceIdentifier,
                lineLimit: 1
            )
        )
        XCTAssertEqual(snapshot.text, "b\n")

        let initial = try await backend.logs(
            ContainerizationHelperLogsRequest(
                resourceIdentifier: create.resourceIdentifier,
                lineLimit: 1,
                maximumBytes: RuntimeStreamEnvelope.maximumChunkBytes
            )
        )
        XCTAssertEqual(initial.text, "b\n")
        XCTAssertEqual(initial.cursorStart, 2)
        XCTAssertEqual(initial.cursorEnd, 4)
        XCTAssertEqual(initial.atCurrentEnd, true)

        try writer.write(Data("\n".utf8))
        let resumed = try await backend.logs(
            ContainerizationHelperLogsRequest(
                resourceIdentifier: create.resourceIdentifier,
                lineLimit: 1,
                cursor: try XCTUnwrap(initial.cursorEnd),
                maximumBytes: RuntimeStreamEnvelope.maximumChunkBytes
            )
        )
        XCTAssertEqual(resumed.text, "\n")
        XCTAssertEqual(resumed.cursorStart, 4)
        XCTAssertEqual(resumed.cursorEnd, 5)
        XCTAssertEqual(resumed.atCurrentEnd, true)

        let emptyLineSnapshot = try await backend.logs(
            ContainerizationHelperLogsRequest(
                resourceIdentifier: create.resourceIdentifier,
                lineLimit: 1
            )
        )
        XCTAssertEqual(emptyLineSnapshot.text, "\n")

        let latestEmptyLine = try await backend.logs(
            ContainerizationHelperLogsRequest(
                resourceIdentifier: create.resourceIdentifier,
                lineLimit: 1,
                maximumBytes: RuntimeStreamEnvelope.maximumChunkBytes
            )
        )
        XCTAssertEqual(latestEmptyLine.text, "\n")
        XCTAssertEqual(latestEmptyLine.cursorStart, 4)
        XCTAssertEqual(latestEmptyLine.cursorEnd, 5)

        try writer.write(Data("c\n".utf8))
        let restarted = try await backend.logs(
            ContainerizationHelperLogsRequest(
                resourceIdentifier: create.resourceIdentifier,
                lineLimit: 1,
                cursor: try XCTUnwrap(resumed.cursorEnd),
                maximumBytes: RuntimeStreamEnvelope.maximumChunkBytes
            )
        )
        XCTAssertEqual(restarted.text, "c\n")
        XCTAssertEqual(restarted.cursorStart, 5)
        XCTAssertEqual(restarted.cursorEnd, 7)
        XCTAssertEqual(restarted.atCurrentEnd, true)
    }

    func testMissingLocalImageIsRejectedWithoutMutation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver(
            localImageError: ContainerizationError(.notFound, message: "image not found")
        )
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )

        do {
            _ = try await backend.localImageEvidence(
                ContainerizationHelperImageRequest(reference: "example.invalid/missing:latest")
            )
            XCTFail("Expected missing local image rejection")
        } catch {
            XCTAssertEqual(
                error as? ContainerizationHelperBackendError,
                .rejected("image is not available locally")
            )
        }
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(operations, [])
    }

    func testFreshFencedLifecycleTransfersExactPriorOwnershipAndRetainsSamePlanContext() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let original = mutationContext()
        let request = try createRequest(context: original)
        _ = try await backend.create(request, context: original)
        func proof() async throws -> ContainerizationHelperMutationPayload {
            let observed = try await backend.observe(.init()).validatedInventory().containers[0]
            return ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
                resourceUUID: request.resourceUUID, expectedOwnership: try XCTUnwrap(observed.ownership))
        }
        let first = mutationContext(fencingToken: "44444444-4444-4444-8444-444444444444", operationID: "operation-2")
        _ = try await backend.start(proof(), context: first)
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, first)
        _ = try await backend.stop(proof(), context: first)
        _ = try await backend.start(proof(), context: first)
        let second = mutationContext(fencingToken: "55555555-5555-4555-8555-555555555555", operationID: "operation-3")
        _ = try await backend.restart(proof(), context: second)
        let observed = try await backend.observe(.init()).validatedInventory().containers[0]
        XCTAssertEqual(observed.ownership?.fencingToken, second.fencingToken)
        XCTAssertEqual(observed.allocation?.cpuCount, request.cpuCount)
        XCTAssertEqual(observed.allocation?.memoryBytes, request.memoryBytes)
        let stale = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID, expectedOwnership: try RuntimeManagedResourceIdentity.ownershipEvidence(
                from: Dictionary(uniqueKeysWithValues: request.labels.map { ($0.key, $0.value) }), expectedProviderID: .appleContainerization))
        await XCTAssertThrowsErrorAsync { _ = try await backend.stop(stale, context: original) }
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, second)
        let currentProof = try await proof()
        await XCTAssertThrowsErrorAsync { _ = try await backend.stop(currentProof, context: original) }
        let reusedOperation = mutationContext(fencingToken: "99999999-9999-4999-8999-999999999999", operationID: original.operationID)
        await XCTAssertThrowsErrorAsync { _ = try await backend.stop(currentProof, context: reusedOperation) }
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, second)
        let third = mutationContext(fencingToken: "66666666-6666-4666-8666-666666666666", operationID: "operation-4")
        _ = try await backend.stop(proof(), context: third)
        let fourth = mutationContext(fencingToken: "77777777-7777-4777-8777-777777777777", operationID: "operation-5")
        _ = try await backend.delete(proof(), context: fourth)
        XCTAssertTrue(try store.loadRecords().isEmpty)
    }

    func testFenceTransferRejectsMissingForgedAndReplayedPriorProofBeforeEffects() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let original = mutationContext()
        let request = try createRequest(context: original)
        _ = try await backend.create(request, context: original)
        let native = try await backend.observe(.init()).validatedInventory().containers[0]
        let prior = try XCTUnwrap(native.ownership)
        let preparedBaseline = await driver.operations()
        let fresh = mutationContext(fencingToken: "44444444-4444-4444-8444-444444444444", operationID: "operation-2")
        for mismatch in ["missing", "uuid", "project", "resource-generation", "project-generation", "provider-generation", "provider", "fence", "same-operation", "same-fence-other-operation"] {
            let forged = RuntimeInventoryOwnershipEvidence(
                resourceUUID: mismatch == "uuid" ? fresh.fencingToken : prior.resourceUUID,
                projectUUID: mismatch == "project" ? fresh.fencingToken : prior.projectUUID,
                resourceGeneration: prior.resourceGeneration + (mismatch == "resource-generation" ? 1 : 0),
                projectGeneration: prior.projectGeneration + (mismatch == "project-generation" ? 1 : 0),
                providerID: mismatch == "provider" ? .appleContainerCLI : prior.providerID,
                providerGeneration: prior.providerGeneration + (mismatch == "provider-generation" ? 1 : 0),
                fencingToken: mismatch == "fence" ? fresh.fencingToken : prior.fencingToken)
            let payload = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
                resourceUUID: request.resourceUUID, expectedOwnership: mismatch == "missing" ? nil : forged)
            let context = mismatch == "same-operation" ? mutationContext(fencingToken: fresh.fencingToken) :
                mismatch == "same-fence-other-operation" ? mutationContext(operationID: fresh.operationID) : fresh
            await XCTAssertThrowsErrorAsync { _ = try await backend.start(payload, context: context) }
            XCTAssertEqual(try store.loadRecords()[0].mutationContext, original)
            let afterRejectedRequest = await driver.operations()
            XCTAssertEqual(afterRejectedRequest, preparedBaseline)
        }
        for mismatch in ["new-uuid", "new-project", "new-resource-generation", "new-project-generation", "new-provider-generation", "new-provider"] {
            let context = RuntimeMutationContext(providerID: mismatch == "new-provider" ? .appleContainerCLI : fresh.providerID,
                capabilitySHA256: fresh.capabilitySHA256, operationID: fresh.operationID,
                resourceUUID: mismatch == "new-uuid" ? fresh.fencingToken : fresh.resourceUUID,
                resourceGeneration: fresh.resourceGeneration + (mismatch == "new-resource-generation" ? 1 : 0),
                projectResourceUUID: mismatch == "new-project" ? fresh.fencingToken : fresh.projectResourceUUID,
                projectGeneration: fresh.projectGeneration + (mismatch == "new-project-generation" ? 1 : 0),
                providerGeneration: fresh.providerGeneration + (mismatch == "new-provider-generation" ? 1 : 0),
                fencingToken: fresh.fencingToken)
            let payload = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
                resourceUUID: request.resourceUUID, expectedOwnership: prior)
            await XCTAssertThrowsErrorAsync { _ = try await backend.start(payload, context: context) }
            XCTAssertEqual(try store.loadRecords()[0].mutationContext, original)
            let afterRejectedRequest = await driver.operations()
            XCTAssertEqual(afterRejectedRequest, preparedBaseline)
        }
        let operations = await driver.operations()
        XCTAssertEqual(operations, preparedBaseline)
        let payload = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID, expectedOwnership: prior)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await backend.start(payload, context: fresh)
        }
        await XCTAssertThrowsErrorAsync { _ = try await cancelled.value }
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, original)
        let afterCancelledRequest = await driver.operations()
        XCTAssertEqual(afterCancelledRequest, preparedBaseline)
    }

    func testFenceTransferCancellationAndConcurrentClaimPreserveAdoptedAuthority() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let original = mutationContext()
        let request = try createRequest(context: original)
        _ = try await backend.create(request, context: original)
        _ = try await backend.start(.init(resourceIdentifier: request.resourceIdentifier, resourceUUID: request.resourceUUID), context: original)
        let prior = try await backend.observe(.init()).validatedInventory().containers[0].ownership
        let adopted = mutationContext(fencingToken: "44444444-4444-4444-8444-444444444444", operationID: "operation-2")
        let payload = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID, expectedOwnership: prior)
        await driver.cancelNextStop()
        await XCTAssertThrowsErrorAsync { _ = try await backend.stop(payload, context: adopted) }
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, adopted)
        let current = try await backend.observe(.init()).validatedInventory().containers[0].ownership
        let retry = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID, expectedOwnership: current)
        await driver.blockNextStop()
        let pending = Task { try await backend.stop(retry, context: adopted) }
        for _ in 0..<1000 {
            if await driver.hasBlockedStop() { break }
            await Task.yield()
        }
        let blocked = await driver.hasBlockedStop()
        XCTAssertTrue(blocked)
        let newer = mutationContext(fencingToken: "55555555-5555-4555-8555-555555555555", operationID: "operation-3")
        await XCTAssertThrowsErrorAsync { _ = try await backend.delete(retry, context: newer) }
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, adopted)
        await driver.resumeStop()
        _ = try await pending.value
        XCTAssertEqual(try store.loadRecords()[0].phase, .stopped)
        await XCTAssertThrowsErrorAsync { _ = try await backend.start(payload, context: original) }
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, adopted)
        let restartedHelper = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        _ = try await restartedHelper.start(retry, context: adopted)
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, adopted)
    }

    func testPersistedFenceHistoryRejectsInvalidDuplicateAndExhaustedHistory() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let original = mutationContext()
        let request = try createRequest(context: original)
        var record = ContainerizationHelperPersistedRecord(request: request, context: original)
        record.phase = .created
        try store.save(record)
        let first = mutationContext(fencingToken: "44444444-4444-4444-8444-444444444444", operationID: "history-1")
        for history in [[original], [first, first], [mutationContext(fencingToken: first.fencingToken, operationID: "")]] {
            record.previousMutationContexts = history
            XCTAssertThrowsError(try store.save(record)) { error in
                XCTAssertEqual(error as? ContainerizationHelperPersistenceError, .invalidRecord)
            }
            XCTAssertNil(try store.loadRecords()[0].previousMutationContexts)
        }
        record.previousMutationContexts = (0...ContainerizationHelperStateStore.maximumPreviousMutationContexts).map {
            mutationContext(fencingToken: String(format: "%08x-4444-4444-8444-444444444444", $0), operationID: "history-\($0)")
        }
        XCTAssertThrowsError(try store.save(record))
        record.previousMutationContexts = (0..<ContainerizationHelperStateStore.maximumPreviousMutationContexts).map {
            mutationContext(fencingToken: String(format: "%08x-4444-4444-8444-444444444444", $0),
                operationID: "history-\($0)-" + String(repeating: "x", count: 240))
        }
        XCTAssertThrowsError(try store.save(record))
        XCTAssertNil(try store.loadRecords()[0].previousMutationContexts)
    }

    func testPreRenameValidationFailurePreservesDiskAndDoesNotConsumeRenameFault() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let fault = RecordRenameFault()
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"), afterRecordRename: { try fault.afterRename() })
        let context = mutationContext()
        var record = ContainerizationHelperPersistedRecord(request: try createRequest(context: context), context: context)
        record.phase = .stopped
        try store.save(record)
        let path = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.recordsURL, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: path)
        fault.failAfterNextRename()
        record.previousMutationContexts = [context]
        XCTAssertThrowsError(try store.save(record)) { error in
            XCTAssertEqual(error as? ContainerizationHelperPersistenceError, .invalidRecord)
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
        record.previousMutationContexts = nil
        XCTAssertThrowsError(try store.save(record)) { error in
            XCTAssertEqual(error as? ContainerizationHelperPersistenceError, .operationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testPostRenameFenceFailureQuarantinesAllAuthorityUntilVerifiedReconstruction() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let fault = RecordRenameFault()
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"), afterRecordRename: { try fault.afterRename() })
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let original = mutationContext()
        let request = try createRequest(context: original)
        _ = try await backend.create(request, context: original)
        let prior = try await backend.observe(.init()).validatedInventory().containers[0].ownership
        let oldProof = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID, expectedOwnership: prior)
        let adopted = mutationContext(fencingToken: "44444444-4444-4444-8444-444444444444", operationID: "operation-2")
        let beforeEffects = await driver.operations()
        fault.failAfterNextRename()
        await XCTAssertThrowsErrorAsync { _ = try await backend.start(oldProof, context: adopted) }
        let durable = try XCTUnwrap(store.loadRecords().first)
        XCTAssertEqual(durable.mutationContext, adopted)
        XCTAssertEqual(durable.previousMutationContexts, [original])
        let recordPath = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.recordsURL, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: recordPath)
        let freshOwnership = try RuntimeManagedResourceIdentity.ownershipEvidence(
            from: Dictionary(uniqueKeysWithValues: durable.labels.map { ($0.key, $0.value) }), expectedProviderID: .appleContainerization)
        let freshProof = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID, expectedOwnership: freshOwnership)
        for (proof, context) in [(oldProof, original), (oldProof, adopted), (freshProof, adopted)] {
            await XCTAssertThrowsErrorAsync { _ = try await backend.start(proof, context: context) }
            await XCTAssertThrowsErrorAsync { _ = try await backend.delete(proof, context: context) }
            XCTAssertEqual(try Data(contentsOf: recordPath), bytes)
        }
        await XCTAssertThrowsErrorAsync { _ = try await backend.create(request, context: original) }
        await XCTAssertThrowsErrorAsync { _ = try await backend.observe(.init()) }
        let idleWhileQuarantined = await backend.shutdownIfIdle()
        XCTAssertFalse(idleWhileQuarantined)
        await backend.shutdown()
        let afterEffects = await driver.operations()
        XCTAssertEqual(afterEffects, beforeEffects)
        XCTAssertEqual(try Data(contentsOf: recordPath), bytes)
        let reopened = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        _ = try await reopened.start(freshProof, context: adopted)
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, adopted)
        XCTAssertEqual(try store.loadRecords()[0].previousMutationContexts, [original])
        await XCTAssertThrowsErrorAsync { _ = try await reopened.stop(oldProof, context: original) }
    }

    func testCreateReservationRejectsReentrantDuplicateAndTransferBeforeProcessResolution() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let original = mutationContext()
        let request = try createRequest(context: original)
        await driver.blockNextResolve()
        let pending = Task { try await backend.create(request, context: original) }
        for _ in 0..<1000 { if await driver.hasBlockedResolve() { break }; await Task.yield() }
        let blocked = await driver.hasBlockedResolve()
        XCTAssertTrue(blocked)
        let idleWhileCreating = await backend.shutdownIfIdle()
        XCTAssertFalse(idleWhileCreating)
        let fresh = mutationContext(fencingToken: "44444444-4444-4444-8444-444444444444", operationID: "operation-2")
        let duplicate = try createRequest(context: fresh)
        await XCTAssertThrowsErrorAsync { _ = try await backend.create(duplicate, context: fresh) }
        let proof = ContainerizationHelperMutationPayload(resourceIdentifier: request.resourceIdentifier, resourceUUID: request.resourceUUID)
        await XCTAssertThrowsErrorAsync { _ = try await backend.start(proof, context: fresh) }
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["resolve"])
        await driver.resumeResolve()
        _ = try await pending.value
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, original)
        let actualPrior = try await backend.observe(.init()).validatedInventory().containers[0].ownership
        _ = try await backend.start(.init(resourceIdentifier: request.resourceIdentifier, resourceUUID: request.resourceUUID,
            expectedOwnership: actualPrior), context: fresh)
        let adopted = try store.loadRecords()[0]
        await XCTAssertThrowsErrorAsync { _ = try await backend.create(request, context: original) }
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, adopted.mutationContext)
        XCTAssertEqual(try store.loadRecords()[0].previousMutationContexts, [original])
    }

    func testCancelledReservedCreateDoesNotPublishAfterResolution() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let context = mutationContext()
        let request = try createRequest(context: context)
        await driver.blockNextResolve()
        let pending = Task { try await backend.create(request, context: context) }
        for _ in 0..<1000 { if await driver.hasBlockedResolve() { break }; await Task.yield() }
        pending.cancel()
        await driver.resumeResolve()
        await XCTAssertThrowsErrorAsync { _ = try await pending.value }
        XCTAssertTrue(try store.loadRecords().isEmpty)
        _ = try await backend.create(request, context: context)
        XCTAssertEqual(try store.loadRecords()[0].mutationContext, context)
    }

    func testNativeIdleShutdownRequiresNoRetainedRecordsAndLatchesCreateAdmission() async throws {
        for phase in [ContainerizationHelperPersistedPhase.created, .preparedCreate, .preparedStart, .running, .preparedRestart, .stopped, .preparedDelete, .failed] {
            let parent = try makePrivateParent()
            defer { try? FileManager.default.removeItem(at: parent) }
            let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
            let context = mutationContext()
            var retained = ContainerizationHelperPersistedRecord(request: try createRequest(context: context), context: context)
            retained.phase = phase
            try store.save(retained)
            let driver = RecordingContainerizationDriver()
            let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
            let accepted = await backend.shutdownIfIdle()
            XCTAssertFalse(accepted)
            let effects = await driver.operations()
            XCTAssertTrue(effects.isEmpty)
            XCTAssertEqual(try store.loadRecords().count, 1)
        }
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        await driver.blockNextShutdown()
        let pendingIdle = Task { await backend.shutdownIfIdle() }
        for _ in 0..<1000 { if await driver.hasBlockedShutdown() { break }; await Task.yield() }
        let shutdownSuspended = await driver.hasBlockedShutdown()
        XCTAssertTrue(shutdownSuspended)
        let context = mutationContext()
        let request = try createRequest(context: context)
        await XCTAssertThrowsErrorAsync { _ = try await backend.create(request, context: context) }
        await driver.resumeShutdown()
        let accepted = await pendingIdle.value
        XCTAssertTrue(accepted)
        let repeated = await backend.shutdownIfIdle()
        XCTAssertTrue(repeated)
        await backend.shutdown()
        await XCTAssertThrowsErrorAsync { _ = try await backend.create(request, context: context) }
        let effects = await driver.operations()
        XCTAssertEqual(effects, ["shutdown"])
        XCTAssertTrue(try store.loadRecords().isEmpty)
    }

    func testNativeDriverIdleUnknownAndPendingNetworkCreationFailClosed() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(rootURL: parent.appendingPathComponent("state"))
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: driver)
        let identity = try RuntimeNetworkIdentity(logicalName: "backend", projectUUID: "22222222-2222-4222-8222-222222222222")
        let context = networkMutationContext(identity: identity)
        let request = RuntimeNetworkCreateRequest(identity: identity, mode: .hostOnly,
            ipv4: .cidr("192.168.240.0/24"), ipv6: .disabled, labels: [:])
        await driver.blockNextNetworkCreate()
        let pending = Task { try await backend.networkCreate(request, context: context) }
        for _ in 0..<1000 { if await driver.hasBlockedNetworkCreate() { break }; await Task.yield() }
        let blocked = await driver.hasBlockedNetworkCreate()
        XCTAssertTrue(blocked)
        let idleWhileNetworkCreating = await backend.shutdownIfIdle()
        XCTAssertFalse(idleWhileNetworkCreating)
        await XCTAssertThrowsErrorAsync { _ = try await backend.networkCreate(request, context: context) }
        await driver.resumeNetworkCreate()
        let created = try await pending.value
        let idleWithNetwork = await backend.shutdownIfIdle()
        XCTAssertFalse(idleWithNetwork)
        let stillOwned = try await backend.networkInspect(.init(identity: identity))
        XCTAssertEqual(stillOwned.observedNetwork, created.observedNetwork)
        _ = try await backend.networkDelete(.init(identity: identity), context: context)
        let emptyAccepted = await backend.shutdownIfIdle()
        XCTAssertTrue(emptyAccepted)
        let effects = await driver.operations()
        XCTAssertEqual(effects, ["network-create", "network-delete", "shutdown"])

        let uncertainDriver = RecordingContainerizationDriver()
        await uncertainDriver.retainUnknownIdleResource()
        let uncertain = try ContainerizationFrameworkBackend(snapshot: snapshot(), store: store, driver: uncertainDriver)
        let unknownAccepted = await uncertain.shutdownIfIdle()
        XCTAssertFalse(unknownAccepted)
        let unknownEffects = await uncertainDriver.operations()
        XCTAssertTrue(unknownEffects.isEmpty)
    }

    func testManagedRestartReplacesOnlyTheRuntimeInstanceIdentity() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: RecordingContainerizationDriver()
        )
        let context = mutationContext()
        let request = try createRequest(context: context)
        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )

        _ = try await backend.create(request, context: context)
        let created = try await backend.observe(.init()).validatedInventory().containers[0]
        _ = try await backend.start(mutation, context: context)
        let started = try await backend.observe(.init()).validatedInventory().containers[0]
        _ = try await backend.restart(mutation, context: context)
        let restarted = try await backend.observe(.init()).validatedInventory().containers[0]

        XCTAssertEqual(created.runtimeID, started.runtimeID)
        XCTAssertNotEqual(started.runtimeID, restarted.runtimeID)
        XCTAssertEqual(restarted.ownership?.resourceUUID, context.resourceUUID)
        XCTAssertEqual(restarted.ownership?.projectUUID, context.projectResourceUUID)
        XCTAssertEqual(try store.loadRecords()[0].runtimeInstanceID, restarted.runtimeID)
    }

    func testRestartRecoveryReportsStoppedUntilExplicitStart() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let context = mutationContext()
        var record = ContainerizationHelperPersistedRecord(
            request: try createRequest(context: context),
            context: context
        )
        record.command = ["/bin/sleep", "30"]
        record.workingDirectory = "/"
        record.phase = .running
        try store.save(record)

        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let observation = try await backend.observe(.init(includeResourceUsage: false))
        XCTAssertEqual(try observation.validatedInventory().containers[0].lifecycle, .stopped)
        XCTAssertEqual(try store.loadRecords()[0].failureCategory, "helper-restarted")

        let result = try await backend.start(
            ContainerizationHelperMutationPayload(
                resourceIdentifier: record.resourceIdentifier,
                resourceUUID: record.resourceUUID
            ),
            context: context
        )
        XCTAssertEqual(result.lifecycle, .running)
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["images", "start"])
    }

    func testPreparedDeleteFinishesThroughObservation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let context = mutationContext()
        var record = ContainerizationHelperPersistedRecord(
            request: try createRequest(context: context),
            context: context
        )
        record.command = ["/bin/true"]
        record.phase = .preparedDelete
        try store.save(record)

        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let observation = try await backend.observe(.init())
        XCTAssertTrue(try observation.validatedInventory().containers.isEmpty)
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["delete", "images"])
    }

    func testCreateRejectsLabelsThatDoNotMatchFenceBeforeDriverMutation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let valid = try createRequest(context: context)
        let invalid = ContainerizationHelperCreatePayload(
            resourceIdentifier: valid.resourceIdentifier,
            resourceUUID: valid.resourceUUID,
            projectUUID: valid.projectUUID,
            logicalServiceName: valid.logicalServiceName,
            image: valid.image,
            command: valid.command,
            environment: valid.environment,
            labels: valid.labels.map {
                $0.key == RuntimeManagedResourceIdentity.fencingTokenLabel
                    ? RuntimeInventoryLabel(key: $0.key, value: UUID().uuidString.lowercased())
                    : $0
            },
            cpuCount: valid.cpuCount,
            memoryBytes: valid.memoryBytes
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await backend.create(invalid, context: context)
        }
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(operations, [])
    }

    func testStopRejectsAStaleFenceBeforeDriverMutation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(context: context)
        _ = try await backend.create(request, context: context)
        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )
        _ = try await backend.start(mutation, context: context)

        let staleContext = mutationContext(
            fencingToken: "44444444-4444-4444-8444-444444444444"
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await backend.stop(mutation, context: staleContext)
        }

        XCTAssertEqual(try store.loadRecords().map(\.phase), [.running])
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["resolve", "create", "start"])
    }

    func testConfigurationRejectsTamperedKernelAndUnsafeConfigurationMode() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let kernel = parent.appendingPathComponent("kernel", isDirectory: false)
        let kernelBytes = Data("kernel".utf8)
        try kernelBytes.write(to: kernel, options: .withoutOverwriting)
        XCTAssertEqual(chmod(kernel.path, 0o600), 0)
        let layout = parent.appendingPathComponent("layout", isDirectory: true)
        XCTAssertEqual(mkdir(layout.path, 0o700), 0)
        for name in ["blobs"] {
            XCTAssertEqual(mkdir(layout.appendingPathComponent(name).path, 0o700), 0)
        }
        for name in ["oci-layout", "index.json"] {
            let file = layout.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file, options: .withoutOverwriting)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        let digest = SHA256.hash(data: kernelBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let validConfiguration = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: digest
        )
        XCTAssertNoThrow(try validConfiguration.validate())

        let tampered = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try tampered.validate()) { error in
            XCTAssertEqual(error as? ContainerizationHelperConfigurationError, .assetDigestMismatch)
        }

        let configURL = parent.appendingPathComponent("helper.json")
        let encoder = JSONEncoder()
        try encoder.encode(validConfiguration).write(to: configURL, options: .withoutOverwriting)
        XCTAssertEqual(chmod(configURL.path, 0o644), 0)
        XCTAssertThrowsError(try ContainerizationHelperConfiguration.load(at: configURL)) { error in
            XCTAssertEqual(error as? ContainerizationHelperConfigurationError, .configurationUnsafe)
        }
    }

    func testInitfsCacheIdentityIsBoundToPinnedFrameworkAndVariant() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let kernel = parent.appendingPathComponent("kernel", isDirectory: false)
        let kernelBytes = Data("kernel".utf8)
        try kernelBytes.write(to: kernel, options: .withoutOverwriting)
        XCTAssertEqual(chmod(kernel.path, 0o600), 0)
        let layout = parent.appendingPathComponent("layout", isDirectory: true)
        XCTAssertEqual(mkdir(layout.path, 0o700), 0)
        XCTAssertEqual(mkdir(layout.appendingPathComponent("blobs").path, 0o700), 0)
        for name in ["oci-layout", "index.json"] {
            let file = layout.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file, options: .withoutOverwriting)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        let digest = SHA256.hash(data: kernelBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let first = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: digest,
            variantDigest: "sha256:" + String(repeating: "b", count: 64)
        )
        let replacement = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: digest,
            variantDigest: "sha256:" + String(repeating: "c", count: 64)
        )

        XCTAssertNotEqual(first.initfsCacheFileName, replacement.initfsCacheFileName)
        XCTAssertEqual(
            first.initfsCacheFileName,
            "initfs-0.35.0-\(String(repeating: "b", count: 64)).ext4"
        )
        XCTAssertFalse(first.initfsCacheFileName.contains(":"))
    }

    private func createRequest(
        context: RuntimeMutationContext,
        networks: [RuntimeDesiredNetworkAttachment] = [],
        networkPolicy: HostwrightServiceNetworkPolicy? = nil,
        cpuCount: Int? = 1,
        memoryBytes: UInt64? = 536_870_912
    ) throws -> ContainerizationHelperCreatePayload {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        return ContainerizationHelperCreatePayload(
            resourceIdentifier: RuntimeManagedResourceIdentity.resourceIdentifier(for: identity),
            resourceUUID: context.resourceUUID,
            projectUUID: context.projectResourceUUID,
            logicalServiceName: identity.serviceName,
            image: RecordingContainerizationDriver.image,
            command: ["/bin/sleep", "30"],
            environment: [RuntimeInventoryEnvironmentEntry(name: "MODE", value: "test")],
            labels: try RuntimeManagedResourceIdentity.labels(for: identity, context: context)
                .map { RuntimeInventoryLabel(key: $0.key, value: $0.value) },
            networks: networks,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            networkPolicy: networkPolicy
        )
    }

    private func mutationContext(
        fencingToken: String = "33333333-3333-4333-8333-333333333333",
        operationID: String = "operation-1"
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerization,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: operationID,
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 1,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: fencingToken
        )
    }

    private func networkMutationContext(
        identity: RuntimeNetworkIdentity,
        operationID: String = "network-operation-1",
        resourceGeneration: Int = 1,
        fencingToken: String = "44444444-4444-4444-8444-444444444444"
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerization,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: operationID,
            resourceUUID: identity.resourceUUID,
            resourceGeneration: resourceGeneration,
            projectResourceUUID: identity.projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: fencingToken
        )
    }

    private func snapshot() -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: HostwrightIdentity.version,
                        build: "test",
                        fingerprint: "abcdef0"
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: "1",
                        build: "test",
                        fingerprint: "abcdef1"
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: "0.35.0",
                        build: "test",
                        fingerprint: "abcdef2"
                    )
                ],
                minimumMacOSVersion: .init(major: 26),
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: .init(major: 26),
                macOSBuild: "25A123",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(
                    feature: $0,
                    state: .experimental,
                    reason: .qualificationIncomplete
                )
            }
        )
    }

    private func configuration(
        parent: URL,
        kernel: URL,
        layout: URL,
        kernelDigest: String,
        variantDigest: String = "sha256:" + String(repeating: "b", count: 64)
    ) -> ContainerizationHelperConfiguration {
        ContainerizationHelperConfiguration(
            schema: 1,
            framework: "0.35.0",
            dataRootPath: parent.appendingPathComponent("data").path,
            runtimeDirectoryPath: parent.appendingPathComponent("run").path,
            kernelPath: kernel.path,
            kernelSHA256: kernelDigest,
            initImageLayoutPath: layout.path,
            initImageReference: "ghcr.io/apple/containerization/vminit:0.35.0",
            initImageDescriptorDigest: "sha256:" + String(repeating: "a", count: 64),
            initImageVariantDigest: variantDigest,
            rootfsSizeBytes: 1_073_741_824
        )
    }

    private func makePrivateParent() throws -> URL {
        let url = URL(
            fileURLWithPath: "/tmp/hostwright-helper-\(getpid())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard mkdir(url.path, 0o700) == 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        return url
    }
}

private actor RecordingContainerizationDriver: ContainerizationHelperRuntimeDriving {
    static let image = ContainerizationHelperImageEvidence(
        reference: "example.local/demo@sha256:" + String(repeating: "c", count: 64),
        descriptorDigest: "sha256:" + String(repeating: "c", count: 64),
        variantDigest: "sha256:" + String(repeating: "d", count: 64),
        architecture: "arm64",
        operatingSystem: "linux"
    )

    private var events: [String] = []
    private let allocationOverride: RuntimeInventoryAllocation?
    private let localImageError: ContainerizationError?
    private var networks: [String: ContainerizationHelperRuntimeNetworkRecord] = [:]
    private var desiredContainerNetworks: [String: [RuntimeDesiredNetworkAttachment]] = [:]
    private var containerNetworks: [String: [RuntimeInventoryNetworkAttachment]] = [:]
    private let networkPolicyAvailable: Bool
    private let policyFailureCalls: Set<Int>
    private let policyCancellationCalls: Set<Int>
    private var policyReconcileCalls = 0
    private var allocations: [String: RuntimeInventoryAllocation] = [:]
    private var mismatchNextAllocation = false
    private var stopCancellation = false
    private var blockStop = false
    private var unknownIdleResource = false
    private var blockNetworkCreate = false
    private var networkCreateContinuation: CheckedContinuation<Void, Never>?
    func retainUnknownIdleResource() { unknownIdleResource = true }
    func blockNextNetworkCreate() { blockNetworkCreate = true }
    func hasBlockedNetworkCreate() -> Bool { networkCreateContinuation != nil }
    func resumeNetworkCreate() { blockNetworkCreate = false; networkCreateContinuation?.resume(); networkCreateContinuation = nil }

    private var blockShutdown = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    func blockNextShutdown() { blockShutdown = true }
    func hasBlockedShutdown() -> Bool { shutdownContinuation != nil }
    func resumeShutdown() { blockShutdown = false; shutdownContinuation?.resume(); shutdownContinuation = nil }

    private var blockResolve = false
    private var resolveContinuation: CheckedContinuation<Void, Never>?

    func blockNextResolve() { blockResolve = true }
    func hasBlockedResolve() -> Bool { resolveContinuation != nil }
    func resumeResolve() { blockResolve = false; resolveContinuation?.resume(); resolveContinuation = nil }
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func cancelNextStop() { stopCancellation = true }
    func blockNextStop() { blockStop = true }
    func hasBlockedStop() -> Bool { stopContinuation != nil }
    func resumeStop() { blockStop = false; stopContinuation?.resume(); stopContinuation = nil }

    func mismatchNextStartOrRestart() {
        mismatchNextAllocation = true
    }
    private var runningResources = Set<String>()
    private var appliedPolicies = Set<String>()
    private var policyApplyCounts: [String: Int] = [:]

    init(
        allocationOverride: RuntimeInventoryAllocation? = nil,
        localImageError: ContainerizationError? = nil,
        networkPolicyAvailable: Bool = false,
        policyFailureCalls: Set<Int> = [],
        policyCancellationCalls: Set<Int> = []
    ) {
        self.allocationOverride = allocationOverride
        self.localImageError = localImageError
        self.networkPolicyAvailable = networkPolicyAvailable
        self.policyFailureCalls = policyFailureCalls
        self.policyCancellationCalls = policyCancellationCalls
    }

    func resolveProcess(
        for request: ContainerizationHelperCreatePayload
    ) async throws -> ContainerizationHelperResolvedProcess {
        events.append("resolve")
        if blockResolve {
            blockResolve = false
            await withCheckedContinuation { resolveContinuation = $0 }
        }
        return ContainerizationHelperResolvedProcess(
            command: request.command,
            environment: request.environment,
            workingDirectory: "/",
            user: nil
        )
    }

    func localImageEvidence(reference: String) async throws -> ContainerizationHelperImageEvidence {
        if let localImageError { throw localImageError }
        return Self.image
    }

    func listImages() async throws -> [ContainerizationHelperImageRecord] {
        events.append("images")
        return [ContainerizationHelperImageRecord(evidence: Self.image, references: [Self.image.reference])]
    }

    func listNetworks() async throws -> [ContainerizationHelperRuntimeNetworkRecord] {
        networks.values.sorted {
            $0.identity.runtimeIdentifier < $1.identity.runtimeIdentifier
        }
    }

    func inspectNetwork(
        _ identity: RuntimeNetworkIdentity
    ) async throws -> ContainerizationHelperRuntimeNetworkRecord? {
        guard let record = networks[identity.runtimeIdentifier],
              record.identity == identity else {
            return nil
        }
        return record
    }

    func createNetwork(
        _ request: RuntimeNetworkCreateRequest,
        labels: [String: String]
    ) async throws -> ContainerizationHelperRuntimeNetworkRecord {
        if blockNetworkCreate {
            blockNetworkCreate = false
            await withCheckedContinuation { networkCreateContinuation = $0 }
        }
        guard networks[request.identity.runtimeIdentifier] == nil else {
            throw ContainerizationHelperBackendError.conflict("network already exists")
        }
        let ipv4: String
        switch request.ipv4 {
        case .automatic:
            ipv4 = "192.168.250.0/24"
        case .cidr(let value):
            ipv4 = value
        case .disabled:
            throw ContainerizationHelperBackendError.unavailable("IPv4 is required")
        }
        let ipv6: String?
        switch request.ipv6 {
        case .disabled:
            ipv6 = nil
        case .cidr(let value):
            ipv6 = value
        case .automatic:
            throw ContainerizationHelperBackendError.unavailable(
                "automatic IPv6 is unavailable"
            )
        }
        let record = ContainerizationHelperRuntimeNetworkRecord(
            identity: request.identity,
            mode: request.mode,
            ipv4Subnet: ipv4,
            ipv4Gateway: "192.168.250.1",
            ipv6Prefix: ipv6,
            ipv6Gateway: ipv6 == nil ? nil : "fd00::1",
            labels: labels
        )
        networks[request.identity.runtimeIdentifier] = record
        events.append("network-create")
        return record
    }

    func deleteNetwork(_ identity: RuntimeNetworkIdentity) async throws {
        let attached = containerNetworks.values.joined().contains {
            $0.networkID == identity.runtimeIdentifier
        }
        guard !attached else {
            throw ContainerizationHelperBackendError.conflict(
                "network still has managed container attachments"
            )
        }
        guard networks.removeValue(forKey: identity.runtimeIdentifier) != nil else {
            throw ContainerizationHelperBackendError.rejected("network is not managed")
        }
        events.append("network-delete")
    }

    func networkAttachments(
        resourceIdentifier: String
    ) async throws -> [RuntimeInventoryNetworkAttachment] {
        containerNetworks[resourceIdentifier] ?? []
    }

    func networkPolicyCapabilities()
        async -> RuntimeNetworkPolicyProviderCapabilities {
        guard networkPolicyAvailable else {
            return .unavailable
        }
        return RuntimeNetworkPolicyProviderCapabilities(
            state: .available,
            reason: .implemented,
            directions: HostwrightNetworkPolicyDirection.allCases,
            enforcesExactIdentity: true,
            enforcesCIDR: true,
            enforcesDNS: true,
            appliesAtomicGenerations: true,
            observesRuleDigest: true
        )
    }

    func reconcileNetworkPolicies(
        records: [ContainerizationHelperPersistedRecord]
    ) async throws -> [String: ContainerizationGuestNetworkPolicyEvidence] {
        guard networkPolicyAvailable ||
                records.contains(where: { $0.networkPolicy != nil }) ||
                !appliedPolicies.isEmpty else {
            return [:]
        }
        policyReconcileCalls += 1
        events.append("policy-reconcile")
        if policyFailureCalls.contains(policyReconcileCalls) {
            throw ContainerizationHelperBackendError.executionFailed(
                "injected guest policy reconcile failure"
            )
        }
        if policyCancellationCalls.contains(policyReconcileCalls) {
            throw CancellationError()
        }
        let protected = records.filter { $0.networkPolicy != nil }
        let protectedIdentifiers = Set(protected.map(\.resourceIdentifier))
        appliedPolicies.formIntersection(protectedIdentifiers)

        var evidence:
            [String: ContainerizationGuestNetworkPolicyEvidence] = [:]
        for record in protected {
            let isRunning = runningResources.contains(
                record.resourceIdentifier
            )
            if isRunning {
                appliedPolicies.insert(record.resourceIdentifier)
                policyApplyCounts[record.resourceIdentifier, default: 0] += 1
            }
            evidence[record.resourceIdentifier] =
                ContainerizationGuestNetworkPolicyEvidence(
                    generation: record.networkPolicyGeneration ?? 1,
                    sha256: String(repeating: "e", count: 64),
                    verified:
                        isRunning &&
                        appliedPolicies.contains(record.resourceIdentifier)
                )
        }
        return evidence
    }

    func create(
        _ record: ContainerizationHelperPersistedRecord,
        networks attachments: [RuntimeDesiredNetworkAttachment]
    ) async throws {
        allocations[record.resourceIdentifier] = allocationOverride ?? RuntimeInventoryAllocation(cpuCount: record.cpuCount, memoryBytes: record.memoryBytes)
        desiredContainerNetworks[record.resourceIdentifier] = attachments
        try observeAttachments(record: record, attachments: attachments)
        events.append("create")
    }

    func start(_ record: ContainerizationHelperPersistedRecord) async throws {
        if mismatchNextAllocation {
            allocations[record.resourceIdentifier] = RuntimeInventoryAllocation(cpuCount: 4, memoryBytes: 1_073_741_824)
        } else {
            allocations[record.resourceIdentifier] = RuntimeInventoryAllocation(cpuCount: record.cpuCount, memoryBytes: record.memoryBytes)
        }
        try observeAttachments(
            record: record,
            attachments: desiredContainerNetworks[record.resourceIdentifier] ?? []
        )
        runningResources.insert(record.resourceIdentifier)
        events.append("start")
    }

    func restart(_ record: ContainerizationHelperPersistedRecord) async throws {
        if mismatchNextAllocation {
            allocations[record.resourceIdentifier] = RuntimeInventoryAllocation(cpuCount: 4, memoryBytes: 1_073_741_824)
        } else {
            allocations[record.resourceIdentifier] = RuntimeInventoryAllocation(cpuCount: record.cpuCount, memoryBytes: record.memoryBytes)
        }
        try observeAttachments(
            record: record,
            attachments: desiredContainerNetworks[record.resourceIdentifier] ?? []
        )
        runningResources.insert(record.resourceIdentifier)
        events.append("restart")
    }

    func stop(_ record: ContainerizationHelperPersistedRecord) async throws {
        if stopCancellation { stopCancellation = false; throw CancellationError() }
        if blockStop {
            blockStop = false
            await withCheckedContinuation { stopContinuation = $0 }
        }
        allocations.removeValue(forKey: record.resourceIdentifier)
        containerNetworks.removeValue(forKey: record.resourceIdentifier)
        runningResources.remove(record.resourceIdentifier)
        appliedPolicies.remove(record.resourceIdentifier)
        events.append("stop")
    }

    func delete(_ record: ContainerizationHelperPersistedRecord) async throws {
        desiredContainerNetworks.removeValue(forKey: record.resourceIdentifier)
        containerNetworks.removeValue(forKey: record.resourceIdentifier)
        runningResources.remove(record.resourceIdentifier)
        appliedPolicies.remove(record.resourceIdentifier)
        events.append("delete")
    }

    private func observeAttachments(
        record: ContainerizationHelperPersistedRecord,
        attachments: [RuntimeDesiredNetworkAttachment]
    ) throws {
        var observed: [RuntimeInventoryNetworkAttachment] = []
        for attachment in attachments {
            guard let network = networks[attachment.networkRuntimeIdentifier],
                  network.identity.resourceUUID == attachment.networkResourceUUID else {
                throw ContainerizationHelperBackendError.rejected(
                    "network attachment ownership changed"
                )
            }
            observed.append(
                RuntimeInventoryNetworkAttachment(
                    networkID: attachment.networkRuntimeIdentifier,
                    addresses: ["192.168.250.2/24"],
                    gateway: network.ipv4Gateway
                )
            )
        }
        containerNetworks[record.resourceIdentifier] = observed
    }

    func allocation(resourceIdentifier: String) async throws -> RuntimeInventoryAllocation? {
        allocations[resourceIdentifier]
    }

    func usage(resourceIdentifier: String) async throws -> ContainerizationHelperResourceUsage {
        events.append("usage")
        return ContainerizationHelperResourceUsage(
            resourceIdentifier: resourceIdentifier,
            cpuUsageMicroseconds: 10,
            memoryUsageBytes: 20,
            memoryLimitBytes: 30,
            networkReceiveBytes: 40,
            networkTransmitBytes: 50,
            blockReadBytes: 60,
            blockWriteBytes: 70,
            processCount: 8
        )
    }

    func shutdownIfIdle() async -> Bool {
        guard !unknownIdleResource, networks.isEmpty, desiredContainerNetworks.isEmpty,
              containerNetworks.isEmpty, allocations.isEmpty, runningResources.isEmpty, appliedPolicies.isEmpty,
              networkCreateContinuation == nil, resolveContinuation == nil, stopContinuation == nil else { return false }
        await shutdown()
        return true
    }

    func shutdown() async {
        events.append("shutdown")
        if blockShutdown {
            blockShutdown = false
            await withCheckedContinuation { shutdownContinuation = $0 }
        }
    }
    func operations() -> [String] { events }
    func simulatePolicyRuleLoss(resourceIdentifier: String) {
        appliedPolicies.remove(resourceIdentifier)
    }
    func policyApplyCount(resourceIdentifier: String) -> Int {
        policyApplyCounts[resourceIdentifier, default: 0]
    }
    func hasAppliedPolicy(resourceIdentifier: String) -> Bool {
        appliedPolicies.contains(resourceIdentifier)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private final class RecordRenameFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func failAfterNextRename() { lock.lock(); armed = true; lock.unlock() }
    func afterRename() throws {
        lock.lock()
        let fail = armed
        armed = false
        lock.unlock()
        if fail { throw ContainerizationHelperPersistenceError.operationFailed }
    }
}
