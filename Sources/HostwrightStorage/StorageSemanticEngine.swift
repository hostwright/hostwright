import Foundation

public struct StorageSemanticEngine: Sendable {
    public init() {}

    public func apply(
        _ request: StorageSemanticRequest,
        to state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        try request.validate()
        try state.validate()
        try refuseInterruption(request)
        try validateTopology(request, state: state)
        if state.providerHealth == .unhealthy,
           request.operation != .health {
            throw failure(
                request,
                .unhealthy,
                .safeAfterObservation,
                "The storage provider is unhealthy."
            )
        }

        switch request.operation {
        case .create:
            return try create(request, state: state, sourceSnapshotID: nil)
        case .delete:
            return try delete(request, state: state)
        case .stage:
            return try stage(request, state: state)
        case .unstage:
            return try unstage(request, state: state)
        case .publish:
            return try publish(request, state: state)
        case .unpublish:
            return try unpublish(request, state: state)
        case .expand:
            return try expand(request, state: state)
        case .snapshot:
            return try snapshot(request, state: state)
        case .restore:
            return try restore(request, state: state)
        case .capacity:
            return transition(
                request,
                disposition: .observed,
                state: state,
                availableCapacityBytes: state.availableCapacityBytes
            )
        case .health:
            return try health(request, state: state)
        }
    }

    private func create(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState,
        sourceSnapshotID: String?
    ) throws -> StorageSemanticTransition {
        let volumeID = request.volumeID!
        if let existing = state.volumes.first(where: { $0.id == volumeID }) {
            guard existing.name == request.volumeName,
                  existing.providerID == request.context.providerID,
                  existing.generation == request.context.generation,
                  existing.fencingToken == request.context.fencingToken,
                  existing.capacityBytes == request.capacityBytes,
                  existing.topology == request.topology,
                  existing.accessMode == request.accessMode,
                  existing.sourceSnapshotID == sourceSnapshotID else {
                throw failure(
                    request,
                    .alreadyExists,
                    .never,
                    "The volume identity already exists with different immutable parameters."
                )
            }
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volumeID
            )
        }
        guard !state.volumes.contains(where: {
            $0.name == request.volumeName
        }) else {
            throw failure(
                request,
                .alreadyExists,
                .never,
                "The volume name already belongs to a different identity."
            )
        }
        guard request.context.generation == 1 else {
            throw failure(
                request,
                .staleGeneration,
                .safeAfterObservation,
                "A new volume must begin at generation 1."
            )
        }
        guard request.capacityBytes! <= state.availableCapacityBytes else {
            throw failure(
                request,
                .capacityExhausted,
                .safeAfterObservation,
                "The requested capacity exceeds current local capacity."
            )
        }

        var volumes = state.volumes
        volumes.append(
            StorageSemanticVolume(
                id: volumeID,
                name: request.volumeName!,
                providerID: request.context.providerID,
                generation: request.context.generation,
                fencingToken: request.context.fencingToken,
                capacityBytes: request.capacityBytes!,
                topology: request.topology!,
                accessMode: request.accessMode!,
                sourceSnapshotID: sourceSnapshotID
            )
        )
        let updated = try replacing(state, volumes: volumes)
        return transition(
            request,
            disposition: .performed,
            state: updated,
            volumeID: volumeID
        )
    }

    private func delete(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let volumeID = request.volumeID!
        guard let volume = state.volumes.first(where: {
            $0.id == volumeID
        }) else {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volumeID
            )
        }
        try validateFence(request, volume: volume)
        guard !state.attachments.contains(where: {
            $0.volumeID == volumeID
        }) else {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "The volume must be unpublished and unstaged before deletion."
            )
        }
        let updated = try replacing(
            state,
            volumes: state.volumes.filter { $0.id != volumeID }
        )
        return transition(
            request,
            disposition: .performed,
            state: updated,
            volumeID: volumeID
        )
    }

    private func stage(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let volume = try requireVolume(request, state: state)
        let attachment = StorageSemanticAttachment(
            volumeID: volume.id,
            nodeID: request.topology!.nodeID,
            kind: .stage,
            path: request.stagingPath!,
            stagingPath: nil,
            readOnly: false
        )
        if state.attachments.contains(attachment) {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volume.id
            )
        }
        guard !state.attachments.contains(where: {
            $0.volumeID == volume.id &&
                $0.nodeID == request.topology!.nodeID &&
                $0.kind == .stage
        }) else {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "The volume is already staged at a different path on this node."
            )
        }
        var attachments = state.attachments
        attachments.append(attachment)
        return transition(
            request,
            disposition: .performed,
            state: try replacing(state, attachments: attachments),
            volumeID: volume.id
        )
    }

    private func unstage(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let volumeID = request.volumeID!
        guard let volume = state.volumes.first(where: {
            $0.id == volumeID
        }) else {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volumeID
            )
        }
        try validateFence(request, volume: volume)
        let nodeID = request.topology!.nodeID
        guard !state.attachments.contains(where: {
            $0.volumeID == volumeID &&
                $0.nodeID == nodeID &&
                $0.kind == .publish
        }) else {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "Published targets must be unpublished before unstage."
            )
        }
        let matching = state.attachments.filter {
            $0.volumeID == volumeID &&
                $0.nodeID == nodeID &&
                $0.kind == .stage
        }
        guard !matching.isEmpty else {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volumeID
            )
        }
        guard matching.count == 1,
              matching[0].path == request.stagingPath else {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "Unstage must name the exact staged path."
            )
        }
        let updated = try replacing(
            state,
            attachments: state.attachments.filter { $0 != matching[0] }
        )
        return transition(
            request,
            disposition: .performed,
            state: updated,
            volumeID: volumeID
        )
    }

    private func publish(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let volume = try requireVolume(request, state: state)
        let nodeID = request.topology!.nodeID
        guard state.attachments.contains(where: {
            $0.volumeID == volume.id &&
                $0.nodeID == nodeID &&
                $0.kind == .stage &&
                $0.path == request.stagingPath
        }) else {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "Publish requires the exact staged volume path."
            )
        }
        guard volume.accessMode != .readOnlyMany ||
            request.readOnly! else {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "A read-only-many volume cannot be published read-write."
            )
        }
        if volume.accessMode == .readWriteOnce,
           !request.readOnly!,
           state.attachments.contains(where: {
               $0.volumeID == volume.id &&
                   $0.kind == .publish &&
                   !$0.readOnly &&
                   $0.nodeID != nodeID
           }) {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "Read-write-once volume is already published on another node."
            )
        }
        let attachment = StorageSemanticAttachment(
            volumeID: volume.id,
            nodeID: nodeID,
            kind: .publish,
            path: request.targetPath!,
            stagingPath: request.stagingPath,
            readOnly: request.readOnly!
        )
        if state.attachments.contains(attachment) {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volume.id
            )
        }
        guard !state.attachments.contains(where: {
            $0.nodeID == nodeID &&
                $0.kind == .publish &&
                $0.path == request.targetPath
        }) else {
            throw failure(
                request,
                .alreadyExists,
                .never,
                "The target path is already published by another attachment."
            )
        }
        var attachments = state.attachments
        attachments.append(attachment)
        return transition(
            request,
            disposition: .performed,
            state: try replacing(state, attachments: attachments),
            volumeID: volume.id
        )
    }

    private func unpublish(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let volumeID = request.volumeID!
        guard let volume = state.volumes.first(where: {
            $0.id == volumeID
        }) else {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volumeID
            )
        }
        try validateFence(request, volume: volume)
        let matching = state.attachments.filter {
            $0.volumeID == volumeID &&
                $0.nodeID == request.topology!.nodeID &&
                $0.kind == .publish &&
                $0.path == request.targetPath
        }
        guard !matching.isEmpty else {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volumeID
            )
        }
        guard matching.count == 1 else {
            throw failure(
                request,
                .ambiguousEffect,
                .resumeFromCheckpoint,
                "Multiple attachments matched the exact unpublish identity."
            )
        }
        return transition(
            request,
            disposition: .performed,
            state: try replacing(
                state,
                attachments: state.attachments.filter {
                    $0 != matching[0]
                }
            ),
            volumeID: volumeID
        )
    }

    private func expand(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let volume = try requireVolume(request, state: state)
        let requested = request.capacityBytes!
        guard requested > volume.capacityBytes else {
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volume.id
            )
        }
        let growth = requested - volume.capacityBytes
        guard growth <= state.availableCapacityBytes else {
            throw failure(
                request,
                .capacityExhausted,
                .safeAfterObservation,
                "Expansion exceeds current local capacity."
            )
        }
        let expanded = StorageSemanticVolume(
            id: volume.id,
            name: volume.name,
            providerID: volume.providerID,
            generation: volume.generation,
            fencingToken: volume.fencingToken,
            capacityBytes: requested,
            topology: volume.topology,
            accessMode: volume.accessMode,
            health: volume.health,
            sourceSnapshotID: volume.sourceSnapshotID
        )
        let updated = try replacing(
            state,
            volumes: state.volumes.map {
                $0.id == volume.id ? expanded : $0
            }
        )
        return transition(
            request,
            disposition: .performed,
            state: updated,
            volumeID: volume.id
        )
    }

    private func snapshot(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let volume = try requireVolume(request, state: state)
        let snapshotID = request.snapshotID!
        if let existing = state.snapshots.first(where: {
            $0.id == snapshotID
        }) {
            guard existing.name == request.snapshotName,
                  existing.sourceVolumeID == volume.id,
                  existing.sourceGeneration == volume.generation else {
                throw failure(
                    request,
                    .alreadyExists,
                    .never,
                    "The snapshot identity already exists with different source evidence."
                )
            }
            return transition(
                request,
                disposition: .alreadySatisfied,
                state: state,
                volumeID: volume.id,
                snapshotID: snapshotID
            )
        }
        guard !state.snapshots.contains(where: {
            $0.name == request.snapshotName
        }) else {
            throw failure(
                request,
                .alreadyExists,
                .never,
                "The snapshot name already belongs to another identity."
            )
        }
        var snapshots = state.snapshots
        snapshots.append(
            StorageSemanticSnapshot(
                id: snapshotID,
                name: request.snapshotName!,
                sourceVolumeID: volume.id,
                sourceGeneration: volume.generation,
                capacityBytes: volume.capacityBytes,
                ready: true
            )
        )
        return transition(
            request,
            disposition: .performed,
            state: try replacing(state, snapshots: snapshots),
            volumeID: volume.id,
            snapshotID: snapshotID
        )
    }

    private func restore(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        guard let snapshot = state.snapshots.first(where: {
            $0.id == request.snapshotID
        }),
        snapshot.ready else {
            throw failure(
                request,
                .notFound,
                .safeAfterObservation,
                "Restore requires an exact ready snapshot."
            )
        }
        guard request.capacityBytes! >= snapshot.capacityBytes else {
            throw failure(
                request,
                .invalidArgument,
                .never,
                "Restored volume capacity cannot be smaller than its snapshot."
            )
        }
        return try create(
            request,
            state: state,
            sourceSnapshotID: snapshot.id
        )
    }

    private func health(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticTransition {
        let health: StorageSemanticHealth
        if let volumeID = request.volumeID {
            guard let volume = state.volumes.first(where: {
                $0.id == volumeID
            }) else {
                throw failure(
                    request,
                    .notFound,
                    .safeAfterObservation,
                    "The requested volume was not observed."
                )
            }
            try validateFence(request, volume: volume)
            health = volume.health
        } else {
            health = state.providerHealth
        }
        return transition(
            request,
            disposition: .observed,
            state: state,
            volumeID: request.volumeID,
            health: health
        )
    }

    private func requireVolume(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws -> StorageSemanticVolume {
        guard let volume = state.volumes.first(where: {
            $0.id == request.volumeID
        }) else {
            throw failure(
                request,
                .notFound,
                .safeAfterObservation,
                "The requested volume was not observed."
            )
        }
        try validateFence(request, volume: volume)
        return volume
    }

    private func validateFence(
        _ request: StorageSemanticRequest,
        volume: StorageSemanticVolume
    ) throws {
        guard volume.providerID == request.context.providerID else {
            throw failure(
                request,
                .failedPrecondition,
                .never,
                "The request provider does not own this volume."
            )
        }
        guard volume.generation == request.context.generation else {
            throw failure(
                request,
                .staleGeneration,
                .safeAfterObservation,
                "The request generation is stale."
            )
        }
        guard volume.fencingToken == request.context.fencingToken else {
            throw failure(
                request,
                .fencingConflict,
                .safeAfterObservation,
                "The request fencing token does not own this generation."
            )
        }
    }

    private func validateTopology(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState
    ) throws {
        if let topology = request.topology,
           !state.topology.isAccessible(from: topology) {
            throw failure(
                request,
                .unsupportedTopology,
                .never,
                "Only the exact local storage topology is supported."
            )
        }
    }

    private func refuseInterruption(
        _ request: StorageSemanticRequest
    ) throws {
        switch request.context.interruption {
        case .none:
            return
        case .cancelled:
            throw failure(
                request,
                .cancelled,
                .safeAfterObservation,
                "The operation was cancelled; observe before retry."
            )
        case .timedOut:
            throw failure(
                request,
                .timedOut,
                .safeAfterObservation,
                "The operation timed out; observe before retry."
            )
        case .ambiguousEffect:
            throw failure(
                request,
                .ambiguousEffect,
                .resumeFromCheckpoint,
                "The external effect is ambiguous; resume from durable observation."
            )
        }
    }

    private func replacing(
        _ state: StorageSemanticState,
        volumes: [StorageSemanticVolume]? = nil,
        attachments: [StorageSemanticAttachment]? = nil,
        snapshots: [StorageSemanticSnapshot]? = nil
    ) throws -> StorageSemanticState {
        try StorageSemanticState(
            topology: state.topology,
            totalCapacityBytes: state.totalCapacityBytes,
            providerHealth: state.providerHealth,
            volumes: volumes ?? state.volumes,
            attachments: attachments ?? state.attachments,
            snapshots: snapshots ?? state.snapshots
        )
    }

    private func transition(
        _ request: StorageSemanticRequest,
        disposition: StorageSemanticDisposition,
        state: StorageSemanticState,
        volumeID: String? = nil,
        snapshotID: String? = nil,
        availableCapacityBytes: Int64? = nil,
        health: StorageSemanticHealth? = nil
    ) -> StorageSemanticTransition {
        StorageSemanticTransition(
            result: StorageSemanticResult(
                operation: request.operation,
                operationID: request.context.operationID,
                idempotencyKey: request.context.idempotencyKey,
                disposition: disposition,
                retryClass: .never,
                volumeID: volumeID,
                snapshotID: snapshotID,
                availableCapacityBytes: availableCapacityBytes,
                health: health
            ),
            state: state
        )
    }

    private func failure(
        _ request: StorageSemanticRequest,
        _ code: StorageSemanticErrorCode,
        _ retryClass: StorageSemanticRetryClass,
        _ message: String
    ) -> StorageSemanticError {
        StorageSemanticError(
            operation: request.operation,
            code: code,
            retryClass: retryClass,
            message: message
        )
    }
}
