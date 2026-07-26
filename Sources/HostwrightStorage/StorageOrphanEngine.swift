import Foundation

public struct StorageOrphanEngine: Sendable {
    public let configuration: StorageOrphanEngineConfiguration

    public init(
        configuration: StorageOrphanEngineConfiguration =
            try! StorageOrphanEngineConfiguration()
    ) {
        self.configuration = configuration
    }

    public func discover(
        inventory: StorageOrphanObservedInventory,
        authoritativeState: StorageOrphanAuthoritativeState,
        atUnixMilliseconds now: Int64
    ) throws -> StorageOrphanReport {
        guard now >= 0 else {
            throw StorageOrphanEngineError.invalidArgument(
                "Storage orphan discovery time must be non-negative."
            )
        }

        let stateByProviderVolumeID = Dictionary(
            authoritativeState.volumes.map {
                ($0.providerID + "\n" + $0.providerVolumeID, $0)
            },
            uniquingKeysWith: { lhs, _ in lhs }
        )
        let attachmentsByVolumeID = Dictionary(grouping:
            authoritativeState.attachments,
            by: \.volumeID
        )
        let holdKeys = Set(authoritativeState.activeHolds.map {
            $0.resourceKind.rawValue + "\n" + $0.resourceID
        })
        let durableOperationResourceIDs = Set(
            authoritativeState.durableOperationResourceIDs
        )
        let trackedByHash = Dictionary(
            authoritativeState.trackedOrphans.map {
                (
                    $0.providerID + "\n" + $0.resourceKind.rawValue
                        + "\n" + $0.providerResourceIDHash,
                    $0
                )
            },
            uniquingKeysWith: { lhs, _ in lhs }
        )

        var findings: [StorageOrphanFinding] = []
        let observedVolumeIDs = Set(
            inventory.volumes.map(\.providerVolumeID)
        )

        for volume in inventory.volumes {
            let volumeHash = StorageOrphanHashing.resourceIDHash(
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceID: volume.providerVolumeID
            )
            let prior = trackedByHash[
                volume.providerID + "\nvolume\n" + volumeHash
            ]
            let discoveredAt = prior?.discoveredAtUnixMilliseconds ?? now
            let age = max(0, now - discoveredAt)
            let state = stateByProviderVolumeID[
                volume.providerID + "\n" + volume.providerVolumeID
            ]
            let stateAttachments = state.map {
                attachmentsByVolumeID[$0.volumeID] ?? []
            } ?? []

            if let finding = try classifyVolume(
                volume,
                state: state,
                stateAttachments: stateAttachments,
                holdKeys: holdKeys,
                durableOperationResourceIDs:
                    durableOperationResourceIDs,
                discoveredAt: discoveredAt,
                age: age
            ) {
                findings.append(finding)
            }

            let liveStateAttachments = Set(
                stateAttachments
                    .filter { $0.lifecycleState.keepsResourceLive }
                    .map(\.attachmentID)
            )
            for attachment in volume.attachments {
                let attachmentHash =
                    StorageOrphanHashing.resourceIDHash(
                        providerID: volume.providerID,
                        resourceKind: .attachment,
                        providerResourceID: attachment.attachmentID
                    )
                let priorAttachment = trackedByHash[
                    volume.providerID + "\nattachment\n"
                        + attachmentHash
                ]
                let attachmentDiscoveredAt =
                    priorAttachment?.discoveredAtUnixMilliseconds ?? now
                let attachmentAge = max(
                    0,
                    now - attachmentDiscoveredAt
                )
                if liveStateAttachments.contains(
                    attachment.attachmentID
                ) {
                    continue
                }
                findings.append(
                    try StorageOrphanFinding(
                        providerID: volume.providerID,
                        resourceKind: .attachment,
                        providerResourceIDHash: attachmentHash,
                        lifecycleState: .held,
                        reason: .unknownAttachment,
                        discoveredAtUnixMilliseconds:
                            attachmentDiscoveredAt,
                        ageUnixMilliseconds: attachmentAge,
                        ownershipProofSHA256: nil,
                        recoveryDisposition: .quarantine
                    )
                )
            }
        }

        for state in authoritativeState.volumes {
            guard !observedVolumeIDs.contains(
                state.providerVolumeID
            ) else {
                continue
            }
            let volumeHash = StorageOrphanHashing.resourceIDHash(
                providerID: state.providerID,
                resourceKind: .volume,
                providerResourceID: state.providerVolumeID
            )
            let prior = trackedByHash[
                state.providerID + "\nvolume\n" + volumeHash
            ]
            let discoveredAt = prior?.discoveredAtUnixMilliseconds ?? now
            let age = max(0, now - discoveredAt)
            findings.append(
                try StorageOrphanFinding(
                    providerID: state.providerID,
                    resourceKind: .volume,
                    providerResourceIDHash: volumeHash,
                    lifecycleState: .held,
                    reason:
                        durableOperationResourceIDs.contains(
                            state.volumeID
                        )
                        ? .durableOperation
                        : .modifiedMetadata,
                    discoveredAtUnixMilliseconds: discoveredAt,
                    ageUnixMilliseconds: age,
                    ownershipProofSHA256: nil,
                    recoveryDisposition: .safeHold,
                    reclaimableBytes: 0
                )
            )
        }

        for snapshot in authoritativeState.snapshots {
            guard snapshot.lifecycleState == .ready else {
                continue
            }
            let holdKey =
                StorageOrphanResourceKind.snapshot.rawValue
                + "\n" + snapshot.snapshotID
            guard !holdKeys.contains(holdKey),
                  !durableOperationResourceIDs.contains(
                      snapshot.snapshotID
                  ),
                  !durableOperationResourceIDs.contains(
                      snapshot.sourceVolumeID
                  ) else {
                continue
            }
            guard let source = stateByProviderVolumeID.values.first(
                where: { $0.volumeID == snapshot.sourceVolumeID }
            ),
            !observedVolumeIDs.contains(source.providerVolumeID)
            else {
                continue
            }
            let hash = StorageOrphanHashing.resourceIDHash(
                providerID: source.providerID,
                resourceKind: .snapshot,
                providerResourceID: snapshot.snapshotID
            )
            let prior = trackedByHash[
                source.providerID + "\nsnapshot\n" + hash
            ]
            let discoveredAt = prior?.discoveredAtUnixMilliseconds ?? now
            findings.append(
                try StorageOrphanFinding(
                    providerID: source.providerID,
                    resourceKind: .snapshot,
                    providerResourceIDHash: hash,
                    lifecycleState: .held,
                    reason: .modifiedMetadata,
                    discoveredAtUnixMilliseconds: discoveredAt,
                    ageUnixMilliseconds: max(0, now - discoveredAt),
                    ownershipProofSHA256: proof(snapshot: snapshot),
                    recoveryDisposition: .quarantine,
                    reclaimableBytes: 0
                )
            )
        }

        for backup in authoritativeState.backups {
            guard backup.lifecycleState == .ready else {
                continue
            }
            let holdKey =
                StorageOrphanResourceKind.backup.rawValue
                + "\n" + backup.backupID
            guard !holdKeys.contains(holdKey),
                  !durableOperationResourceIDs.contains(
                      backup.backupID
                  ),
                  !durableOperationResourceIDs.contains(
                      backup.volumeID
                  ) else {
                continue
            }
            guard let volume = stateByProviderVolumeID.values.first(
                where: { $0.volumeID == backup.volumeID }
            ),
            !observedVolumeIDs.contains(volume.providerVolumeID)
            else {
                continue
            }
            let hash = StorageOrphanHashing.resourceIDHash(
                providerID: volume.providerID,
                resourceKind: .backup,
                providerResourceID: backup.backupID
            )
            let prior = trackedByHash[
                volume.providerID + "\nbackup\n" + hash
            ]
            let discoveredAt = prior?.discoveredAtUnixMilliseconds ?? now
            findings.append(
                try StorageOrphanFinding(
                    providerID: volume.providerID,
                    resourceKind: .backup,
                    providerResourceIDHash: hash,
                    lifecycleState: .held,
                    reason: .modifiedMetadata,
                    discoveredAtUnixMilliseconds: discoveredAt,
                    ageUnixMilliseconds: max(0, now - discoveredAt),
                    ownershipProofSHA256: proof(backup: backup),
                    recoveryDisposition: .quarantine,
                    reclaimableBytes: 0
                )
            )
        }

        for unmanaged in inventory.unmanagedEntries {
            let hash = StorageOrphanHashing.resourceIDHash(
                providerID: inventory.providerID,
                resourceKind: .volume,
                providerResourceID: unmanaged
            )
            let prior = trackedByHash[
                inventory.providerID + "\nvolume\n" + hash
            ]
            let discoveredAt = prior?.discoveredAtUnixMilliseconds ?? now
            findings.append(
                try StorageOrphanFinding(
                    providerID: inventory.providerID,
                    resourceKind: .volume,
                    providerResourceIDHash: hash,
                    lifecycleState: .ignored,
                    reason: .unmanaged,
                    discoveredAtUnixMilliseconds: discoveredAt,
                    ageUnixMilliseconds: max(0, now - discoveredAt),
                    ownershipProofSHA256: nil,
                    recoveryDisposition: .none
                )
            )
        }

        for ambiguous in inventory.ambiguousVolumeIDs {
            let hash = StorageOrphanHashing.resourceIDHash(
                providerID: inventory.providerID,
                resourceKind: .volume,
                providerResourceID: ambiguous
            )
            let prior = trackedByHash[
                inventory.providerID + "\nvolume\n" + hash
            ]
            let discoveredAt = prior?.discoveredAtUnixMilliseconds ?? now
            findings.append(
                try StorageOrphanFinding(
                    providerID: inventory.providerID,
                    resourceKind: .volume,
                    providerResourceIDHash: hash,
                    lifecycleState: .held,
                    reason: .ambiguousProvider,
                    discoveredAtUnixMilliseconds: discoveredAt,
                    ageUnixMilliseconds: max(0, now - discoveredAt),
                    ownershipProofSHA256: nil,
                    recoveryDisposition: .safeHold
                )
            )
        }

        guard findings.count <= configuration.maximumTrackedResources
        else {
            throw StorageOrphanEngineError.invalidArgument(
                "Storage orphan discovery exceeded bounded tracking limits."
            )
        }

        let eligible = findings
            .filter(\.isEligibleForReclaim)
            .sorted {
                (
                    $0.ageUnixMilliseconds,
                    $0.providerID,
                    $0.providerResourceIDHash
                ) > (
                    $1.ageUnixMilliseconds,
                    $1.providerID,
                    $1.providerResourceIDHash
                )
            }
        let selected = Array(
            eligible.prefix(configuration.maximumReclaimSelection)
        )
        return try StorageOrphanReport(
            findings: findings,
            reclaimPlan: StorageOrphanReclaimPlan(entries: selected)
        )
    }

    public func reclaim(
        plan: StorageOrphanReclaimPlan,
        exactConfirmationSHA256: String
    ) throws -> StorageOrphanReclaimResult {
        guard exactConfirmationSHA256 == plan.confirmationSHA256 else {
            throw StorageOrphanEngineError.confirmationMismatch
        }
        return StorageOrphanReclaimResult(reclaimed: plan.entries)
    }

    private func classifyVolume(
        _ volume: StorageOrphanObservedVolume,
        state: StorageOrphanAuthoritativeVolume?,
        stateAttachments: [StorageOrphanAuthoritativeAttachment],
        holdKeys: Set<String>,
        durableOperationResourceIDs: Set<String>,
        discoveredAt: Int64,
        age: Int64
    ) throws -> StorageOrphanFinding? {
        let volumeHash = StorageOrphanHashing.resourceIDHash(
            providerID: volume.providerID,
            resourceKind: .volume,
            providerResourceID: volume.providerVolumeID
        )
        let volumeHoldKey: String
        if let state {
            volumeHoldKey = StorageOrphanResourceKind.volume.rawValue
                + "\n" + state.volumeID
        } else {
            volumeHoldKey = ""
        }

        let hasLiveProviderAttachments = !volume.attachments.isEmpty
        let hasLiveStateAttachments = stateAttachments.contains {
            $0.lifecycleState.keepsResourceLive
        }
        let ownershipProof = proof(
            observed: volume,
            state: state
        )

        if let state,
           state.projectID != volume.projectID ||
            state.providerID != volume.providerID {
            return try StorageOrphanFinding(
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceIDHash: volumeHash,
                lifecycleState: .held,
                reason: .modifiedMetadata,
                discoveredAtUnixMilliseconds: discoveredAt,
                ageUnixMilliseconds: age,
                ownershipProofSHA256: nil,
                recoveryDisposition: .safeHold,
                reclaimableBytes: 0
            )
        }

        if durableOperationResourceIDs.contains(
            state?.volumeID ?? volume.providerVolumeID
        ) {
            return try StorageOrphanFinding(
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceIDHash: volumeHash,
                lifecycleState: .held,
                reason: .durableOperation,
                discoveredAtUnixMilliseconds: discoveredAt,
                ageUnixMilliseconds: age,
                ownershipProofSHA256: nil,
                recoveryDisposition: .safeHold,
                reclaimableBytes: 0
            )
        }

        if hasLiveProviderAttachments || hasLiveStateAttachments {
            return try StorageOrphanFinding(
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceIDHash: volumeHash,
                lifecycleState: .held,
                reason: .liveAttachment,
                discoveredAtUnixMilliseconds: discoveredAt,
                ageUnixMilliseconds: age,
                ownershipProofSHA256: nil,
                recoveryDisposition: .quarantine,
                reclaimableBytes: 0
            )
        }

        if state != nil, holdKeys.contains(volumeHoldKey) {
            return try StorageOrphanFinding(
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceIDHash: volumeHash,
                lifecycleState: .held,
                reason: .activeHold,
                discoveredAtUnixMilliseconds: discoveredAt,
                ageUnixMilliseconds: age,
                ownershipProofSHA256: nil,
                recoveryDisposition: .safeHold,
                reclaimableBytes: 0
            )
        }

        if let state, state.reclaimPolicy == .retain {
            return try StorageOrphanFinding(
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceIDHash: volumeHash,
                lifecycleState: .held,
                reason: .retainPolicy,
                discoveredAtUnixMilliseconds: discoveredAt,
                ageUnixMilliseconds: age,
                ownershipProofSHA256: nil,
                recoveryDisposition: .safeHold,
                reclaimableBytes: 0
            )
        }

        if let state,
           state.lifecycleState != .deleted {
            if state.providerID == volume.providerID,
               state.providerVolumeID == volume.providerVolumeID {
                return nil
            }
            return try StorageOrphanFinding(
                providerID: volume.providerID,
                resourceKind: .volume,
                providerResourceIDHash: volumeHash,
                lifecycleState: .held,
                reason: .modifiedMetadata,
                discoveredAtUnixMilliseconds: discoveredAt,
                ageUnixMilliseconds: age,
                ownershipProofSHA256: nil,
                recoveryDisposition: .safeHold,
                reclaimableBytes: 0
            )
        }

        let eligible = age >= configuration.reclaimAgeUnixMilliseconds
        return try StorageOrphanFinding(
            providerID: volume.providerID,
            resourceKind: .volume,
            providerResourceIDHash: volumeHash,
            lifecycleState: eligible ? .discovered : .held,
            reason: eligible ? .reclaimEligible : .awaitingAge,
            discoveredAtUnixMilliseconds: discoveredAt,
            ageUnixMilliseconds: age,
            ownershipProofSHA256: eligible ? ownershipProof : nil,
            recoveryDisposition: eligible ? .exactCleanup : .quarantine,
            reclaimableBytes: eligible ? volume.capacityBytes : 0
        )
    }

    private func proof(
        observed: StorageOrphanObservedVolume,
        state: StorageOrphanAuthoritativeVolume?
    ) -> String {
        StorageOrphanHashing.sha256(
            [
                "hostwright.storage.orphan-proof.v1",
                observed.providerID,
                observed.providerVolumeID,
                observed.projectID,
                String(observed.projectGeneration),
                String(observed.generation),
                observed.fencingToken,
                state?.volumeID ?? "",
                state?.projectID ?? "",
                state?.lifecycleState.rawValue ?? "",
            ].joined(separator: "\n")
        )
    }

    private func proof(
        snapshot: StorageOrphanAuthoritativeSnapshot
    ) -> String {
        StorageOrphanHashing.sha256(
            [
                "hostwright.storage.orphan-proof.v1",
                "snapshot",
                snapshot.snapshotID,
                snapshot.sourceVolumeID,
                snapshot.lifecycleState.rawValue,
            ].joined(separator: "\n")
        )
    }

    private func proof(
        backup: StorageOrphanAuthoritativeBackup
    ) -> String {
        StorageOrphanHashing.sha256(
            [
                "hostwright.storage.orphan-proof.v1",
                "backup",
                backup.backupID,
                backup.volumeID,
                backup.snapshotID ?? "",
                backup.lifecycleState.rawValue,
            ].joined(separator: "\n")
        )
    }
}
