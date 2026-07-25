import Foundation
import HostwrightCore
import HostwrightRuntime

public struct ImageDigestLockRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func save(_ record: ImageDigestLockRecord) throws {
        try validate(record)
        try store.withValidatedConnection { connection in
            try connection.transaction {
                let existing = try load(id: record.id, on: connection)
                if let existing {
                    guard immutableEvidenceMatches(
                        existing,
                        record
                    ) else {
                        throw StateStoreError.invalidRecord(
                            "Image digest lock identity already exists with different immutable evidence."
                        )
                    }
                    try connection.run(
                        """
                        UPDATE image_digest_locks
                        SET observation_sha256 = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        bindings: [
                            optionalText(record.observationSHA256),
                            .text(record.updatedAt),
                            .text(record.id)
                        ]
                    )
                    return
                }
                try connection.run(
                    """
                    INSERT INTO image_digest_locks (
                        id, project_id, resource_uuid, service_name, replica_index,
                        state_kind, lock_schema_version, requested_reference,
                        resolved_reference, descriptor_digest, variant_digest,
                        operating_system, architecture, runtime_provider,
                        provider_generation, capability_sha256, plan_hash,
                        operation_group_id, observation_sha256, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: bindings(for: record)
                )
            }
        }
    }

    public func load(projectID: String? = nil) throws -> [ImageDigestLockRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let sql: String
            let bindings: [SQLiteValue]
            if let projectID {
                sql = """
                    SELECT id, project_id, resource_uuid, service_name, replica_index,
                           state_kind, lock_schema_version, requested_reference,
                           resolved_reference, descriptor_digest, variant_digest,
                           operating_system, architecture, runtime_provider,
                           provider_generation, capability_sha256, plan_hash,
                           operation_group_id, observation_sha256, created_at, updated_at
                    FROM image_digest_locks
                    WHERE project_id = ?
                    ORDER BY service_name, replica_index, plan_hash, state_kind
                    """
                bindings = [.text(projectID)]
            } else {
                sql = """
                    SELECT id, project_id, resource_uuid, service_name, replica_index,
                           state_kind, lock_schema_version, requested_reference,
                           resolved_reference, descriptor_digest, variant_digest,
                           operating_system, architecture, runtime_provider,
                           provider_generation, capability_sha256, plan_hash,
                           operation_group_id, observation_sha256, created_at, updated_at
                    FROM image_digest_locks
                    ORDER BY project_id, service_name, replica_index, plan_hash, state_kind
                    """
                bindings = []
            }
            return try connection.query(sql, bindings: bindings).map(record(from:))
        }
    }

    public func load(
        planSHA256: String,
        resourceUUID: String,
        stateKind: ImageDigestLockStateKind
    ) throws -> ImageDigestLockRecord? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, resource_uuid, service_name, replica_index,
                       state_kind, lock_schema_version, requested_reference,
                       resolved_reference, descriptor_digest, variant_digest,
                       operating_system, architecture, runtime_provider,
                       provider_generation, capability_sha256, plan_hash,
                       operation_group_id, observation_sha256, created_at, updated_at
                FROM image_digest_locks
                WHERE plan_hash = ? AND resource_uuid = ? AND state_kind = ?
                LIMIT 1
                """,
                bindings: [
                    .text(planSHA256),
                    .text(resourceUUID),
                    .text(stateKind.rawValue)
                ]
            )
            return try rows.first.map(record(from:))
        }
    }

    public func loadCurrent(
        projectID: String,
        maximumRecords: Int = 1_024
    ) throws -> [ImageDigestLockRecord] {
        guard !projectID.isEmpty,
              (1...1_024).contains(maximumRecords) else {
            throw StateStoreError.invalidRecord(
                "Current image digest lock query requires one project and a bounded record limit."
            )
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, resource_uuid, service_name, replica_index,
                       state_kind, lock_schema_version, requested_reference,
                       resolved_reference, descriptor_digest, variant_digest,
                       operating_system, architecture, runtime_provider,
                       provider_generation, capability_sha256, plan_hash,
                       operation_group_id, observation_sha256, created_at, updated_at
                FROM image_digest_locks
                WHERE rowid IN (
                    SELECT MAX(rowid)
                    FROM image_digest_locks
                    WHERE project_id = ?
                    GROUP BY resource_uuid, state_kind
                )
                ORDER BY service_name, replica_index, state_kind
                LIMIT ?
                """,
                bindings: [
                    .text(projectID),
                    .int(maximumRecords)
                ]
            )
            return try rows.map(record(from:))
        }
    }

    public func loadCurrentDesired(
        runtimeProvider: String,
        maximumRecords: Int = 10_000
    ) throws -> [ImageDigestLockRecord] {
        guard RuntimeProviderBinding.stableID(
            for: runtimeProvider
        ) != nil,
        (1...10_000).contains(maximumRecords) else {
            throw StateStoreError.invalidRecord(
                "Current desired image lock query requires one provider and a bounded record limit."
            )
        }
        return try store.withValidatedConnection(
            readOnly: true
        ) { connection in
            let rows = try connection.query(
                """
                SELECT lock.id, lock.project_id, lock.resource_uuid,
                       lock.service_name, lock.replica_index,
                       lock.state_kind, lock.lock_schema_version,
                       lock.requested_reference,
                       lock.resolved_reference,
                       lock.descriptor_digest, lock.variant_digest,
                       lock.operating_system, lock.architecture,
                       lock.runtime_provider,
                       lock.provider_generation,
                       lock.capability_sha256, lock.plan_hash,
                       lock.operation_group_id,
                       lock.observation_sha256,
                       lock.created_at, lock.updated_at
                FROM image_digest_locks AS lock
                JOIN desired_services AS desired
                  ON desired.project_id = lock.project_id
                 AND desired.resource_uuid = lock.resource_uuid
                WHERE lock.state_kind = 'desired'
                  AND lock.runtime_provider = ?
                  AND lock.rowid IN (
                    SELECT MAX(candidate.rowid)
                    FROM image_digest_locks AS candidate
                    WHERE candidate.state_kind = 'desired'
                      AND candidate.runtime_provider = ?
                    GROUP BY candidate.project_id,
                             candidate.resource_uuid
                  )
                ORDER BY lock.project_id, lock.service_name,
                         lock.replica_index
                LIMIT ?
                """,
                bindings: [
                    .text(runtimeProvider),
                    .text(runtimeProvider),
                    .int(maximumRecords)
                ]
            )
            return try rows.map(record(from:))
        }
    }

    private func load(
        id: String,
        on connection: SQLiteConnection
    ) throws -> ImageDigestLockRecord? {
        let rows = try connection.query(
            """
            SELECT id, project_id, resource_uuid, service_name, replica_index,
                   state_kind, lock_schema_version, requested_reference,
                   resolved_reference, descriptor_digest, variant_digest,
                   operating_system, architecture, runtime_provider,
                   provider_generation, capability_sha256, plan_hash,
                   operation_group_id, observation_sha256, created_at, updated_at
            FROM image_digest_locks
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        )
        return try rows.first.map(record(from:))
    }

    private func validate(_ record: ImageDigestLockRecord) throws {
        let digestPattern = "^[a-f0-9]{64}$"
        guard HostwrightResourceUUID.isValid(record.id),
              !record.projectID.isEmpty,
              HostwrightResourceUUID.isValid(record.resourceUUID),
              !record.serviceName.isEmpty,
              record.replicaIndex >= 0,
              record.providerGeneration > 0,
              record.planSHA256.range(
                  of: digestPattern,
                  options: .regularExpression
              ) != nil,
              HostwrightResourceUUID.isValid(record.operationGroupID),
              record.observationSHA256.map({
                  $0.range(of: digestPattern, options: .regularExpression) != nil
              }) ?? true,
              !record.createdAt.isEmpty,
              !record.updatedAt.isEmpty,
              record.lock.schemaVersion ==
                RuntimeImageDigestLock.currentSchemaVersion,
              record.stateKind == .observed
                ? record.observationSHA256 != nil
                : record.observationSHA256 == nil else {
            throw StateStoreError.invalidRecord(
                "Image digest lock record is incomplete or internally inconsistent."
            )
        }
    }

    private func immutableEvidenceMatches(
        _ lhs: ImageDigestLockRecord,
        _ rhs: ImageDigestLockRecord
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.projectID == rhs.projectID &&
            lhs.resourceUUID == rhs.resourceUUID &&
            lhs.serviceName == rhs.serviceName &&
            lhs.replicaIndex == rhs.replicaIndex &&
            lhs.stateKind == rhs.stateKind &&
            lhs.lock == rhs.lock &&
            lhs.providerGeneration == rhs.providerGeneration &&
            lhs.planSHA256 == rhs.planSHA256 &&
            lhs.operationGroupID == rhs.operationGroupID
    }

    private func bindings(for record: ImageDigestLockRecord) -> [SQLiteValue] {
        [
            .text(record.id),
            .text(record.projectID),
            .text(record.resourceUUID),
            .text(record.serviceName),
            .int(record.replicaIndex),
            .text(record.stateKind.rawValue),
            .int(record.lock.schemaVersion),
            .text(record.lock.requestedReference),
            .text(record.lock.resolvedReference),
            .text(record.lock.descriptorDigest),
            .text(record.lock.variantDigest),
            .text(record.lock.operatingSystem),
            .text(record.lock.architecture),
            .text(record.lock.providerID.rawValue),
            .int(record.providerGeneration),
            .text(record.lock.capabilitySHA256),
            .text(record.planSHA256),
            .text(record.operationGroupID),
            optionalText(record.observationSHA256),
            .text(record.createdAt),
            .text(record.updatedAt)
        ]
    }

    private func record(from row: [String?]) throws -> ImageDigestLockRecord {
        guard row.count == 21,
              let id = row[0],
              let projectID = row[1],
              let resourceUUID = row[2],
              let serviceName = row[3],
              let replicaText = row[4],
              let replicaIndex = Int(replicaText),
              let stateText = row[5],
              let stateKind = ImageDigestLockStateKind(rawValue: stateText),
              let schemaText = row[6],
              let schemaVersion = Int(schemaText),
              let requestedReference = row[7],
              let resolvedReference = row[8],
              let descriptorDigest = row[9],
              let variantDigest = row[10],
              let operatingSystem = row[11],
              let architecture = row[12],
              let providerText = row[13],
              let providerGenerationText = row[14],
              let providerGeneration = Int(providerGenerationText),
              let capabilitySHA256 = row[15],
              let planSHA256 = row[16],
              let operationGroupID = row[17],
              let createdAt = row[19],
              let updatedAt = row[20] else {
            throw StateStoreError.invalidRecord(
                "Could not decode image digest lock row."
            )
        }
        let providerID = RuntimeProviderID(rawValue: providerText)
        let lock: RuntimeImageDigestLock
        do {
            lock = try RuntimeImageDigestLock(
                schemaVersion: schemaVersion,
                requestedReference: requestedReference,
                resolvedReference: resolvedReference,
                descriptorDigest: descriptorDigest,
                variantDigest: variantDigest,
                operatingSystem: operatingSystem,
                architecture: architecture,
                providerID: providerID,
                capabilitySHA256: capabilitySHA256
            )
        } catch {
            throw StateStoreError.invalidRecord(
                "Could not validate image digest lock evidence."
            )
        }
        let value = ImageDigestLockRecord(
            id: id,
            projectID: projectID,
            resourceUUID: resourceUUID,
            serviceName: serviceName,
            replicaIndex: replicaIndex,
            stateKind: stateKind,
            lock: lock,
            providerGeneration: providerGeneration,
            planSHA256: planSHA256,
            operationGroupID: operationGroupID,
            observationSHA256: row[18],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        try validate(value)
        return value
    }
}
