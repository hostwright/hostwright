import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRuntime

public struct DesiredStateRepository: Sendable {
    let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func saveManifestSnapshot(
        projectID: String,
        manifestPath: String?,
        manifestHash: String,
        desiredGeneration: Int,
        manifest: HostwrightManifest,
        timestamp: String,
        mutationProvider: String? = nil
    ) throws {
        guard let projectName = manifest.project, !projectName.isEmpty else {
            throw StateStoreError.invalidRecord("Manifest snapshot requires a project name.")
        }
        guard desiredGeneration > 0 else {
            throw StateStoreError.invalidRecord("Manifest snapshot desired generation must be positive.")
        }
        if let mutationProvider,
           mutationProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StateStoreError.invalidRecord("Manifest snapshot mutation provider must be non-empty when supplied.")
        }

        let project = StateProjectRecord(
            id: projectID,
            name: projectName,
            manifestPath: manifestPath,
            manifestHash: manifestHash,
            createdAt: timestamp,
            updatedAt: timestamp,
            manifestVersion: manifest.effectiveVersion,
            mutationProvider: mutationProvider,
            providerGeneration: mutationProvider == nil ? 0 : desiredGeneration
        )

        let services = try manifest.services.map { service in
            try desiredServiceRecord(
                projectID: projectID,
                manifestHash: manifestHash,
                desiredGeneration: desiredGeneration,
                service: service,
                timestamp: timestamp,
                mutationProvider: mutationProvider
            )
        }

        try store.withValidatedConnection { connection in
            try connection.transaction {
                try upsert(project, on: connection)
                for service in services {
                    try upsert(service, on: connection)
                }
            }
        }
    }

    public func loadProject(id: String) throws -> StateProjectRecord {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, name, manifest_path, manifest_hash, created_at, updated_at,
                       resource_uuid, manifest_version, mutation_provider, provider_generation
                FROM projects
                WHERE id = ?
                """,
                bindings: [.text(id)]
            )
            guard let row = rows.first else {
                throw StateStoreError.notFound("Project \(id)")
            }
            return try projectRecord(from: row)
        }
    }

    public func loadDesiredServices(projectID: String) throws -> [DesiredServiceRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, service_name, image, command_json, ports_json, mounts_json,
                       env_json_redacted, manifest_hash, desired_generation, created_at, updated_at,
                       resource_uuid, resource_generation, mutation_provider
                FROM desired_services
                WHERE project_id = ?
                ORDER BY desired_generation ASC, service_name ASC
                """,
                bindings: [.text(projectID)]
            )
            return try rows.map(desiredServiceRecord(from:))
        }
    }

    public func loadRecoverySnapshot(
        projectID: String
    ) throws -> DesiredStateRecoverySnapshot? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let projectRows = try connection.query(
                """
                SELECT id, name, manifest_path, manifest_hash, created_at, updated_at,
                       resource_uuid, manifest_version, mutation_provider, provider_generation
                FROM projects
                WHERE id = ?
                """,
                bindings: [.text(projectID)]
            )
            guard let projectRow = projectRows.first else {
                return nil
            }
            let project = try projectRecord(from: projectRow)
            let serviceRows = try connection.query(
                """
                SELECT id, project_id, service_name, image, command_json, ports_json, mounts_json,
                       env_json_redacted, manifest_hash, desired_generation, created_at, updated_at,
                       resource_uuid, resource_generation, mutation_provider
                FROM desired_services
                WHERE project_id = ? AND desired_generation = ?
                ORDER BY desired_generation ASC, service_name ASC
                """,
                bindings: [
                    .text(projectID),
                    .int(project.providerGeneration)
                ]
            )
            return DesiredStateRecoverySnapshot(
                project: project,
                desiredServices: try serviceRows.map(desiredServiceRecord(from:))
            )
        }
    }

    public func restoreRecoverySnapshot(
        _ snapshot: DesiredStateRecoverySnapshot,
        expectedCurrentManifestHash: String,
        expectedProjectResourceUUID: String,
        expectedMutationProvider: String,
        expectedProviderGeneration: Int
    ) throws {
        try validateRecoverySnapshot(
            snapshot,
            expectedProjectResourceUUID: expectedProjectResourceUUID,
            expectedMutationProvider: expectedMutationProvider,
            expectedProviderGeneration: expectedProviderGeneration
        )

        try store.withValidatedConnection { connection in
            try connection.transaction {
                let projectRows = try connection.query(
                    """
                    SELECT id, name, manifest_path, manifest_hash, created_at, updated_at,
                           resource_uuid, manifest_version, mutation_provider, provider_generation
                    FROM projects
                    WHERE id = ?
                    """,
                    bindings: [.text(snapshot.project.id)]
                )
                guard let projectRow = projectRows.first else {
                    throw StateStoreError.notFound(
                        "Project \(snapshot.project.id)"
                    )
                }
                let current = try projectRecord(from: projectRow)
                guard current.resourceUUID == expectedProjectResourceUUID,
                      current.mutationProvider == expectedMutationProvider,
                      current.providerGeneration == expectedProviderGeneration else {
                    throw StateStoreError.invalidRecord(
                        "Desired-state recovery refused a stale project identity, provider, or generation."
                    )
                }

                if current.manifestHash == snapshot.project.manifestHash {
                    let currentServices = try loadDesiredServices(
                        projectID: snapshot.project.id,
                        desiredGeneration: expectedProviderGeneration,
                        on: connection
                    )
                    guard current == snapshot.project,
                          currentServices == snapshot.desiredServices else {
                        throw StateStoreError.invalidRecord(
                            "Desired-state recovery found a partially restored healthy snapshot."
                        )
                    }
                    return
                }
                guard current.manifestHash == expectedCurrentManifestHash else {
                    throw StateStoreError.invalidRecord(
                        "Desired-state recovery refused to overwrite a newer manifest revision."
                    )
                }

                try connection.run(
                    """
                    DELETE FROM desired_services
                    WHERE project_id = ? AND desired_generation = ?
                    """,
                    bindings: [
                        .text(snapshot.project.id),
                        .int(expectedProviderGeneration)
                    ]
                )
                try connection.run(
                    """
                    UPDATE projects
                    SET name = ?, manifest_path = ?, manifest_hash = ?, created_at = ?,
                        updated_at = ?, resource_uuid = ?, manifest_version = ?,
                        mutation_provider = ?, provider_generation = ?
                    WHERE id = ?
                    """,
                    bindings: [
                        .text(snapshot.project.name),
                        optionalText(snapshot.project.manifestPath),
                        .text(snapshot.project.manifestHash),
                        .text(snapshot.project.createdAt),
                        .text(snapshot.project.updatedAt),
                        .text(snapshot.project.resourceUUID),
                        .int(snapshot.project.manifestVersion),
                        optionalText(snapshot.project.mutationProvider),
                        .int(snapshot.project.providerGeneration),
                        .text(snapshot.project.id)
                    ]
                )
                for service in snapshot.desiredServices {
                    try upsert(service, on: connection)
                }

                guard let restoredProjectRow = try connection.query(
                    """
                    SELECT id, name, manifest_path, manifest_hash, created_at, updated_at,
                           resource_uuid, manifest_version, mutation_provider, provider_generation
                    FROM projects
                    WHERE id = ?
                    """,
                    bindings: [.text(snapshot.project.id)]
                ).first,
                      try projectRecord(from: restoredProjectRow) == snapshot.project,
                      try loadDesiredServices(
                          projectID: snapshot.project.id,
                          desiredGeneration: expectedProviderGeneration,
                          on: connection
                      ) == snapshot.desiredServices else {
                    throw StateStoreError.invalidRecord(
                        "Desired-state recovery could not verify the restored healthy snapshot."
                    )
                }
            }
        }
    }

    private func loadDesiredServices(
        projectID: String,
        desiredGeneration: Int,
        on connection: SQLiteConnection
    ) throws -> [DesiredServiceRecord] {
        let rows = try connection.query(
            """
            SELECT id, project_id, service_name, image, command_json, ports_json, mounts_json,
                   env_json_redacted, manifest_hash, desired_generation, created_at, updated_at,
                   resource_uuid, resource_generation, mutation_provider
            FROM desired_services
            WHERE project_id = ? AND desired_generation = ?
            ORDER BY desired_generation ASC, service_name ASC
            """,
            bindings: [
                .text(projectID),
                .int(desiredGeneration)
            ]
        )
        return try rows.map(desiredServiceRecord(from:))
    }

    private func validateRecoverySnapshot(
        _ snapshot: DesiredStateRecoverySnapshot,
        expectedProjectResourceUUID: String,
        expectedMutationProvider: String,
        expectedProviderGeneration: Int
    ) throws {
        let project = snapshot.project
        let serviceKeys = Set(
            snapshot.desiredServices.map {
                "\($0.serviceName):\($0.desiredGeneration)"
            }
        )
        guard snapshot.schemaVersion ==
                DesiredStateRecoverySnapshot.currentSchemaVersion,
              project.resourceUUID == expectedProjectResourceUUID,
              project.mutationProvider == expectedMutationProvider,
              project.providerGeneration == expectedProviderGeneration,
              expectedProviderGeneration > 0,
              !snapshot.desiredServices.isEmpty,
              serviceKeys.count == snapshot.desiredServices.count,
              snapshot.desiredServices.allSatisfy({
                  $0.projectID == project.id &&
                      $0.manifestHash == project.manifestHash &&
                      $0.desiredGeneration == expectedProviderGeneration &&
                      $0.mutationProvider == expectedMutationProvider &&
                      StateJSON.isArray($0.commandJSON) &&
                      StateJSON.isArray($0.portsJSON) &&
                      StateJSON.isArray($0.mountsJSON) &&
                      StateJSON.isObject($0.environmentJSONRedacted)
              }) else {
            throw StateStoreError.invalidRecord(
                "Desired-state recovery snapshot is not bound to one exact redacted project generation."
            )
        }
    }

    private func desiredServiceRecord(
        projectID: String,
        manifestHash: String,
        desiredGeneration: Int,
        service: HostwrightService,
        timestamp: String,
        mutationProvider: String?
    ) throws -> DesiredServiceRecord {
        guard let image = service.image, !image.isEmpty else {
            throw StateStoreError.invalidRecord("Desired service \(service.name) requires an image.")
        }

        var redactedEnvironment = RuntimeRedactionPolicy.default.redact(environment: service.env)
        for key in service.secretEnv.keys {
            redactedEnvironment[key] = RuntimeRedactionPolicy.default.replacement
        }

        return DesiredServiceRecord(
            id: "\(projectID):\(service.name):\(desiredGeneration)",
            projectID: projectID,
            serviceName: service.name,
            image: image,
            commandJSON: try StateJSON.encodeStringArray(service.command),
            portsJSON: try StateJSON.encodeStringArray(service.ports),
            mountsJSON: try StateJSON.encodeStringArray(service.volumes),
            environmentJSONRedacted: try StateJSON.encode(redactedEnvironment),
            manifestHash: manifestHash,
            desiredGeneration: desiredGeneration,
            createdAt: timestamp,
            updatedAt: timestamp,
            mutationProvider: mutationProvider
        )
    }

    private func upsert(_ project: StateProjectRecord, on connection: SQLiteConnection) throws {
        if let incomingProvider = project.mutationProvider {
            let existingProvider = try connection.query(
                "SELECT mutation_provider FROM projects WHERE id = ? LIMIT 1",
                bindings: [.text(project.id)]
            ).first?.first ?? nil
            if let existingProvider, existingProvider != incomingProvider {
                throw StateStoreError.invalidRecord(
                    "Project \(project.id) is bound to mutation provider \(existingProvider); explicit provider migration is required before using \(incomingProvider)."
                )
            }
        }
        try connection.run(
            """
            INSERT INTO projects (
                id, name, manifest_path, manifest_hash, created_at, updated_at,
                resource_uuid, manifest_version, mutation_provider, provider_generation
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                manifest_path = excluded.manifest_path,
                manifest_hash = excluded.manifest_hash,
                resource_uuid = excluded.resource_uuid,
                manifest_version = excluded.manifest_version,
                mutation_provider = COALESCE(projects.mutation_provider, excluded.mutation_provider),
                provider_generation = MAX(projects.provider_generation, excluded.provider_generation),
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(project.id),
                .text(project.name),
                optionalText(project.manifestPath),
                .text(project.manifestHash),
                .text(project.createdAt),
                .text(project.updatedAt),
                .text(project.resourceUUID),
                .int(project.manifestVersion),
                optionalText(project.mutationProvider),
                .int(project.providerGeneration)
            ]
        )
    }

    private func upsert(_ service: DesiredServiceRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO desired_services (
                id, project_id, service_name, image, command_json, ports_json, mounts_json,
                env_json_redacted, manifest_hash, desired_generation, created_at, updated_at
                , resource_uuid, resource_generation, mutation_provider
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id, service_name, desired_generation) DO UPDATE SET
                image = excluded.image,
                command_json = excluded.command_json,
                ports_json = excluded.ports_json,
                mounts_json = excluded.mounts_json,
                env_json_redacted = excluded.env_json_redacted,
                manifest_hash = excluded.manifest_hash,
                resource_uuid = desired_services.resource_uuid,
                resource_generation = MAX(desired_services.resource_generation, excluded.resource_generation),
                mutation_provider = COALESCE(desired_services.mutation_provider, excluded.mutation_provider),
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(service.id),
                .text(service.projectID),
                .text(service.serviceName),
                .text(service.image),
                .text(service.commandJSON),
                .text(service.portsJSON),
                .text(service.mountsJSON),
                .text(service.environmentJSONRedacted),
                .text(service.manifestHash),
                .int(service.desiredGeneration),
                .text(service.createdAt),
                .text(service.updatedAt),
                .text(service.resourceUUID),
                .int(service.resourceGeneration),
                optionalText(service.mutationProvider)
            ]
        )
    }
}

public struct ObservedStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func saveSnapshot(
        snapshotID: String,
        projectID: String?,
        observedState: ObservedRuntimeState,
        runtimeAdapter: String,
        parserVersion: String,
        rawOutputHash: String?,
        redactedSummary: String,
        observedAt: String
    ) throws {
        let metadata = observedState.adapterMetadata
        let capabilityNames = metadata?.capabilities.map(\.rawValue).sorted() ?? []
        let capabilities = try RuntimeProviderMetadataEvidence.appendingCurrentEvidence(
            to: capabilityNames,
            capabilitySHA256: observedState.capabilitySHA256
        )
        let snapshot = ObservedRuntimeSnapshotRecord(
            id: snapshotID,
            projectID: projectID ?? "",
            runtimeAdapter: runtimeAdapter,
            runtimeName: metadata?.runtimeName ?? "unknown",
            runtimeVersion: metadata?.runtimeVersion,
            observedAt: observedAt,
            parserVersion: parserVersion,
            rawOutputHash: rawOutputHash,
            redactedSummary: RuntimeRedactionPolicy.default.redact(redactedSummary),
            capabilitiesJSON: try StateJSON.encodeStringArray(capabilities)
        )

        let identityCounts = Dictionary(
            grouping: observedState.services,
            by: \.identity
        ).mapValues(\.count)
        let services = try observedState.services
            .sorted {
                ($0.identity.displayName, $0.resourceIdentifier) <
                    ($1.identity.displayName, $1.resourceIdentifier)
            }
            .map { service in
                try observedServiceRecord(
                    snapshotID: snapshotID,
                    service: service,
                    disambiguateResource: identityCounts[service.identity, default: 0] > 1
                )
            }

        try store.withValidatedConnection { connection in
            try connection.transaction {
                try insert(snapshot, projectID: projectID, on: connection)
                for service in services {
                    try insert(service, on: connection)
                }
            }
        }
    }

    public func loadSnapshots(projectID: String?) throws -> [ObservedRuntimeSnapshotRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows: [[String?]]
            if let projectID {
                rows = try connection.query(
                    """
                    SELECT id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                           parser_version, raw_output_hash, redacted_summary, capabilities_json
                    FROM observed_runtime_snapshots
                    WHERE project_id = ?
                    ORDER BY observed_at ASC, id ASC
                    """,
                    bindings: [.text(projectID)]
                )
            } else {
                rows = try connection.query(
                    """
                    SELECT id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                           parser_version, raw_output_hash, redacted_summary, capabilities_json
                    FROM observed_runtime_snapshots
                    ORDER BY observed_at ASC, id ASC
                    """
                )
            }
            return try rows.map(observedSnapshotRecord(from:))
        }
    }

    public func loadLatestSnapshot(
        projectID: String,
        providerID: RuntimeProviderID
    ) throws -> ObservedRuntimeSnapshotRecord? {
        let persistedValues = RuntimeProviderBinding.persistedValues(for: providerID)
        let placeholders = Array(repeating: "?", count: persistedValues.count).joined(separator: ", ")
        let bindings: [SQLiteValue] = [.text(projectID)] + persistedValues.map(SQLiteValue.text)
        return try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                       parser_version, raw_output_hash, redacted_summary, capabilities_json
                FROM observed_runtime_snapshots
                WHERE project_id = ?
                  AND runtime_adapter IN (\(placeholders))
                ORDER BY observed_at DESC, id DESC
                LIMIT 1
                """,
                bindings: bindings
            )
            return try rows.first.map(observedSnapshotRecord(from:))
        }
    }

    public func loadObservedServices(snapshotID: String) throws -> [ObservedServiceRecord] {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT id, snapshot_id, project_name, service_name, instance_name, resource_identifier,
                       image, lifecycle_state, health_state, ports_json, networks_json, mounts_json,
                       runtime_identifiers_json
                FROM observed_services
                WHERE snapshot_id = ?
                ORDER BY service_name ASC, instance_name ASC
                """,
                bindings: [.text(snapshotID)]
            )
            return try rows.map(observedServiceRecord(from:))
        }
    }

    private func observedServiceRecord(
        snapshotID: String,
        service: ObservedRuntimeService,
        disambiguateResource: Bool
    ) throws -> ObservedServiceRecord {
        let identityID = "\(snapshotID):\(service.identity.displayName)"
        let resourceDisambiguator = HostwrightResourceUUID.legacy(
            kind: "observed-service",
            identifier: service.resourceIdentifier
        )
        return ObservedServiceRecord(
            id: disambiguateResource
                ? "\(identityID):\(resourceDisambiguator)"
                : identityID,
            snapshotID: snapshotID,
            projectName: service.identity.projectName,
            serviceName: service.identity.serviceName,
            instanceName: service.identity.instanceName,
            resourceIdentifier: service.resourceIdentifier,
            image: service.image,
            lifecycleState: service.lifecycleState,
            healthState: service.healthState,
            portsJSON: try StateJSON.encode(service.ports.map(portJSON)),
            networksJSON: try StateJSON.encode(service.networks.map(networkJSON)),
            mountsJSON: try StateJSON.encode(service.mounts.map(mountJSON)),
            runtimeIdentifiersJSON: try StateJSON.encode([
                "displayName": service.identity.displayName,
                "observedAt": service.observedAt ?? ""
            ])
        )
    }

    private func insert(_ snapshot: ObservedRuntimeSnapshotRecord, projectID: String?, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO observed_runtime_snapshots (
                id, project_id, runtime_adapter, runtime_name, runtime_version, observed_at,
                parser_version, raw_output_hash, redacted_summary, capabilities_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(snapshot.id),
                optionalText(projectID),
                .text(snapshot.runtimeAdapter),
                .text(snapshot.runtimeName),
                optionalText(snapshot.runtimeVersion),
                .text(snapshot.observedAt),
                .text(snapshot.parserVersion),
                optionalText(snapshot.rawOutputHash),
                .text(snapshot.redactedSummary),
                .text(snapshot.capabilitiesJSON)
            ]
        )
    }

    private func insert(_ service: ObservedServiceRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO observed_services (
                id, snapshot_id, project_name, service_name, instance_name, resource_identifier,
                image, lifecycle_state, health_state, ports_json, networks_json, mounts_json,
                runtime_identifiers_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(service.id),
                .text(service.snapshotID),
                .text(service.projectName),
                .text(service.serviceName),
                optionalText(service.instanceName),
                .text(service.resourceIdentifier),
                optionalText(service.image),
                .text(service.lifecycleState.rawValue),
                .text(service.healthState.rawValue),
                .text(service.portsJSON),
                .text(service.networksJSON),
                .text(service.mountsJSON),
                .text(service.runtimeIdentifiersJSON)
            ]
        )
    }
}
