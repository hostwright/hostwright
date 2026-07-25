import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRegistry
import HostwrightRuntime
import HostwrightState

struct RegistryReferrerMutationCoordinator {
    static let groupKind = "oci-referrer-lifecycle"

    let store: SQLiteStateStore
    let client: OCIReferrerRegistryClient
    let output: CLIOutputFormat
    let credentialResolver:
        (RegistryEndpoint) throws ->
            RegistryReferrerCredentialResolution
    let now: () -> Date

    func publish(
        discoveryID: String,
        targetServer: String,
        targetRepository: String
    ) throws -> CLIRunResult {
        guard try store.ociReferrers.loadGraph(
            discoveryID: discoveryID
        ) != nil else {
            throw invalid("The exact verified referrer graph was not found.")
        }
        let endpoint = try RegistryEndpoint(targetServer)
        let repository = try OCIRepositoryName(targetRepository)
        let intent = ReferrerMutationIntent(
            action: .publish,
            discoveryID: discoveryID,
            endpoint: endpoint.canonicalURLString,
            repository: repository.value,
            referrerDigest: nil
        )
        let group = try acquire(intent)
        return try executePublish(intent: intent, group: group)
    }

    func prune(
        discoveryID: String,
        referrerDigest: String,
        confirmationPlanSHA256: String?
    ) throws -> CLIRunResult {
        guard let record = try store.ociReferrers.loadDiscovery(
            id: discoveryID
        ),
        let graph = try store.ociReferrers.loadGraph(
            discoveryID: discoveryID
        ) else {
            throw invalid("The exact verified referrer graph was not found.")
        }
        let digest = try OCIContentDigest(referrerDigest)
        guard graph.verifiedReferrers.contains(
            where: { $0.digest == digest }
        ) else {
            throw invalid(
                "The exact referrer digest is not a verified graph root."
            )
        }
        let intent = ReferrerMutationIntent(
            action: .prune,
            discoveryID: discoveryID,
            endpoint: record.registryEndpoint,
            repository: record.repository,
            referrerDigest: digest.canonicalValue
        )
        let plan = try planHash(intent)
        guard let confirmationPlanSHA256 else {
            return render([
                "apiVersion": "hostwright.dev/oci-referrers/v1",
                "operation": "prune",
                "status": "confirmation-required",
                "discoveryID": discoveryID,
                "referrerDigest": digest.canonicalValue,
                "planSHA256": plan,
                "effects": [
                    "remove exact fallback index membership if present",
                    "delete exact verified Hostwright-owned manifest",
                    "retain all blobs and unrelated manifests"
                ]
            ])
        }
        guard confirmationPlanSHA256 == plan else {
            throw invalid(
                "Referrer prune confirmation does not match the exact current plan."
            )
        }
        let group = try acquire(intent)
        return try executePrune(intent: intent, group: group)
    }

    func resume(
        groupID: String,
        confirmationPlanSHA256: String
    ) throws -> CLIRunResult {
        guard let existing = try store.operationGroups.load(id: groupID),
              existing.groupKind == Self.groupKind,
              existing.planHash == confirmationPlanSHA256 else {
            throw invalid(
                "Referrer recovery requires the exact operation group and plan."
            )
        }
        let intent = try decodeIntent(existing.intentJSONRedacted)
        let timestamp = self.timestamp()
        let group: OperationGroupRecord
        switch existing.status {
        case .interrupted:
            group = try store.operationGroups.resumeInterrupted(
                groupID: existing.id,
                expectedFencingToken: existing.fencingToken,
                lockOwner: "hostwright-referrer-recovery",
                lockExpiresAt: timestampAdding(
                    seconds: 300,
                    to: timestamp
                ),
                updatedAt: timestamp
            )
        case .active:
            let result = try store.operationGroups
                .reclaimExpiredActive(
                    groupID: existing.id,
                    expectedPlanHash: existing.planHash,
                    expectedFencingToken: existing.fencingToken,
                    lockOwner: "hostwright-referrer-recovery",
                    lockExpiresAt: timestampAdding(
                        seconds: 300,
                        to: timestamp
                    ),
                    currentTimestamp: timestamp
                )
            switch result {
            case .reclaimed(let reclaimed):
                group = reclaimed
            case .activeUnexpired:
                throw partial(
                    "The referrer operation lease is still active."
                )
            }
        case .succeeded:
            return render([
                "apiVersion": "hostwright.dev/oci-referrers/v1",
                "operation": "resume",
                "status": "already-succeeded",
                "operationGroupID": existing.id,
                "planSHA256": existing.planHash
            ])
        case .failed:
            throw invalid(
                "A failed referrer operation cannot be resumed."
            )
        }
        switch intent.action {
        case .publish:
            return try executePublish(intent: intent, group: group)
        case .prune:
            return try executePrune(intent: intent, group: group)
        }
    }

    private func executePublish(
        intent: ReferrerMutationIntent,
        group: OperationGroupRecord
    ) throws -> CLIRunResult {
        do {
            guard let graph = try store.ociReferrers.loadGraph(
                discoveryID: intent.discoveryID
            ) else {
                throw invalid(
                    "The recovery graph is no longer available."
                )
            }
            let endpoint = try RegistryEndpoint(intent.endpoint)
            let repository = try OCIRepositoryName(intent.repository)
            let credential = try credentialResolver(endpoint)
            let result = try client.publish(
                graph,
                endpoint: endpoint,
                repository: repository,
                credential: credential.credential,
                credentialKind: credential.kind
            )

            let rootDigests = Set(
                graph.verifiedReferrers.map(\.digest)
            )
            var ownedRoots = Set(
                result.publishedDigests.filter {
                    rootDigests.contains($0)
                }
            )
            if group.checkpoint == "remote-observed",
               let prior = try? decodeVerification(
                   group.verificationJSONRedacted
               ) {
                ownedRoots.formUnion(
                    prior.ownedReferrerDigests.compactMap {
                        try? OCIContentDigest($0)
                    }.filter { rootDigests.contains($0) }
                )
            }
            let verification = ReferrerMutationVerification(
                remoteObserved: true,
                ownedReferrerDigests: ownedRoots.map(
                    \.canonicalValue
                ).sorted()
            )
            try checkpoint(
                group: group,
                name: "remote-observed",
                verification: verification
            )

            let targetDiscovery = OCIReferrerDiscoveryResult(
                endpoint: endpoint,
                repository: repository,
                subjectDigest: graph.discovery.subjectDigest,
                artifactType: graph.discovery.artifactType,
                mode: result.mode,
                serverFilterApplied: false,
                pageCount: 1,
                descriptors: result.verifiedReferrers,
                etag: nil
            )
            let targetGraph = try OCIReferrerGraph(
                discovery: targetDiscovery,
                verifiedReferrers: result.verifiedReferrers,
                objects: graph.objects
            )
            var evidence:
                [OCIContentDigest: OCIReferrerPublicationEvidence] = [:]
            for digest in ownedRoots {
                evidence[digest] = OCIReferrerPublicationEvidence(
                    ownershipProofSHA256: ownershipProof(
                        group: group,
                        endpoint: endpoint,
                        repository: repository,
                        subject: graph.discovery.subjectDigest,
                        referrer: digest
                    ),
                    operationGroupID: group.id
                )
            }
            let record = try store.ociReferrers.saveGraph(
                targetGraph,
                publicationEvidence: evidence,
                observedAt: timestamp()
            )
            try finish(
                group: group,
                status: .succeeded,
                checkpoint: "state-observed"
            )
            return render([
                "apiVersion": "hostwright.dev/oci-referrers/v1",
                "operation": "publish",
                "status": "verified",
                "operationGroupID": group.id,
                "planSHA256": group.planHash,
                "discoveryID": record.id,
                "endpoint": endpoint.canonicalURLString,
                "repository": repository.value,
                "subjectDigest":
                    graph.discovery.subjectDigest.canonicalValue,
                "publishedDigests":
                    result.publishedDigests.map(\.canonicalValue),
                "reusedDigests":
                    result.reusedDigests.map(\.canonicalValue),
                "ownedReferrerDigests":
                    ownedRoots.map(\.canonicalValue).sorted()
            ])
        } catch {
            try? interrupt(group: group, error: error)
            throw error
        }
    }

    private func executePrune(
        intent: ReferrerMutationIntent,
        group: OperationGroupRecord
    ) throws -> CLIRunResult {
        do {
            guard let digestValue = intent.referrerDigest,
                  let graph = try store.ociReferrers.loadGraph(
                      discoveryID: intent.discoveryID
                  ) else {
                throw invalid(
                    "The exact prune recovery graph is unavailable."
                )
            }
            let digest = try OCIContentDigest(digestValue)
            guard !(try store.ociReferrers.hasActiveRetentionLease(
                discoveryID: intent.discoveryID,
                currentTimestamp: timestamp()
            )) else {
                throw invalid(
                    "An active retention lease blocks exact referrer cleanup."
                )
            }
            guard !(try store.imageSBOM.hasActiveReference(
                discoveryID: intent.discoveryID,
                referrerDigest: digest.canonicalValue
            )) else {
                throw invalid(
                    "An immutable image SBOM binding blocks exact referrer cleanup."
                )
            }
            guard !(try store.imageVulnerability.hasActiveReference(
                discoveryID: intent.discoveryID,
                referrerDigest: digest.canonicalValue
            )) else {
                throw invalid(
                    "An immutable image vulnerability report binding blocks exact referrer cleanup."
                )
            }
            guard !(try store.imageProvenance.hasActiveReference(
                discoveryID: intent.discoveryID,
                referrerDigest: digest.canonicalValue
            )) else {
                throw invalid(
                    "An immutable image provenance binding blocks exact referrer cleanup."
                )
            }
            guard let publication =
                try store.ociReferrers.loadPublication(
                    endpoint: intent.endpoint,
                    repository: intent.repository,
                    subjectDigest:
                        graph.discovery.subjectDigest.canonicalValue,
                    referrerDigest: digest.canonicalValue
                ),
            publication.cleanupEligible else {
                throw invalid(
                    "Exact Hostwright ownership evidence is missing or cleanup is already complete."
                )
            }
            let endpoint = try RegistryEndpoint(intent.endpoint)
            let repository = try OCIRepositoryName(intent.repository)
            let credential = try credentialResolver(endpoint)
            let result = try client.removeOwnedReferrer(
                graph: graph,
                referrerDigest: digest,
                endpoint: endpoint,
                repository: repository,
                ownershipProofSHA256:
                    publication.ownershipProofSHA256,
                credential: credential.credential,
                credentialKind: credential.kind
            )
            try checkpoint(
                group: group,
                name: "remote-observed",
                verification: ReferrerMutationVerification(
                    remoteObserved: true,
                    ownedReferrerDigests: []
                )
            )
            guard try store.ociReferrers.markPublicationCleaned(
                endpoint: intent.endpoint,
                repository: intent.repository,
                subjectDigest:
                    graph.discovery.subjectDigest.canonicalValue,
                referrerDigest: digest.canonicalValue,
                expectedOwnershipProofSHA256:
                    publication.ownershipProofSHA256,
                observedAt: timestamp()
            ) else {
                throw partial(
                    "Remote referrer absence is verified but local ownership state could not be fenced."
                )
            }
            try finish(
                group: group,
                status: .succeeded,
                checkpoint: "state-observed"
            )
            return render([
                "apiVersion": "hostwright.dev/oci-referrers/v1",
                "operation": "prune",
                "status": "verified",
                "operationGroupID": group.id,
                "planSHA256": group.planHash,
                "discoveryID": intent.discoveryID,
                "referrerDigest": digest.canonicalValue,
                "removed": result.removed,
                "blobsDeleted": 0
            ])
        } catch {
            try? interrupt(group: group, error: error)
            throw error
        }
    }

    private func acquire(
        _ intent: ReferrerMutationIntent
    ) throws -> OperationGroupRecord {
        let encoded = try encode(intent)
        let plan = sha256(encoded)
        let createdAt = timestamp()
        let id = UUID().uuidString.lowercased()
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: Self.groupKind,
            projectID: nil,
            serviceName: nil,
            plannedActionType: intent.action.rawValue,
            status: .active,
            groupIdempotencyKey: plan,
            planHash: plan,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-referrer-command",
            lockExpiresAt: timestampAdding(
                seconds: 300,
                to: createdAt
            ),
            rollbackAvailable: false,
            manualRecoveryHintRedacted:
                "Resume the exact OCI referrer operation with its operation-group ID and plan SHA-256.",
            createdAt: createdAt,
            updatedAt: createdAt,
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/oci-referrers/v1"}"#,
            fencingToken: UUID().uuidString.lowercased(),
            intentJSONRedacted: String(
                decoding: encoded,
                as: UTF8.self
            ),
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        let acquired = try store.operationGroups.acquire(
            group,
            currentTimestamp: createdAt
        )
        if let value = acquired.acquired {
            return value
        }
        let existing = acquired.existingActive
        throw partial(
            "An exact referrer operation is already active" +
                (existing.map { " as group \($0.id)." } ?? ".")
        )
    }

    private func checkpoint(
        group: OperationGroupRecord,
        name: String,
        verification: ReferrerMutationVerification
    ) throws {
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: name,
            verificationJSONRedacted: String(
                decoding: try encode(verification),
                as: UTF8.self
            ),
            updatedAt: timestamp()
        )
    }

    private func finish(
        group: OperationGroupRecord,
        status: OperationGroupStatus,
        checkpoint: String
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: status,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted:
                status == .succeeded ? "" :
                "Resume the exact OCI referrer operation.",
            updatedAt: timestamp(),
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/oci-referrers/v1"}"#
        )
    }

    private func interrupt(
        group: OperationGroupRecord,
        error: Error
    ) throws {
        try finish(
            group: group,
            status: .interrupted,
            checkpoint: "recovery-required"
        )
        _ = error
    }

    private func ownershipProof(
        group: OperationGroupRecord,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subject: OCIContentDigest,
        referrer: OCIContentDigest
    ) -> String {
        sha256(
            Data(
                [
                    group.id,
                    group.planHash,
                    endpoint.canonicalURLString,
                    repository.value,
                    subject.canonicalValue,
                    referrer.canonicalValue
                ].joined(separator: "\u{1f}").utf8
            )
        )
    }

    private func planHash(
        _ intent: ReferrerMutationIntent
    ) throws -> String {
        sha256(try encode(intent))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decodeIntent(
        _ value: String
    ) throws -> ReferrerMutationIntent {
        do {
            return try JSONDecoder().decode(
                ReferrerMutationIntent.self,
                from: Data(value.utf8)
            )
        } catch {
            throw invalid("Stored referrer recovery intent is invalid.")
        }
    }

    private func decodeVerification(
        _ value: String
    ) throws -> ReferrerMutationVerification {
        try JSONDecoder().decode(
            ReferrerMutationVerification.self,
            from: Data(value.utf8)
        )
    }

    private func render(_ object: [String: Any]) -> CLIRunResult {
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
        return CLIRunResult(
            standardOutput:
                "OCI referrer \(object["operation"] ?? "operation"): " +
                "\(object["status"] ?? "complete")\n"
        )
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: now())
    }

    private func timestampAdding(
        seconds: Int,
        to timestamp: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: timestamp) ?? now()
        return formatter.string(
            from: date.addingTimeInterval(TimeInterval(seconds))
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .registryInvalid, message: message)
    }

    private func partial(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .registryPartialEffect,
            message: message
        )
    }
}

private enum ReferrerMutationAction:
    String,
    Codable,
    Sendable
{
    case publish
    case prune
}

private struct ReferrerMutationIntent: Codable, Sendable {
    let action: ReferrerMutationAction
    let discoveryID: String
    let endpoint: String
    let repository: String
    let referrerDigest: String?
}

private struct ReferrerMutationVerification: Codable, Sendable {
    let remoteObserved: Bool
    let ownedReferrerDigests: [String]
}
