import Foundation

public final class PodSandboxLifecycleStateMachine: @unchecked Sendable {
    private struct ReplaySignature: Equatable {
        let transition: PodSandboxTransition
        let ownerID: String
        let generation: UInt64
        let spec: PodSandboxSpec?
    }

    private struct ReplayEntry {
        let signature: ReplaySignature
        let result: PodSandboxLifecycleResult
    }

    private struct Record {
        let spec: PodSandboxSpec
        var state: PodSandboxState
        var resourcePresent: Bool
        var prepared: Bool
        var running: Bool
        var cleanupComplete: Bool
        var cleanupResourceCount: Int
        var lastTransition: PodSandboxTransition?
        var replays: [String: ReplayEntry]
    }

    private struct Tombstone {
        let ownerID: String
        let generation: UInt64
        let lastTransition: PodSandboxTransition
        var replays: [String: ReplayEntry]
    }

    private let lock = NSLock()
    private var records: [PodSandboxID: Record] = [:]
    private var tombstones: [PodSandboxID: Tombstone] = [:]

    public init() {}

    public func snapshot(for id: PodSandboxID) -> PodSandboxSnapshot? {
        lock.withLock {
            if let record = records[id] {
                return snapshot(from: record)
            }
            if let tombstone = tombstones[id] {
                return PodSandboxSnapshot(
                    id: id,
                    ownerID: tombstone.ownerID,
                    generation: tombstone.generation,
                    state: .absent,
                    resourcePresent: false,
                    prepared: false,
                    running: false,
                    cleanupComplete: true,
                    cleanupResourceCount: 0,
                    lastTransition: tombstone.lastTransition
                )
            }
            return nil
        }
    }

    @discardableResult
    public func markRecoveryRequired(
        _ evidence: PodSandboxRecoveryEvidence
    ) throws -> PodSandboxSnapshot {
        try lock.withLock {
            if let tombstone = tombstones[evidence.id] {
                try validateTombstone(
                    tombstone,
                    ownerID: evidence.ownerID,
                    generation: evidence.generation,
                    isCreate: false
                )
            }

            if var record = records[evidence.id] {
                try validateOwnership(
                    record.spec,
                    ownerID: evidence.ownerID,
                    generation: evidence.generation
                )
                record.state = .recovering
                record.resourcePresent = evidence.resourcePresent
                record.prepared = evidence.prepared
                record.running = evidence.running
                record.cleanupComplete = false
                record.cleanupResourceCount = resourceCount(
                    resourcePresent: evidence.resourcePresent,
                    prepared: evidence.prepared,
                    running: evidence.running
                )
                records[evidence.id] = record
                return snapshot(from: record)
            }

            guard evidence.resourcePresent else {
                return PodSandboxSnapshot(
                    id: evidence.id,
                    ownerID: evidence.ownerID,
                    generation: evidence.generation,
                    state: .absent,
                    resourcePresent: false,
                    prepared: false,
                    running: false,
                    cleanupComplete: true,
                    cleanupResourceCount: 0,
                    lastTransition: .recover
                )
            }

            let spec = try PodSandboxSpec(
                id: evidence.id,
                ownerID: evidence.ownerID,
                generation: evidence.generation
            )
            let record = Record(
                spec: spec,
                state: .recovering,
                resourcePresent: evidence.resourcePresent,
                prepared: evidence.prepared,
                running: evidence.running,
                cleanupComplete: false,
                cleanupResourceCount: resourceCount(
                    resourcePresent: evidence.resourcePresent,
                    prepared: evidence.prepared,
                    running: evidence.running
                ),
                lastTransition: .recover,
                replays: [:]
            )
            records[evidence.id] = record
            return snapshot(from: record)
        }
    }

    public func apply(
        _ transition: PodSandboxTransition,
        id: PodSandboxID,
        ownerID: String,
        generation: UInt64,
        requestID: String,
        spec: PodSandboxSpec? = nil
    ) throws -> PodSandboxLifecycleResult {
        try PodSandboxValidation.safeIdentifier(ownerID, maximumLength: 128, field: "ownerID")
        try PodSandboxValidation.generation(generation)
        try PodSandboxValidation.safeIdentifier(requestID, maximumLength: 128, field: "requestID")
        if let spec {
            guard spec.id == id, spec.ownerID == ownerID, spec.generation == generation else {
                throw PodSandboxLifecycleError.generationMismatch
            }
        }

        return try lock.withLock {
            if transition == .create {
                return try create(
                    id: id,
                    ownerID: ownerID,
                    generation: generation,
                    requestID: requestID,
                    spec: spec
                )
            }

            if let record = records[id] {
                try validateOwnership(record.spec, ownerID: ownerID, generation: generation)
                let signature = ReplaySignature(
                    transition: transition,
                    ownerID: ownerID,
                    generation: generation,
                    spec: spec
                )
                if let replay = record.replays[requestID] {
                    guard replay.signature == signature else {
                        throw PodSandboxLifecycleError.replayMismatch
                    }
                    return result(
                        replay.result,
                        replayed: true,
                        cleanupPerformed: false
                    )
                }

                let outcome = try applyTransition(
                    transition,
                    id: id,
                    record: record
                )
                if let outcome {
                    let lifecycleResult = PodSandboxLifecycleResult(
                        transition: transition,
                        snapshot: outcome.snapshot,
                        replayed: false,
                        cleanupPerformed: outcome.cleanupPerformed
                    )
                    if outcome.snapshot.state == .absent {
                        guard var tombstone = tombstones[id] else {
                            throw PodSandboxLifecycleError.cleanupIncomplete
                        }
                        tombstone.replays[requestID] = ReplayEntry(
                            signature: signature,
                            result: lifecycleResult
                        )
                        tombstones[id] = tombstone
                    } else {
                        records[id] = outcome.record
                        records[id]?.replays[requestID] = ReplayEntry(
                            signature: signature,
                            result: lifecycleResult
                        )
                    }
                    return lifecycleResult
                }
                throw PodSandboxLifecycleError.cleanupIncomplete
            }

            guard var tombstone = tombstones[id] else {
                throw PodSandboxLifecycleError.sandboxNotFound
            }
            try validateTombstone(
                tombstone,
                ownerID: ownerID,
                generation: generation,
                isCreate: false
            )
            let signature = ReplaySignature(
                transition: transition,
                ownerID: ownerID,
                generation: generation,
                spec: spec
            )
            if let replay = tombstone.replays[requestID] {
                guard replay.signature == signature else {
                    throw PodSandboxLifecycleError.replayMismatch
                }
                return result(
                    replay.result,
                    replayed: true,
                    cleanupPerformed: false
                )
            }
            guard transition == .teardown || transition == tombstone.lastTransition else {
                throw PodSandboxLifecycleError.sandboxNotFound
            }
            let snapshot = PodSandboxSnapshot(
                id: id,
                ownerID: tombstone.ownerID,
                generation: tombstone.generation,
                state: .absent,
                resourcePresent: false,
                prepared: false,
                running: false,
                cleanupComplete: true,
                cleanupResourceCount: 0,
                lastTransition: tombstone.lastTransition
            )
            let lifecycleResult = PodSandboxLifecycleResult(
                transition: transition,
                snapshot: snapshot,
                replayed: true,
                cleanupPerformed: false
            )
            tombstone.replays[requestID] = ReplayEntry(
                signature: signature,
                result: lifecycleResult
            )
            tombstones[id] = tombstone
            return lifecycleResult
        }
    }

    private func create(
        id: PodSandboxID,
        ownerID: String,
        generation: UInt64,
        requestID: String,
        spec: PodSandboxSpec?
    ) throws -> PodSandboxLifecycleResult {
        guard let spec else {
            throw PodSandboxValidationError.missingField("spec")
        }
        guard spec.id == id, spec.ownerID == ownerID, spec.generation == generation else {
            throw PodSandboxLifecycleError.generationMismatch
        }

        if let record = records[id] {
            try validateOwnership(record.spec, ownerID: ownerID, generation: generation)
            guard record.spec == spec else {
                throw PodSandboxLifecycleError.generationConflict
            }
            let snapshot = snapshot(from: record)
            let lifecycleResult = PodSandboxLifecycleResult(
                transition: .create,
                snapshot: snapshot,
                replayed: true,
                cleanupPerformed: false
            )
            return lifecycleResult
        }

        if let tombstone = tombstones[id] {
            guard tombstone.ownerID == ownerID else {
                throw PodSandboxLifecycleError.ownershipMismatch
            }
            guard generation > tombstone.generation else {
                throw PodSandboxLifecycleError.generationConflict
            }
        }

        let record = Record(
            spec: spec,
            state: .created,
            resourcePresent: true,
            prepared: false,
            running: false,
            cleanupComplete: false,
            cleanupResourceCount: 1,
            lastTransition: .create,
            replays: [:]
        )
        records[id] = record
        let lifecycleResult = PodSandboxLifecycleResult(
            transition: .create,
            snapshot: snapshot(from: record),
            replayed: false,
            cleanupPerformed: false
        )
        records[id]?.replays[requestID] = ReplayEntry(
            signature: ReplaySignature(
                transition: .create,
                ownerID: ownerID,
                generation: generation,
                spec: spec
            ),
            result: lifecycleResult
        )
        return lifecycleResult
    }

    private struct TransitionOutcome {
        let record: Record
        let snapshot: PodSandboxSnapshot
        let cleanupPerformed: Bool
    }

    private func applyTransition(
        _ transition: PodSandboxTransition,
        id: PodSandboxID,
        record original: Record
    ) throws -> TransitionOutcome? {
        var record = original
        var cleanupPerformed = false

        switch transition {
        case .prepare:
            switch record.state {
            case .created, .stopped:
                record.state = .prepared
                record.prepared = true
                record.running = false
                record.lastTransition = .prepare
                record.cleanupResourceCount = resourceCount(from: record)
            case .prepared:
                return TransitionOutcome(
                    record: record,
                    snapshot: snapshot(from: record),
                    cleanupPerformed: false
                )
            default:
                throw PodSandboxLifecycleError.invalidTransition(transition, record.state)
            }

        case .start:
            switch record.state {
            case .prepared, .stopped:
                record.state = .running
                record.prepared = true
                record.running = true
                record.lastTransition = .start
                record.cleanupResourceCount = resourceCount(from: record)
            case .running:
                return TransitionOutcome(
                    record: record,
                    snapshot: snapshot(from: record),
                    cleanupPerformed: false
                )
            default:
                throw PodSandboxLifecycleError.invalidTransition(transition, record.state)
            }

        case .stop:
            switch record.state {
            case .running:
                record.state = .stopped
                record.running = false
                record.lastTransition = .stop
            case .stopped:
                return TransitionOutcome(
                    record: record,
                    snapshot: snapshot(from: record),
                    cleanupPerformed: false
                )
            default:
                throw PodSandboxLifecycleError.invalidTransition(transition, record.state)
            }

        case .restart:
            switch record.state {
            case .prepared, .stopped, .running:
                record.state = .running
                record.prepared = true
                record.running = true
                record.lastTransition = .restart
                record.cleanupResourceCount = resourceCount(from: record)
            default:
                throw PodSandboxLifecycleError.invalidTransition(transition, record.state)
            }

        case .recover:
            switch record.state {
            case .recovering:
                guard record.resourcePresent else {
                    return try teardownRecord(
                        id: id,
                        record: record,
                        transition: .recover
                    )
                }
                record.state = record.running ? .running : (record.prepared ? .prepared : .created)
                record.lastTransition = .recover
                record.cleanupResourceCount = resourceCount(from: record)
            case .created, .prepared, .running, .stopped:
                return TransitionOutcome(
                    record: record,
                    snapshot: snapshot(from: record),
                    cleanupPerformed: false
                )
            default:
                throw PodSandboxLifecycleError.invalidTransition(transition, record.state)
            }

        case .cancel:
            guard record.state != .tearingDown else {
                throw PodSandboxLifecycleError.invalidTransition(transition, record.state)
            }
            record.state = .cancelling
            record.lastTransition = .cancel
            let outcome = try teardownRecord(id: id, record: record, transition: .cancel)
            cleanupPerformed = outcome.cleanupPerformed
            return outcome

        case .teardown:
            record.state = .tearingDown
            record.lastTransition = .teardown
            let outcome = try teardownRecord(id: id, record: record, transition: .teardown)
            cleanupPerformed = outcome.cleanupPerformed
            return outcome

        case .create:
            throw PodSandboxLifecycleError.invalidTransition(transition, record.state)
        }

        return TransitionOutcome(
            record: record,
            snapshot: snapshot(from: record),
            cleanupPerformed: cleanupPerformed
        )
    }

    private func teardownRecord(
        id: PodSandboxID,
        record: Record,
        transition: PodSandboxTransition
    ) throws -> TransitionOutcome {
        let count = resourceCount(from: record)
        guard count >= 0 else {
            throw PodSandboxLifecycleError.cleanupIncomplete
        }
        let snapshot = PodSandboxSnapshot(
            id: id,
            ownerID: record.spec.ownerID,
            generation: record.spec.generation,
            state: .absent,
            resourcePresent: false,
            prepared: false,
            running: false,
            cleanupComplete: true,
            cleanupResourceCount: 0,
            lastTransition: transition
        )
        let removed = Record(
            spec: record.spec,
            state: .absent,
            resourcePresent: false,
            prepared: false,
            running: false,
            cleanupComplete: true,
            cleanupResourceCount: 0,
            lastTransition: transition,
            replays: record.replays
        )
        records.removeValue(forKey: id)
        tombstones[id] = Tombstone(
            ownerID: record.spec.ownerID,
            generation: record.spec.generation,
            lastTransition: transition,
            replays: record.replays
        )
        return TransitionOutcome(
            record: removed,
            snapshot: snapshot,
            cleanupPerformed: count > 0
        )
    }

    private func validateOwnership(
        _ spec: PodSandboxSpec,
        ownerID: String,
        generation: UInt64
    ) throws {
        guard spec.ownerID == ownerID else {
            throw PodSandboxLifecycleError.ownershipMismatch
        }
        guard spec.generation == generation else {
            throw PodSandboxLifecycleError.generationMismatch
        }
    }

    private func validateTombstone(
        _ tombstone: Tombstone,
        ownerID: String,
        generation: UInt64,
        isCreate: Bool
    ) throws {
        guard tombstone.ownerID == ownerID else {
            throw PodSandboxLifecycleError.ownershipMismatch
        }
        if isCreate {
            guard generation > tombstone.generation else {
                throw PodSandboxLifecycleError.generationConflict
            }
        } else {
            guard generation == tombstone.generation else {
                throw PodSandboxLifecycleError.generationMismatch
            }
        }
    }

    private func snapshot(from record: Record) -> PodSandboxSnapshot {
        PodSandboxSnapshot(
            id: record.spec.id,
            ownerID: record.spec.ownerID,
            generation: record.spec.generation,
            state: record.state,
            resourcePresent: record.resourcePresent,
            prepared: record.prepared,
            running: record.running,
            cleanupComplete: record.cleanupComplete,
            cleanupResourceCount: record.cleanupResourceCount,
            lastTransition: record.lastTransition
        )
    }

    private func resourceCount(from record: Record) -> Int {
        resourceCount(
            resourcePresent: record.resourcePresent,
            prepared: record.prepared,
            running: record.running
        )
    }

    private func resourceCount(
        resourcePresent: Bool,
        prepared: Bool,
        running: Bool
    ) -> Int {
        guard resourcePresent else { return 0 }
        return 1 + (prepared ? 1 : 0) + (running ? 1 : 0)
    }

    private func result(
        _ original: PodSandboxLifecycleResult,
        replayed: Bool,
        cleanupPerformed: Bool
    ) -> PodSandboxLifecycleResult {
        PodSandboxLifecycleResult(
            transition: original.transition,
            snapshot: original.snapshot,
            replayed: replayed,
            cleanupPerformed: cleanupPerformed
        )
    }
}
