import Foundation

public struct ContentCacheRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func upsert(_ record: ContentCacheRecord) throws {
        try Self.validate(record)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.refuseActiveExclusiveLease(
                    providerScope: record.providerScope,
                    digest: record.digest,
                    reference: nil,
                    currentTimestamp: record.observedAt,
                    on: connection
                )
                try Self.upsert(record, on: connection)
            }
        }
    }

    public func touch(
        providerScope: String,
        digest: String,
        lastUsedAt: String,
        observedAt: String
    ) throws -> Bool {
        try Self.validateProviderScope(providerScope)
        try Self.validateDigest(digest)
        try Self.validateTimestamp(lastUsedAt)
        try Self.validateTimestamp(observedAt)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.refuseActiveExclusiveLease(
                    providerScope: providerScope,
                    digest: digest,
                    reference: nil,
                    currentTimestamp: observedAt,
                    on: connection
                )
                let rows = try connection.query(
                    """
                    SELECT created_at, last_used_at, observed_at
                    FROM content_cache_objects
                    WHERE provider_scope = ? AND digest = ?
                    LIMIT 1
                    """,
                    bindings: [.text(providerScope), .text(digest)]
                )
                guard let row = rows.first,
                      row.count == 3,
                      let createdAt = row[0],
                      let existingLastUsedAt = row[1],
                      let existingObservedAt = row[2] else {
                    return false
                }
                guard Self.date(lastUsedAt) >= Self.date(createdAt),
                      Self.date(lastUsedAt) >= Self.date(existingLastUsedAt),
                      Self.date(observedAt) >= Self.date(createdAt),
                      Self.date(observedAt) >= Self.date(existingObservedAt) else {
                    throw StateStoreError.invalidRecord(
                        "Content cache touch timestamps must be monotonic."
                    )
                }
                try connection.run(
                    """
                    UPDATE content_cache_objects
                    SET last_used_at = ?, observed_at = ?
                    WHERE provider_scope = ? AND digest = ?
                    """,
                    bindings: [
                        .text(lastUsedAt), .text(observedAt),
                        .text(providerScope), .text(digest)
                    ]
                )
                return true
            }
        }
    }

    public func setPinPolicy(
        providerScope: String,
        digest: String,
        pinPolicy: ContentCachePinPolicy,
        observedAt: String
    ) throws -> Bool {
        try Self.validateProviderScope(providerScope)
        try Self.validateDigest(digest)
        try Self.validateTimestamp(observedAt)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.refuseActiveExclusiveLease(
                    providerScope: providerScope,
                    digest: digest,
                    reference: nil,
                    currentTimestamp: observedAt,
                    on: connection
                )
                let rows = try connection.query(
                    """
                    SELECT created_at, observed_at
                    FROM content_cache_objects
                    WHERE provider_scope = ? AND digest = ?
                    LIMIT 1
                    """,
                    bindings: [.text(providerScope), .text(digest)]
                )
                guard let row = rows.first,
                      row.count == 2,
                      let createdAt = row[0],
                      let existingObservedAt = row[1] else {
                    return false
                }
                guard Self.date(observedAt) >= Self.date(createdAt),
                      Self.date(observedAt) >= Self.date(existingObservedAt) else {
                    throw StateStoreError.invalidRecord(
                        "Content cache pin observation must be monotonic."
                    )
                }
                try connection.run(
                    """
                    UPDATE content_cache_objects
                    SET pin_policy = ?, observed_at = ?
                    WHERE provider_scope = ? AND digest = ?
                    """,
                    bindings: [
                        .text(pinPolicy.rawValue), .text(observedAt),
                        .text(providerScope), .text(digest)
                    ]
                )
                return true
            }
        }
    }

    public func saveReference(
        _ record: ContentCacheReferenceRecord
    ) throws {
        try Self.validate(record)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.refuseActiveExclusiveLease(
                    providerScope: record.providerScope,
                    digest: record.digest,
                    reference: record.reference,
                    currentTimestamp: record.observedAt,
                    on: connection
                )
                let content = try connection.query(
                    """
                    SELECT 1 FROM content_cache_objects
                    WHERE provider_scope = ? AND digest = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(record.providerScope),
                        .text(record.digest)
                    ]
                )
                guard !content.isEmpty else {
                    throw StateStoreError.notFound(
                        "Content reference target does not exist."
                    )
                }
                let existing = try connection.query(
                    """
                    SELECT id, digest, ownership_operation_id,
                           ownership_proof_sha256, created_at,
                           observed_at
                    FROM content_cache_references
                    WHERE provider_scope = ? AND reference = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(record.providerScope),
                        .text(record.reference)
                    ]
                )
                if let row = existing.first {
                    guard row.count == 6,
                          row[0] == record.id,
                          row[1] == record.digest,
                          row[2] == record.ownershipOperationID,
                          row[3] == record.ownershipProofSHA256,
                          row[4] == record.createdAt,
                          let existingObservedAt = row[5],
                          Self.date(record.observedAt)
                            >= Self.date(existingObservedAt) else {
                        throw StateStoreError.invalidRecord(
                            "Content reference already exists with different ownership."
                        )
                    }
                    try connection.run(
                        """
                        UPDATE content_cache_references
                        SET observed_at = ?
                        WHERE provider_scope = ? AND reference = ?
                        """,
                        bindings: [
                            .text(record.observedAt),
                            .text(record.providerScope),
                            .text(record.reference)
                        ]
                    )
                    return
                }
                try connection.run(
                    """
                    INSERT INTO content_cache_references (
                        id, provider_scope, reference, digest,
                        ownership_operation_id, ownership_proof_sha256,
                        created_at, observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(record.id), .text(record.providerScope),
                        .text(record.reference), .text(record.digest),
                        .text(record.ownershipOperationID),
                        .text(record.ownershipProofSHA256),
                        .text(record.createdAt), .text(record.observedAt)
                    ]
                )
            }
        }
    }

    func removeReference(
        id: String,
        providerScope: String,
        reference: String,
        digest: String,
        ownershipOperationID: String,
        ownershipProofSHA256: String
    ) throws -> Bool {
        try Self.validateUUID(id, field: "reference ID")
        try Self.validateProviderScope(providerScope)
        try Self.validateReference(reference)
        try Self.validateDigest(digest)
        try Self.validateUUID(
            ownershipOperationID,
            field: "ownership operation ID"
        )
        try Self.validateSHA256(
            ownershipProofSHA256,
            field: "ownership proof"
        )
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT id FROM content_cache_references
                    WHERE id = ? AND provider_scope = ? AND reference = ?
                      AND digest = ? AND ownership_operation_id = ?
                      AND ownership_proof_sha256 = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(id), .text(providerScope), .text(reference),
                        .text(digest), .text(ownershipOperationID),
                        .text(ownershipProofSHA256)
                    ]
                )
                guard !rows.isEmpty else { return false }
                try connection.run(
                    """
                    DELETE FROM content_cache_references
                    WHERE id = ? AND provider_scope = ? AND reference = ?
                      AND digest = ? AND ownership_operation_id = ?
                      AND ownership_proof_sha256 = ?
                    """,
                    bindings: [
                        .text(id), .text(providerScope), .text(reference),
                        .text(digest), .text(ownershipOperationID),
                        .text(ownershipProofSHA256)
                    ]
                )
                return true
            }
        }
    }

    public func removeReferenceUnderLease(
        id: String,
        providerScope: String,
        reference: String,
        digest: String,
        ownershipOperationID: String,
        ownershipProofSHA256: String,
        exclusiveLeaseID: String,
        expectedFencingToken: String,
        removedAt: String
    ) throws -> Bool {
        try Self.validateUUID(id, field: "reference ID")
        try Self.validateProviderScope(providerScope)
        try Self.validateReference(reference)
        try Self.validateDigest(digest)
        try Self.validateUUID(
            ownershipOperationID,
            field: "ownership operation ID"
        )
        try Self.validateSHA256(
            ownershipProofSHA256,
            field: "ownership proof"
        )
        try Self.validateUUID(exclusiveLeaseID, field: "lease ID")
        try Self.validateUUID(
            expectedFencingToken,
            field: "lease fencing token"
        )
        try Self.validateTimestamp(removedAt)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let lease = try connection.query(
                    """
                    SELECT 1 FROM content_cache_leases
                    WHERE id = ? AND fencing_token = ?
                      AND provider_scope = ?
                      AND mode = 'exclusive-delete'
                      AND released_at IS NULL AND expires_at > ?
                      AND digest = ?
                      AND (reference IS NULL OR reference = ?)
                    LIMIT 1
                    """,
                    bindings: [
                        .text(exclusiveLeaseID),
                        .text(expectedFencingToken),
                        .text(providerScope), .text(removedAt),
                        .text(digest), .text(reference)
                    ]
                )
                guard !lease.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Exact active exclusive lease is required to remove an owned content reference."
                    )
                }
                let rows = try connection.query(
                    """
                    SELECT 1 FROM content_cache_references
                    WHERE id = ? AND provider_scope = ? AND reference = ?
                      AND digest = ? AND ownership_operation_id = ?
                      AND ownership_proof_sha256 = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(id), .text(providerScope), .text(reference),
                        .text(digest), .text(ownershipOperationID),
                        .text(ownershipProofSHA256)
                    ]
                )
                guard !rows.isEmpty else { return false }
                try connection.run(
                    """
                    DELETE FROM content_cache_references
                    WHERE id = ? AND provider_scope = ? AND reference = ?
                      AND digest = ? AND ownership_operation_id = ?
                      AND ownership_proof_sha256 = ?
                    """,
                    bindings: [
                        .text(id), .text(providerScope), .text(reference),
                        .text(digest), .text(ownershipOperationID),
                        .text(ownershipProofSHA256)
                    ]
                )
                return true
            }
        }
    }

    public func acquireLease(
        providerScope: String,
        digest: String,
        reference: String? = nil,
        mode: ContentCacheLeaseMode,
        ownerID: String,
        purpose: String,
        acquiredAt: String,
        expiresAt: String
    ) throws -> ContentCacheLeaseRecord {
        try Self.validateProviderScope(providerScope)
        try Self.validateDigest(digest)
        if let reference { try Self.validateReference(reference) }
        try Self.validateBoundedToken(ownerID, field: "lease owner")
        try Self.validateBoundedToken(purpose, field: "lease purpose")
        try Self.validateTimestamp(acquiredAt)
        try Self.validateTimestamp(expiresAt)
        guard Self.date(expiresAt) > Self.date(acquiredAt),
              Self.date(expiresAt).timeIntervalSince(Self.date(acquiredAt))
                <= 86_400 else {
            throw StateStoreError.invalidRecord(
                "Content lease lifetime must be greater than zero and at most 24 hours."
            )
        }
        let record = ContentCacheLeaseRecord(
            id: UUID().uuidString.lowercased(),
            providerScope: providerScope,
            digest: digest,
            reference: reference,
            mode: mode,
            ownerID: ownerID,
            purpose: purpose,
            fencingToken: UUID().uuidString.lowercased(),
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            releasedAt: nil
        )
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let content = try connection.query(
                    """
                    SELECT pin_policy
                    FROM content_cache_objects
                    WHERE provider_scope = ? AND digest = ?
                    LIMIT 1
                    """,
                    bindings: [.text(providerScope), .text(digest)]
                )
                guard let pinPolicy = content.first?.first ?? nil else {
                    throw StateStoreError.notFound(
                        "Content lease target does not exist."
                    )
                }
                if let reference {
                    let mapped = try connection.query(
                        """
                        SELECT 1 FROM content_cache_references
                        WHERE provider_scope = ? AND reference = ?
                          AND digest = ?
                        LIMIT 1
                        """,
                        bindings: [
                            .text(providerScope), .text(reference),
                            .text(digest)
                        ]
                    )
                    if mapped.isEmpty {
                        throw StateStoreError.notFound(
                            "Lease reference does not map to the exact content digest."
                        )
                    }
                }
                if mode == .exclusiveDelete {
                    guard pinPolicy == ContentCachePinPolicy.unpinned.rawValue else {
                        throw StateStoreError.invalidRecord(
                            "Pinned content cannot receive an exclusive deletion lease."
                        )
                    }
                }
                let conflicts = try Self.activeLeaseConflicts(
                    providerScope: providerScope,
                    digest: digest,
                    reference: reference,
                    currentTimestamp: acquiredAt,
                    on: connection
                )
                if !conflicts.isEmpty {
                    let hasExclusive = conflicts.contains {
                        $0 == ContentCacheLeaseMode.exclusiveDelete.rawValue
                    }
                    if mode != .shared || hasExclusive {
                        throw StateStoreError.invalidRecord(
                            "Content lease conflicts with an active lease."
                        )
                    }
                }
                try connection.run(
                    """
                    INSERT INTO content_cache_leases (
                        id, provider_scope, digest, reference, mode,
                        owner_id, purpose, fencing_token, acquired_at,
                        expires_at, released_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    bindings: [
                        .text(record.id), .text(providerScope), .text(digest),
                        Self.optionalText(reference), .text(mode.rawValue),
                        .text(ownerID), .text(purpose),
                        .text(record.fencingToken), .text(acquiredAt),
                        .text(expiresAt)
                    ]
                )
                return record
            }
        }
    }

    public func releaseLease(
        id: String,
        expectedFencingToken: String,
        releasedAt: String
    ) throws -> Bool {
        try Self.validateUUID(id, field: "lease ID")
        try Self.validateUUID(
            expectedFencingToken,
            field: "lease fencing token"
        )
        try Self.validateTimestamp(releasedAt)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT acquired_at FROM content_cache_leases
                    WHERE id = ? AND fencing_token = ?
                      AND released_at IS NULL
                    LIMIT 1
                    """,
                    bindings: [
                        .text(id), .text(expectedFencingToken)
                    ]
                )
                guard let acquiredAt = rows.first?.first ?? nil else {
                    return false
                }
                guard Self.date(releasedAt) >= Self.date(acquiredAt) else {
                    throw StateStoreError.invalidRecord(
                        "Content lease release precedes acquisition."
                    )
                }
                try connection.run(
                    """
                    UPDATE content_cache_leases
                    SET released_at = ?
                    WHERE id = ? AND fencing_token = ?
                      AND released_at IS NULL
                    """,
                    bindings: [
                        .text(releasedAt), .text(id),
                        .text(expectedFencingToken)
                    ]
                )
                return true
            }
        }
    }

    public func activeLeases(
        providerScope: String,
        digest: String? = nil,
        reference: String? = nil,
        currentTimestamp: String,
        limit: Int = 1_024
    ) throws -> [ContentCacheLeaseRecord] {
        try Self.validateProviderScope(providerScope)
        if let digest { try Self.validateDigest(digest) }
        if let reference { try Self.validateReference(reference) }
        try Self.validateTimestamp(currentTimestamp)
        try Self.validateLimit(limit)
        return try store.withValidatedConnection(readOnly: true) { connection in
            var filters = ["provider_scope = ?", "released_at IS NULL", "expires_at > ?"]
            var bindings: [SQLiteValue] = [
                .text(providerScope), .text(currentTimestamp)
            ]
            if let digest {
                filters.append("digest = ?")
                bindings.append(.text(digest))
            }
            if let reference {
                filters.append("reference = ?")
                bindings.append(.text(reference))
            }
            bindings.append(.int(limit))
            let rows = try connection.query(
                """
                SELECT id, provider_scope, digest, reference, mode,
                       owner_id, purpose, fencing_token, acquired_at,
                       expires_at, released_at
                FROM content_cache_leases
                WHERE \(filters.joined(separator: " AND "))
                ORDER BY expires_at, id
                LIMIT ?
                """,
                bindings: bindings
            )
            return try rows.map(Self.lease(from:))
        }
    }

    public func listContent(
        providerScope: String? = nil,
        kind: ContentCacheKind? = nil,
        limit: Int = 1_024
    ) throws -> [ContentCacheRecord] {
        if let providerScope {
            try Self.validateProviderScope(providerScope)
        }
        try Self.validateLimit(limit)
        return try store.withValidatedConnection(readOnly: true) { connection in
            var filters: [String] = []
            var bindings: [SQLiteValue] = []
            if let providerScope {
                filters.append("provider_scope = ?")
                bindings.append(.text(providerScope))
            }
            if let kind {
                filters.append("content_kind = ?")
                bindings.append(.text(kind.rawValue))
            }
            bindings.append(.int(limit))
            let predicate = filters.isEmpty
                ? ""
                : "WHERE \(filters.joined(separator: " AND "))"
            let rows = try connection.query(
                """
                SELECT provider_scope, digest, content_kind, size_bytes,
                       pin_policy, created_at, observed_at, last_used_at
                FROM content_cache_objects
                \(predicate)
                ORDER BY provider_scope, digest
                LIMIT ?
                """,
                bindings: bindings
            )
            return try rows.map(Self.content(from:))
        }
    }

    public func listReferences(
        providerScope: String,
        digest: String? = nil,
        limit: Int = 1_024
    ) throws -> [ContentCacheReferenceRecord] {
        try Self.validateProviderScope(providerScope)
        if let digest { try Self.validateDigest(digest) }
        try Self.validateLimit(limit)
        return try store.withValidatedConnection(readOnly: true) { connection in
            var bindings: [SQLiteValue] = [.text(providerScope)]
            let digestFilter: String
            if let digest {
                digestFilter = "AND digest = ?"
                bindings.append(.text(digest))
            } else {
                digestFilter = ""
            }
            bindings.append(.int(limit))
            let rows = try connection.query(
                """
                SELECT id, provider_scope, reference, digest,
                       ownership_operation_id, ownership_proof_sha256,
                       created_at, observed_at
                FROM content_cache_references
                WHERE provider_scope = ? \(digestFilter)
                ORDER BY reference, id
                LIMIT ?
                """,
                bindings: bindings
            )
            return try rows.map(Self.reference(from:))
        }
    }

    public func snapshot(
        providerScope: String? = nil,
        currentTimestamp: String,
        limit: Int = 1_024
    ) throws -> ContentCacheSnapshot {
        if let providerScope {
            try Self.validateProviderScope(providerScope)
        }
        try Self.validateTimestamp(currentTimestamp)
        try Self.validateLimit(limit)
        return try store.withValidatedConnection(readOnly: true) { connection in
            var scopePredicate = ""
            var contentBindings: [SQLiteValue] = []
            if let providerScope {
                scopePredicate = "WHERE provider_scope = ?"
                contentBindings.append(.text(providerScope))
            }
            contentBindings.append(.int(limit))
            let contentRows = try connection.query(
                """
                SELECT provider_scope, digest, content_kind, size_bytes,
                       pin_policy, created_at, observed_at, last_used_at
                FROM content_cache_objects
                \(scopePredicate)
                ORDER BY provider_scope, digest
                LIMIT ?
                """,
                bindings: contentBindings
            )
            let contents = try contentRows.map(Self.content(from:))
            var referenceBindings: [SQLiteValue] = []
            if let providerScope {
                referenceBindings.append(.text(providerScope))
            }
            referenceBindings.append(.int(limit))
            let referenceRows = try connection.query(
                """
                SELECT id, provider_scope, reference, digest,
                       ownership_operation_id, ownership_proof_sha256,
                       created_at, observed_at
                FROM content_cache_references
                \(scopePredicate)
                ORDER BY provider_scope, reference, id
                LIMIT ?
                """,
                bindings: referenceBindings
            )
            var leaseFilters = [
                "released_at IS NULL",
                "expires_at > ?"
            ]
            var leaseBindings: [SQLiteValue] = [.text(currentTimestamp)]
            if let providerScope {
                leaseFilters.append("provider_scope = ?")
                leaseBindings.append(.text(providerScope))
            }
            leaseBindings.append(.int(limit))
            let leaseRows = try connection.query(
                """
                SELECT id, provider_scope, digest, reference, mode,
                       owner_id, purpose, fencing_token, acquired_at,
                       expires_at, released_at
                FROM content_cache_leases
                WHERE \(leaseFilters.joined(separator: " AND "))
                ORDER BY provider_scope, expires_at, id
                LIMIT ?
                """,
                bindings: leaseBindings
            )
            let activeLeases = try leaseRows.map(Self.lease(from:))
            var aggregateBindings: [SQLiteValue] = []
            if let providerScope {
                aggregateBindings.append(.text(providerScope))
            }
            let aggregate = try connection.query(
                """
                SELECT
                    COALESCE(SUM(size_bytes), 0),
                    COALESCE(SUM(
                        CASE WHEN pin_policy = 'unpinned'
                        THEN 0 ELSE size_bytes END
                    ), 0)
                FROM content_cache_objects
                \(scopePredicate)
                """,
                bindings: aggregateBindings
            )
            guard let aggregateRow = aggregate.first,
                  aggregateRow.count == 2,
                  let totalValue = aggregateRow[0],
                  let totalBytes = Int64(totalValue),
                  let pinnedValue = aggregateRow[1],
                  let pinnedBytes = Int64(pinnedValue) else {
                throw StateStoreError.invalidRecord(
                    "Content cache aggregate accounting is malformed."
                )
            }
            return ContentCacheSnapshot(
                contents: contents,
                references: try referenceRows.map(Self.reference(from:)),
                activeLeases: activeLeases,
                totalBytes: totalBytes,
                pinnedBytes: pinnedBytes
            )
        }
    }

    public func status(
        providerScope: String? = nil,
        currentTimestamp: String,
        limit: Int = 1_024
    ) throws -> ContentCacheSnapshot {
        try snapshot(
            providerScope: providerScope,
            currentTimestamp: currentTimestamp,
            limit: limit
        )
    }

    public func removeContent(
        providerScope: String,
        digest: String,
        expectedKind: ContentCacheKind,
        expectedSizeBytes: Int64,
        expectedCreatedAt: String,
        exclusiveLeaseID: String,
        expectedFencingToken: String,
        removedAt: String
    ) throws -> Bool {
        try Self.validateProviderScope(providerScope)
        try Self.validateDigest(digest)
        guard expectedSizeBytes >= 0 else {
            throw StateStoreError.invalidRecord(
                "Expected content size cannot be negative."
            )
        }
        try Self.validateTimestamp(expectedCreatedAt)
        try Self.validateUUID(exclusiveLeaseID, field: "lease ID")
        try Self.validateUUID(
            expectedFencingToken,
            field: "lease fencing token"
        )
        try Self.validateTimestamp(removedAt)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let lease = try connection.query(
                    """
                    SELECT acquired_at FROM content_cache_leases
                    WHERE id = ? AND fencing_token = ?
                      AND provider_scope = ? AND digest = ?
                      AND mode = 'exclusive-delete'
                      AND released_at IS NULL AND expires_at > ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(exclusiveLeaseID),
                        .text(expectedFencingToken),
                        .text(providerScope), .text(digest),
                        .text(removedAt)
                    ]
                )
                guard !lease.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Exact active exclusive deletion lease is required."
                    )
                }
                let references = try connection.query(
                    """
                    SELECT 1 FROM content_cache_references
                    WHERE provider_scope = ? AND digest = ?
                    LIMIT 1
                    """,
                    bindings: [.text(providerScope), .text(digest)]
                )
                guard references.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Content became referenced while deletion was leased."
                    )
                }
                let content = try connection.query(
                    """
                    SELECT pin_policy FROM content_cache_objects
                    WHERE provider_scope = ? AND digest = ?
                      AND content_kind = ? AND size_bytes = ?
                      AND created_at = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(providerScope), .text(digest),
                        .text(expectedKind.rawValue),
                        .int64(expectedSizeBytes),
                        .text(expectedCreatedAt)
                    ]
                )
                guard let pinPolicy = content.first?.first ?? nil else {
                    return false
                }
                guard pinPolicy == ContentCachePinPolicy.unpinned.rawValue else {
                    throw StateStoreError.invalidRecord(
                        "Content became pinned while deletion was leased."
                    )
                }
                try connection.run(
                    """
                    DELETE FROM content_cache_objects
                    WHERE provider_scope = ? AND digest = ?
                      AND content_kind = ? AND size_bytes = ?
                      AND created_at = ? AND pin_policy = 'unpinned'
                    """,
                    bindings: [
                        .text(providerScope), .text(digest),
                        .text(expectedKind.rawValue),
                        .int64(expectedSizeBytes),
                        .text(expectedCreatedAt)
                    ]
                )
                try connection.run(
                    """
                    UPDATE content_cache_leases
                    SET released_at = ?
                    WHERE id = ? AND fencing_token = ?
                      AND released_at IS NULL
                    """,
                    bindings: [
                        .text(removedAt), .text(exclusiveLeaseID),
                        .text(expectedFencingToken)
                    ]
                )
                return true
            }
        }
    }

    static func upsert(
        _ record: ContentCacheRecord,
        on connection: SQLiteConnection
    ) throws {
        try validate(record)
        let existing = try connection.query(
            """
            SELECT content_kind, size_bytes, created_at, observed_at,
                   last_used_at
            FROM content_cache_objects
            WHERE provider_scope = ? AND digest = ?
            LIMIT 1
            """,
            bindings: [.text(record.providerScope), .text(record.digest)]
        )
        if let row = existing.first {
            guard row.count == 5,
                  row[0] == record.kind.rawValue,
                  row[1] == String(record.sizeBytes),
                  row[2] == record.createdAt,
                  let oldObserved = row[3],
                  let oldLastUsed = row[4],
                  date(record.observedAt) >= date(oldObserved),
                  date(record.lastUsedAt) >= date(oldLastUsed) else {
                throw StateStoreError.invalidRecord(
                    "Content digest already exists with different immutable or newer accounting."
                )
            }
            try connection.run(
                """
                UPDATE content_cache_objects
                SET pin_policy = ?, observed_at = ?, last_used_at = ?
                WHERE provider_scope = ? AND digest = ?
                """,
                bindings: [
                    .text(record.pinPolicy.rawValue),
                    .text(record.observedAt), .text(record.lastUsedAt),
                    .text(record.providerScope), .text(record.digest)
                ]
            )
            return
        }
        try connection.run(
            """
            INSERT INTO content_cache_objects (
                provider_scope, digest, content_kind, size_bytes,
                pin_policy, created_at, observed_at, last_used_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(record.providerScope), .text(record.digest),
                .text(record.kind.rawValue), .int64(record.sizeBytes),
                .text(record.pinPolicy.rawValue), .text(record.createdAt),
                .text(record.observedAt), .text(record.lastUsedAt)
            ]
        )
    }

    static func upsertObservedContent(
        providerScope: String,
        digest: String,
        kind: ContentCacheKind,
        sizeBytes: Int64,
        observedAt: String,
        on connection: SQLiteConnection
    ) throws {
        try refuseActiveExclusiveLease(
            providerScope: providerScope,
            digest: digest,
            reference: nil,
            currentTimestamp: observedAt,
            on: connection
        )
        let rows = try connection.query(
            """
            SELECT created_at, pin_policy
            FROM content_cache_objects
            WHERE provider_scope = ? AND digest = ?
            LIMIT 1
            """,
            bindings: [.text(providerScope), .text(digest)]
        )
        let createdAt = rows.first?.first.flatMap { $0 } ?? observedAt
        let pinPolicy = rows.first.flatMap { row in
            row.count == 2 ? row[1] : nil
        }.flatMap { $0 }.flatMap(ContentCachePinPolicy.init(rawValue:))
            ?? .unpinned
        try upsert(
            ContentCacheRecord(
                providerScope: providerScope,
                digest: digest,
                kind: kind,
                sizeBytes: sizeBytes,
                pinPolicy: pinPolicy,
                createdAt: createdAt,
                observedAt: observedAt,
                lastUsedAt: observedAt
            ),
            on: connection
        )
    }

    static func hasDeletionProtection(
        providerScope: String,
        digest: String,
        currentTimestamp: String,
        on connection: SQLiteConnection
    ) throws -> Bool {
        let rows = try connection.query(
            """
            SELECT 1
            WHERE EXISTS (
                SELECT 1 FROM content_cache_objects
                WHERE provider_scope = ? AND digest = ?
                  AND pin_policy != 'unpinned'
            ) OR EXISTS (
                SELECT 1 FROM content_cache_references
                WHERE provider_scope = ? AND digest = ?
            ) OR EXISTS (
                SELECT 1 FROM content_cache_leases
                WHERE provider_scope = ? AND digest = ?
                  AND released_at IS NULL AND expires_at > ?
            )
            LIMIT 1
            """,
            bindings: [
                .text(providerScope), .text(digest),
                .text(providerScope), .text(digest),
                .text(providerScope), .text(digest),
                .text(currentTimestamp)
            ]
        )
        return !rows.isEmpty
    }

    static func removeAccounting(
        providerScope: String,
        digest: String,
        expectedKind: ContentCacheKind,
        currentTimestamp: String,
        on connection: SQLiteConnection
    ) throws {
        try connection.run(
            """
            DELETE FROM content_cache_objects
            WHERE provider_scope = ? AND digest = ?
              AND content_kind = ?
              AND pin_policy = 'unpinned'
              AND NOT EXISTS (
                  SELECT 1 FROM content_cache_references
                  WHERE provider_scope = ? AND digest = ?
              )
              AND NOT EXISTS (
                  SELECT 1 FROM content_cache_leases
                  WHERE provider_scope = ? AND digest = ?
                    AND released_at IS NULL AND expires_at > ?
              )
            """,
            bindings: [
                .text(providerScope), .text(digest),
                .text(expectedKind.rawValue),
                .text(providerScope), .text(digest),
                .text(providerScope), .text(digest),
                .text(currentTimestamp)
            ]
        )
    }

    private static func activeLeaseConflicts(
        providerScope: String,
        digest: String,
        reference: String?,
        currentTimestamp: String,
        on connection: SQLiteConnection
    ) throws -> [String] {
        try connection.query(
            """
            SELECT mode FROM content_cache_leases
            WHERE provider_scope = ?
              AND released_at IS NULL AND expires_at > ?
              AND (
                  digest = ?
                  OR (? IS NOT NULL AND reference = ?)
              )
            ORDER BY id
            """,
            bindings: [
                .text(providerScope), .text(currentTimestamp),
                .text(digest), optionalText(reference),
                optionalText(reference)
            ]
        ).compactMap(\.first).compactMap { $0 }
    }

    private static func refuseActiveExclusiveLease(
        providerScope: String,
        digest: String,
        reference: String?,
        currentTimestamp: String,
        on connection: SQLiteConnection
    ) throws {
        let conflicts = try activeLeaseConflicts(
            providerScope: providerScope,
            digest: digest,
            reference: reference,
            currentTimestamp: currentTimestamp,
            on: connection
        )
        guard !conflicts.contains(
            ContentCacheLeaseMode.exclusiveDelete.rawValue
        ) else {
            throw StateStoreError.invalidRecord(
                "Active exclusive deletion lease prevents new content readers or references."
            )
        }
    }

    private static func content(
        from row: [String?]
    ) throws -> ContentCacheRecord {
        guard row.count == 8,
              let providerScope = row[0],
              let digest = row[1],
              let kindValue = row[2],
              let kind = ContentCacheKind(rawValue: kindValue),
              let sizeValue = row[3],
              let sizeBytes = Int64(sizeValue),
              let pinValue = row[4],
              let pinPolicy = ContentCachePinPolicy(rawValue: pinValue),
              let createdAt = row[5],
              let observedAt = row[6],
              let lastUsedAt = row[7] else {
            throw StateStoreError.invalidRecord(
                "Stored content cache accounting is malformed."
            )
        }
        let record = ContentCacheRecord(
            providerScope: providerScope,
            digest: digest,
            kind: kind,
            sizeBytes: sizeBytes,
            pinPolicy: pinPolicy,
            createdAt: createdAt,
            observedAt: observedAt,
            lastUsedAt: lastUsedAt
        )
        try validate(record)
        return record
    }

    private static func reference(
        from row: [String?]
    ) throws -> ContentCacheReferenceRecord {
        guard row.count == 8,
              let id = row[0],
              let providerScope = row[1],
              let reference = row[2],
              let digest = row[3],
              let operationID = row[4],
              let proof = row[5],
              let createdAt = row[6],
              let observedAt = row[7] else {
            throw StateStoreError.invalidRecord(
                "Stored content cache reference is malformed."
            )
        }
        let record = ContentCacheReferenceRecord(
            id: id,
            providerScope: providerScope,
            reference: reference,
            digest: digest,
            ownershipOperationID: operationID,
            ownershipProofSHA256: proof,
            createdAt: createdAt,
            observedAt: observedAt
        )
        try validate(record)
        return record
    }

    private static func lease(
        from row: [String?]
    ) throws -> ContentCacheLeaseRecord {
        guard row.count == 11,
              let id = row[0],
              let providerScope = row[1],
              let digest = row[2],
              let modeValue = row[4],
              let mode = ContentCacheLeaseMode(rawValue: modeValue),
              let ownerID = row[5],
              let purpose = row[6],
              let fencingToken = row[7],
              let acquiredAt = row[8],
              let expiresAt = row[9] else {
            throw StateStoreError.invalidRecord(
                "Stored content cache lease is malformed."
            )
        }
        return ContentCacheLeaseRecord(
            id: id,
            providerScope: providerScope,
            digest: digest,
            reference: row[3],
            mode: mode,
            ownerID: ownerID,
            purpose: purpose,
            fencingToken: fencingToken,
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            releasedAt: row[10]
        )
    }

    private static func validate(_ record: ContentCacheRecord) throws {
        try validateProviderScope(record.providerScope)
        try validateDigest(record.digest)
        guard (0...1_099_511_627_776).contains(record.sizeBytes) else {
            throw StateStoreError.invalidRecord(
                "Content size must be between zero and one tebibyte."
            )
        }
        try validateTimestamp(record.createdAt)
        try validateTimestamp(record.observedAt)
        try validateTimestamp(record.lastUsedAt)
        guard date(record.observedAt) >= date(record.createdAt),
              date(record.lastUsedAt) >= date(record.createdAt) else {
            throw StateStoreError.invalidRecord(
                "Content observation and use cannot precede creation."
            )
        }
    }

    private static func validate(
        _ record: ContentCacheReferenceRecord
    ) throws {
        try validateUUID(record.id, field: "reference ID")
        try validateProviderScope(record.providerScope)
        try validateReference(record.reference)
        try validateDigest(record.digest)
        try validateUUID(
            record.ownershipOperationID,
            field: "ownership operation ID"
        )
        try validateSHA256(
            record.ownershipProofSHA256,
            field: "ownership proof"
        )
        try validateTimestamp(record.createdAt)
        try validateTimestamp(record.observedAt)
        guard date(record.observedAt) >= date(record.createdAt) else {
            throw StateStoreError.invalidRecord(
                "Content reference observation cannot precede creation."
            )
        }
    }

    private static func validateProviderScope(_ value: String) throws {
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
        )
        guard (1...256).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy(allowed.contains),
              value.first?.isLetter == true || value.first?.isNumber == true else {
            throw StateStoreError.invalidRecord(
                "Provider scope must be a bounded explicit identifier."
            )
        }
    }

    private static func validateDigest(_ value: String) throws {
        guard value.count == 71,
              value.hasPrefix("sha256:"),
              value.dropFirst(7).allSatisfy({
                  ("0"..."9").contains($0)
                    || ("a"..."f").contains($0)
              }) else {
            throw StateStoreError.invalidRecord(
                "Content digest must be an exact lowercase sha256 digest."
            )
        }
    }

    private static func validateReference(_ value: String) throws {
        guard (1...1_024).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw StateStoreError.invalidRecord(
                "Content reference must be bounded and contain no control characters."
            )
        }
    }

    private static func validateBoundedToken(
        _ value: String,
        field: String
    ) throws {
        guard (1...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw StateStoreError.invalidRecord(
                "\(field) must be a bounded printable ASCII value."
            )
        }
    }

    private static func validateUUID(
        _ value: String,
        field: String
    ) throws {
        guard value.utf8.count == 36,
              UUID(uuidString: value)?.uuidString.lowercased() == value else {
            throw StateStoreError.invalidRecord(
                "\(field) must be an exact UUID."
            )
        }
    }

    private static func validateSHA256(
        _ value: String,
        field: String
    ) throws {
        guard value.count == 64,
              value.allSatisfy({
                  ("0"..."9").contains($0)
                    || ("a"..."f").contains($0)
              }) else {
            throw StateStoreError.invalidRecord(
                "\(field) must be a lowercase sha256 proof."
            )
        }
    }

    private static func validateTimestamp(_ value: String) throws {
        guard value.utf8.count <= 64, parsedDate(value) != nil else {
            throw StateStoreError.invalidRecord(
                "Content cache timestamp must be ISO-8601."
            )
        }
    }

    private static func validateLimit(_ value: Int) throws {
        guard (1...1_024).contains(value) else {
            throw StateStoreError.invalidRecord(
                "Content cache query limit must be between 1 and 1024."
            )
        }
    }

    private static func parsedDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? whole.date(from: value)
    }

    private static func date(_ value: String) -> Date {
        parsedDate(value)!
    }

    private static func optionalText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }
}
