import XCTest
@testable import HostwrightStorage

final class StorageOrphanEngineTests: XCTestCase {
    private let now: Int64 = 10_000_000
    private let oldDiscoveredAt: Int64 = 1_000_000

    func testDeletedOwnedVolumeAgesIntoExactReclaimPlan() throws {
        let engine = try StorageOrphanEngine(
            configuration: .init(
                quarantineAgeUnixMilliseconds: 10,
                reclaimAgeUnixMilliseconds: 100
            )
        )
        let volume = try observedVolume()
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: uuid("01"),
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: volume.providerVolumeID,
                    projectID: volume.projectID,
                    lifecycleState: .deleted,
                    reclaimPolicy: .deleteWhenUnused
                )
            ],
            trackedOrphans: [
                try .init(
                    providerID: LocalStorageProviderContract.providerID,
                    resourceKind: .volume,
                    providerResourceIDHash:
                        StorageOrphanHashing.resourceIDHash(
                            providerID:
                                LocalStorageProviderContract.providerID,
                            resourceKind: .volume,
                            providerResourceID: volume.providerVolumeID
                        ),
                    ownershipProofSHA256: nil,
                    lifecycleState: .discovered,
                    discoveredAtUnixMilliseconds: oldDiscoveredAt
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )

        XCTAssertEqual(report.findings.count, 1)
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.reason, .reclaimEligible)
        XCTAssertEqual(finding.lifecycleState, .discovered)
        XCTAssertNotNil(finding.ownershipProofSHA256)
        XCTAssertEqual(finding.reclaimableBytes, volume.capacityBytes)
        XCTAssertEqual(report.reclaimPlan.entries, [finding])

        XCTAssertThrowsError(
            try engine.reclaim(
                plan: report.reclaimPlan,
                exactConfirmationSHA256:
                    String(repeating: "0", count: 64)
            )
        )
        let result = try engine.reclaim(
            plan: report.reclaimPlan,
            exactConfirmationSHA256:
                report.reclaimPlan.confirmationSHA256
        )
        XCTAssertEqual(result.reclaimed, [finding])
    }

    func testRetainPolicyNeverBecomesReclaimable() throws {
        let engine = StorageOrphanEngine()
        let volume = try observedVolume(retention: .retain)
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: uuid("01"),
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: volume.providerVolumeID,
                    projectID: volume.projectID,
                    lifecycleState: .deleted,
                    reclaimPolicy: .retain
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(report.reclaimPlan.entries.count, 0)
        XCTAssertEqual(report.findings.first?.reason, .retainPolicy)
        XCTAssertEqual(report.findings.first?.lifecycleState, .held)
    }

    func testDurableOperationHoldsExactOwnedVolume() throws {
        let engine = StorageOrphanEngine()
        let volumeID = uuid("01")
        let volume = try observedVolume()
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: volumeID,
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: volume.providerVolumeID,
                    projectID: volume.projectID,
                    lifecycleState: .deleted,
                    reclaimPolicy: .deleteWhenUnused
                )
            ],
            durableOperationResourceIDs: [volumeID]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )

        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.reason, .durableOperation)
        XCTAssertEqual(finding.lifecycleState, .held)
        XCTAssertEqual(finding.recoveryDisposition, .safeHold)
        XCTAssertEqual(finding.reclaimableBytes, 0)
        XCTAssertTrue(report.reclaimPlan.entries.isEmpty)
    }

    func testLiveAttachmentsBlockReclaim() throws {
        let engine = StorageOrphanEngine()
        let volume = try observedVolume(
            attachments: [
                try .init(
                    attachmentID: uuid("31"),
                    consumerID: "api",
                    generation: 1,
                    fencingToken: uuid("41"),
                    readOnly: false
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: try .init(volumes: []),
            atUnixMilliseconds: now
        )

        XCTAssertEqual(report.reclaimPlan.entries.count, 0)
        let volumeFinding = try XCTUnwrap(
            report.findings.first { $0.resourceKind == .volume }
        )
        XCTAssertEqual(volumeFinding.reason, .liveAttachment)
        XCTAssertEqual(report.findings.first?.recoveryDisposition, .quarantine)
    }

    func testUnmanagedAndAmbiguousEntriesAreHashedAndRedacted() throws {
        let engine = StorageOrphanEngine()
        let inventory = try StorageOrphanObservedInventory(
            providerID: LocalStorageProviderContract.providerID,
            volumes: [],
            unmanagedEntries: ["/private/raw-provider-entry"],
            ambiguousVolumeIDs: [uuid("22")]
        )

        let report = try engine.discover(
            inventory: inventory,
            authoritativeState: try .init(volumes: []),
            atUnixMilliseconds: now
        )

        XCTAssertEqual(report.findings.count, 2)
        XCTAssertTrue(
            report.findings.allSatisfy {
                !$0.providerResourceIDHash.contains(
                    "/private/raw-provider-entry"
                )
            }
        )
        XCTAssertEqual(
            Set(report.findings.map(\.reason)),
            [.unmanaged, .ambiguousProvider]
        )
    }

    func testMetadataMismatchQuarantinesVolume() throws {
        let engine = StorageOrphanEngine()
        let volume = try observedVolume(projectID: uuid("91"))
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: uuid("01"),
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: volume.providerVolumeID,
                    projectID: uuid("92"),
                    lifecycleState: .available,
                    reclaimPolicy: .deleteWhenUnused
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )

        XCTAssertEqual(report.reclaimPlan.entries.count, 0)
        XCTAssertEqual(report.findings.first?.reason, .modifiedMetadata)
        XCTAssertEqual(report.findings.first?.recoveryDisposition, .safeHold)
    }

    func testUnknownAttachmentIsQuarantined() throws {
        let engine = StorageOrphanEngine()
        let attachmentID = uuid("31")
        let volume = try observedVolume(
            attachments: [
                try .init(
                    attachmentID: attachmentID,
                    consumerID: "worker",
                    generation: 1,
                    fencingToken: uuid("51"),
                    readOnly: true
                )
            ]
        )
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: uuid("01"),
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: volume.providerVolumeID,
                    projectID: volume.projectID,
                    lifecycleState: .available,
                    reclaimPolicy: .deleteWhenUnused
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )

        XCTAssertEqual(report.findings.count, 2)
        let attachmentFinding = try XCTUnwrap(
            report.findings.first {
                $0.resourceKind == .attachment
            }
        )
        XCTAssertEqual(attachmentFinding.reason, .unknownAttachment)
        XCTAssertEqual(attachmentFinding.lifecycleState, .held)
    }

    func testTrackedDiscoveryAgeCarriesForwardDeterministically() throws {
        let engine = try StorageOrphanEngine(
            configuration: .init(
                quarantineAgeUnixMilliseconds: 10,
                reclaimAgeUnixMilliseconds: 100
            )
        )
        let volume = try observedVolume()
        let hash = StorageOrphanHashing.resourceIDHash(
            providerID: LocalStorageProviderContract.providerID,
            resourceKind: .volume,
            providerResourceID: volume.providerVolumeID
        )
        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: try .init(
                volumes: [],
                trackedOrphans: [
                    try .init(
                        providerID:
                            LocalStorageProviderContract.providerID,
                        resourceKind: .volume,
                        providerResourceIDHash: hash,
                        ownershipProofSHA256: nil,
                        lifecycleState: .held,
                        discoveredAtUnixMilliseconds: oldDiscoveredAt
                    )
                ]
            ),
            atUnixMilliseconds: now
        )
        XCTAssertEqual(
            report.findings.first?.discoveredAtUnixMilliseconds,
            oldDiscoveredAt
        )
        XCTAssertEqual(
            report.findings.first?.ageUnixMilliseconds,
            now - oldDiscoveredAt
        )
    }

    func testSelectionIsBoundedToExactMaximum() throws {
        let engine = try StorageOrphanEngine(
            configuration: .init(
                quarantineAgeUnixMilliseconds: 0,
                reclaimAgeUnixMilliseconds: 0,
                maximumTrackedResources: 10,
                maximumReclaimSelection: 1
            )
        )
        let v1 = try observedVolume(volumeID: uuid("71"))
        let v2 = try observedVolume(volumeID: uuid("72"))
        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [v1, v2]
            ),
            authoritativeState: try .init(volumes: []),
            atUnixMilliseconds: now
        )
        XCTAssertEqual(report.reclaimPlan.entries.count, 1)
    }

    func testMissingAuthoritativeVolumeIsClassifiedAsHeld() throws {
        let engine = StorageOrphanEngine()
        let missingID = uuid("81")
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: missingID,
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: missingID,
                    projectID: uuid("82"),
                    lifecycleState: .available,
                    reclaimPolicy: .deleteWhenUnused
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: []
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )

        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.resourceKind, .volume)
        XCTAssertEqual(finding.reason, .modifiedMetadata)
        XCTAssertEqual(finding.lifecycleState, .held)
        XCTAssertEqual(finding.recoveryDisposition, .safeHold)
    }

    func testActiveHoldVolumeIsQuarantinedAndNeverReclaimable() throws {
        let engine = StorageOrphanEngine()
        let volume = try observedVolume()
        let volumeID = uuid("88")
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: volumeID,
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: volume.providerVolumeID,
                    projectID: volume.projectID,
                    lifecycleState: .deleted,
                    reclaimPolicy: .deleteWhenUnused
                )
            ],
            activeHolds: [
                try .init(
                    resourceKind: .volume,
                    resourceID: volumeID
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: [volume]
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )

        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.reason, .activeHold)
        XCTAssertEqual(finding.lifecycleState, .held)
        XCTAssertEqual(finding.recoveryDisposition, .safeHold)
        XCTAssertTrue(report.reclaimPlan.entries.isEmpty)
    }

    func testReadySnapshotAndBackupBecomeHeldWhenSourceVolumeIsMissing() throws {
        let engine = StorageOrphanEngine()
        let sourceID = uuid("83")
        let state = try StorageOrphanAuthoritativeState(
            volumes: [
                try .init(
                    volumeID: sourceID,
                    providerID: LocalStorageProviderContract.providerID,
                    providerVolumeID: sourceID,
                    projectID: uuid("84"),
                    lifecycleState: .deleted,
                    reclaimPolicy: .deleteWhenUnused
                )
            ],
            snapshots: [
                try .init(
                    snapshotID: uuid("85"),
                    sourceVolumeID: sourceID,
                    lifecycleState: .ready
                )
            ],
            backups: [
                try .init(
                    backupID: uuid("86"),
                    volumeID: sourceID,
                    snapshotID: uuid("85"),
                    lifecycleState: .ready
                )
            ]
        )

        let report = try engine.discover(
            inventory: try .init(
                providerID: LocalStorageProviderContract.providerID,
                volumes: []
            ),
            authoritativeState: state,
            atUnixMilliseconds: now
        )

        XCTAssertEqual(
            Set(report.findings.map(\.resourceKind)),
            [.volume, .snapshot, .backup]
        )
        XCTAssertTrue(
            report.findings.filter {
                $0.resourceKind == .snapshot || $0.resourceKind == .backup
            }.allSatisfy {
                $0.lifecycleState == .held &&
                    $0.reason == .modifiedMetadata &&
                    $0.recoveryDisposition == .quarantine &&
                    $0.ownershipProofSHA256 != nil
            }
        )
    }

    private func observedVolume(
        volumeID: String? = nil,
        projectID: String? = nil,
        retention: LocalStorageRetentionPolicy = .deleteWhenUnused,
        attachments: [StorageOrphanObservedAttachment] = []
    ) throws -> StorageOrphanObservedVolume {
        try .init(
            providerID: LocalStorageProviderContract.providerID,
            providerVolumeID: volumeID ?? uuid("11"),
            projectID: projectID ?? uuid("21"),
            projectGeneration: 1,
            generation: 2,
            fencingToken: uuid("61"),
            retention: retention,
            capacityBytes: 4096,
            attachments: attachments
        )
    }

    private func uuid(_ suffix: String) -> String {
        let normalized = suffix.padding(
            toLength: 2,
            withPad: "0",
            startingAt: 0
        )
        return "00000000-0000-4000-8000-0000000000\(normalized)"
    }
}
