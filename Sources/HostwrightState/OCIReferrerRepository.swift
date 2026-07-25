import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRegistry

public struct OCIReferrerRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func saveGraph(
        _ graph: OCIReferrerGraph,
        publicationEvidence:
            [OCIContentDigest: OCIReferrerPublicationEvidence] = [:],
        observedAt: String
    ) throws -> OCIReferrerDiscoveryRecord {
        try validateTimestamp(observedAt)
        let rootDigests = Set(graph.verifiedReferrers.map(\.digest))
        guard Set(publicationEvidence.keys).isSubset(of: rootDigests) else {
            throw StateStoreError.invalidRecord(
                "OCI publication evidence must identify a verified root referrer."
            )
        }
        for evidence in publicationEvidence.values {
            guard validSHA256(evidence.ownershipProofSHA256),
                  HostwrightResourceUUID.isValid(
                      evidence.operationGroupID
                  ) else {
                throw StateStoreError.invalidRecord(
                    "OCI publication evidence requires an exact proof and operation group."
                )
            }
        }

        let graphSHA256 = try graphDigest(graph)
        let identity = [
            graph.discovery.endpoint.canonicalURLString,
            graph.discovery.repository.value,
            graph.discovery.subjectDigest.canonicalValue,
            graphSHA256
        ].joined(separator: "\u{1f}")
        let discovery = OCIReferrerDiscoveryRecord(
            id: HostwrightResourceUUID.legacy(
                kind: "oci-referrer-discovery",
                identifier: identity
            ),
            registryEndpoint:
                graph.discovery.endpoint.canonicalURLString,
            repository: graph.discovery.repository.value,
            subjectDigest:
                graph.discovery.subjectDigest.canonicalValue,
            artifactType: graph.discovery.artifactType?.value,
            discoveryMode: graph.discovery.mode.rawValue,
            serverFilterApplied:
                graph.discovery.serverFilterApplied,
            pageCount: graph.discovery.pageCount,
            descriptorCount: graph.verifiedReferrers.count,
            graphSHA256: graphSHA256,
            etag: graph.discovery.etag,
            complete: true,
            observedAt: observedAt
        )
        try validate(discovery)

        try store.withValidatedConnection { connection in
            try connection.transaction {
                try upsert(discovery, on: connection)
                for object in graph.objects {
                    try upsert(
                        object,
                        observedAt: observedAt,
                        on: connection
                    )
                    try ContentCacheRepository.upsertObservedContent(
                        providerScope: Self.contentCacheProviderScope,
                        digest: object.digest.canonicalValue,
                        kind: .ociCacheObject,
                        sizeBytes: Int64(object.size),
                        observedAt: observedAt,
                        on: connection
                    )
                }
                for descriptor in graph.verifiedReferrers {
                    try upsert(
                        descriptor,
                        discovery: discovery,
                        observedAt: observedAt,
                        on: connection
                    )
                    for object in graph.objects {
                        try connection.run(
                            """
                            INSERT OR IGNORE INTO oci_referrer_graph_objects (
                                discovery_id, referrer_digest, object_digest
                            )
                            VALUES (?, ?, ?)
                            """,
                            bindings: [
                                .text(discovery.id),
                                .text(
                                    descriptor.digest.canonicalValue
                                ),
                                .text(object.digest.canonicalValue)
                            ]
                        )
                    }
                    if let evidence =
                        publicationEvidence[descriptor.digest] {
                        try upsertPublication(
                            descriptor: descriptor,
                            discovery: discovery,
                            evidence: evidence,
                            observedAt: observedAt,
                            on: connection
                        )
                    }
                }
            }
        }
        return discovery
    }

    public func loadDiscovery(
        id: String
    ) throws -> OCIReferrerDiscoveryRecord? {
        guard HostwrightResourceUUID.isValid(id) else {
            throw StateStoreError.invalidRecord(
                "OCI discovery lookup requires an exact UUID."
            )
        }
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            try loadDiscovery(id: id, on: connection)
        }
    }

    public func loadObjects(
        discoveryID: String
    ) throws -> [OCIReferrerCachedObjectRecord] {
        guard HostwrightResourceUUID.isValid(discoveryID) else {
            throw StateStoreError.invalidRecord(
                "OCI cache lookup requires an exact discovery UUID."
            )
        }
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            let rows = try connection.query(
                """
                SELECT DISTINCT cache.digest, cache.media_type,
                       cache.size_bytes, cache.object_kind,
                       cache.payload_base64, cache.payload_sha256,
                       cache.children_json, cache.created_at,
                       cache.last_accessed_at
                FROM oci_referrer_cache_objects AS cache
                JOIN oci_referrer_graph_objects AS graph
                  ON graph.object_digest = cache.digest
                WHERE graph.discovery_id = ?
                ORDER BY cache.digest
                """,
                bindings: [.text(discoveryID)]
            )
            return try rows.map(cachedObject(from:))
        }
    }

    public func loadGraph(
        discoveryID: String
    ) throws -> OCIReferrerGraph? {
        guard HostwrightResourceUUID.isValid(discoveryID) else {
            throw StateStoreError.invalidRecord(
                "OCI graph lookup requires an exact discovery UUID."
            )
        }
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            guard let record = try loadDiscovery(
                id: discoveryID,
                on: connection
            ) else {
                return nil
            }
            let descriptorRows = try connection.query(
                """
                SELECT media_type, referrer_digest, size_bytes,
                       artifact_type, annotations_json
                FROM oci_referrers
                WHERE discovery_id = ? AND verified_subject = 1
                ORDER BY referrer_digest
                """,
                bindings: [.text(discoveryID)]
            )
            let descriptors = try descriptorRows.map(
                descriptor(from:)
            )
            guard descriptors.count == record.descriptorCount else {
                throw StateStoreError.invalidRecord(
                    "OCI graph descriptor count no longer matches its discovery proof."
                )
            }
            let objectRows = try connection.query(
                """
                SELECT DISTINCT cache.digest, cache.media_type,
                       cache.size_bytes, cache.object_kind,
                       cache.payload_base64, cache.payload_sha256,
                       cache.children_json, cache.created_at,
                       cache.last_accessed_at
                FROM oci_referrer_cache_objects AS cache
                JOIN oci_referrer_graph_objects AS graph
                  ON graph.object_digest = cache.digest
                WHERE graph.discovery_id = ?
                ORDER BY cache.digest
                """,
                bindings: [.text(discoveryID)]
            )
            let cached = try objectRows.map(cachedObject(from:))
            let objects = try cached.map(fetchedObject(from:))
            let discovery = OCIReferrerDiscoveryResult(
                endpoint: try RegistryEndpoint(
                    record.registryEndpoint
                ),
                repository: try OCIRepositoryName(
                    record.repository
                ),
                subjectDigest: try OCIContentDigest(
                    record.subjectDigest
                ),
                artifactType: try record.artifactType.map(
                    OCIArtifactType.init
                ),
                mode: OCIReferrerDiscoveryMode(
                    rawValue: record.discoveryMode
                )!,
                serverFilterApplied:
                    record.serverFilterApplied,
                pageCount: record.pageCount,
                descriptors: descriptors,
                etag: record.etag
            )
            let graph = try OCIReferrerGraph(
                discovery: discovery,
                verifiedReferrers: descriptors,
                objects: objects
            )
            guard try graphDigest(graph) == record.graphSHA256 else {
                throw StateStoreError.invalidRecord(
                    "OCI graph content no longer matches its stored proof."
                )
            }
            return graph
        }
    }

    public func latestDiscovery(
        endpoint: String,
        repository: String,
        subjectDigest: String,
        artifactType: String?
    ) throws -> OCIReferrerDiscoveryRecord? {
        _ = try RegistryEndpoint(endpoint)
        _ = try OCIRepositoryName(repository)
        _ = try OCIContentDigest(subjectDigest)
        _ = try artifactType.map(OCIArtifactType.init)
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            let rows = try connection.query(
                """
                SELECT id, registry_endpoint, repository, subject_digest,
                       artifact_type, discovery_mode,
                       server_filter_applied, page_count,
                       descriptor_count, graph_sha256, etag,
                       complete, observed_at
                FROM oci_referrer_discoveries
                WHERE registry_endpoint = ? AND repository = ?
                  AND subject_digest = ? AND complete = 1
                  AND (
                    (artifact_type IS NULL AND ? IS NULL)
                    OR artifact_type = ?
                  )
                ORDER BY observed_at DESC, id DESC
                LIMIT 1
                """,
                bindings: [
                    .text(endpoint),
                    .text(repository),
                    .text(subjectDigest),
                    optionalText(artifactType),
                    optionalText(artifactType)
                ]
            )
            return try rows.first.map(discovery(from:))
        }
    }

    public func acquireRetentionLease(
        discoveryID: String,
        ownerID: String,
        acquiredAt: String,
        expiresAt: String
    ) throws -> OCIReferrerRetentionLeaseRecord {
        guard HostwrightResourceUUID.isValid(discoveryID),
              ownerID.range(
                  of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,127})$",
                  options: .regularExpression
              ) != nil else {
            throw StateStoreError.invalidRecord(
                "OCI retention lease identity is invalid."
            )
        }
        try validateTimestamp(acquiredAt)
        try validateTimestamp(expiresAt)
        guard expiresAt > acquiredAt else {
            throw StateStoreError.invalidRecord(
                "OCI retention lease expiry must be after acquisition."
            )
        }
        let lease = OCIReferrerRetentionLeaseRecord(
            id: HostwrightResourceUUID.generate(),
            discoveryID: discoveryID,
            ownerID: ownerID,
            fencingToken: HostwrightResourceUUID.generate(),
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            releasedAt: nil
        )
        try store.withValidatedConnection { connection in
            try connection.transaction {
                guard try loadDiscovery(
                    id: discoveryID,
                    on: connection
                ) != nil else {
                    throw StateStoreError.notFound(
                        "OCI referrer discovery does not exist."
                    )
                }
                try connection.run(
                    """
                    INSERT INTO oci_referrer_retention_leases (
                        id, discovery_id, owner_id, fencing_token,
                        acquired_at, expires_at, released_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """,
                    bindings: [
                        .text(lease.id),
                        .text(lease.discoveryID),
                        .text(lease.ownerID),
                        .text(lease.fencingToken),
                        .text(lease.acquiredAt),
                        .text(lease.expiresAt)
                    ]
                )
            }
        }
        return lease
    }

    public func releaseRetentionLease(
        id: String,
        expectedFencingToken: String,
        releasedAt: String
    ) throws -> Bool {
        guard HostwrightResourceUUID.isValid(id),
              HostwrightResourceUUID.isValid(
                  expectedFencingToken
              ) else {
            throw StateStoreError.invalidRecord(
                "OCI retention release requires exact UUID evidence."
            )
        }
        try validateTimestamp(releasedAt)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT fencing_token, released_at
                    FROM oci_referrer_retention_leases
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(id)]
                )
                guard rows.count == 1,
                      rows[0][0] ==
                        expectedFencingToken.lowercased(),
                      rows[0][1] == nil else {
                    return false
                }
                try connection.run(
                    """
                    UPDATE oci_referrer_retention_leases
                    SET released_at = ?
                    WHERE id = ? AND fencing_token = ?
                      AND released_at IS NULL
                    """,
                    bindings: [
                        .text(releasedAt),
                        .text(id),
                        .text(expectedFencingToken.lowercased())
                    ]
                )
                return true
            }
        }
    }

    public func loadRetentionLeases(
        discoveryID: String
    ) throws -> [OCIReferrerRetentionLeaseRecord] {
        guard HostwrightResourceUUID.isValid(discoveryID) else {
            throw StateStoreError.invalidRecord(
                "OCI retention lease lookup requires an exact discovery UUID."
            )
        }
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            let rows = try connection.query(
                """
                SELECT id, discovery_id, owner_id, fencing_token,
                       acquired_at, expires_at, released_at
                FROM oci_referrer_retention_leases
                WHERE discovery_id = ?
                ORDER BY acquired_at ASC, id ASC
                """,
                bindings: [.text(discoveryID)]
            )
            return try rows.map(retentionLease(from:))
        }
    }

    public func hasActiveRetentionLease(
        discoveryID: String,
        currentTimestamp: String
    ) throws -> Bool {
        guard HostwrightResourceUUID.isValid(discoveryID) else {
            throw StateStoreError.invalidRecord(
                "OCI retention lease lookup requires an exact discovery UUID."
            )
        }
        try validateTimestamp(currentTimestamp)
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            let rows = try connection.query(
                """
                SELECT 1
                FROM oci_referrer_retention_leases
                WHERE discovery_id = ? AND released_at IS NULL
                  AND expires_at > ?
                LIMIT 1
                """,
                bindings: [
                    .text(discoveryID),
                    .text(currentTimestamp)
                ]
            )
            return !rows.isEmpty
        }
    }

    public func removeDiscovery(
        id: String,
        expectedGraphSHA256: String,
        currentTimestamp: String
    ) throws -> Bool {
        guard HostwrightResourceUUID.isValid(id),
              validSHA256(expectedGraphSHA256) else {
            throw StateStoreError.invalidRecord(
                "OCI discovery removal requires exact identity and graph proof."
            )
        }
        try validateTimestamp(currentTimestamp)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT graph_sha256
                    FROM oci_referrer_discoveries
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(id)]
                )
                guard let graph = rows.first?.first ?? nil else {
                    return false
                }
                guard graph == expectedGraphSHA256 else {
                    throw StateStoreError.invalidRecord(
                        "OCI discovery graph proof no longer matches."
                    )
                }
                let leases = try connection.query(
                    """
                    SELECT id
                    FROM oci_referrer_retention_leases
                    WHERE discovery_id = ?
                      AND released_at IS NULL
                      AND expires_at > ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(id),
                        .text(currentTimestamp)
                    ]
                )
                guard leases.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "OCI discovery is protected by an active retention lease."
                    )
                }
                try connection.run(
                    "DELETE FROM oci_referrer_discoveries WHERE id = ? AND graph_sha256 = ?",
                    bindings: [
                        .text(id),
                        .text(expectedGraphSHA256)
                    ]
                )
                return true
            }
        }
    }

    public func pruneUnreferencedCache(
        maximumObjects: Int = 1_024,
        currentTimestamp: String = ISO8601DateFormatter()
            .string(from: Date())
    ) throws -> [String] {
        guard (1...1_024).contains(maximumObjects) else {
            throw StateStoreError.invalidRecord(
                "OCI cache prune requires a bounded exact limit."
            )
        }
        try validateTimestamp(currentTimestamp)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT cache.digest
                    FROM oci_referrer_cache_objects AS cache
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM oci_referrer_graph_objects AS graph
                        WHERE graph.object_digest = cache.digest
                    )
                      AND NOT EXISTS (
                        SELECT 1
                        FROM content_cache_objects AS accounting
                        WHERE accounting.provider_scope = ?
                          AND accounting.digest = cache.digest
                          AND accounting.pin_policy != 'unpinned'
                      )
                      AND NOT EXISTS (
                        SELECT 1
                        FROM content_cache_leases AS lease
                        WHERE lease.provider_scope = ?
                          AND lease.digest = cache.digest
                          AND lease.released_at IS NULL
                          AND lease.expires_at > ?
                      )
                    ORDER BY cache.digest
                    LIMIT ?
                    """,
                    bindings: [
                        .text(Self.contentCacheProviderScope),
                        .text(Self.contentCacheProviderScope),
                        .text(currentTimestamp),
                        .int(maximumObjects)
                    ]
                )
                let digests = rows.compactMap(\.first)
                    .compactMap { $0 }
                var removed: [String] = []
                for digest in digests {
                    guard try !ContentCacheRepository
                        .hasDeletionProtection(
                            providerScope:
                                Self.contentCacheProviderScope,
                            digest: digest,
                            currentTimestamp: currentTimestamp,
                            on: connection
                        ) else {
                        continue
                    }
                    try connection.run(
                        """
                        DELETE FROM oci_referrer_cache_objects
                        WHERE digest = ?
                          AND NOT EXISTS (
                              SELECT 1
                              FROM oci_referrer_graph_objects
                              WHERE object_digest = ?
                          )
                        """,
                        bindings: [.text(digest), .text(digest)]
                    )
                    let remains = try connection.query(
                        """
                        SELECT 1 FROM oci_referrer_cache_objects
                        WHERE digest = ?
                        LIMIT 1
                        """,
                        bindings: [.text(digest)]
                    )
                    guard remains.isEmpty else { continue }
                    try ContentCacheRepository.removeAccounting(
                        providerScope:
                            Self.contentCacheProviderScope,
                        digest: digest,
                        expectedKind: .ociCacheObject,
                        currentTimestamp: currentTimestamp,
                        on: connection
                    )
                    let accountingRemains = try connection.query(
                        """
                        SELECT 1 FROM content_cache_objects
                        WHERE provider_scope = ? AND digest = ?
                        LIMIT 1
                        """,
                        bindings: [
                            .text(Self.contentCacheProviderScope),
                            .text(digest)
                        ]
                    )
                    guard accountingRemains.isEmpty else {
                        throw StateStoreError.invalidRecord(
                            "OCI cache accounting changed during exact prune."
                        )
                    }
                    removed.append(digest)
                }
                return removed
            }
        }
    }

    public func loadPublication(
        endpoint: String,
        repository: String,
        subjectDigest: String,
        referrerDigest: String
    ) throws -> OCIReferrerPublicationRecord? {
        _ = try RegistryEndpoint(endpoint)
        _ = try OCIRepositoryName(repository)
        _ = try OCIContentDigest(subjectDigest)
        _ = try OCIContentDigest(referrerDigest)
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            let rows = try connection.query(
                """
                SELECT id, registry_endpoint, repository,
                       subject_digest, referrer_digest,
                       ownership_proof_sha256, operation_group_id,
                       cleanup_eligible, created_at, observed_at
                FROM oci_referrer_publications
                WHERE registry_endpoint = ? AND repository = ?
                  AND subject_digest = ? AND referrer_digest = ?
                LIMIT 1
                """,
                bindings: [
                    .text(endpoint),
                    .text(repository),
                    .text(subjectDigest),
                    .text(referrerDigest)
                ]
            )
            return try rows.first.map(publication(from:))
        }
    }

    public func markPublicationCleaned(
        endpoint: String,
        repository: String,
        subjectDigest: String,
        referrerDigest: String,
        expectedOwnershipProofSHA256: String,
        observedAt: String
    ) throws -> Bool {
        _ = try RegistryEndpoint(endpoint)
        _ = try OCIRepositoryName(repository)
        _ = try OCIContentDigest(subjectDigest)
        _ = try OCIContentDigest(referrerDigest)
        guard validSHA256(expectedOwnershipProofSHA256) else {
            throw StateStoreError.invalidRecord(
                "OCI cleanup requires the exact ownership proof."
            )
        }
        try validateTimestamp(observedAt)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT ownership_proof_sha256, cleanup_eligible
                    FROM oci_referrer_publications
                    WHERE registry_endpoint = ? AND repository = ?
                      AND subject_digest = ? AND referrer_digest = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(endpoint),
                        .text(repository),
                        .text(subjectDigest),
                        .text(referrerDigest)
                    ]
                )
                guard let row = rows.first,
                      row[0] == expectedOwnershipProofSHA256 else {
                    return false
                }
                if row[1] == "0" {
                    return true
                }
                try connection.run(
                    """
                    UPDATE oci_referrer_publications
                    SET cleanup_eligible = 0, observed_at = ?
                    WHERE registry_endpoint = ? AND repository = ?
                      AND subject_digest = ? AND referrer_digest = ?
                      AND ownership_proof_sha256 = ?
                      AND cleanup_eligible = 1
                    """,
                    bindings: [
                        .text(observedAt),
                        .text(endpoint),
                        .text(repository),
                        .text(subjectDigest),
                        .text(referrerDigest),
                        .text(expectedOwnershipProofSHA256)
                    ]
                )
                let verified = try connection.query(
                    """
                    SELECT cleanup_eligible
                    FROM oci_referrer_publications
                    WHERE registry_endpoint = ? AND repository = ?
                      AND subject_digest = ? AND referrer_digest = ?
                      AND ownership_proof_sha256 = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(endpoint),
                        .text(repository),
                        .text(subjectDigest),
                        .text(referrerDigest),
                        .text(expectedOwnershipProofSHA256)
                    ]
                )
                return verified.first?.first == "0"
            }
        }
    }

    private func upsert(
        _ discovery: OCIReferrerDiscoveryRecord,
        on connection: SQLiteConnection
    ) throws {
        try connection.run(
            """
            INSERT INTO oci_referrer_discoveries (
                id, registry_endpoint, repository, subject_digest,
                artifact_type, discovery_mode, server_filter_applied,
                page_count, descriptor_count, graph_sha256, etag,
                complete, observed_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                etag = excluded.etag,
                observed_at = excluded.observed_at,
                complete = excluded.complete
            """,
            bindings: [
                .text(discovery.id),
                .text(discovery.registryEndpoint),
                .text(discovery.repository),
                .text(discovery.subjectDigest),
                optionalText(discovery.artifactType),
                .text(discovery.discoveryMode),
                .bool(discovery.serverFilterApplied),
                .int(discovery.pageCount),
                .int(discovery.descriptorCount),
                .text(discovery.graphSHA256),
                optionalText(discovery.etag),
                .bool(discovery.complete),
                .text(discovery.observedAt)
            ]
        )
    }

    private func upsert(
        _ object: OCIReferrerFetchedObject,
        observedAt: String,
        on connection: SQLiteConnection
    ) throws {
        let payloadSHA256 = sha256(object.payload)
        let payloadBase64 = object.payload.base64EncodedString()
        let childrenJSON = try encodeChildren(
            object.childDescriptors
        )
        let rows = try connection.query(
            """
            SELECT media_type, size_bytes, object_kind,
                   payload_base64, payload_sha256, children_json
            FROM oci_referrer_cache_objects
            WHERE digest = ?
            LIMIT 1
            """,
            bindings: [.text(object.digest.canonicalValue)]
        )
        if let row = rows.first {
            guard row.count == 6,
                  row[0] == object.mediaType,
                  row[1] == String(object.size),
                  row[2] == object.kind.rawValue,
                  row[3] == payloadBase64,
                  row[4] == payloadSHA256,
                  row[5] == childrenJSON else {
                throw StateStoreError.invalidRecord(
                    "OCI cache digest already exists with different immutable content."
                )
            }
            try connection.run(
                """
                UPDATE oci_referrer_cache_objects
                SET last_accessed_at = ?
                WHERE digest = ?
                """,
                bindings: [
                    .text(observedAt),
                    .text(object.digest.canonicalValue)
                ]
            )
            return
        }
        try connection.run(
            """
            INSERT INTO oci_referrer_cache_objects (
                digest, media_type, size_bytes, object_kind,
                payload_base64, payload_sha256, children_json,
                created_at, last_accessed_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(object.digest.canonicalValue),
                .text(object.mediaType),
                .int(object.size),
                .text(object.kind.rawValue),
                .text(payloadBase64),
                .text(payloadSHA256),
                .text(childrenJSON),
                .text(observedAt),
                .text(observedAt)
            ]
        )
    }

    private func upsert(
        _ descriptor: OCIReferrerDescriptor,
        discovery: OCIReferrerDiscoveryRecord,
        observedAt: String,
        on connection: SQLiteConnection
    ) throws {
        let id = HostwrightResourceUUID.legacy(
            kind: "oci-referrer",
            identifier: [
                discovery.id,
                descriptor.digest.canonicalValue
            ].joined(separator: "\u{1f}")
        )
        try connection.run(
            """
            INSERT INTO oci_referrers (
                id, discovery_id, registry_endpoint, repository,
                subject_digest, referrer_digest, media_type,
                artifact_type, size_bytes, annotations_json,
                verified_subject, observed_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(id) DO UPDATE SET
                annotations_json = excluded.annotations_json,
                observed_at = excluded.observed_at
            """,
            bindings: [
                .text(id),
                .text(discovery.id),
                .text(discovery.registryEndpoint),
                .text(discovery.repository),
                .text(discovery.subjectDigest),
                .text(descriptor.digest.canonicalValue),
                .text(descriptor.mediaType),
                optionalText(descriptor.artifactType?.value),
                .int(descriptor.size),
                .text(try encodeAnnotations(descriptor.annotations)),
                .text(observedAt)
            ]
        )
    }

    private func upsertPublication(
        descriptor: OCIReferrerDescriptor,
        discovery: OCIReferrerDiscoveryRecord,
        evidence: OCIReferrerPublicationEvidence,
        observedAt: String,
        on connection: SQLiteConnection
    ) throws {
        let groups = try connection.query(
            """
            SELECT id
            FROM operation_groups
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(evidence.operationGroupID)]
        )
        guard groups.count == 1 else {
            throw StateStoreError.invalidRecord(
                "OCI publication ownership requires its exact durable operation group."
            )
        }
        let existing = try connection.query(
            """
            SELECT ownership_proof_sha256, operation_group_id
            FROM oci_referrer_publications
            WHERE registry_endpoint = ? AND repository = ?
              AND subject_digest = ? AND referrer_digest = ?
            LIMIT 1
            """,
            bindings: [
                .text(discovery.registryEndpoint),
                .text(discovery.repository),
                .text(discovery.subjectDigest),
                .text(descriptor.digest.canonicalValue)
            ]
        )
        if let row = existing.first {
            guard row[0] == evidence.ownershipProofSHA256,
                  row[1] == evidence.operationGroupID else {
                throw StateStoreError.invalidRecord(
                    "OCI publication ownership proof is immutable."
                )
            }
            try connection.run(
                """
                UPDATE oci_referrer_publications
                SET observed_at = ?
                WHERE registry_endpoint = ? AND repository = ?
                  AND subject_digest = ? AND referrer_digest = ?
                """,
                bindings: [
                    .text(observedAt),
                    .text(discovery.registryEndpoint),
                    .text(discovery.repository),
                    .text(discovery.subjectDigest),
                    .text(descriptor.digest.canonicalValue)
                ]
            )
            return
        }
        let id = HostwrightResourceUUID.legacy(
            kind: "oci-referrer-publication",
            identifier: [
                discovery.registryEndpoint,
                discovery.repository,
                discovery.subjectDigest,
                descriptor.digest.canonicalValue
            ].joined(separator: "\u{1f}")
        )
        try connection.run(
            """
            INSERT INTO oci_referrer_publications (
                id, registry_endpoint, repository, subject_digest,
                referrer_digest, ownership_proof_sha256,
                operation_group_id, cleanup_eligible,
                created_at, observed_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """,
            bindings: [
                .text(id),
                .text(discovery.registryEndpoint),
                .text(discovery.repository),
                .text(discovery.subjectDigest),
                .text(descriptor.digest.canonicalValue),
                .text(evidence.ownershipProofSHA256),
                .text(evidence.operationGroupID),
                .text(observedAt),
                .text(observedAt)
            ]
        )
    }

    private func loadDiscovery(
        id: String,
        on connection: SQLiteConnection
    ) throws -> OCIReferrerDiscoveryRecord? {
        let rows = try connection.query(
            """
            SELECT id, registry_endpoint, repository, subject_digest,
                   artifact_type, discovery_mode, server_filter_applied,
                   page_count, descriptor_count, graph_sha256, etag,
                   complete, observed_at
            FROM oci_referrer_discoveries
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        )
        return try rows.first.map(discovery(from:))
    }

    private func discovery(
        from row: [String?]
    ) throws -> OCIReferrerDiscoveryRecord {
        guard row.count == 13,
              let id = row[0],
              let endpoint = row[1],
              let repository = row[2],
              let subject = row[3],
              let mode = row[5],
              let filterText = row[6],
              let filter = Int(filterText),
              let pageText = row[7],
              let pageCount = Int(pageText),
              let descriptorText = row[8],
              let descriptorCount = Int(descriptorText),
              let graphSHA256 = row[9],
              let completeText = row[11],
              let complete = Int(completeText),
              let observedAt = row[12] else {
            throw StateStoreError.invalidRecord(
                "Could not decode OCI referrer discovery."
            )
        }
        let record = OCIReferrerDiscoveryRecord(
            id: id,
            registryEndpoint: endpoint,
            repository: repository,
            subjectDigest: subject,
            artifactType: row[4],
            discoveryMode: mode,
            serverFilterApplied: filter == 1,
            pageCount: pageCount,
            descriptorCount: descriptorCount,
            graphSHA256: graphSHA256,
            etag: row[10],
            complete: complete == 1,
            observedAt: observedAt
        )
        try validate(record)
        return record
    }

    private func cachedObject(
        from row: [String?]
    ) throws -> OCIReferrerCachedObjectRecord {
        guard row.count == 9,
              let digestValue = row[0],
              let mediaType = row[1],
              let sizeText = row[2],
              let size = Int(sizeText),
              let kindValue = row[3],
              let payloadBase64 = row[4],
              let payload = Data(base64Encoded: payloadBase64),
              payload.base64EncodedString() == payloadBase64,
              let payloadSHA256 = row[5],
              let childrenJSON = row[6],
              let createdAt = row[7],
              let lastAccessedAt = row[8],
              let kind = OCIReferrerObjectKind(rawValue: kindValue) else {
            throw StateStoreError.invalidRecord(
                "Could not decode OCI referrer cache object."
            )
        }
        let digest: OCIContentDigest
        let children: [OCIContentDescriptor]
        do {
            digest = try OCIContentDigest(digestValue)
            children = try JSONDecoder().decode(
                [OCIContentDescriptor].self,
                from: Data(childrenJSON.utf8)
            )
            _ = try OCIReferrerFetchedObject(
                digest: digest,
                mediaType: mediaType,
                size: size,
                kind: kind,
                payload: payload,
                childDescriptors: children
            )
        } catch {
            throw StateStoreError.invalidRecord(
                "OCI referrer cache content failed digest validation."
            )
        }
        guard sha256(payload) == payloadSHA256 else {
            throw StateStoreError.invalidRecord(
                "OCI referrer cache payload proof does not match."
            )
        }
        return OCIReferrerCachedObjectRecord(
            digest: digestValue,
            mediaType: mediaType,
            size: size,
            objectKind: kindValue,
            payload: payload,
            payloadSHA256: payloadSHA256,
            childrenJSON: childrenJSON,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt
        )
    }

    private func fetchedObject(
        from record: OCIReferrerCachedObjectRecord
    ) throws -> OCIReferrerFetchedObject {
        do {
            return try OCIReferrerFetchedObject(
                digest: OCIContentDigest(record.digest),
                mediaType: record.mediaType,
                size: record.size,
                kind: OCIReferrerObjectKind(
                    rawValue: record.objectKind
                )!,
                payload: record.payload,
                childDescriptors: JSONDecoder().decode(
                    [OCIContentDescriptor].self,
                    from: Data(record.childrenJSON.utf8)
                )
            )
        } catch {
            throw StateStoreError.invalidRecord(
                "Could not reconstruct verified OCI cache content."
            )
        }
    }

    private func descriptor(
        from row: [String?]
    ) throws -> OCIReferrerDescriptor {
        guard row.count == 5,
              let mediaType = row[0],
              let digest = row[1],
              let sizeText = row[2],
              let size = Int(sizeText),
              let annotationsJSON = row[4],
              let data = annotationsJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              object.values.allSatisfy({ $0 is String }) else {
            throw StateStoreError.invalidRecord(
                "Could not decode verified OCI referrer descriptor."
            )
        }
        do {
            return try OCIReferrerDescriptor(
                mediaType: mediaType,
                digest: OCIContentDigest(digest),
                size: size,
                artifactType: try row[3].map(
                    OCIArtifactType.init
                ),
                annotations: object.mapValues { $0 as! String }
            )
        } catch {
            throw StateStoreError.invalidRecord(
                "Stored OCI referrer descriptor is invalid."
            )
        }
    }

    private func publication(
        from row: [String?]
    ) throws -> OCIReferrerPublicationRecord {
        guard row.count == 10,
              let id = row[0],
              let endpoint = row[1],
              let repository = row[2],
              let subject = row[3],
              let referrer = row[4],
              let proof = row[5],
              let operationGroupID = row[6],
              let cleanupText = row[7],
              let cleanup = Int(cleanupText),
              let createdAt = row[8],
              let observedAt = row[9],
              HostwrightResourceUUID.isValid(id),
              validSHA256(proof),
              HostwrightResourceUUID.isValid(operationGroupID) else {
            throw StateStoreError.invalidRecord(
                "Could not decode OCI referrer publication evidence."
            )
        }
        _ = try RegistryEndpoint(endpoint)
        _ = try OCIRepositoryName(repository)
        _ = try OCIContentDigest(subject)
        _ = try OCIContentDigest(referrer)
        return OCIReferrerPublicationRecord(
            id: id,
            registryEndpoint: endpoint,
            repository: repository,
            subjectDigest: subject,
            referrerDigest: referrer,
            ownershipProofSHA256: proof,
            operationGroupID: operationGroupID,
            cleanupEligible: cleanup == 1,
            createdAt: createdAt,
            observedAt: observedAt
        )
    }

    private func retentionLease(
        from row: [String?]
    ) throws -> OCIReferrerRetentionLeaseRecord {
        guard row.count == 7,
              let id = row[0],
              let discoveryID = row[1],
              let ownerID = row[2],
              let fencingToken = row[3],
              let acquiredAt = row[4],
              let expiresAt = row[5],
              HostwrightResourceUUID.isValid(id),
              HostwrightResourceUUID.isValid(discoveryID),
              HostwrightResourceUUID.isValid(fencingToken),
              ownerID.range(
                  of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,127})$",
                  options: .regularExpression
              ) != nil else {
            throw StateStoreError.invalidRecord(
                "Could not decode OCI referrer retention lease."
            )
        }
        try validateTimestamp(acquiredAt)
        try validateTimestamp(expiresAt)
        if let releasedAt = row[6] {
            try validateTimestamp(releasedAt)
        }
        return OCIReferrerRetentionLeaseRecord(
            id: id,
            discoveryID: discoveryID,
            ownerID: ownerID,
            fencingToken: fencingToken,
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            releasedAt: row[6]
        )
    }

    private func validate(
        _ record: OCIReferrerDiscoveryRecord
    ) throws {
        guard HostwrightResourceUUID.isValid(record.id),
              (try? RegistryEndpoint(record.registryEndpoint)) != nil,
              (try? OCIRepositoryName(record.repository)) != nil,
              (try? OCIContentDigest(record.subjectDigest)) != nil,
              record.artifactType.map({
                  (try? OCIArtifactType($0)) != nil
              }) ?? true,
              OCIReferrerDiscoveryMode(
                  rawValue: record.discoveryMode
              ) != nil,
              (1...OCIReferrerLimits.maximumDiscoveryPages)
                .contains(record.pageCount),
              (0...OCIReferrerLimits.maximumReferrerDescriptors)
                .contains(record.descriptorCount),
              validSHA256(record.graphSHA256),
              record.complete else {
            throw StateStoreError.invalidRecord(
                "OCI referrer discovery record is invalid."
            )
        }
        try validateTimestamp(record.observedAt)
    }

    private func graphDigest(
        _ graph: OCIReferrerGraph
    ) throws -> String {
        var values = [
            graph.discovery.endpoint.canonicalURLString,
            graph.discovery.repository.value,
            graph.discovery.subjectDigest.canonicalValue,
            graph.discovery.mode.rawValue,
            String(graph.discovery.serverFilterApplied),
            String(graph.discovery.pageCount)
        ]
        for descriptor in graph.verifiedReferrers.sorted(by: {
            $0.digest.canonicalValue < $1.digest.canonicalValue
        }) {
            values += [
                descriptor.digest.canonicalValue,
                descriptor.mediaType,
                String(descriptor.size),
                descriptor.artifactType?.value ?? "",
                try encodeAnnotations(descriptor.annotations)
            ]
        }
        for object in graph.objects.sorted(by: {
            $0.digest.canonicalValue < $1.digest.canonicalValue
        }) {
            values += [
                object.digest.canonicalValue,
                object.mediaType,
                String(object.size),
                object.kind.rawValue,
                sha256(object.payload),
                try encodeChildren(object.childDescriptors)
            ]
        }
        return sha256(Data(values.joined(separator: "\u{1f}").utf8))
    }

    private func encodeAnnotations(
        _ annotations: [String: String]
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: annotations,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= 1_024 * 1_024,
              let value = String(data: data, encoding: .utf8) else {
            throw StateStoreError.invalidRecord(
                "OCI referrer annotations are too large."
            )
        }
        return value
    }

    private func encodeChildren(
        _ children: [OCIContentDescriptor]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(children)
        guard data.count <= OCIReferrerLimits.maximumObjectBytes,
              let value = String(data: data, encoding: .utf8) else {
            throw StateStoreError.invalidRecord(
                "OCI referrer graph edges are too large."
            )
        }
        return value
    }

    private func validSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static let contentCacheProviderScope =
        "oci-referrer-cache"

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func validateTimestamp(_ value: String) throws {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard value.utf8.count <= 64,
              fractional.date(from: value) != nil ||
                whole.date(from: value) != nil else {
            throw StateStoreError.invalidRecord(
                "OCI referrer timestamp is invalid."
            )
        }
    }
}
