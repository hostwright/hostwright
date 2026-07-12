import Foundation
import HostwrightManifest
import HostwrightRuntime

public struct DesiredStateRepository: Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func saveManifestSnapshot(
        projectID: String,
        manifestPath: String?,
        manifestHash: String,
        desiredGeneration: Int,
        manifest: HostwrightManifest,
        timestamp: String
    ) throws {
        guard let projectName = manifest.project, !projectName.isEmpty else {
            throw StateStoreError.invalidRecord("Manifest snapshot requires a project name.")
        }

        let project = StateProjectRecord(
            id: projectID,
            name: projectName,
            manifestPath: manifestPath,
            manifestHash: manifestHash,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let services = try manifest.services.map { service in
            try desiredServiceRecord(
                projectID: projectID,
                manifestHash: manifestHash,
                desiredGeneration: desiredGeneration,
                service: service,
                timestamp: timestamp
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
                SELECT id, name, manifest_path, manifest_hash, created_at, updated_at
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
                       env_json_redacted, manifest_hash, desired_generation, created_at, updated_at
                FROM desired_services
                WHERE project_id = ?
                ORDER BY desired_generation ASC, service_name ASC
                """,
                bindings: [.text(projectID)]
            )
            return try rows.map(desiredServiceRecord(from:))
        }
    }

    private func desiredServiceRecord(
        projectID: String,
        manifestHash: String,
        desiredGeneration: Int,
        service: HostwrightService,
        timestamp: String
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
            updatedAt: timestamp
        )
    }

    private func upsert(_ project: StateProjectRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO projects (id, name, manifest_path, manifest_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                manifest_path = excluded.manifest_path,
                manifest_hash = excluded.manifest_hash,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(project.id),
                .text(project.name),
                optionalText(project.manifestPath),
                .text(project.manifestHash),
                .text(project.createdAt),
                .text(project.updatedAt)
            ]
        )
    }

    private func upsert(_ service: DesiredServiceRecord, on connection: SQLiteConnection) throws {
        try connection.run(
            """
            INSERT INTO desired_services (
                id, project_id, service_name, image, command_json, ports_json, mounts_json,
                env_json_redacted, manifest_hash, desired_generation, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id, service_name, desired_generation) DO UPDATE SET
                image = excluded.image,
                command_json = excluded.command_json,
                ports_json = excluded.ports_json,
                mounts_json = excluded.mounts_json,
                env_json_redacted = excluded.env_json_redacted,
                manifest_hash = excluded.manifest_hash,
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
                .text(service.updatedAt)
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
        let capabilities = metadata?.capabilities.map(\.rawValue).sorted() ?? []
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

        let services = try observedState.services
            .sorted { $0.identity.displayName < $1.identity.displayName }
            .map { service in
                try observedServiceRecord(snapshotID: snapshotID, service: service)
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

    private func observedServiceRecord(snapshotID: String, service: ObservedRuntimeService) throws -> ObservedServiceRecord {
        ObservedServiceRecord(
            id: "\(snapshotID):\(service.identity.displayName)",
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
