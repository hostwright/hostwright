import Foundation
import HostwrightCore
import HostwrightRuntime

public struct RuntimeProviderMigrationStateResource: Equatable, Sendable {
    public let resourceIdentifier: String
    public let serviceName: String
    public let identityVersion: Int
    public let resourceUUID: String
    public let resourceGeneration: Int

    public init(
        resourceIdentifier: String,
        serviceName: String,
        identityVersion: Int,
        resourceUUID: String,
        resourceGeneration: Int
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.serviceName = serviceName
        self.identityVersion = identityVersion
        self.resourceUUID = resourceUUID
        self.resourceGeneration = resourceGeneration
    }
}

public enum RuntimeProviderMigrationStateCommitResult: Equatable, Sendable {
    case committed(projectID: String)
    case alreadyCommitted(projectID: String)
}

public extension DesiredStateRepository {
    func commitRuntimeProviderMigration(
        projectResourceUUID: String,
        projectGeneration: Int,
        expectedSourceProviderID: RuntimeProviderID,
        expectedSourceProviderGeneration: Int,
        targetProviderID: RuntimeProviderID,
        targetProviderGeneration: Int,
        targetFencingToken: String,
        resources: [RuntimeProviderMigrationStateResource],
        timestamp: String
    ) throws -> RuntimeProviderMigrationStateCommitResult {
        guard HostwrightResourceUUID.isValid(projectResourceUUID),
              HostwrightResourceUUID.isValid(targetFencingToken),
              projectGeneration > 0,
              expectedSourceProviderGeneration > 0,
              targetProviderGeneration == expectedSourceProviderGeneration + 1,
              expectedSourceProviderID != targetProviderID,
              RuntimeProviderID.knownValues.contains(expectedSourceProviderID),
              RuntimeProviderID.knownValues.contains(targetProviderID),
              !resources.isEmpty,
              resources.allSatisfy({
                  HostwrightResourceUUID.isValid($0.resourceUUID) &&
                      $0.resourceGeneration > 0 &&
                      ($0.identityVersion == 1 ||
                          $0.identityVersion == RuntimeManagedResourceIdentity.currentVersion) &&
                      RuntimeManagedResourceIdentity.isSupportedIdentifier($0.resourceIdentifier) &&
                      !$0.serviceName.isEmpty
              }) else {
            throw StateStoreError.invalidRecord(
                "Runtime provider migration commit requires exact provider generations, UUID ownership, and a non-empty resource set."
            )
        }
        guard Set(resources.map(\.resourceUUID)).count == resources.count,
              Set(resources.map(\.resourceIdentifier)).count == resources.count,
              Set(resources.map(\.serviceName)).count == resources.count else {
            throw StateStoreError.invalidRecord(
                "Runtime provider migration resources must have unique UUIDs, identifiers, and service names."
            )
        }

        return try store.withValidatedConnection { connection in
            try connection.transaction {
                let projectRows = try connection.query(
                    """
                    SELECT id, mutation_provider, provider_generation
                    FROM projects
                    WHERE resource_uuid = ?
                    """,
                    bindings: [.text(projectResourceUUID.lowercased())]
                )
                guard projectRows.count == 1,
                      let projectID = projectRows[0][0],
                      let providerGenerationText = projectRows[0][2],
                      let currentProviderGeneration = Int(providerGenerationText) else {
                    throw StateStoreError.invalidRecord(
                        "Runtime provider migration requires one exact project UUID binding."
                    )
                }
                let currentProviderText = projectRows[0][1]
                let currentProviderID = currentProviderText.flatMap(RuntimeProviderBinding.stableID(for:))

                if currentProviderID == targetProviderID,
                   currentProviderGeneration == targetProviderGeneration {
                    try Self.verifyMigrationOwnership(
                        connection: connection,
                        projectID: projectID,
                        projectResourceUUID: projectResourceUUID,
                        projectGeneration: projectGeneration,
                        providerID: targetProviderID,
                        providerGeneration: targetProviderGeneration,
                        fencingToken: targetFencingToken,
                        resources: resources
                    )
                    return .alreadyCommitted(projectID: projectID)
                }
                guard currentProviderID == expectedSourceProviderID,
                      currentProviderGeneration == expectedSourceProviderGeneration else {
                    throw StateStoreError.invalidRecord(
                        "Runtime provider migration source binding changed before commit."
                    )
                }

                let sourceRecordIDs = try Self.verifySourceMigrationOwnership(
                    connection: connection,
                    projectID: projectID,
                    projectResourceUUID: projectResourceUUID,
                    projectGeneration: projectGeneration,
                    providerID: expectedSourceProviderID,
                    providerGeneration: expectedSourceProviderGeneration,
                    resources: resources
                )
                try Self.refuseConflictingTargetOwnership(
                    connection: connection,
                    providerID: targetProviderID,
                    resources: resources
                )

                try connection.run(
                    """
                    UPDATE projects
                    SET mutation_provider = ?, provider_generation = ?, updated_at = ?
                    WHERE id = ? AND resource_uuid = ? AND provider_generation = ?
                    """,
                    bindings: [
                        .text(targetProviderID.rawValue),
                        .int(targetProviderGeneration),
                        .text(timestamp),
                        .text(projectID),
                        .text(projectResourceUUID.lowercased()),
                        .int(expectedSourceProviderGeneration)
                    ]
                )
                try connection.run(
                    """
                    UPDATE desired_services
                    SET mutation_provider = ?, updated_at = ?
                    WHERE project_id = ?
                    """,
                    bindings: [
                        .text(targetProviderID.rawValue),
                        .text(timestamp),
                        .text(projectID)
                    ]
                )

                for resource in resources.sorted(by: { $0.resourceIdentifier < $1.resourceIdentifier }) {
                    guard let sourceRecordID = sourceRecordIDs[resource.resourceUUID.lowercased()] else {
                        throw StateStoreError.invalidRecord(
                            "Runtime provider migration source ownership record disappeared for \(resource.resourceIdentifier)."
                        )
                    }
                    try connection.run(
                        """
                        UPDATE ownership_records
                        SET runtime_adapter = ?, observed_at = ?, cleanup_eligible = 1,
                            identity_version = ?, resource_generation = ?, project_resource_uuid = ?,
                            project_generation = ?, provider_generation = ?, fencing_token = ?
                        WHERE id = ? AND resource_uuid = ? AND project_id = ? AND service_name = ?
                        """,
                        bindings: [
                            .text(targetProviderID.rawValue),
                            .text(timestamp),
                            .int(resource.identityVersion),
                            .int(resource.resourceGeneration),
                            .text(projectResourceUUID.lowercased()),
                            .int(projectGeneration),
                            .int(targetProviderGeneration),
                            .text(targetFencingToken.lowercased()),
                            .text(sourceRecordID),
                            .text(resource.resourceUUID.lowercased()),
                            .text(projectID),
                            .text(resource.serviceName)
                        ]
                    )
                }

                try Self.verifyMigrationOwnership(
                    connection: connection,
                    projectID: projectID,
                    projectResourceUUID: projectResourceUUID,
                    projectGeneration: projectGeneration,
                    providerID: targetProviderID,
                    providerGeneration: targetProviderGeneration,
                    fencingToken: targetFencingToken,
                    resources: resources
                )
                return .committed(projectID: projectID)
            }
        }
    }

    private static func verifySourceMigrationOwnership(
        connection: SQLiteConnection,
        projectID: String,
        projectResourceUUID: String,
        projectGeneration: Int,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        resources: [RuntimeProviderMigrationStateResource]
    ) throws -> [String: String] {
        var recordIDs: [String: String] = [:]
        for resource in resources {
            let rows = try connection.query(
                """
                SELECT id, runtime_adapter, resource_uuid, resource_generation, project_resource_uuid,
                       project_generation, provider_generation
                FROM ownership_records
                WHERE resource_identifier = ? AND project_id = ? AND service_name = ?
                """,
                bindings: [
                    .text(resource.resourceIdentifier),
                    .text(projectID),
                    .text(resource.serviceName)
                ]
            )
            let matching = rows.filter { row in
                row[1].flatMap(RuntimeProviderBinding.stableID(for:)) == providerID
            }
            guard matching.count == 1,
                  let recordID = matching[0][0],
                  matching[0][2] == resource.resourceUUID.lowercased(),
                  matching[0][3] == String(resource.resourceGeneration),
                  matching[0][4] == projectResourceUUID.lowercased(),
                  matching[0][5] == String(projectGeneration),
                  matching[0][6] == String(providerGeneration) else {
                throw StateStoreError.invalidRecord(
                    "Runtime provider migration source ownership changed for \(resource.resourceIdentifier)."
                )
            }
            recordIDs[resource.resourceUUID.lowercased()] = recordID
        }
        return recordIDs
    }

    private static func refuseConflictingTargetOwnership(
        connection: SQLiteConnection,
        providerID: RuntimeProviderID,
        resources: [RuntimeProviderMigrationStateResource]
    ) throws {
        for resource in resources {
            let rows = try connection.query(
                """
                SELECT runtime_adapter, resource_uuid
                FROM ownership_records
                WHERE resource_identifier = ?
                """,
                bindings: [
                    .text(resource.resourceIdentifier)
                ]
            )
            let targetRows = rows.filter { row in
                row[0].flatMap(RuntimeProviderBinding.stableID(for:)) == providerID
            }
            guard targetRows.isEmpty else {
                throw StateStoreError.invalidRecord(
                    "Runtime provider migration target ownership conflicts for \(resource.resourceIdentifier)."
                )
            }
        }
    }

    private static func verifyMigrationOwnership(
        connection: SQLiteConnection,
        projectID: String,
        projectResourceUUID: String,
        projectGeneration: Int,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        fencingToken: String,
        resources: [RuntimeProviderMigrationStateResource]
    ) throws {
        for resource in resources {
            let rows = try connection.query(
                """
                SELECT resource_uuid, resource_generation, project_resource_uuid,
                       project_generation, provider_generation, fencing_token
                FROM ownership_records
                WHERE resource_identifier = ? AND runtime_adapter = ?
                  AND project_id = ? AND service_name = ?
                """,
                bindings: [
                    .text(resource.resourceIdentifier),
                    .text(providerID.rawValue),
                    .text(projectID),
                    .text(resource.serviceName)
                ]
            )
            guard rows.count == 1,
                  rows[0][0] == resource.resourceUUID.lowercased(),
                  rows[0][1] == String(resource.resourceGeneration),
                  rows[0][2] == projectResourceUUID.lowercased(),
                  rows[0][3] == String(projectGeneration),
                  rows[0][4] == String(providerGeneration),
                  rows[0][5] == fencingToken.lowercased() else {
                throw StateStoreError.invalidRecord(
                    "Runtime provider migration target ownership verification failed for \(resource.resourceIdentifier)."
                )
            }
        }
    }
}
