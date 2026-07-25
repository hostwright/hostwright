import Foundation
import HostwrightCore
import HostwrightRegistry
import HostwrightRuntime
import HostwrightState

struct RegistryReferrerCommandRunner {
    let action: RegistryReferrerCLIAction
    let stateDatabasePath: String?
    let output: CLIOutputFormat
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        do {
            switch action {
            case .discover(
                let server,
                let repository,
                let subjectDigest,
                let artifactType,
                let offline
            ):
                return try discover(
                    server: server,
                    repository: repository,
                    subjectDigest: subjectDigest,
                    artifactType: artifactType,
                    offline: offline
                )
            case .fetch(
                let server,
                let repository,
                let subjectDigest,
                let artifactType,
                let offline
            ):
                return try fetch(
                    server: server,
                    repository: repository,
                    subjectDigest: subjectDigest,
                    artifactType: artifactType,
                    offline: offline
                )
            case .publish(
                let discoveryID,
                let targetServer,
                let targetRepository
            ):
                return try mutationCoordinator().publish(
                    discoveryID: discoveryID,
                    targetServer: targetServer,
                    targetRepository: targetRepository
                )
            case .copy(
                let server,
                let repository,
                let subjectDigest,
                let artifactType,
                let targetServer,
                let targetRepository
            ):
                let cached = try fetchGraph(
                    server: server,
                    repository: repository,
                    subjectDigest: subjectDigest,
                    artifactType: artifactType
                )
                return try mutationCoordinator().publish(
                    discoveryID: cached.record.id,
                    targetServer: targetServer,
                    targetRepository: targetRepository
                )
            case .retain(
                let discoveryID,
                let ownerID,
                let expiresAt
            ):
                return try retain(
                    discoveryID: discoveryID,
                    ownerID: ownerID,
                    expiresAt: expiresAt
                )
            case .release(let leaseID, let fencingToken):
                return try release(
                    leaseID: leaseID,
                    fencingToken: fencingToken
                )
            case .status(let discoveryID):
                return try status(discoveryID: discoveryID)
            case .prune(
                let discoveryID,
                let referrerDigest,
                let confirmation
            ):
                return try mutationCoordinator().prune(
                    discoveryID: discoveryID,
                    referrerDigest: referrerDigest,
                    confirmationPlanSHA256: confirmation
                )
            case .resume(let groupID, let confirmation):
                return try mutationCoordinator().resume(
                    groupID: groupID,
                    confirmationPlanSHA256: confirmation
                )
            }
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch let error as OCIReferrerRegistryError {
            throw registryDiagnostic(error)
        } catch let error as StateStoreError {
            throw HostwrightDiagnostic(
                code: .stateStoreUnavailable,
                message: RuntimeRedactionPolicy.default.redact(
                    String(describing: error)
                )
            )
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: RuntimeRedactionPolicy.default.redact(
                    String(describing: error)
                )
            )
        }
    }

    private func discover(
        server: String,
        repository: String,
        subjectDigest: String,
        artifactType: String?,
        offline: Bool
    ) throws -> CLIRunResult {
        let endpoint = try RegistryEndpoint(server)
        let repository = try OCIRepositoryName(repository)
        let subject = try OCIContentDigest(subjectDigest)
        let artifact = try artifactType.map(OCIArtifactType.init)
        if offline {
            let store = try migratedStore()
            guard let record = try store.ociReferrers.latestDiscovery(
                endpoint: endpoint.canonicalURLString,
                repository: repository.value,
                subjectDigest: subject.canonicalValue,
                artifactType: artifact?.value
            ),
            let graph = try store.ociReferrers.loadGraph(
                discoveryID: record.id
            ) else {
                throw HostwrightDiagnostic(
                    code: .registryTransportUnavailable,
                    message: "No complete verified offline referrer cache matches the exact subject."
                )
            }
            let descriptors = graph.verifiedReferrers.filter {
                artifact == nil || $0.artifactType == artifact
            }
            return render(
                operation: "discover",
                discovery: graph.discovery,
                descriptors: descriptors,
                discoveryID: record.id,
                objectCount: nil,
                totalBytes: nil,
                offline: true
            )
        }
        let credential = try resolvedCredential(endpoint)
        let result = try registryClient().discover(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subject,
            artifactType: artifact,
            credential: credential.credential,
            credentialKind: credential.kind
        )
        return render(
            operation: "discover",
            discovery: result,
            descriptors: result.descriptors,
            discoveryID: nil,
            objectCount: nil,
            totalBytes: nil,
            offline: false
        )
    }

    private func fetch(
        server: String,
        repository: String,
        subjectDigest: String,
        artifactType: String?,
        offline: Bool
    ) throws -> CLIRunResult {
        let endpoint = try RegistryEndpoint(server)
        let repository = try OCIRepositoryName(repository)
        let subject = try OCIContentDigest(subjectDigest)
        let artifact = try artifactType.map(OCIArtifactType.init)
        if offline {
            let store = try migratedStore()
            guard let record = try store.ociReferrers.latestDiscovery(
                endpoint: endpoint.canonicalURLString,
                repository: repository.value,
                subjectDigest: subject.canonicalValue,
                artifactType: artifact?.value
            ),
            let graph = try store.ociReferrers.loadGraph(
                discoveryID: record.id
            ),
            artifact == nil ||
                graph.verifiedReferrers.allSatisfy({
                    $0.artifactType == artifact
                }) else {
                throw HostwrightDiagnostic(
                    code: .registryTransportUnavailable,
                    message: "No complete verified offline referrer graph matches the exact request."
                )
            }
            return renderGraph(
                operation: "fetch",
                graph: graph,
                discoveryID: record.id,
                offline: true
            )
        }
        let cached = try fetchGraph(
            server: server,
            repository: repository.value,
            subjectDigest: subject.canonicalValue,
            artifactType: artifact?.value
        )
        return renderGraph(
            operation: "fetch",
            graph: cached.graph,
            discoveryID: cached.record.id,
            offline: false
        )
    }

    private func fetchGraph(
        server: String,
        repository: String,
        subjectDigest: String,
        artifactType: String?
    ) throws -> (
        graph: OCIReferrerGraph,
        record: OCIReferrerDiscoveryRecord
    ) {
        let endpoint = try RegistryEndpoint(server)
        let repository = try OCIRepositoryName(repository)
        let subject = try OCIContentDigest(subjectDigest)
        let artifact = try artifactType.map(OCIArtifactType.init)
        let credential = try resolvedCredential(endpoint)
        let graph = try registryClient().fetch(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subject,
            artifactType: artifact,
            credential: credential.credential,
            credentialKind: credential.kind
        )
        let record = try migratedStore().ociReferrers.saveGraph(
            graph,
            observedAt: timestamp()
        )
        return (graph, record)
    }

    private func retain(
        discoveryID: String,
        ownerID: String,
        expiresAt: String
    ) throws -> CLIRunResult {
        let lease = try migratedStore().ociReferrers
            .acquireRetentionLease(
                discoveryID: discoveryID,
                ownerID: ownerID,
                acquiredAt: timestamp(),
                expiresAt: expiresAt
            )
        return renderObject([
            "apiVersion": "hostwright.dev/oci-referrers/v1",
            "operation": "retain",
            "status": "retained",
            "discoveryID": lease.discoveryID,
            "leaseID": lease.id,
            "ownerID": lease.ownerID,
            "fencingToken": lease.fencingToken,
            "expiresAt": lease.expiresAt
        ])
    }

    private func release(
        leaseID: String,
        fencingToken: String
    ) throws -> CLIRunResult {
        let released = try migratedStore().ociReferrers
            .releaseRetentionLease(
                id: leaseID,
                expectedFencingToken: fencingToken,
                releasedAt: timestamp()
            )
        guard released else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The exact active retention lease and fencing token did not match."
            )
        }
        return renderObject([
            "apiVersion": "hostwright.dev/oci-referrers/v1",
            "operation": "release",
            "status": "released",
            "leaseID": leaseID
        ])
    }

    private func status(discoveryID: String) throws -> CLIRunResult {
        let store = try migratedStore()
        guard let record = try store.ociReferrers.loadDiscovery(
            id: discoveryID
        ) else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The exact OCI referrer discovery was not found."
            )
        }
        let leases = try store.ociReferrers.loadRetentionLeases(
            discoveryID: discoveryID
        )
        return renderObject([
            "apiVersion": "hostwright.dev/oci-referrers/v1",
            "operation": "status",
            "status": record.complete ? "complete" : "incomplete",
            "discoveryID": record.id,
            "endpoint": record.registryEndpoint,
            "repository": record.repository,
            "subjectDigest": record.subjectDigest,
            "mode": record.discoveryMode,
            "descriptorCount": record.descriptorCount,
            "graphSHA256": record.graphSHA256,
            "observedAt": record.observedAt,
            "leases": leases.map {
                [
                    "id": $0.id,
                    "ownerID": $0.ownerID,
                    "fencingToken": $0.fencingToken,
                    "expiresAt": $0.expiresAt,
                    "releasedAt":
                        $0.releasedAt.map { $0 as Any } ?? NSNull()
                ] as [String: Any]
            }
        ])
    }

    private func renderGraph(
        operation: String,
        graph: OCIReferrerGraph,
        discoveryID: String,
        offline: Bool
    ) -> CLIRunResult {
        render(
            operation: operation,
            discovery: graph.discovery,
            descriptors: graph.verifiedReferrers,
            discoveryID: discoveryID,
            objectCount: graph.objects.count,
            totalBytes: graph.totalBytes,
            offline: offline
        )
    }

    private func render(
        operation: String,
        discovery: OCIReferrerDiscoveryResult,
        descriptors: [OCIReferrerDescriptor],
        discoveryID: String?,
        objectCount: Int?,
        totalBytes: Int?,
        offline: Bool
    ) -> CLIRunResult {
        renderObject([
            "apiVersion": "hostwright.dev/oci-referrers/v1",
            "operation": operation,
            "status": "verified",
            "offline": offline,
            "discoveryID":
                discoveryID.map { $0 as Any } ?? NSNull(),
            "endpoint": discovery.endpoint.canonicalURLString,
            "repository": discovery.repository.value,
            "subjectDigest":
                discovery.subjectDigest.canonicalValue,
            "artifactType": discovery.artifactType
                .map { $0.value as Any } ?? NSNull(),
            "mode": discovery.mode.rawValue,
            "pageCount": discovery.pageCount,
            "serverFilterApplied":
                discovery.serverFilterApplied,
            "descriptorCount": descriptors.count,
            "objectCount":
                objectCount.map { $0 as Any } ?? NSNull(),
            "totalBytes":
                totalBytes.map { $0 as Any } ?? NSNull(),
            "descriptors": descriptors.map {
                [
                    "mediaType": $0.mediaType,
                    "digest": $0.digest.canonicalValue,
                    "size": $0.size,
                    "artifactType": $0.artifactType
                        .map { $0.value as Any } ?? NSNull(),
                    "annotations": $0.annotations
                ] as [String: Any]
            }
        ])
    }

    private func renderObject(
        _ object: [String: Any]
    ) -> CLIRunResult {
        if output == .json {
            let data = try! JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return CLIRunResult(
                standardOutput:
                    String(decoding: data, as: UTF8.self) + "\n"
            )
        }
        let operation = object["operation"] as? String ?? "referrers"
        let status = object["status"] as? String ?? "complete"
        let subject = object["subjectDigest"] as? String
        return CLIRunResult(
            standardOutput:
                "OCI referrer \(operation): \(status)\n" +
                (subject.map { "Subject: \($0)\n" } ?? "")
        )
    }

    private func mutationCoordinator()
        throws -> RegistryReferrerMutationCoordinator
    {
        RegistryReferrerMutationCoordinator(
            store: try migratedStore(),
            client: registryClient(),
            output: output,
            credentialResolver: resolvedCredential,
            now: environment.registryDate
        )
    }

    private func migratedStore() throws -> SQLiteStateStore {
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: stateDatabasePath,
                environment: environment
            )
        )
        try store.migrate()
        return store
    }

    private func registryClient() -> OCIReferrerRegistryClient {
        OCIReferrerRegistryClient(
            authenticationClient: RegistryAuthenticationClient(
                transport: environment.registryTransport(),
                now: environment.registryDate
            )
        )
    }

    private func resolvedCredential(
        _ endpoint: RegistryEndpoint
    ) throws -> RegistryReferrerCredentialResolution {
        let base = try RegistryCommandRunner(
            options: RegistryCLIOptions(
                action: .status(
                    server: endpoint.canonicalURLString,
                    repository: nil,
                    actions: []
                ),
                stateDatabasePath: stateDatabasePath,
                output: output
            ),
            environment: environment
        ).resolveCredential(endpoint)
        return RegistryReferrerCredentialResolution(
            credential: base.credential,
            kind: base.kind
        )
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: environment.registryDate())
    }

    private func registryDiagnostic(
        _ error: OCIReferrerRegistryError
    ) -> HostwrightDiagnostic {
        let code: HostwrightErrorCode
        switch error {
        case .authorizationFailed:
            code = .registryAuthenticationDenied
        case .transportUnavailable:
            code = .registryTransportUnavailable
        case .cancelled:
            code = .registryCancelled
        case .partialEffect:
            code = .registryPartialEffect
        case .invalidRequest, .invalidResponse, .subjectMismatch,
             .digestMismatch, .invalidGraph, .ownershipUnverified,
             .fallbackDigestUnsupported, .fallbackWriteUnavailable,
             .unsafeUploadLocation,
             .unexpectedStatus, .paginationRejected, .limitExceeded:
            code = .registryInvalid
        }
        return HostwrightDiagnostic(
            code: code,
            message: RuntimeRedactionPolicy.default.redact(
                error.description
            )
        )
    }
}

struct RegistryReferrerCredentialResolution {
    let credential: RegistryCredential?
    let kind: RegistryCredentialAuthorizationKind
}
