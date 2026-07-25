import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRegistry

public struct ImageTrustRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func recordVerification(
        _ record: ImageTrustVerificationRecord
    ) throws -> ImageTrustVerificationRecord {
        let canonical = try canonicalVerification(record)
        let verificationID = verificationIdentity(for: canonical)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                if let exceptionID = canonical.exceptionID {
                    guard let exception = try loadException(
                        id: exceptionID,
                        on: connection
                    ) else {
                        throw StateStoreError.invalidRecord(
                            "Image trust verification requires an exact persisted exception."
                        )
                    }
                    guard exception.projectID == canonical.projectID,
                          exception.serviceName == canonical.serviceName,
                          exception.descriptorDigest == canonical.descriptorDigest,
                          exception.policySHA256 == canonical.policySHA256,
                          isActive(exception, at: canonical.createdAt) else {
                        throw StateStoreError.invalidRecord(
                            "Image trust verification exception must match the exact active project, service, descriptor digest, and policy."
                        )
                    }
                }
                let discoveryRows = try connection.query(
                    """
                    SELECT graph_sha256
                    FROM oci_referrer_discoveries
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(canonical.evidenceDiscoveryID)]
                )
                guard discoveryRows.count == 1,
                      discoveryRows[0][0] == canonical.evidenceGraphSHA256 else {
                    throw StateStoreError.invalidRecord(
                        "Image trust verification must bind to the exact persisted Gate 6 discovery and graph hash."
                    )
                }

                let rows = try connection.query(
                    """
                    SELECT project_id, service_name, descriptor_digest,
                           policy_sha256, evidence_graph_sha256,
                           evidence_discovery_id, trusted_root_sha256, verifier_version,
                           matched_authority_ids_json, threshold, outcome,
                           exception_id, operation_group_id, created_at
                    FROM image_trust_verifications
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(verificationID)]
                )
                if let existing = try rows.first.map(verification(from:)) {
                    guard existing == canonical else {
                        throw StateStoreError.invalidRecord(
                            "Image trust verification identity already exists with different immutable evidence."
                        )
                    }
                    return canonical
                }

                try connection.run(
                    """
                    INSERT INTO image_trust_verifications (
                        id, project_id, service_name, descriptor_digest,
                        policy_sha256, evidence_graph_sha256,
                        evidence_discovery_id, trusted_root_sha256, verifier_version,
                        matched_authority_ids_json, threshold, outcome,
                        exception_id, operation_group_id, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(verificationID),
                        .text(canonical.projectID),
                        .text(canonical.serviceName),
                        .text(canonical.descriptorDigest),
                        .text(canonical.policySHA256),
                        .text(canonical.evidenceGraphSHA256),
                        .text(canonical.evidenceDiscoveryID),
                        .text(canonical.trustedRootSHA256),
                        .text(canonical.verifierVersion),
                        .text(try authorityIDsJSON(canonical.matchedAuthorityIDs)),
                        .int(canonical.threshold),
                        .text(canonical.outcome),
                        optionalText(canonical.exceptionID),
                        .text(canonical.operationGroupID),
                        .text(canonical.createdAt)
                    ]
                )
                return canonical
            }
        }
    }

    public func loadVerifications(
        projectID: String,
        serviceName: String? = nil,
        descriptorDigest: String? = nil
    ) throws -> [ImageTrustVerificationRecord] {
        guard !projectID.isEmpty else {
            throw StateStoreError.invalidRecord(
                "Image trust verification lookup requires an exact project."
            )
        }
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            var sql = """
                SELECT project_id, service_name, descriptor_digest,
                       policy_sha256, evidence_graph_sha256,
                       evidence_discovery_id, trusted_root_sha256, verifier_version,
                       matched_authority_ids_json, threshold, outcome,
                       exception_id, operation_group_id, created_at
                FROM image_trust_verifications
                WHERE project_id = ?
                """
            var bindings: [SQLiteValue] = [.text(projectID)]
            if let serviceName {
                sql += " AND service_name = ?"
                bindings.append(.text(serviceName))
            }
            if let descriptorDigest {
                sql += " AND descriptor_digest = ?"
                bindings.append(
                    .text(try canonicalDescriptorDigest(descriptorDigest))
                )
            }
            sql += " ORDER BY created_at ASC, rowid ASC"
            return try connection.query(sql, bindings: bindings)
                .map(verification(from:))
        }
    }

    @discardableResult
    public func recordException(
        _ record: ImageTrustExceptionRecord
    ) throws -> ImageTrustExceptionRecord {
        let canonical = try canonicalException(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let existing = try loadException(
                    idempotencyKey: canonical.idempotencyKey,
                    on: connection
                )
                if let existing {
                    guard existing == canonical else {
                        throw StateStoreError.invalidRecord(
                            "Image trust exception idempotency key already exists with different immutable evidence."
                        )
                    }
                    return canonical
                }

                try connection.run(
                    """
                    INSERT INTO image_trust_exceptions (
                        id, project_id, service_name, descriptor_digest,
                        policy_sha256, reason, approver, approved_at,
                        expires_at, revoked_at, idempotency_key
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(canonical.id),
                        .text(canonical.projectID),
                        .text(canonical.serviceName),
                        .text(canonical.descriptorDigest),
                        .text(canonical.policySHA256),
                        .text(canonical.reason),
                        .text(canonical.approver),
                        .text(canonical.approvedAt),
                        .text(canonical.expiresAt),
                        optionalText(canonical.revokedAt),
                        .text(canonical.idempotencyKey)
                    ]
                )
                return canonical
            }
        }
    }

    @discardableResult
    public func cacheSubjectManifest(
        _ record: ImageTrustSubjectManifestRecord
    ) throws -> ImageTrustSubjectManifestRecord {
        let canonical = try canonicalSubjectManifest(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT registry_endpoint, repository, descriptor_digest,
                           payload_base64, payload_sha256, observed_at
                    FROM image_trust_subject_manifests
                    WHERE registry_endpoint = ? AND repository = ?
                      AND descriptor_digest = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(canonical.registryEndpoint),
                        .text(canonical.repository),
                        .text(canonical.descriptorDigest)
                    ]
                )
                if let existing = try rows.first.map(subjectManifest(from:)) {
                    guard existing.payload == canonical.payload,
                          existing.payloadSHA256 == canonical.payloadSHA256 else {
                        throw StateStoreError.invalidRecord(
                            "Image trust subject manifest already exists with different immutable content."
                        )
                    }
                    if existing.observedAt != canonical.observedAt {
                        try connection.run(
                            """
                            UPDATE image_trust_subject_manifests
                            SET observed_at = ?
                            WHERE registry_endpoint = ? AND repository = ?
                              AND descriptor_digest = ?
                            """,
                            bindings: [
                                .text(canonical.observedAt),
                                .text(canonical.registryEndpoint),
                                .text(canonical.repository),
                                .text(canonical.descriptorDigest)
                            ]
                        )
                    }
                    return ImageTrustSubjectManifestRecord(
                        registryEndpoint: canonical.registryEndpoint,
                        repository: canonical.repository,
                        descriptorDigest: canonical.descriptorDigest,
                        payload: canonical.payload,
                        payloadSHA256: canonical.payloadSHA256,
                        observedAt: canonical.observedAt
                    )
                }

                try connection.run(
                    """
                    INSERT INTO image_trust_subject_manifests (
                        id, registry_endpoint, repository, descriptor_digest,
                        size_bytes, payload_base64, payload_sha256, observed_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(subjectManifestIdentity(for: canonical)),
                        .text(canonical.registryEndpoint),
                        .text(canonical.repository),
                        .text(canonical.descriptorDigest),
                        .int(canonical.payload.count),
                        .text(canonical.payload.base64EncodedString()),
                        .text(canonical.payloadSHA256),
                        .text(canonical.observedAt)
                    ]
                )
                return canonical
            }
        }
    }

    public func loadExceptions(
        projectID: String? = nil
    ) throws -> [ImageTrustExceptionRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let sql: String
            let bindings: [SQLiteValue]
            if let projectID {
                guard !projectID.isEmpty else {
                    throw StateStoreError.invalidRecord(
                        "Image trust exception lookup requires a non-empty project."
                    )
                }
                sql = """
                    SELECT id, project_id, service_name, descriptor_digest,
                           policy_sha256, reason, approver, approved_at,
                           expires_at, revoked_at, idempotency_key
                    FROM image_trust_exceptions
                    WHERE project_id = ?
                    ORDER BY approved_at ASC, rowid ASC
                    """
                bindings = [.text(projectID)]
            } else {
                sql = """
                    SELECT id, project_id, service_name, descriptor_digest,
                           policy_sha256, reason, approver, approved_at,
                           expires_at, revoked_at, idempotency_key
                    FROM image_trust_exceptions
                    ORDER BY project_id ASC, service_name ASC,
                             approved_at ASC, rowid ASC
                    """
                bindings = []
            }
            return try connection.query(sql, bindings: bindings)
                .map(exception(from:))
        }
    }

    public func loadException(
        idempotencyKey: String
    ) throws -> ImageTrustExceptionRecord? {
        let key = try canonicalSafeToken(
            idempotencyKey,
            label: "Image trust exception idempotency key"
        ).lowercased()
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            try loadException(idempotencyKey: key, on: connection)
        }
    }

    public func loadSubjectManifest(
        endpoint: String,
        repository: String,
        descriptorDigest: String
    ) throws -> ImageTrustSubjectManifestRecord? {
        let endpoint = try RegistryEndpoint(endpoint)
        let repository = try OCIRepositoryName(repository)
        let descriptorDigest = try canonicalDescriptorDigest(
            descriptorDigest
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            let rows = try connection.query(
                """
                SELECT registry_endpoint, repository, descriptor_digest,
                       payload_base64, payload_sha256, observed_at
                FROM image_trust_subject_manifests
                WHERE registry_endpoint = ? AND repository = ?
                  AND descriptor_digest = ?
                LIMIT 1
                """,
                bindings: [
                    .text(endpoint.canonicalURLString),
                    .text(repository.value),
                    .text(descriptorDigest)
                ]
            )
            return try rows.first.map(subjectManifest(from:))
        }
    }

    public func activeException(
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String,
        currentTimestamp: String
    ) throws -> ImageTrustExceptionRecord? {
        try validateTimestamp(
            currentTimestamp,
            label: "Image trust exception lookup timestamp"
        )
        guard !projectID.isEmpty,
              !serviceName.isEmpty else {
            throw StateStoreError.invalidRecord(
                "Image trust exception lookup requires exact project and service values."
            )
        }
        let canonicalDescriptor =
            try canonicalDescriptorDigest(descriptorDigest)
        let canonicalPolicy = try canonicalSHA256(
            policySHA256,
            label: "Image trust exception policy SHA256"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, descriptor_digest,
                       policy_sha256, reason, approver, approved_at,
                       expires_at, revoked_at, idempotency_key
                FROM image_trust_exceptions
                WHERE project_id = ? AND service_name = ?
                  AND descriptor_digest = ? AND policy_sha256 = ?
                  AND approved_at <= ? AND expires_at > ?
                  AND (revoked_at IS NULL OR revoked_at > ?)
                ORDER BY approved_at DESC, rowid DESC
                LIMIT 1
                """,
                bindings: [
                    .text(projectID),
                    .text(serviceName),
                    .text(canonicalDescriptor),
                    .text(canonicalPolicy),
                    .text(currentTimestamp),
                    .text(currentTimestamp),
                    .text(currentTimestamp)
                ]
            )
            return try rows.first.map(exception(from:))
        }
    }

    @discardableResult
    public func revokeException(
        idempotencyKey: String,
        revokedAt: String
    ) throws -> Bool {
        let key = try canonicalSafeToken(
            idempotencyKey,
            label: "Image trust exception idempotency key"
        ).lowercased()
        try validateTimestamp(
            revokedAt,
            label: "Image trust exception revocation timestamp"
        )
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let rows = try connection.query(
                    """
                    SELECT approved_at, revoked_at
                    FROM image_trust_exceptions
                    WHERE idempotency_key = ?
                    LIMIT 1
                    """,
                    bindings: [.text(key)]
                )
                guard let row = rows.first,
                      let approvedAt = row[0] else {
                    return false
                }
                guard revokedAt >= approvedAt else {
                    throw StateStoreError.invalidRecord(
                        "Image trust exception revocation must not predate approval."
                    )
                }
                if let existingRevokedAt = row[1] {
                    return existingRevokedAt == revokedAt
                }
                try connection.run(
                    """
                    UPDATE image_trust_exceptions
                    SET revoked_at = ?
                    WHERE idempotency_key = ? AND revoked_at IS NULL
                    """,
                    bindings: [.text(revokedAt), .text(key)]
                )
                let verified = try connection.query(
                    """
                    SELECT revoked_at
                    FROM image_trust_exceptions
                    WHERE idempotency_key = ?
                    LIMIT 1
                    """,
                    bindings: [.text(key)]
                )
                return verified.first?.first == revokedAt
            }
        }
    }

    private func loadException(
        id: String,
        on connection: SQLiteConnection
    ) throws -> ImageTrustExceptionRecord? {
        let rows = try connection.query(
            """
            SELECT id, project_id, service_name, descriptor_digest,
                   policy_sha256, reason, approver, approved_at,
                   expires_at, revoked_at, idempotency_key
            FROM image_trust_exceptions
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id.lowercased())]
        )
        return try rows.first.map(exception(from:))
    }

    private func loadException(
        idempotencyKey: String,
        on connection: SQLiteConnection
    ) throws -> ImageTrustExceptionRecord? {
        let rows = try connection.query(
            """
            SELECT id, project_id, service_name, descriptor_digest,
                   policy_sha256, reason, approver, approved_at,
                   expires_at, revoked_at, idempotency_key
            FROM image_trust_exceptions
            WHERE idempotency_key = ?
            LIMIT 1
            """,
            bindings: [.text(idempotencyKey)]
        )
        return try rows.first.map(exception(from:))
    }

    private func verification(
        from row: [String?]
    ) throws -> ImageTrustVerificationRecord {
        guard row.count == 14,
              let projectID = row[0],
              let serviceName = row[1],
              let descriptorDigest = row[2],
              let policySHA256 = row[3],
              let evidenceGraphSHA256 = row[4],
              let evidenceDiscoveryID = row[5],
              let trustedRootSHA256 = row[6],
              let verifierVersion = row[7],
              let matchedAuthorityIDsJSON = row[8],
              let thresholdText = row[9],
              let threshold = Int(thresholdText),
              let outcome = row[10],
              let operationGroupID = row[12],
              let createdAt = row[13] else {
            throw StateStoreError.invalidRecord(
                "Could not decode image trust verification."
            )
        }
        let matchedAuthorityIDs =
            try authorityIDs(from: matchedAuthorityIDsJSON)
        let record = ImageTrustVerificationRecord(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            evidenceGraphSHA256: evidenceGraphSHA256,
            evidenceDiscoveryID: evidenceDiscoveryID,
            trustedRootSHA256: trustedRootSHA256,
            verifierVersion: verifierVersion,
            matchedAuthorityIDs: matchedAuthorityIDs,
            threshold: threshold,
            outcome: outcome,
            exceptionID: row[11],
            operationGroupID: operationGroupID,
            createdAt: createdAt
        )
        return try canonicalVerification(record)
    }

    private func exception(
        from row: [String?]
    ) throws -> ImageTrustExceptionRecord {
        guard row.count == 11,
              let id = row[0],
              let projectID = row[1],
              let serviceName = row[2],
              let descriptorDigest = row[3],
              let policySHA256 = row[4],
              let reason = row[5],
              let approver = row[6],
              let approvedAt = row[7],
              let expiresAt = row[8],
              let idempotencyKey = row[10],
              HostwrightResourceUUID.isValid(id) else {
            throw StateStoreError.invalidRecord(
                "Could not decode image trust exception."
            )
        }
        let record = ImageTrustExceptionRecord(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            reason: reason,
            approver: approver,
            approvedAt: approvedAt,
            expiresAt: expiresAt,
            revokedAt: row[9],
            idempotencyKey: idempotencyKey
        )
        guard record.id == id.lowercased() else {
            throw StateStoreError.invalidRecord(
                "Image trust exception identity does not match its idempotency key."
            )
        }
        return try canonicalException(record)
    }

    private func subjectManifest(
        from row: [String?]
    ) throws -> ImageTrustSubjectManifestRecord {
        guard row.count == 6,
              let endpoint = row[0],
              let repository = row[1],
              let descriptorDigest = row[2],
              let payloadBase64 = row[3],
              let payload = Data(base64Encoded: payloadBase64),
              payload.base64EncodedString() == payloadBase64,
              let payloadSHA256 = row[4],
              let observedAt = row[5] else {
            throw StateStoreError.invalidRecord(
                "Could not decode image trust subject manifest."
            )
        }
        let record = ImageTrustSubjectManifestRecord(
            registryEndpoint: endpoint,
            repository: repository,
            descriptorDigest: descriptorDigest,
            payload: payload,
            payloadSHA256: payloadSHA256,
            observedAt: observedAt
        )
        return try canonicalSubjectManifest(record)
    }

    private func canonicalVerification(
        _ record: ImageTrustVerificationRecord
    ) throws -> ImageTrustVerificationRecord {
        guard !record.projectID.isEmpty,
              !record.serviceName.isEmpty,
              (1...8).contains(record.threshold) else {
            throw StateStoreError.invalidRecord(
                "Image trust verification requires exact project, service, and threshold values."
            )
        }
        let verifierVersion = try canonicalSafeToken(
            record.verifierVersion,
            label: "Image trust verifier version"
        )
        let outcome = try canonicalSafeToken(
            record.outcome,
            label: "Image trust verification outcome"
        )
        guard outcome == "passed" || outcome == "threshold-not-met" else {
            throw StateStoreError.invalidRecord(
                "Image trust verification outcome is not supported."
            )
        }
        let descriptorDigest = try canonicalDescriptorDigest(
            record.descriptorDigest
        )
        let policySHA256 = try canonicalSHA256(
            record.policySHA256,
            label: "Image trust policy SHA256"
        )
        let evidenceGraphSHA256 = try canonicalSHA256(
            record.evidenceGraphSHA256,
            label: "Image trust evidence graph SHA256"
        )
        let evidenceDiscoveryID = try canonicalUUID(
            record.evidenceDiscoveryID,
            label: "Image trust evidence discovery id"
        )
        let trustedRootSHA256 = try canonicalSHA256(
            record.trustedRootSHA256,
            label: "Image trust trusted-root SHA256"
        )
        let matchedAuthorityIDs = try canonicalAuthorityIDs(
            record.matchedAuthorityIDs
        )
        guard matchedAuthorityIDs.count <= 8 else {
            throw StateStoreError.invalidRecord(
                "Image trust verification must bind to at most eight authority ids."
            )
        }
        let exceptionID = try record.exceptionID.map {
            try canonicalUUID(
                $0,
                label: "Image trust verification exception id"
            )
        }
        let operationGroupID = try canonicalUUID(
            record.operationGroupID,
            label: "Image trust verification operation group id"
        )
        try validateTimestamp(
            record.createdAt,
            label: "Image trust verification timestamp"
        )
        return ImageTrustVerificationRecord(
            projectID: record.projectID,
            serviceName: record.serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            evidenceGraphSHA256: evidenceGraphSHA256,
            evidenceDiscoveryID: evidenceDiscoveryID,
            trustedRootSHA256: trustedRootSHA256,
            verifierVersion: verifierVersion,
            matchedAuthorityIDs: matchedAuthorityIDs,
            threshold: record.threshold,
            outcome: outcome,
            exceptionID: exceptionID,
            operationGroupID: operationGroupID,
            createdAt: record.createdAt
        )
    }

    private func canonicalException(
        _ record: ImageTrustExceptionRecord
    ) throws -> ImageTrustExceptionRecord {
        guard !record.projectID.isEmpty,
              !record.serviceName.isEmpty else {
            throw StateStoreError.invalidRecord(
                "Image trust exception requires exact project and service values."
            )
        }
        let descriptorDigest = try canonicalDescriptorDigest(
            record.descriptorDigest
        )
        let policySHA256 = try canonicalSHA256(
            record.policySHA256,
            label: "Image trust exception policy SHA256"
        )
        let idempotencyKey = try canonicalSafeToken(
            record.idempotencyKey,
            label: "Image trust exception idempotency key"
        ).lowercased()
        guard record.reason.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false,
        record.reason.utf8.count <= 512 else {
            throw StateStoreError.invalidRecord(
                "Image trust exception reason must be a bounded non-empty string."
            )
        }
        let approver = try canonicalPrincipal(
            record.approver,
            label: "Image trust exception approver"
        )
        try validateTimestamp(
            record.approvedAt,
            label: "Image trust exception approval timestamp"
        )
        try validateTimestamp(
            record.expiresAt,
            label: "Image trust exception expiry timestamp"
        )
        guard record.expiresAt > record.approvedAt else {
            throw StateStoreError.invalidRecord(
                "Image trust exception expiry must be after approval."
            )
        }
        if let revokedAt = record.revokedAt {
            try validateTimestamp(
                revokedAt,
                label: "Image trust exception revocation timestamp"
            )
            guard revokedAt >= record.approvedAt else {
                throw StateStoreError.invalidRecord(
                    "Image trust exception revocation must not predate approval."
                )
            }
        }
        let canonical = ImageTrustExceptionRecord(
            projectID: record.projectID,
            serviceName: record.serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            reason: record.reason,
            approver: approver,
            approvedAt: record.approvedAt,
            expiresAt: record.expiresAt,
            revokedAt: record.revokedAt,
            idempotencyKey: idempotencyKey
        )
        guard canonical.id == record.id else {
            throw StateStoreError.invalidRecord(
                "Image trust exception identity must be derived from its idempotency key."
            )
        }
        return canonical
    }

    private func verificationIdentity(
        for record: ImageTrustVerificationRecord
    ) -> String {
        let exceptionID = record.exceptionID ?? "none"
        return HostwrightResourceUUID.legacy(
            kind: "image-trust-verification",
            identifier: [
                record.projectID,
                record.serviceName,
                record.descriptorDigest,
                record.policySHA256,
                record.evidenceGraphSHA256,
                record.evidenceDiscoveryID,
                record.trustedRootSHA256,
                record.verifierVersion,
                record.matchedAuthorityIDs.joined(separator: ","),
                String(record.threshold),
                record.outcome,
                exceptionID,
                record.operationGroupID,
                record.createdAt
            ].joined(separator: "\u{1f}")
        )
    }

    private func subjectManifestIdentity(
        for record: ImageTrustSubjectManifestRecord
    ) -> String {
        HostwrightResourceUUID.legacy(
            kind: "image-trust-subject-manifest",
            identifier: [
                record.registryEndpoint,
                record.repository,
                record.descriptorDigest
            ].joined(separator: "\u{1f}")
        )
    }

    private func authorityIDsJSON(_ values: [String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: values,
            options: [.withoutEscapingSlashes]
        )
        guard data.count <= 4_096,
              let json = String(data: data, encoding: .utf8) else {
            throw StateStoreError.invalidRecord(
                "Image trust authority matches are too large."
            )
        }
        return json
    }

    private func authorityIDs(from json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(
                with: data
              ) as? [String] else {
            throw StateStoreError.invalidRecord(
                "Image trust matched authority ids are invalid."
            )
        }
        return try canonicalAuthorityIDs(values)
    }

    private func canonicalAuthorityIDs(
        _ values: [String]
    ) throws -> [String] {
        var seen = Set<String>()
        var canonical: [String] = []
        canonical.reserveCapacity(values.count)
        for value in values {
            guard value.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$"#,
                options: .regularExpression
            ) != nil else {
                throw StateStoreError.invalidRecord(
                    "Image trust authority ids must be bounded safe identifiers."
                )
            }
            guard seen.insert(value).inserted else {
                throw StateStoreError.invalidRecord(
                    "Image trust matched authority ids must be distinct."
                )
            }
            canonical.append(value)
        }
        return canonical.sorted()
    }

    private func canonicalDescriptorDigest(
        _ value: String
    ) throws -> String {
        let canonical = value.lowercased()
        guard canonical.range(
            of: #"^sha256:[a-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "Image trust descriptor digests must use canonical lowercase sha256 form."
            )
        }
        return canonical
    }

    private func canonicalSHA256(
        _ value: String,
        label: String
    ) throws -> String {
        let canonical = value.lowercased()
        guard canonical.range(
            of: #"^[a-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "\(label) must be a canonical lowercase SHA256."
            )
        }
        return canonical
    }

    private func canonicalUUID(
        _ value: String,
        label: String
    ) throws -> String {
        let canonical = value.lowercased()
        guard HostwrightResourceUUID.isValid(canonical) else {
            throw StateStoreError.invalidRecord(
                "\(label) must be an exact UUID."
            )
        }
        return canonical
    }

    private func canonicalSubjectManifest(
        _ record: ImageTrustSubjectManifestRecord
    ) throws -> ImageTrustSubjectManifestRecord {
        let endpoint = try RegistryEndpoint(record.registryEndpoint)
        let repository = try OCIRepositoryName(record.repository)
        let descriptor = try canonicalDescriptorDigest(
            record.descriptorDigest
        )
        let payloadSHA256 = try canonicalSHA256(
            record.payloadSHA256,
            label: "Image trust subject manifest payload SHA256"
        )
        guard !record.payload.isEmpty,
              record.payload.count <= 1_024 * 1_024 else {
            throw StateStoreError.invalidRecord(
                "Image trust subject manifest payload must be non-empty and bounded to one MiB."
            )
        }
        try validateTimestamp(
            record.observedAt,
            label: "Image trust subject manifest observation timestamp"
        )
        let actualPayloadSHA256 = sha256(record.payload)
        guard actualPayloadSHA256 == payloadSHA256,
              descriptor == "sha256:\(actualPayloadSHA256)" else {
            throw StateStoreError.invalidRecord(
                "Image trust subject manifest bytes must match their exact payload and descriptor digests."
            )
        }
        return ImageTrustSubjectManifestRecord(
            registryEndpoint: endpoint.canonicalURLString,
            repository: repository.value,
            descriptorDigest: descriptor,
            payload: record.payload,
            payloadSHA256: payloadSHA256,
            observedAt: record.observedAt
        )
    }

    private func canonicalSafeToken(
        _ value: String,
        label: String
    ) throws -> String {
        guard value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$"#,
            options: .regularExpression
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "\(label) must be a bounded safe token."
            )
        }
        return value
    }

    private func canonicalPrincipal(
        _ value: String,
        label: String
    ) throws -> String {
        guard value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._@:+-]{0,126}$"#,
            options: .regularExpression
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "\(label) must be a bounded safe identifier."
            )
        }
        return value
    }

    private func validateTimestamp(
        _ value: String,
        label: String
    ) throws {
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
                "\(label) is invalid."
            )
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func isActive(
        _ record: ImageTrustExceptionRecord,
        at timestamp: String
    ) -> Bool {
        record.approvedAt <= timestamp &&
            record.expiresAt > timestamp &&
            (record.revokedAt == nil || record.revokedAt! > timestamp)
    }
}
