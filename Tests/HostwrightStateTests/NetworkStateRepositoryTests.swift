import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime
@testable import HostwrightState

final class NetworkStateRepositoryTests: XCTestCase {
    private let projectID = "project-web"
    private let projectUUID =
        "10000000-0000-4000-8000-000000000001"
    private var networkID: String {
        networkResourceUUID(name: "backend")
    }
    private let attachmentID =
        "30000000-0000-4000-8000-000000000001"
    private let workloadUUID =
        "40000000-0000-4000-8000-000000000001"

    func testSchemaV15MigratesAdditivelyToV16NetworkState()
        throws
    {
        try withStore(throughVersion: 15) { store in
            XCTAssertEqual(try store.schemaVersion(), 15)
            XCTAssertFalse(
                try tableNames(store).contains("network_resources")
            )

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            XCTAssertEqual(
                try migrationVersions(store),
                Array(1...16)
            )
            XCTAssertEqual(
                Set(try tableNames(store).filter {
                    $0.hasPrefix("network_")
                }),
                Set([
                    "network_resources",
                    "network_attachments"
                ])
            )
            XCTAssertEqual(
                StateIntegrityService(store: store).inspect().health,
                .healthy
            )
        }
    }

    func testNetworkAndAttachmentLifecycleUsesExactFences()
        throws
    {
        try withStore { store in
            try seedProject(store)

            let create = try operationGroup(store, suffix: "01")
            let creating = network(
                generation: 1,
                fence: create.fence,
                operationGroupID: create.id
            )
            XCTAssertEqual(
                try store.networks.saveNetwork(creating),
                creating
            )
            try finish(store, create.id)

            let observe = try operationGroup(store, suffix: "02")
            let available = network(
                generation: 2,
                fence: observe.fence,
                lifecycle: .available,
                finalizer: .active,
                observedIPv4: ["10.44.0.2"],
                observedSHA256: digest("b"),
                operationGroupID: observe.id
            )
            XCTAssertThrowsError(
                try store.networks.saveNetwork(
                    available,
                    replacing: NetworkStateExpectedVersion(
                        generation: 1,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                )
            )
            XCTAssertEqual(
                try store.networks.saveNetwork(
                    available,
                    replacing: version(creating)
                ),
                available
            )
            try finish(store, observe.id)

            let attach = try operationGroup(store, suffix: "03")
            let attaching = attachment(
                generation: 1,
                fence: attach.fence,
                operationGroupID: attach.id
            )
            XCTAssertEqual(
                try store.networks.saveAttachment(attaching),
                attaching
            )
            try finish(store, attach.id)

            let attachedGroup = try operationGroup(
                store,
                suffix: "04"
            )
            let attached = attachment(
                generation: 2,
                fence: attachedGroup.fence,
                lifecycle: .attached,
                finalizer: .active,
                observedSHA256: digest("d"),
                operationGroupID: attachedGroup.id
            )
            _ = try store.networks.saveAttachment(
                attached,
                replacing: version(attaching)
            )
            try finish(store, attachedGroup.id)

            let detach = try operationGroup(store, suffix: "05")
            let detaching = attachment(
                generation: 3,
                fence: detach.fence,
                lifecycle: .detaching,
                finalizer: .releasing,
                observedSHA256: digest("d"),
                operationGroupID: detach.id
            )
            _ = try store.networks.saveAttachment(
                detaching,
                replacing: version(attached)
            )
            try finish(store, detach.id)

            let detachedGroup = try operationGroup(
                store,
                suffix: "06"
            )
            let detached = attachment(
                generation: 4,
                fence: detachedGroup.fence,
                lifecycle: .detached,
                finalizer: .released,
                observedSHA256: digest("e"),
                operationGroupID: detachedGroup.id
            )
            _ = try store.networks.saveAttachment(
                detached,
                replacing: version(detaching)
            )
            try finish(store, detachedGroup.id)

            XCTAssertThrowsError(
                try store.networks.removeDetachedAttachment(
                    id: attachmentID,
                    expected: NetworkStateExpectedVersion(
                        generation: 4,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    )
                )
            )
            XCTAssertTrue(
                try store.networks.removeDetachedAttachment(
                    id: attachmentID,
                    expected: version(detached)
                )
            )

            let delete = try operationGroup(store, suffix: "07")
            let deleting = network(
                generation: 3,
                fence: delete.fence,
                lifecycle: .deleting,
                finalizer: .releasing,
                observedIPv4: ["10.44.0.2"],
                observedSHA256: digest("b"),
                operationGroupID: delete.id
            )
            _ = try store.networks.saveNetwork(
                deleting,
                replacing: version(available)
            )
            try finish(store, delete.id)

            let deletedGroup = try operationGroup(
                store,
                suffix: "08"
            )
            let deleted = network(
                generation: 4,
                fence: deletedGroup.fence,
                lifecycle: .deleted,
                finalizer: .released,
                observedIPv4: [],
                observedSHA256: digest("f"),
                operationGroupID: deletedGroup.id
            )
            _ = try store.networks.saveNetwork(
                deleted,
                replacing: version(deleting)
            )
            try finish(store, deletedGroup.id)

            XCTAssertTrue(
                try store.networks.removeDeletedNetwork(
                    id: networkID,
                    expected: version(deleted)
                )
            )
            XCTAssertNil(try store.networks.loadNetwork(id: networkID))
            XCTAssertNil(
                try store.networks.loadAttachment(id: attachmentID)
            )
        }
    }

    func testListsAreDeterministicAndExactUUIDsAreRequired()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let zetaGroup = try operationGroup(store, suffix: "11")
            _ = try store.networks.saveNetwork(
                network(
                    id: networkResourceUUID(name: "zeta"),
                    name: "zeta",
                    generation: 1,
                    fence: zetaGroup.fence,
                    operationGroupID: zetaGroup.id
                )
            )
            try finish(store, zetaGroup.id)

            let alphaGroup = try operationGroup(store, suffix: "12")
            _ = try store.networks.saveNetwork(
                network(
                    id: networkResourceUUID(name: "alpha"),
                    name: "alpha",
                    generation: 1,
                    fence: alphaGroup.fence,
                    operationGroupID: alphaGroup.id
                )
            )
            try finish(store, alphaGroup.id)

            XCTAssertEqual(
                try store.networks.listNetworks(
                    projectUUID: projectUUID
                ).map(\.name),
                ["alpha", "zeta"]
            )
            XCTAssertThrowsError(
                try store.networks.loadNetwork(id: "not-a-uuid")
            )

            let unavailableGroup = try operationGroup(
                store,
                suffix: "13"
            )
            XCTAssertThrowsError(
                try store.networks.saveAttachment(
                    attachment(
                        resourceUUID: "not-a-uuid",
                        generation: 1,
                        fence: unavailableGroup.fence,
                        operationGroupID: unavailableGroup.id
                    )
                )
            )
        }
    }

    func testIntegrityRejectsMalformedNetworkContent()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let group = try operationGroup(store, suffix: "21")
            _ = try store.networks.saveNetwork(
                network(
                    generation: 1,
                    fence: group.fence,
                    operationGroupID: group.id
                )
            )
            try store.withConnection { connection in
                try connection.run(
                    """
                    UPDATE network_resources
                    SET observed_ipv4_json = '["not-an-ip"]'
                    WHERE id = ?
                    """,
                    bindings: [.text(networkID)]
                )
            }

            let report = StateIntegrityService(store: store).inspect()
            XCTAssertEqual(report.health, .unrecoverable)
            XCTAssertTrue(
                report.checks.contains {
                    $0.identifier ==
                        "hostwright.authoritative-records" &&
                        $0.affectedRows >= 1
                }
            )
        }
    }

    func testDurableIntentRequiresFreshCapabilityAndExactFence()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let create = try operationGroup(store, suffix: "31")
            let creating = network(
                generation: 1,
                fence: create.fence,
                operationGroupID: create.id
            )

            XCTAssertThrowsError(
                try store.networks.saveNetwork(
                    creating,
                    authority: authority(
                        create,
                        plannedCapability: digest("7"),
                        currentCapability: digest("8")
                    )
                )
            )
            XCTAssertNil(
                try store.networks.loadNetwork(id: networkID)
            )
            XCTAssertThrowsError(
                try store.networks.saveNetwork(
                    creating,
                    authority: authority(
                        create,
                        plannedCapability: digest("8"),
                        currentCapability: digest("8")
                    )
                )
            )
            XCTAssertNil(
                try store.networks.loadNetwork(id: networkID)
            )

            _ = try store.networks.saveNetwork(
                creating,
                authority: authority(create)
            )
            XCTAssertEqual(
                try store.networks.loadNetwork(id: networkID),
                creating
            )
            try finish(store, create.id)

            let observe = try operationGroup(store, suffix: "32")
            let available = network(
                generation: 2,
                fence: observe.fence,
                lifecycle: .available,
                finalizer: .active,
                observedIPv4: ["10.44.0.2"],
                observedSHA256: digest("b"),
                operationGroupID: observe.id
            )
            XCTAssertThrowsError(
                try store.networks.saveNetwork(
                    available,
                    replacing: NetworkStateExpectedVersion(
                        generation: creating.generation,
                        fencingToken:
                            "ffffffff-ffff-4fff-8fff-ffffffffffff"
                    ),
                    authority: authority(observe)
                )
            )
            XCTAssertEqual(
                try store.networks.loadNetwork(id: networkID),
                creating
            )
        }
    }

    func testRecoveryClassifiesCreatingAvailableDeletingAndFaulted()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let create = try operationGroup(store, suffix: "41")
            let creating = network(
                generation: 1,
                fence: create.fence,
                operationGroupID: create.id
            )
            _ = try store.networks.saveNetwork(
                creating,
                authority: authority(create)
            )
            try finish(store, create.id)

            let verify = try operationGroup(store, suffix: "42")
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(creating),
                    authority: authority(verify),
                    trigger: .timedOut,
                    observation: .absent
                ).action,
                .retryMutation
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(creating),
                    authority: authority(verify),
                    trigger: .cancelled,
                    observation: .exactOwned(
                        observedSHA256: digest("b")
                    )
                ).action,
                .verifyAndAdvance
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(creating),
                    authority: authority(verify),
                    trigger: .partialEffect,
                    observation: .indeterminate
                ).action,
                .quarantine
            )

            let available = network(
                generation: 2,
                fence: verify.fence,
                lifecycle: .available,
                finalizer: .active,
                observedIPv4: ["10.44.0.2"],
                observedSHA256: digest("b"),
                operationGroupID: verify.id
            )
            _ = try store.networks.saveNetwork(
                available,
                replacing: version(creating),
                authority: authority(verify)
            )
            try finish(store, verify.id)

            let delete = try operationGroup(store, suffix: "43")
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(available),
                    authority: authority(delete),
                    trigger: .processTerminated,
                    observation: .exactOwned(
                        observedSHA256: digest("b")
                    )
                ).action,
                .stable
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(available),
                    authority: authority(delete),
                    trigger: .timedOut,
                    observation: .absent
                ).action,
                .retryMutation
            )

            let deleting = network(
                generation: 3,
                fence: delete.fence,
                lifecycle: .deleting,
                finalizer: .releasing,
                observedIPv4: ["10.44.0.2"],
                observedSHA256: digest("b"),
                operationGroupID: delete.id
            )
            _ = try store.networks.saveNetwork(
                deleting,
                replacing: version(available),
                authority: authority(delete)
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(deleting),
                    authority: authority(delete),
                    trigger: .cancelled,
                    observation: .exactOwned(
                        observedSHA256: digest("b")
                    )
                ).action,
                .resumeDeletion
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(deleting),
                    authority: authority(delete),
                    trigger: .partialEffect,
                    observation: .absent
                ).action,
                .finalizeDeletion
            )

            let faulted = network(
                generation: 4,
                fence: delete.fence,
                lifecycle: .faulted,
                finalizer: .releasing,
                observedIPv4: ["10.44.0.2"],
                observedSHA256: digest("b"),
                operationGroupID: delete.id
            )
            _ = try store.networks.saveNetwork(
                faulted,
                replacing: version(deleting),
                authority: authority(delete)
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(faulted),
                    authority: authority(delete),
                    trigger: .processTerminated,
                    observation: .exactOwned(
                        observedSHA256: digest("b")
                    )
                ).action,
                .resumeDeletion
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(faulted),
                    authority: authority(delete),
                    trigger: .processTerminated,
                    observation: .absent
                ).action,
                .finalizeDeletion
            )
        }
    }

    func testAmbiguousNetworkAndAttachmentOrphansAreQuarantined()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let create = try operationGroup(store, suffix: "51")
            let creating = network(
                generation: 1,
                fence: create.fence,
                operationGroupID: create.id
            )
            _ = try store.networks.saveNetwork(
                creating,
                authority: authority(create)
            )
            try finish(store, create.id)

            let observe = try operationGroup(store, suffix: "52")
            let available = network(
                generation: 2,
                fence: observe.fence,
                lifecycle: .available,
                finalizer: .active,
                observedIPv4: ["10.44.0.2"],
                observedSHA256: digest("b"),
                operationGroupID: observe.id
            )
            _ = try store.networks.saveNetwork(
                available,
                replacing: version(creating),
                authority: authority(observe)
            )
            try finish(store, observe.id)

            let attach = try operationGroup(store, suffix: "53")
            let attaching = attachment(
                generation: 1,
                fence: attach.fence,
                operationGroupID: attach.id
            )
            _ = try store.networks.saveAttachment(
                attaching,
                authority: authority(attach)
            )
            try finish(store, attach.id)

            let networkRecovery = try operationGroup(
                store,
                suffix: "54"
            )
            XCTAssertEqual(
                try store.networks.evaluateNetworkRecovery(
                    id: networkID,
                    expected: version(available),
                    authority: authority(networkRecovery),
                    trigger: .timedOut,
                    observation: .indeterminate
                ).action,
                .quarantine
            )
            XCTAssertThrowsError(
                try store.networks.quarantineNetwork(
                    id: networkID,
                    expected: version(available),
                    authority: authority(
                        networkRecovery,
                        providerGeneration: 2
                    ),
                    observedSHA256: digest("f"),
                    updatedAt: "2026-07-26T12:10:00Z"
                )
            ) { error in
                guard case .invalidRecord(let message) =
                        error as? StateStoreError else {
                    return XCTFail(
                        "Expected stale authority refusal, got \(error)."
                    )
                }
                XCTAssertTrue(message.contains("stale provider"))
            }
            let quarantinedNetwork =
                try store.networks.quarantineNetwork(
                    id: networkID,
                    expected: version(available),
                    authority: authority(networkRecovery),
                    observedSHA256: digest("f"),
                    updatedAt: "2026-07-26T12:10:00Z"
                )
            XCTAssertEqual(
                quarantinedNetwork.lifecycleState,
                .faulted
            )
            XCTAssertEqual(
                quarantinedNetwork.finalizerState,
                .quarantined
            )
            try finish(store, networkRecovery.id)

            let attachmentRecovery = try operationGroup(
                store,
                suffix: "55"
            )
            XCTAssertEqual(
                try store.networks.evaluateAttachmentRecovery(
                    id: attachmentID,
                    expected: version(attaching),
                    authority: authority(attachmentRecovery),
                    trigger: .partialEffect,
                    observation: .conflictingOwner(
                        observedSHA256: digest("e")
                    )
                ).action,
                .quarantine
            )
            let quarantinedAttachment =
                try store.networks.quarantineAttachment(
                    id: attachmentID,
                    expected: version(attaching),
                    authority: authority(attachmentRecovery),
                    observedSHA256: digest("e"),
                    updatedAt: "2026-07-26T12:11:00Z"
                )
            XCTAssertEqual(
                quarantinedAttachment.lifecycleState,
                .faulted
            )
            XCTAssertEqual(
                quarantinedAttachment.finalizerState,
                .quarantined
            )
        }
    }

    func testReverseTeardownOrdersAttachmentsBeforeNetworks()
        throws
    {
        try withStore { store in
            try seedProject(store)
            let backend = try persistAvailableNetwork(
                store,
                name: "backend",
                createSuffix: "61",
                availableSuffix: "62"
            )
            let frontend = try persistAvailableNetwork(
                store,
                name: "frontend",
                createSuffix: "63",
                availableSuffix: "64"
            )

            let firstAttachmentID =
                "30000000-0000-4000-8000-000000000061"
            let secondAttachmentID =
                "30000000-0000-4000-8000-000000000062"
            let firstAttach = try operationGroup(
                store,
                suffix: "65"
            )
            _ = try store.networks.saveAttachment(
                attachment(
                    id: firstAttachmentID,
                    networkUUID: backend.id,
                    resourceUUID:
                        "40000000-0000-4000-8000-000000000061",
                    generation: 1,
                    fence: firstAttach.fence,
                    operationGroupID: firstAttach.id
                ),
                authority: authority(firstAttach)
            )
            try finish(store, firstAttach.id)

            let secondAttach = try operationGroup(
                store,
                suffix: "66"
            )
            _ = try store.networks.saveAttachment(
                attachment(
                    id: secondAttachmentID,
                    networkUUID: frontend.id,
                    resourceUUID:
                        "40000000-0000-4000-8000-000000000062",
                    generation: 1,
                    fence: secondAttach.fence,
                    operationGroupID: secondAttach.id
                ),
                authority: authority(secondAttach)
            )
            try finish(store, secondAttach.id)

            let order = try store.networks.reverseTeardownOrder(
                projectUUID: projectUUID
            )
            XCTAssertEqual(
                order.map(\.kind),
                [
                    .attachment,
                    .attachment,
                    .network,
                    .network
                ]
            )
            XCTAssertEqual(
                Set(order.prefix(2).map(\.id)),
                Set([firstAttachmentID, secondAttachmentID])
            )
            XCTAssertEqual(
                order.suffix(2).map(\.id),
                [frontend.id, backend.id]
            )
            XCTAssertEqual(
                try store.networks.reverseTeardownOrder(
                    projectUUID: projectUUID
                ),
                order
            )
        }
    }

    func testFutureSchemaRefusesNetworkReads()
        throws
    {
        try withStore { store in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO schema_migrations (
                        version, description, checksum, applied_at
                    ) VALUES (
                        17, 'future network schema',
                        'future-checksum', '2026-07-26T12:00:00Z'
                    )
                    """
                )
            }
            XCTAssertThrowsError(
                try store.networks.listNetworks()
            ) { error in
                guard case .incompatibleSchema(
                    let found,
                    let supported,
                    _
                ) = error as? StateStoreError else {
                    return XCTFail(
                        "Expected downgrade refusal, got \(error)."
                    )
                }
                XCTAssertEqual(found, 17)
                XCTAssertEqual(supported, 16)
            }
        }
    }

    private func network(
        id: String? = nil,
        name: String = "backend",
        generation: Int64,
        fence: String,
        lifecycle: NetworkStateResourceLifecycle = .creating,
        finalizer: NetworkStateFinalizer = .pending,
        observedIPv4: [String] = [],
        observedSHA256: String? = nil,
        operationGroupID: String
    ) -> NetworkStateResourceRecord {
        let resourceUUID = id ?? networkResourceUUID(name: name)
        let identity = try! RuntimeNetworkIdentity(
            logicalName: name,
            resourceUUID: resourceUUID,
            projectUUID: projectUUID
        )
        return NetworkStateResourceRecord(
            id: resourceUUID,
            projectUUID: projectUUID,
            name: name,
            runtimeName: identity.runtimeIdentifier,
            generation: generation,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: fence,
            driver: .nat,
            requestedIPv4: .cidr("10.44.0.0/24"),
            requestedIPv6: .disabled,
            observedIPv4: observedIPv4,
            observedIPv6: [],
            desiredSHA256: digest("a"),
            observedSHA256: observedSHA256,
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            operationGroupID: operationGroupID,
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt:
                "2026-07-26T12:\(String(format: "%02d", generation)):00Z"
        )
    }

    private func attachment(
        id: String? = nil,
        networkUUID: String? = nil,
        resourceUUID: String? = nil,
        generation: Int64,
        fence: String,
        lifecycle: NetworkStateAttachmentLifecycle = .attaching,
        finalizer: NetworkStateFinalizer = .pending,
        observedSHA256: String? = nil,
        operationGroupID: String
    ) -> NetworkStateAttachmentRecord {
        NetworkStateAttachmentRecord(
            id: id ?? attachmentID,
            networkUUID: networkUUID ?? networkID,
            projectUUID: projectUUID,
            resourceUUID: resourceUUID ?? workloadUUID,
            generation: generation,
            providerID: "apple-container-cli",
            providerGeneration: 1,
            fencingToken: fence,
            desiredSHA256: digest("c"),
            observedSHA256: observedSHA256,
            lifecycleState: lifecycle,
            finalizerState: finalizer,
            operationGroupID: operationGroupID,
            createdAt: "2026-07-26T12:03:00Z",
            updatedAt:
                "2026-07-26T12:\(String(format: "%02d", generation + 2)):00Z"
        )
    }

    private func authority(
        _ group: (id: String, fence: String),
        providerGeneration: Int64 = 1,
        plannedCapability: String? = nil,
        currentCapability: String? = nil
    ) -> NetworkStateMutationAuthority {
        NetworkStateMutationAuthority(
            providerID: "apple-container-cli",
            providerGeneration: providerGeneration,
            operationGroupID: group.id,
            fencingToken: group.fence,
            plannedCapabilitySHA256:
                plannedCapability ?? digest("7"),
            currentCapabilitySHA256:
                currentCapability ?? digest("7")
        )
    }

    private func persistAvailableNetwork(
        _ store: SQLiteStateStore,
        name: String,
        createSuffix: String,
        availableSuffix: String
    ) throws -> NetworkStateResourceRecord {
        let create = try operationGroup(
            store,
            suffix: createSuffix
        )
        let creating = network(
            id: networkResourceUUID(name: name),
            name: name,
            generation: 1,
            fence: create.fence,
            operationGroupID: create.id
        )
        _ = try store.networks.saveNetwork(
            creating,
            authority: authority(create)
        )
        try finish(store, create.id)

        let observe = try operationGroup(
            store,
            suffix: availableSuffix
        )
        let available = network(
            id: creating.id,
            name: name,
            generation: 2,
            fence: observe.fence,
            lifecycle: .available,
            finalizer: .active,
            observedIPv4: ["10.44.0.2"],
            observedSHA256: digest("b"),
            operationGroupID: observe.id
        )
        _ = try store.networks.saveNetwork(
            available,
            replacing: version(creating),
            authority: authority(observe)
        )
        try finish(store, observe.id)
        return available
    }

    private func version(
        _ record: NetworkStateResourceRecord
    ) -> NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private func version(
        _ record: NetworkStateAttachmentRecord
    ) -> NetworkStateExpectedVersion {
        NetworkStateExpectedVersion(
            generation: record.generation,
            fencingToken: record.fencingToken
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func networkResourceUUID(name: String) -> String {
        HostwrightResourceUUID.legacy(
            kind: "network",
            identifier: "\(projectUUID):\(name)"
        )
    }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.withConnection { connection in
            try connection.run(
                """
                INSERT INTO projects (
                    id, name, manifest_path, manifest_hash,
                    created_at, updated_at, resource_uuid,
                    manifest_version, mutation_provider,
                    provider_generation
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, 2, ?, 1)
                """,
                bindings: [
                    .text(projectID),
                    .text("web"),
                    .text(digest("1")),
                    .text("2026-07-26T12:00:00Z"),
                    .text("2026-07-26T12:00:00Z"),
                    .text(projectUUID),
                    .text("apple-container-cli")
                ]
            )
        }
    }

    private func operationGroup(
        _ store: SQLiteStateStore,
        suffix: String
    ) throws -> (id: String, fence: String) {
        let id =
            "50000000-0000-4000-8000-0000000000\(suffix)"
        let fence =
            "60000000-0000-4000-8000-0000000000\(suffix)"
        let group = OperationGroupRecord(
            id: id,
            operationID: "network-operation-\(suffix)",
            groupKind: "network-operation",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "network",
            status: .active,
            groupIdempotencyKey: "network:\(suffix)",
            planHash: digest("9"),
            checkpoint: "intent-persisted",
            lockOwner: "network-state-test",
            lockExpiresAt: "2027-07-26T12:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-26T12:00:00Z",
            updatedAt: "2026-07-26T12:00:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted:
                "{\"capabilitySHA256\":\"\(digest("7"))\"}"
        )
        XCTAssertEqual(
            try store.operationGroups.acquire(group).acquired,
            group
        )
        return (id, fence)
    }

    private func finish(
        _ store: SQLiteStateStore,
        _ groupID: String
    ) throws {
        try store.operationGroups.finish(
            groupID: groupID,
            status: .succeeded,
            checkpoint: "verified",
            manualRecoveryHintRedacted: "",
            updatedAt: "2026-07-26T12:30:00Z",
            metadataJSONRedacted: "{}"
        )
    }

    private func tableNames(
        _ store: SQLiteStateStore
    ) throws -> [String] {
        try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) {
            try $0.query(
                """
                SELECT name FROM sqlite_master
                WHERE type = 'table'
                ORDER BY name
                """
            ).compactMap { $0.first ?? nil }
        }
    }

    private func migrationVersions(
        _ store: SQLiteStateStore
    ) throws -> [Int] {
        try store.withConnection(
            createIfNeeded: false,
            readOnly: true
        ) {
            try $0.query(
                "SELECT version FROM schema_migrations ORDER BY version"
            ).compactMap { $0.first ?? nil }.compactMap(Int.init)
        }
    }

    private func withStore(
        throughVersion: Int? = nil,
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-network-state-\(UUID().uuidString)",
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
        if let throughVersion {
            try MigrationRunner().apply(
                to: store,
                throughVersion: throughVersion
            )
        } else {
            try store.migrate()
        }
        try body(store)
    }
}
