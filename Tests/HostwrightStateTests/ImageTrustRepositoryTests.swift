import CryptoKit
import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class ImageTrustRepositoryTests: XCTestCase {
    func testExceptionVerificationAndExplicitRevokeRoundTrip() throws {
        try withStore { store in
            try seedProject(store)
            let groupID = HostwrightResourceUUID.generate()
            try insertOperationGroup(id: groupID, into: store)
            let evidenceGraphSHA256 = String(repeating: "c", count: 64)
            let discoveryID = try insertDiscovery(
                graphSHA256: evidenceGraphSHA256,
                into: store
            )

            let savedException = try store.imageTrust.recordException(
                ImageTrustExceptionRecord(
                    projectID: "project-demo",
                    serviceName: "api",
                    descriptorDigest: "sha256:\(String(repeating: "a", count: 64))",
                    policySHA256: String(repeating: "b", count: 64),
                    reason: "operator-approved-rollback-window",
                    approver: "release.lead",
                    approvedAt: "2026-07-24T12:00:00Z",
                    expiresAt: "2026-07-24T14:00:00Z",
                    idempotencyKey: "image-trust-exception-1"
                )
            )

            XCTAssertEqual(
                try store.imageTrust.activeException(
                    projectID: "project-demo",
                    serviceName: "api",
                    descriptorDigest: "sha256:\(String(repeating: "a", count: 64))",
                    policySHA256: String(repeating: "b", count: 64),
                    currentTimestamp: "2026-07-24T13:00:00Z"
                ),
                savedException
            )

            let savedVerification = try store.imageTrust.recordVerification(
                ImageTrustVerificationRecord(
                    projectID: "project-demo",
                    serviceName: "api",
                    descriptorDigest: "sha256:\(String(repeating: "a", count: 64))",
                    policySHA256: String(repeating: "b", count: 64),
                    evidenceGraphSHA256: evidenceGraphSHA256,
                    evidenceDiscoveryID: discoveryID,
                    trustedRootSHA256: String(repeating: "d", count: 64),
                    verifierVersion: "cosign.2.4.1",
                    matchedAuthorityIDs: ["beta", "alpha"],
                    threshold: 2,
                    outcome: "passed",
                    exceptionID: savedException.id,
                    operationGroupID: groupID,
                    createdAt: "2026-07-24T13:00:00Z"
                )
            )

            XCTAssertEqual(
                savedVerification.matchedAuthorityIDs,
                ["alpha", "beta"]
            )
            XCTAssertEqual(
                try store.imageTrust.loadVerifications(
                    projectID: "project-demo",
                    serviceName: "api"
                ),
                [savedVerification]
            )
            XCTAssertTrue(
                try store.imageTrust.revokeException(
                    idempotencyKey: savedException.idempotencyKey,
                    revokedAt: "2026-07-24T13:30:00Z"
                )
            )
            XCTAssertNil(
                try store.imageTrust.activeException(
                    projectID: "project-demo",
                    serviceName: "api",
                    descriptorDigest: "sha256:\(String(repeating: "a", count: 64))",
                    policySHA256: String(repeating: "b", count: 64),
                    currentTimestamp: "2026-07-24T13:30:00Z"
                )
            )
        }
    }

    func testExceptionAndManifestCacheRejectImmutableConflicts() throws {
        try withStore { store in
            try seedProject(store)

            let exception = ImageTrustExceptionRecord(
                projectID: "project-demo",
                serviceName: "api",
                descriptorDigest: "sha256:\(String(repeating: "e", count: 64))",
                policySHA256: String(repeating: "f", count: 64),
                reason: "break-glass-maintenance",
                approver: "ops.oncall",
                approvedAt: "2026-07-24T12:00:00Z",
                expiresAt: "2026-07-24T16:00:00Z",
                idempotencyKey: "image-trust-exception-2"
            )
            _ = try store.imageTrust.recordException(exception)

            XCTAssertThrowsError(
                try store.imageTrust.recordException(
                    ImageTrustExceptionRecord(
                        projectID: exception.projectID,
                        serviceName: exception.serviceName,
                        descriptorDigest: exception.descriptorDigest,
                        policySHA256: exception.policySHA256,
                        reason: "different-reason",
                        approver: exception.approver,
                        approvedAt: exception.approvedAt,
                        expiresAt: exception.expiresAt,
                        idempotencyKey: exception.idempotencyKey
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "different immutable evidence"
                    )
                )
            }

            let payload = try JSONSerialization.data(
                withJSONObject: [
                    "config": [
                        "digest": "sha256:\(String(repeating: "1", count: 64))",
                        "mediaType":
                            "application/vnd.oci.image.config.v1+json",
                        "size": 123
                    ],
                    "layers": [],
                    "mediaType":
                        "application/vnd.oci.image.manifest.v1+json",
                    "schemaVersion": 2
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let payloadSHA256 = sha256(payload)
            let cached = try store.imageTrust.cacheSubjectManifest(
                ImageTrustSubjectManifestRecord(
                    registryEndpoint: "https://registry.example.com",
                    repository: "team/api",
                    descriptorDigest: "sha256:\(payloadSHA256)",
                    payload: payload,
                    payloadSHA256: payloadSHA256,
                    observedAt: "2026-07-24T12:30:00Z"
                )
            )

            XCTAssertEqual(
                try store.imageTrust.loadSubjectManifest(
                    endpoint: cached.registryEndpoint,
                    repository: cached.repository,
                    descriptorDigest: cached.descriptorDigest
                ),
                cached
            )

            XCTAssertThrowsError(
                try store.imageTrust.cacheSubjectManifest(
                    ImageTrustSubjectManifestRecord(
                        registryEndpoint: cached.registryEndpoint,
                        repository: cached.repository,
                        descriptorDigest: cached.descriptorDigest,
                        payload: Data("tampered".utf8),
                        payloadSHA256: sha256(Data("tampered".utf8)),
                        observedAt: "2026-07-24T12:31:00Z"
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "bytes must match"
                    )
                )
            }
        }
    }

    func testVerificationRejectsExpiredExceptionBinding() throws {
        try withStore { store in
            try seedProject(store)
            let groupID = HostwrightResourceUUID.generate()
            try insertOperationGroup(id: groupID, into: store)
            let discoveryID = try insertDiscovery(
                graphSHA256: String(repeating: "7", count: 64),
                into: store
            )

            let exception = try store.imageTrust.recordException(
                ImageTrustExceptionRecord(
                    projectID: "project-demo",
                    serviceName: "api",
                    descriptorDigest: "sha256:\(String(repeating: "9", count: 64))",
                    policySHA256: String(repeating: "8", count: 64),
                    reason: "narrow-window",
                    approver: "ops.lead",
                    approvedAt: "2026-07-24T10:00:00Z",
                    expiresAt: "2026-07-24T10:30:00Z",
                    idempotencyKey: "image-trust-exception-3"
                )
            )

            XCTAssertThrowsError(
                try store.imageTrust.recordVerification(
                    ImageTrustVerificationRecord(
                        projectID: "project-demo",
                        serviceName: "api",
                        descriptorDigest:
                            exception.descriptorDigest,
                        policySHA256: exception.policySHA256,
                        evidenceGraphSHA256:
                            String(repeating: "7", count: 64),
                        evidenceDiscoveryID: discoveryID,
                        trustedRootSHA256:
                            String(repeating: "6", count: 64),
                        verifierVersion: "cosign.2.4.1",
                        matchedAuthorityIDs: ["alpha"],
                        threshold: 1,
                        outcome: "passed",
                        exceptionID: exception.id,
                        operationGroupID: groupID,
                        createdAt: "2026-07-24T11:00:00Z"
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "exact active project, service, descriptor digest, and policy"
                    )
                )
            }
        }
    }

    func testVerificationRejectsUnsupportedOutcome() throws {
        try withStore { store in
            try seedProject(store)
            let groupID = HostwrightResourceUUID.generate()
            try insertOperationGroup(id: groupID, into: store)
            let graphSHA256 = String(repeating: "3", count: 64)
            let discoveryID = try insertDiscovery(
                graphSHA256: graphSHA256,
                into: store
            )

            XCTAssertThrowsError(
                try store.imageTrust.recordVerification(
                    ImageTrustVerificationRecord(
                        projectID: "project-demo",
                        serviceName: "api",
                        descriptorDigest:
                            "sha256:\(String(repeating: "4", count: 64))",
                        policySHA256: String(repeating: "5", count: 64),
                        evidenceGraphSHA256: graphSHA256,
                        evidenceDiscoveryID: discoveryID,
                        trustedRootSHA256:
                            String(repeating: "6", count: 64),
                        verifierVersion: "cosign.3.1.2",
                        matchedAuthorityIDs: ["release"],
                        threshold: 1,
                        outcome: "verified",
                        operationGroupID: groupID,
                        createdAt: "2026-07-24T13:00:00Z"
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "outcome is not supported"
                    )
                )
            }
        }
    }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: "hostwright.yaml",
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: HostwrightManifest(project: "demo", services: []),
            timestamp: "2026-07-24T11:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
        )
    }

    private func insertOperationGroup(
        id: String,
        into store: SQLiteStateStore
    ) throws {
        let record = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "image-trust-lifecycle",
            projectID: "project-demo",
            serviceName: "api",
            plannedActionType: "verify",
            status: .active,
            groupIdempotencyKey: String(repeating: "f", count: 64),
            planHash: String(repeating: "e", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "test",
            lockExpiresAt: "2099-01-01T00:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "",
            createdAt: "2026-07-24T11:59:00Z",
            updatedAt: "2026-07-24T11:59:00Z",
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.generate(),
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        let acquired = try store.operationGroups.acquire(
            record,
            currentTimestamp: record.createdAt
        )
        XCTAssertEqual(acquired.acquired?.id, id)
    }

    private func insertDiscovery(
        graphSHA256: String,
        into store: SQLiteStateStore
    ) throws -> String {
        let id = HostwrightResourceUUID.generate()
        try store.withValidatedConnection { connection in
            try connection.run(
                """
                INSERT INTO oci_referrer_discoveries (
                    id, registry_endpoint, repository, subject_digest,
                    artifact_type, discovery_mode, server_filter_applied,
                    page_count, descriptor_count, graph_sha256, etag,
                    complete, observed_at
                )
                VALUES (?, ?, ?, ?, NULL, 'native', 0, 1, 0, ?, NULL, 1, ?)
                """,
                bindings: [
                    .text(id),
                    .text("https://registry.example.com"),
                    .text("team/api"),
                    .text("sha256:\(String(repeating: "2", count: 64))"),
                    .text(graphSHA256),
                    .text("2026-07-24T11:58:00Z")
                ]
            )
        }
        return id
    }

    private func withStore(
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-image-trust-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        try body(store)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
