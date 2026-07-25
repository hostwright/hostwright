import Foundation
import HostwrightCore
import HostwrightRegistry

public struct ImageSBOMRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    @discardableResult
    public func record(_ record: ImageSBOMRecord) throws -> ImageSBOMRecord {
        let canonical = try canonicalRecord(record)
        let recordID = recordIdentity(for: canonical)
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try validateEvidenceBindings(canonical, on: connection)

                let rows = try connection.query(
                    """
                    SELECT project_id, service_name, descriptor_digest,
                           policy_sha256, format, document_digest,
                           document_media_type, evidence_discovery_id,
                           evidence_graph_sha256, sbom_referrer_digest,
                           provenance_descriptor_digest,
                           provenance_referrer_digest, component_count,
                           normalized_components_sha256,
                           operation_group_id, created_at
                    FROM image_sbom_records
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(recordID)]
                )
                if let existing = try rows.first.map(record(from:)) {
                    guard existing == canonical else {
                        throw StateStoreError.invalidRecord(
                            "Image SBOM identity already exists with different immutable evidence."
                        )
                    }
                    return canonical
                }

                try connection.run(
                    """
                    INSERT INTO image_sbom_records (
                        id, project_id, service_name, descriptor_digest,
                        policy_sha256, format, document_digest,
                        document_media_type, evidence_discovery_id,
                        evidence_graph_sha256, sbom_referrer_digest,
                        provenance_descriptor_digest,
                        provenance_referrer_digest, component_count,
                        normalized_components_sha256, operation_group_id,
                        created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(recordID),
                        .text(canonical.projectID),
                        .text(canonical.serviceName),
                        .text(canonical.descriptorDigest),
                        .text(canonical.policySHA256),
                        .text(canonical.format.rawValue),
                        .text(canonical.documentDigest),
                        .text(canonical.documentMediaType),
                        .text(canonical.evidenceDiscoveryID),
                        .text(canonical.evidenceGraphSHA256),
                        .text(canonical.sbomReferrerDigest),
                        optionalText(canonical.provenanceDescriptorDigest),
                        optionalText(canonical.provenanceReferrerDigest),
                        .int(canonical.componentCount),
                        .text(canonical.normalizedComponentsSHA256),
                        .text(canonical.operationGroupID),
                        .text(canonical.createdAt)
                    ]
                )
                return canonical
            }
        }
    }

    public func loadRecords(
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String
    ) throws -> [ImageSBOMRecord] {
        let canonicalProjectID = try canonicalName(
            projectID,
            label: "Image SBOM project"
        )
        let canonicalServiceName = try canonicalName(
            serviceName,
            label: "Image SBOM service"
        )
        let canonicalDescriptorDigest = try canonicalDescriptorDigest(
            descriptorDigest
        )
        let canonicalPolicySHA256 = try canonicalSHA256(
            policySHA256,
            label: "Image SBOM policy SHA256"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            try connection.query(
                """
                SELECT project_id, service_name, descriptor_digest,
                       policy_sha256, format, document_digest,
                       document_media_type, evidence_discovery_id,
                       evidence_graph_sha256, sbom_referrer_digest,
                       provenance_descriptor_digest,
                       provenance_referrer_digest, component_count,
                       normalized_components_sha256,
                       operation_group_id, created_at
                FROM image_sbom_records
                WHERE project_id = ? AND service_name = ?
                  AND descriptor_digest = ? AND policy_sha256 = ?
                ORDER BY created_at ASC, rowid ASC
                """,
                bindings: [
                    .text(canonicalProjectID),
                    .text(canonicalServiceName),
                    .text(canonicalDescriptorDigest),
                    .text(canonicalPolicySHA256)
                ]
            ).map(record(from:))
        }
    }

    public func hasActiveReference(
        discoveryID: String,
        referrerDigest: String
    ) throws -> Bool {
        let canonicalDiscoveryID = try canonicalUUID(
            discoveryID,
            label: "Image SBOM discovery id"
        )
        let canonicalReferrerDigest = try canonicalOCIDigest(
            referrerDigest,
            label: "Image SBOM referrer digest"
        )
        return try store.withValidatedConnection(readOnly: true) {
            connection in
            let rows = try connection.query(
                """
                SELECT 1
                FROM image_sbom_records
                WHERE evidence_discovery_id = ?
                  AND (
                    sbom_referrer_digest = ?
                    OR provenance_referrer_digest = ?
                  )
                LIMIT 1
                """,
                bindings: [
                    .text(canonicalDiscoveryID),
                    .text(canonicalReferrerDigest),
                    .text(canonicalReferrerDigest)
                ]
            )
            return rows.count == 1
        }
    }

    private func validateEvidenceBindings(
        _ record: ImageSBOMRecord,
        on connection: SQLiteConnection
    ) throws {
        let discovery = try connection.query(
            """
            SELECT graph_sha256
            FROM oci_referrer_discoveries
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(record.evidenceDiscoveryID)]
        )
        guard discovery.count == 1,
              discovery[0][0] == record.evidenceGraphSHA256 else {
            throw StateStoreError.invalidRecord(
                "Image SBOM record must bind to the exact persisted Gate 6 discovery and graph hash."
            )
        }

        guard try referrerExists(
            discoveryID: record.evidenceDiscoveryID,
            referrerDigest: record.sbomReferrerDigest,
            on: connection
        ) else {
            throw StateStoreError.invalidRecord(
                "Image SBOM record requires an exact persisted SBOM referrer descriptor."
            )
        }

        guard try objectExists(
            discoveryID: record.evidenceDiscoveryID,
            objectDigest: record.documentDigest,
            on: connection
        ) else {
            throw StateStoreError.invalidRecord(
                "Image SBOM record requires an exact persisted SBOM document object."
            )
        }

        if let provenanceReferrerDigest = record.provenanceReferrerDigest,
           let provenanceDescriptorDigest = record.provenanceDescriptorDigest {
            guard try referrerExists(
                discoveryID: record.evidenceDiscoveryID,
                referrerDigest: provenanceReferrerDigest,
                on: connection
            ) else {
                throw StateStoreError.invalidRecord(
                    "Image SBOM record requires an exact persisted provenance referrer descriptor."
                )
            }
            guard try objectExists(
                discoveryID: record.evidenceDiscoveryID,
                objectDigest: provenanceDescriptorDigest,
                on: connection
            ) else {
                throw StateStoreError.invalidRecord(
                    "Image SBOM record requires an exact persisted provenance descriptor object."
                )
            }
        }
    }

    private func referrerExists(
        discoveryID: String,
        referrerDigest: String,
        on connection: SQLiteConnection
    ) throws -> Bool {
        let rows = try connection.query(
            """
            SELECT 1
            FROM oci_referrers
            WHERE discovery_id = ? AND referrer_digest = ?
            LIMIT 1
            """,
            bindings: [
                .text(discoveryID),
                .text(referrerDigest)
            ]
        )
        return rows.count == 1
    }

    private func objectExists(
        discoveryID: String,
        objectDigest: String,
        on connection: SQLiteConnection
    ) throws -> Bool {
        let rows = try connection.query(
            """
            SELECT 1
            FROM oci_referrer_graph_objects
            WHERE discovery_id = ? AND object_digest = ?
            LIMIT 1
            """,
            bindings: [
                .text(discoveryID),
                .text(objectDigest)
            ]
        )
        return rows.count == 1
    }

    private func record(from row: [String?]) throws -> ImageSBOMRecord {
        guard row.count == 16,
              let projectID = row[0],
              let serviceName = row[1],
              let descriptorDigest = row[2],
              let policySHA256 = row[3],
              let formatValue = row[4],
              let format = ImageSBOMDocumentFormat(rawValue: formatValue),
              let documentDigest = row[5],
              let documentMediaType = row[6],
              let evidenceDiscoveryID = row[7],
              let evidenceGraphSHA256 = row[8],
              let sbomReferrerDigest = row[9],
              let componentCountText = row[12],
              let componentCount = Int(componentCountText),
              let normalizedComponentsSHA256 = row[13],
              let operationGroupID = row[14],
              let createdAt = row[15] else {
            throw StateStoreError.invalidRecord(
                "Could not decode image SBOM row."
            )
        }

        return try canonicalRecord(
            ImageSBOMRecord(
                projectID: projectID,
                serviceName: serviceName,
                descriptorDigest: descriptorDigest,
                policySHA256: policySHA256,
                format: format,
                documentDigest: documentDigest,
                documentMediaType: documentMediaType,
                evidenceDiscoveryID: evidenceDiscoveryID,
                evidenceGraphSHA256: evidenceGraphSHA256,
                sbomReferrerDigest: sbomReferrerDigest,
                provenanceDescriptorDigest: row[10],
                provenanceReferrerDigest: row[11],
                componentCount: componentCount,
                normalizedComponentsSHA256: normalizedComponentsSHA256,
                operationGroupID: operationGroupID,
                createdAt: createdAt
            )
        )
    }

    private func recordIdentity(for record: ImageSBOMRecord) -> String {
        HostwrightResourceUUID.legacy(
            kind: "image-sbom-record",
            identifier: [
                record.projectID,
                record.serviceName,
                record.descriptorDigest,
                record.policySHA256,
                record.format.rawValue,
                record.documentDigest,
                record.documentMediaType,
                record.evidenceDiscoveryID,
                record.evidenceGraphSHA256,
                record.sbomReferrerDigest,
                record.provenanceDescriptorDigest ?? "",
                record.provenanceReferrerDigest ?? "",
                String(record.componentCount),
                record.normalizedComponentsSHA256
            ].joined(separator: "\u{1f}")
        )
    }

    private func canonicalRecord(_ record: ImageSBOMRecord) throws -> ImageSBOMRecord {
        let projectID = try canonicalName(
            record.projectID,
            label: "Image SBOM project"
        )
        let serviceName = try canonicalName(
            record.serviceName,
            label: "Image SBOM service"
        )
        let descriptorDigest = try canonicalDescriptorDigest(
            record.descriptorDigest
        )
        let policySHA256 = try canonicalSHA256(
            record.policySHA256,
            label: "Image SBOM policy SHA256"
        )
        let documentDigest = try canonicalOCIDigest(
            record.documentDigest,
            label: "Image SBOM document digest"
        )
        try OCIMediaTypePolicy.validate(record.documentMediaType)
        let evidenceDiscoveryID = try canonicalUUID(
            record.evidenceDiscoveryID,
            label: "Image SBOM evidence discovery id"
        )
        let evidenceGraphSHA256 = try canonicalSHA256(
            record.evidenceGraphSHA256,
            label: "Image SBOM evidence graph SHA256"
        )
        let sbomReferrerDigest = try canonicalOCIDigest(
            record.sbomReferrerDigest,
            label: "Image SBOM referrer digest"
        )
        let provenanceDescriptorDigest: String?
        let provenanceReferrerDigest: String?
        switch (
            record.provenanceDescriptorDigest,
            record.provenanceReferrerDigest
        ) {
        case let (.some(descriptor), .some(referrer)):
            provenanceDescriptorDigest = try canonicalOCIDigest(
                descriptor,
                label: "Image SBOM provenance descriptor digest"
            )
            provenanceReferrerDigest = try canonicalOCIDigest(
                referrer,
                label: "Image SBOM provenance referrer digest"
            )
        case (nil, nil):
            provenanceDescriptorDigest = nil
            provenanceReferrerDigest = nil
        default:
            throw StateStoreError.invalidRecord(
                "Image SBOM provenance descriptor and referrer digests must be provided together."
            )
        }
        guard (0...1_000_000).contains(record.componentCount) else {
            throw StateStoreError.invalidRecord(
                "Image SBOM component count must be bounded between 0 and 1000000."
            )
        }
        let normalizedComponentsSHA256 = try canonicalSHA256(
            record.normalizedComponentsSHA256,
            label: "Image SBOM normalized components SHA256"
        )
        let operationGroupID = try canonicalUUID(
            record.operationGroupID,
            label: "Image SBOM operation group id"
        )
        try validateTimestamp(
            record.createdAt,
            label: "Image SBOM created timestamp"
        )

        return ImageSBOMRecord(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            format: record.format,
            documentDigest: documentDigest,
            documentMediaType: record.documentMediaType,
            evidenceDiscoveryID: evidenceDiscoveryID,
            evidenceGraphSHA256: evidenceGraphSHA256,
            sbomReferrerDigest: sbomReferrerDigest,
            provenanceDescriptorDigest: provenanceDescriptorDigest,
            provenanceReferrerDigest: provenanceReferrerDigest,
            componentCount: record.componentCount,
            normalizedComponentsSHA256: normalizedComponentsSHA256,
            operationGroupID: operationGroupID,
            createdAt: record.createdAt
        )
    }

    private func canonicalName(
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

    private func canonicalDescriptorDigest(_ value: String) throws -> String {
        let canonical = value.lowercased()
        guard canonical.range(
            of: #"^sha256:[a-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw StateStoreError.invalidRecord(
                "Image SBOM descriptor digest must use canonical lowercase sha256 form."
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

    private func canonicalOCIDigest(
        _ value: String,
        label: String
    ) throws -> String {
        do {
            return try OCIContentDigest(value).canonicalValue
        } catch {
            throw StateStoreError.invalidRecord(
                "\(label) must be a canonical OCI content digest."
            )
        }
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
                "\(label) must be an ISO8601 timestamp."
            )
        }
    }
}
