import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRegistry

public struct ImageProvenanceRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func record(
        _ record: ImageProvenanceRecord
    ) throws -> ImageProvenanceRecord {
        let canonical = try Self.canonicalRecord(record)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateEvidenceBindings(
                    canonical,
                    on: connection
                )
                let rows = try connection.query(
                    Self.select + " WHERE id = ? LIMIT 1",
                    bindings: [.text(canonical.id)]
                )
                if let existing = try rows.first.map(
                    Self.record(from:)
                ) {
                    guard existing == canonical else {
                        throw StateStoreError.invalidRecord(
                            "Image provenance identity already exists with different immutable evidence."
                        )
                    }
                    return canonical
                }

                try connection.run(
                    """
                    INSERT INTO image_provenance_records (
                        id, project_id, service_name,
                        descriptor_digest, policy_sha256,
                        statement_digest, envelope_digest,
                        referrer_digest, evidence_discovery_id,
                        evidence_graph_sha256, source_uri,
                        source_digest, builder_id, builder_version,
                        build_type, invocation_id,
                        normalized_materials_sha256, command_sha256,
                        environment_policy_sha256, started_at,
                        finished_at, reproducibility_status,
                        comparison_digest, signer_id,
                        signer_public_key_sha256, signature_sha256,
                        verifier_version, verified_at,
                        operation_group_id, created_at
                    )
                    VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    )
                    """,
                    bindings: [
                        .text(canonical.id),
                        .text(canonical.projectID),
                        .text(canonical.serviceName),
                        .text(canonical.descriptorDigest),
                        .text(canonical.policySHA256),
                        .text(canonical.statementDigest),
                        .text(canonical.envelopeDigest),
                        .text(canonical.referrerDigest),
                        .text(canonical.evidenceDiscoveryID),
                        .text(canonical.evidenceGraphSHA256),
                        .text(canonical.sourceURI),
                        .text(canonical.sourceDigest),
                        .text(canonical.builderID),
                        .text(canonical.builderVersion),
                        .text(canonical.buildType),
                        .text(canonical.invocationID),
                        .text(
                            canonical
                                .normalizedMaterialsSHA256
                        ),
                        .text(canonical.commandSHA256),
                        .text(
                            canonical
                                .environmentPolicySHA256
                        ),
                        .text(canonical.startedAt),
                        .text(canonical.finishedAt),
                        .text(
                            canonical
                                .reproducibilityStatus.rawValue
                        ),
                        optionalText(
                            canonical.comparisonDigest
                        ),
                        .text(canonical.signerID),
                        .text(
                            canonical
                                .signerPublicKeySHA256
                        ),
                        .text(canonical.signatureSHA256),
                        .text(canonical.verifierVersion),
                        .text(canonical.verifiedAt),
                        .text(canonical.operationGroupID),
                        .text(canonical.createdAt)
                    ]
                )
                return canonical
            }
        }
    }

    public func loadRecord(
        id: String
    ) throws -> ImageProvenanceRecord? {
        let id = try Self.canonicalUUID(
            id,
            label: "Image provenance record id"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            try connection.query(
                Self.select + " WHERE id = ? LIMIT 1",
                bindings: [.text(id)]
            ).first.map(Self.record(from:))
        }
    }

    public func loadRecords(
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String
    ) throws -> [ImageProvenanceRecord] {
        let projectID = try Self.canonicalName(
            projectID,
            label: "Image provenance project"
        )
        let serviceName = try Self.canonicalName(
            serviceName,
            label: "Image provenance service"
        )
        let descriptorDigest = try Self.canonicalSHA256Digest(
            descriptorDigest,
            label: "Image provenance descriptor digest"
        )
        let policySHA256 = try Self.canonicalSHA256(
            policySHA256,
            label: "Image provenance policy SHA256"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            try connection.query(
                Self.select + """
                 WHERE project_id = ? AND service_name = ?
                   AND descriptor_digest = ? AND policy_sha256 = ?
                 ORDER BY verified_at ASC, created_at ASC, rowid ASC
                """,
                bindings: [
                    .text(projectID),
                    .text(serviceName),
                    .text(descriptorDigest),
                    .text(policySHA256)
                ]
            ).map(Self.record(from:))
        }
    }

    public func hasActiveReference(
        discoveryID: String,
        referrerDigest: String
    ) throws -> Bool {
        let discoveryID = try Self.canonicalUUID(
            discoveryID,
            label: "Image provenance discovery id"
        )
        let referrerDigest = try Self.canonicalSHA256Digest(
            referrerDigest,
            label: "Image provenance referrer digest"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            try connection.query(
                """
                SELECT 1
                FROM image_provenance_records
                WHERE evidence_discovery_id = ?
                  AND referrer_digest = ?
                LIMIT 1
                """,
                bindings: [
                    .text(discoveryID),
                    .text(referrerDigest)
                ]
            ).count == 1
        }
    }

    static func validateStoredRecord(
        id: String,
        row: [String?],
        on connection: SQLiteConnection
    ) throws {
        let canonicalID = try canonicalUUID(
            id,
            label: "Image provenance record id"
        )
        let record = try Self.record(from: row)
        guard record.id == canonicalID else {
            throw StateStoreError.invalidRecord(
                "Image provenance identity does not match its immutable evidence."
            )
        }
        try validateEvidenceBindings(record, on: connection)
    }

    static func invalidStoredRecordCount(
        on connection: SQLiteConnection
    ) throws -> Int {
        let rows = try connection.query(
            """
            SELECT id, project_id, service_name, descriptor_digest,
                   policy_sha256, statement_digest, envelope_digest,
                   referrer_digest, evidence_discovery_id,
                   evidence_graph_sha256, source_uri, source_digest,
                   builder_id, builder_version, build_type,
                   invocation_id, normalized_materials_sha256,
                   command_sha256, environment_policy_sha256,
                   started_at, finished_at, reproducibility_status,
                   comparison_digest, signer_id,
                   signer_public_key_sha256, signature_sha256,
                   verifier_version, verified_at,
                   operation_group_id, created_at
            FROM image_provenance_records
            """
        )
        var invalid = 0
        for row in rows {
            guard let id = row.first ?? nil else {
                invalid += 1
                continue
            }
            do {
                try validateStoredRecord(
                    id: id,
                    row: Array(row.dropFirst()),
                    on: connection
                )
            } catch {
                invalid += 1
            }
        }
        return invalid
    }

    static let select = """
        SELECT project_id, service_name, descriptor_digest,
               policy_sha256, statement_digest, envelope_digest,
               referrer_digest, evidence_discovery_id,
               evidence_graph_sha256, source_uri, source_digest,
               builder_id, builder_version, build_type,
               invocation_id, normalized_materials_sha256,
               command_sha256, environment_policy_sha256,
               started_at, finished_at, reproducibility_status,
               comparison_digest, signer_id,
               signer_public_key_sha256, signature_sha256,
               verifier_version, verified_at,
               operation_group_id, created_at
        FROM image_provenance_records
        """

    static func record(
        from row: [String?]
    ) throws -> ImageProvenanceRecord {
        guard row.count == 29,
              let projectID = row[0],
              let serviceName = row[1],
              let descriptorDigest = row[2],
              let policySHA256 = row[3],
              let statementDigest = row[4],
              let envelopeDigest = row[5],
              let referrerDigest = row[6],
              let evidenceDiscoveryID = row[7],
              let evidenceGraphSHA256 = row[8],
              let sourceURI = row[9],
              let sourceDigest = row[10],
              let builderID = row[11],
              let builderVersion = row[12],
              let buildType = row[13],
              let invocationID = row[14],
              let normalizedMaterialsSHA256 = row[15],
              let commandSHA256 = row[16],
              let environmentPolicySHA256 = row[17],
              let startedAt = row[18],
              let finishedAt = row[19],
              let reproducibilityValue = row[20],
              let reproducibilityStatus =
                ImageProvenanceReproducibilityStatus(
                    rawValue: reproducibilityValue
                ),
              let signerID = row[22],
              let signerPublicKeySHA256 = row[23],
              let signatureSHA256 = row[24],
              let verifierVersion = row[25],
              let verifiedAt = row[26],
              let operationGroupID = row[27],
              let createdAt = row[28] else {
            throw StateStoreError.invalidRecord(
                "Could not decode image provenance row."
            )
        }
        return try canonicalRecord(
            ImageProvenanceRecord(
                projectID: projectID,
                serviceName: serviceName,
                descriptorDigest: descriptorDigest,
                policySHA256: policySHA256,
                statementDigest: statementDigest,
                envelopeDigest: envelopeDigest,
                referrerDigest: referrerDigest,
                evidenceDiscoveryID: evidenceDiscoveryID,
                evidenceGraphSHA256: evidenceGraphSHA256,
                sourceURI: sourceURI,
                sourceDigest: sourceDigest,
                builderID: builderID,
                builderVersion: builderVersion,
                buildType: buildType,
                invocationID: invocationID,
                normalizedMaterialsSHA256:
                    normalizedMaterialsSHA256,
                commandSHA256: commandSHA256,
                environmentPolicySHA256:
                    environmentPolicySHA256,
                startedAt: startedAt,
                finishedAt: finishedAt,
                reproducibilityStatus:
                    reproducibilityStatus,
                comparisonDigest: row[21],
                signerID: signerID,
                signerPublicKeySHA256:
                    signerPublicKeySHA256,
                signatureSHA256: signatureSHA256,
                verifierVersion: verifierVersion,
                verifiedAt: verifiedAt,
                operationGroupID: operationGroupID,
                createdAt: createdAt
            )
        )
    }

    static func validateEvidenceBindings(
        _ record: ImageProvenanceRecord,
        on connection: SQLiteConnection
    ) throws {
        let discoveries = try connection.query(
            """
            SELECT graph_sha256, subject_digest, complete
            FROM oci_referrer_discoveries
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(record.evidenceDiscoveryID)]
        )
        guard discoveries.count == 1,
              discoveries[0][0] ==
                record.evidenceGraphSHA256,
              discoveries[0][1] == record.descriptorDigest,
              discoveries[0][2] == "1" else {
            throw StateStoreError.invalidRecord(
                "Image provenance must bind the exact complete Gate 6 discovery, subject, and graph hash."
            )
        }

        let roots = try connection.query(
            """
            SELECT referrer.media_type, referrer.artifact_type,
                   cache.payload_base64, cache.media_type,
                   cache.object_kind
            FROM oci_referrers AS referrer
            JOIN oci_referrer_graph_objects AS graph
              ON graph.discovery_id = referrer.discovery_id
             AND graph.referrer_digest = referrer.referrer_digest
             AND graph.object_digest = referrer.referrer_digest
            JOIN oci_referrer_cache_objects AS cache
              ON cache.digest = graph.object_digest
            WHERE referrer.discovery_id = ?
              AND referrer.referrer_digest = ?
              AND referrer.subject_digest = ?
              AND referrer.verified_subject = 1
            LIMIT 2
            """,
            bindings: [
                .text(record.evidenceDiscoveryID),
                .text(record.referrerDigest),
                .text(record.descriptorDigest)
            ]
        )
        guard roots.count == 1,
              roots[0][0] ==
                OCIReferrerDescriptor.manifestMediaType,
              roots[0][1] ==
                ImageProvenanceDSSEEnvelope.artifactType,
              roots[0][3] ==
                OCIReferrerDescriptor.manifestMediaType,
              roots[0][4] == "manifest",
              let rootPayloadBase64 = roots[0][2],
              let rootPayload = Data(
                base64Encoded: rootPayloadBase64
              ),
              try OCIContentDigest.sha256(of: rootPayload)
                .canonicalValue == record.referrerDigest,
              rootManifestBinds(
                  rootPayload,
                  subjectDigest: record.descriptorDigest,
                  statementDigest: record.statementDigest,
                  envelopeDigest: record.envelopeDigest,
                  signerID: record.signerID
              ) else {
            throw StateStoreError.invalidRecord(
                "Image provenance must bind the exact verified OCI provenance referrer manifest."
            )
        }

        let envelopes = try connection.query(
            """
            SELECT cache.payload_base64, cache.media_type,
                   cache.object_kind
            FROM oci_referrer_graph_objects AS graph
            JOIN oci_referrer_cache_objects AS cache
              ON cache.digest = graph.object_digest
            WHERE graph.discovery_id = ?
              AND graph.referrer_digest = ?
              AND graph.object_digest = ?
            LIMIT 2
            """,
            bindings: [
                .text(record.evidenceDiscoveryID),
                .text(record.referrerDigest),
                .text(record.envelopeDigest)
            ]
        )
        guard envelopes.count == 1,
              envelopes[0][1] ==
                ImageProvenanceDSSEEnvelope.layerMediaType,
              envelopes[0][2] == "blob",
              let envelopePayloadBase64 = envelopes[0][0],
              let envelopePayload = Data(
                base64Encoded: envelopePayloadBase64
              ),
              let envelope = try?
                ImageProvenanceDSSEEnvelope.parse(
                    envelopePayload,
                    expectedSubjectDigest:
                        OCIContentDigest(
                            record.descriptorDigest
                        )
                ),
              envelope.envelopeDigest.canonicalValue ==
                record.envelopeDigest,
              envelope.statement.statementDigest
                .canonicalValue == record.statementDigest,
              envelope.statement.source.uri == record.sourceURI,
              envelope.statement.source.digest
                .canonicalValue == record.sourceDigest,
              envelope.statement.builderID == record.builderID,
              envelope.statement.builderVersion ==
                record.builderVersion,
              envelope.statement.buildType == record.buildType,
              envelope.statement.invocationID ==
                record.invocationID,
              envelope.statement.normalizedMaterialsSHA256 ==
                record.normalizedMaterialsSHA256,
              envelope.statement.commandSHA256 ==
                record.commandSHA256,
              envelope.statement.environmentPolicySHA256 ==
                record.environmentPolicySHA256,
              envelope.statement.startedAt == record.startedAt,
              envelope.statement.finishedAt == record.finishedAt,
              envelope.statement.reproducibility.status ==
                record.reproducibilityStatus,
              envelope.statement.reproducibility
                .comparisonDigest?.canonicalValue ==
                record.comparisonDigest,
              envelope.signerID == record.signerID,
              sha256(envelope.signature) ==
                record.signatureSHA256 else {
            throw StateStoreError.invalidRecord(
                "Image provenance must bind the exact parsed statement, envelope, build evidence, and signature."
            )
        }
    }

    private static func canonicalRecord(
        _ record: ImageProvenanceRecord
    ) throws -> ImageProvenanceRecord {
        let projectID = try canonicalName(
            record.projectID,
            label: "Image provenance project"
        )
        let serviceName = try canonicalName(
            record.serviceName,
            label: "Image provenance service"
        )
        let descriptorDigest = try canonicalSHA256Digest(
            record.descriptorDigest,
            label: "Image provenance descriptor digest"
        )
        let policySHA256 = try canonicalSHA256(
            record.policySHA256,
            label: "Image provenance policy SHA256"
        )
        let statementDigest = try canonicalSHA256Digest(
            record.statementDigest,
            label: "Image provenance statement digest"
        )
        let envelopeDigest = try canonicalSHA256Digest(
            record.envelopeDigest,
            label: "Image provenance envelope digest"
        )
        let referrerDigest = try canonicalSHA256Digest(
            record.referrerDigest,
            label: "Image provenance referrer digest"
        )
        let evidenceDiscoveryID = try canonicalUUID(
            record.evidenceDiscoveryID,
            label: "Image provenance discovery id"
        )
        let evidenceGraphSHA256 = try canonicalSHA256(
            record.evidenceGraphSHA256,
            label: "Image provenance graph SHA256"
        )
        let sourceDigest = try canonicalSHA256Digest(
            record.sourceDigest,
            label: "Image provenance source digest"
        )
        guard (try? ImageProvenanceResource(
            uri: record.sourceURI,
            digest: OCIContentDigest(sourceDigest)
        )) != nil,
        (try? ImageProvenanceResource(
            uri: record.builderID,
            digest: OCIContentDigest(descriptorDigest)
        )) != nil,
        (try? ImageProvenanceResource(
            uri: record.buildType,
            digest: OCIContentDigest(descriptorDigest)
        )) != nil,
        safeText(record.builderVersion, maximumBytes: 128),
        UUID(uuidString: record.invocationID) != nil,
        safeIdentifier(record.signerID) else {
            throw StateStoreError.invalidRecord(
                "Image provenance source, builder, build type, invocation, or signer identity is malformed."
            )
        }
        let normalizedMaterialsSHA256 = try canonicalSHA256(
            record.normalizedMaterialsSHA256,
            label: "Image provenance materials SHA256"
        )
        let commandSHA256 = try canonicalSHA256(
            record.commandSHA256,
            label: "Image provenance command SHA256"
        )
        let environmentPolicySHA256 = try canonicalSHA256(
            record.environmentPolicySHA256,
            label: "Image provenance environment policy SHA256"
        )
        let started = try timestamp(
            record.startedAt,
            label: "Image provenance start timestamp"
        )
        let finished = try timestamp(
            record.finishedAt,
            label: "Image provenance finish timestamp"
        )
        let verified = try timestamp(
            record.verifiedAt,
            label: "Image provenance verification timestamp"
        )
        try validateTimestamp(
            record.createdAt,
            label: "Image provenance creation timestamp"
        )
        guard finished >= started,
              verified >= finished else {
            throw StateStoreError.invalidRecord(
                "Image provenance timestamps must preserve build and verification order."
            )
        }
        let comparisonDigest: String?
        switch (
            record.reproducibilityStatus,
            record.comparisonDigest
        ) {
        case let (.verified, .some(value)):
            comparisonDigest = try canonicalSHA256Digest(
                value,
                label: "Image provenance comparison digest"
            )
            guard comparisonDigest == descriptorDigest else {
                throw StateStoreError.invalidRecord(
                    "Verified reproducibility must bind the exact image digest."
                )
            }
        case (.notVerified, nil):
            comparisonDigest = nil
        default:
            throw StateStoreError.invalidRecord(
                "Image provenance reproducibility evidence is inconsistent."
            )
        }
        let signerPublicKeySHA256 = try canonicalSHA256(
            record.signerPublicKeySHA256,
            label: "Image provenance signer key SHA256"
        )
        let signatureSHA256 = try canonicalSHA256(
            record.signatureSHA256,
            label: "Image provenance signature SHA256"
        )
        guard record.verifierVersion ==
                ImageProvenanceVerification.verifierVersion else {
            throw StateStoreError.invalidRecord(
                "Image provenance verifier version is unsupported."
            )
        }
        let operationGroupID = try canonicalUUID(
            record.operationGroupID,
            label: "Image provenance operation group id"
        )

        return ImageProvenanceRecord(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            statementDigest: statementDigest,
            envelopeDigest: envelopeDigest,
            referrerDigest: referrerDigest,
            evidenceDiscoveryID: evidenceDiscoveryID,
            evidenceGraphSHA256: evidenceGraphSHA256,
            sourceURI: record.sourceURI,
            sourceDigest: sourceDigest,
            builderID: record.builderID,
            builderVersion: record.builderVersion,
            buildType: record.buildType,
            invocationID: record.invocationID.lowercased(),
            normalizedMaterialsSHA256:
                normalizedMaterialsSHA256,
            commandSHA256: commandSHA256,
            environmentPolicySHA256:
                environmentPolicySHA256,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            reproducibilityStatus:
                record.reproducibilityStatus,
            comparisonDigest: comparisonDigest,
            signerID: record.signerID,
            signerPublicKeySHA256:
                signerPublicKeySHA256,
            signatureSHA256: signatureSHA256,
            verifierVersion: record.verifierVersion,
            verifiedAt: record.verifiedAt,
            operationGroupID: operationGroupID,
            createdAt: record.createdAt
        )
    }

    private static func canonicalName(
        _ value: String,
        label: String
    ) throws -> String {
        guard value.range(
            of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#,
            options: .regularExpression
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "\(label) must be lowercase DNS-like text."
            )
        }
        return value
    }

    private static func canonicalSHA256Digest(
        _ value: String,
        label: String
    ) throws -> String {
        let canonical = value.lowercased()
        guard canonical.range(
            of: #"^sha256:[a-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "\(label) must use canonical lowercase sha256 form."
            )
        }
        return canonical
    }

    private static func canonicalSHA256(
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

    private static func canonicalUUID(
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

    private static func safeText(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func timestamp(
        _ value: String,
        label: String
    ) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard value.utf8.count <= 64,
              let date = fractional.date(from: value) ??
                whole.date(from: value) else {
            throw StateStoreError.invalidRecord(
                "\(label) must be an ISO8601 timestamp."
            )
        }
        return date
    }

    private static func validateTimestamp(
        _ value: String,
        label: String
    ) throws {
        _ = try timestamp(value, label: label)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func rootManifestBinds(
        _ payload: Data,
        subjectDigest: String,
        statementDigest: String,
        envelopeDigest: String,
        signerID: String
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(
            with: payload
        ) as? [String: Any],
        Set(object.keys) == [
            "schemaVersion", "mediaType", "artifactType",
            "config", "layers", "subject", "annotations"
        ],
        object["schemaVersion"] as? Int == 2,
        object["mediaType"] as? String ==
            OCIReferrerDescriptor.manifestMediaType,
        object["artifactType"] as? String ==
            ImageProvenanceDSSEEnvelope.artifactType,
        let subject = object["subject"] as? [String: Any],
        subject["digest"] as? String == subjectDigest,
        let subjectMediaType = subject["mediaType"] as? String,
        imageSubjectMediaTypes.contains(subjectMediaType),
        let layers = object["layers"] as? [Any],
        layers.count == 1,
        let layer = layers[0] as? [String: Any],
        layer["digest"] as? String == envelopeDigest,
        layer["mediaType"] as? String ==
            ImageProvenanceDSSEEnvelope.layerMediaType,
        let annotations = object["annotations"]
            as? [String: Any],
        annotations["org.hostwright.image.digest"]
            as? String == subjectDigest,
        annotations[
            "org.hostwright.provenance.statement.digest"
        ] as? String == statementDigest,
        annotations[
            "org.hostwright.provenance.predicate-type"
        ] as? String == ImageProvenanceStatement.predicateType,
        annotations[
            "org.hostwright.provenance.signer-id"
        ] as? String == signerID else {
            return false
        }
        return true
    }

    private static let imageSubjectMediaTypes = Set([
        OCIReferrerDescriptor.manifestMediaType,
        OCIReferrerDescriptor.indexMediaType,
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.docker.distribution.manifest.list.v2+json"
    ])
}
