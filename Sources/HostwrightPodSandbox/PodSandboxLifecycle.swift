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
    private let recoveryStore: (any PodSandboxRecoveryStore)?
    private var records: [PodSandboxID: Record] = [:]
    private var tombstones: [PodSandboxID: Tombstone] = [:]

    public init() {
        self.recoveryStore = nil
    }

    public init(recoveryStore: any PodSandboxRecoveryStore) throws {
        self.recoveryStore = recoveryStore
        guard let data = try recoveryStore.load() else {
            return
        }
        let journal = try decodePodSandboxRecoveryJournal(data)
        let restored = try Self.restore(journal)
        self.records = restored.records
        self.tombstones = restored.tombstones
    }

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
        try transact {
            try markRecoveryRequiredLocked(evidence)
        }
    }

    private func markRecoveryRequiredLocked(
        _ evidence: PodSandboxRecoveryEvidence
    ) throws -> PodSandboxSnapshot {
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

        return try transact {
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
            let signature = ReplaySignature(
                transition: .create,
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

    private func transact<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            let priorRecords = records
            let priorTombstones = tombstones
            do {
                let value = try body()
                try persistLocked()
                return value
            } catch {
                records = priorRecords
                tombstones = priorTombstones
                throw error
            }
        }
    }

    private func persistLocked() throws {
        guard let recoveryStore else { return }
        let journal = PodSandboxRecoveryJournal(
            schemaVersion: podSandboxRecoverySchemaVersion,
            records: records.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                guard let record = records[id] else { return nil }
                return PodSandboxRecoveryRecord(
                    spec: record.spec,
                    state: record.state,
                    resourcePresent: record.resourcePresent,
                    prepared: record.prepared,
                    running: record.running,
                    cleanupComplete: record.cleanupComplete,
                    cleanupResourceCount: record.cleanupResourceCount,
                    lastTransition: record.lastTransition,
                    replays: record.replays.keys.sorted().compactMap { requestID in
                        guard let replay = record.replays[requestID] else { return nil }
                        return PodSandboxRecoveryReplay(
                            requestID: requestID,
                            transition: replay.signature.transition,
                            ownerID: replay.signature.ownerID,
                            generation: replay.signature.generation,
                            spec: replay.signature.spec,
                            result: replay.result
                        )
                    }
                )
            },
            tombstones: tombstones.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                guard let tombstone = tombstones[id] else { return nil }
                return PodSandboxRecoveryTombstone(
                    id: id,
                    ownerID: tombstone.ownerID,
                    generation: tombstone.generation,
                    lastTransition: tombstone.lastTransition,
                    replays: tombstone.replays.keys.sorted().compactMap { requestID in
                        guard let replay = tombstone.replays[requestID] else { return nil }
                        return PodSandboxRecoveryReplay(
                            requestID: requestID,
                            transition: replay.signature.transition,
                            ownerID: replay.signature.ownerID,
                            generation: replay.signature.generation,
                            spec: replay.signature.spec,
                            result: replay.result
                        )
                    }
                )
            }
        )
        do {
            try recoveryStore.save(try encodePodSandboxRecoveryJournal(journal))
        } catch let error as PodSandboxLifecycleError {
            throw error
        } catch {
            throw PodSandboxLifecycleError.recoveryPersistenceFailed
        }
    }

    private static func restore(
        _ journal: PodSandboxRecoveryJournal
    ) throws -> (records: [PodSandboxID: Record], tombstones: [PodSandboxID: Tombstone]) {
        guard journal.records.count <= 1_024,
              journal.tombstones.count <= 1_024 else {
            throw PodSandboxRecoveryStoreError.fileTooLarge
        }

        var records: [PodSandboxID: Record] = [:]
        for persisted in journal.records {
            let id = persisted.spec.id
            guard records[id] == nil else {
                throw PodSandboxRecoveryStoreError.duplicateField("records.id")
            }
            try validatePersistedRecord(persisted)
            records[id] = Record(
                spec: persisted.spec,
                state: persisted.state,
                resourcePresent: persisted.resourcePresent,
                prepared: persisted.prepared,
                running: persisted.running,
                cleanupComplete: persisted.cleanupComplete,
                cleanupResourceCount: persisted.cleanupResourceCount,
                lastTransition: persisted.lastTransition,
                replays: try replayEntries(
                    persisted.replays,
                    id: id,
                    ownerID: persisted.spec.ownerID,
                    generation: persisted.spec.generation
                )
            )
        }

        var tombstones: [PodSandboxID: Tombstone] = [:]
        for persisted in journal.tombstones {
            let id = persisted.id
            guard tombstones[id] == nil, records[id] == nil else {
                throw PodSandboxRecoveryStoreError.malformed
            }
            try PodSandboxValidation.safeIdentifier(
                persisted.ownerID,
                maximumLength: 128,
                field: "ownerID"
            )
            try PodSandboxValidation.generation(persisted.generation)
            guard [.cancel, .teardown, .recover].contains(persisted.lastTransition) else {
                throw PodSandboxRecoveryStoreError.malformed
            }
            tombstones[id] = Tombstone(
                ownerID: persisted.ownerID,
                generation: persisted.generation,
                lastTransition: persisted.lastTransition,
                replays: try replayEntries(
                    persisted.replays,
                    id: id,
                    ownerID: persisted.ownerID,
                    generation: persisted.generation
                )
            )
        }
        return (records, tombstones)
    }

    private static func validatePersistedRecord(
        _ record: PodSandboxRecoveryRecord
    ) throws {
        guard record.state != .absent,
              record.state != .cancelling,
              record.state != .tearingDown,
              !record.cleanupComplete,
              record.resourcePresent || (!record.prepared && !record.running),
              !record.running || record.prepared else {
            throw PodSandboxRecoveryStoreError.malformed
        }
        let expectedResourceCount = record.resourcePresent
            ? 1 + (record.prepared ? 1 : 0) + (record.running ? 1 : 0)
            : 0
        guard record.cleanupResourceCount == expectedResourceCount else {
            throw PodSandboxRecoveryStoreError.malformed
        }
        switch record.state {
        case .created:
            guard record.resourcePresent, !record.prepared, !record.running else {
                throw PodSandboxRecoveryStoreError.malformed
            }
        case .prepared, .stopped:
            guard record.resourcePresent, record.prepared, !record.running else {
                throw PodSandboxRecoveryStoreError.malformed
            }
        case .running:
            guard record.resourcePresent, record.prepared, record.running else {
                throw PodSandboxRecoveryStoreError.malformed
            }
        case .recovering:
            break
        case .absent, .cancelling, .tearingDown:
            throw PodSandboxRecoveryStoreError.malformed
        }
    }

    private static func replayEntries(
        _ entries: [PodSandboxRecoveryReplay],
        id: PodSandboxID,
        ownerID: String,
        generation: UInt64
    ) throws -> [String: ReplayEntry] {
        guard entries.count <= 4_096 else {
            throw PodSandboxRecoveryStoreError.fileTooLarge
        }
        var result: [String: ReplayEntry] = [:]
        for entry in entries {
            guard result[entry.requestID] == nil else {
                throw PodSandboxRecoveryStoreError.duplicateField("replays.requestID")
            }
            try PodSandboxValidation.safeIdentifier(
                entry.requestID,
                maximumLength: 128,
                field: "requestID"
            )
            guard entry.ownerID == ownerID,
                  entry.generation == generation,
                  entry.result.transition == entry.transition,
                  entry.result.snapshot.id == id,
                  entry.result.snapshot.ownerID == ownerID,
                  entry.result.snapshot.generation == generation else {
                throw PodSandboxRecoveryStoreError.malformed
            }
            if let spec = entry.spec {
                guard spec.id == id, spec.ownerID == ownerID, spec.generation == generation else {
                    throw PodSandboxRecoveryStoreError.malformed
                }
            }
            result[entry.requestID] = ReplayEntry(
                signature: ReplaySignature(
                    transition: entry.transition,
                    ownerID: entry.ownerID,
                    generation: entry.generation,
                    spec: entry.spec
                ),
                result: entry.result
            )
        }
        return result
    }
}
