import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRegistry
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleImageProvenancePreflightTests:
    XCTestCase
{
    func testRequiredProvenanceFailsBeforeMutationWhenMissing()
        throws
    {
        try withFixture { fixture in
            XCTAssertThrowsError(
                try lifecyclePreflightImageProvenance(
                    planSHA256:
                        String(repeating: "c", count: 64),
                    projectID: "project-demo",
                    providerID: .appleContainerCLI,
                    desiredState: fixture.desired,
                    store: fixture.store,
                    manifest: fixture.manifest
                )
            ) {
                XCTAssertTrue(
                    String(describing: $0).contains(
                        "Required exact image provenance"
                    )
                )
            }
            XCTAssertTrue(
                try fixture.store.events.loadAll().isEmpty
            )
        }
    }

    func testExactSignedProvenanceAuthorizesLifecycleAndRecovery()
        throws
    {
        try withFixture { fixture in
            try seedProvenance(fixture)
            let plan = try lifecyclePlan(fixture)

            try lifecyclePreflightImageProvenance(
                planSHA256: plan.planSHA256,
                projectID: plan.projectID,
                providerID: plan.providerID,
                desiredState: fixture.desired,
                store: fixture.store,
                manifest: fixture.manifest
            )

            let event = try XCTUnwrap(
                fixture.store.events.loadAll().first {
                    $0.type ==
                        "image.provenance.lifecycle.authorized"
                }
            )
            XCTAssertTrue(
                event.payloadJSONRedacted.contains(
                    plan.planSHA256
                )
            )
            XCTAssertTrue(
                event.payloadJSONRedacted.contains(
                    fixture.digest.canonicalValue
                )
            )
            XCTAssertNoThrow(
                try LifecyclePersistedRecoveryDriver(
                    environment: .live
                ).preflightImageProvenanceRecovery(
                    plan: plan,
                    store: fixture.store
                )
            )
        }
    }

    func testOptionalPolicyRecordsExactNotRequiredProof()
        throws
    {
        try withFixture { fixture in
            var manifest = fixture.manifest
            manifest.imageProvenance?.requirement = .optional

            try lifecyclePreflightImageProvenance(
                planSHA256: String(repeating: "d", count: 64),
                projectID: "project-demo",
                providerID: .appleContainerCLI,
                desiredState: fixture.desired,
                store: fixture.store,
                manifest: manifest
            )

            let event = try XCTUnwrap(
                fixture.store.events.loadAll().first
            )
            XCTAssertEqual(
                event.type,
                "image.provenance.lifecycle.not-required"
            )
            XCTAssertTrue(
                event.payloadJSONRedacted.contains(
                    #""required":false"#
                )
            )
            XCTAssertTrue(
                event.payloadJSONRedacted.contains(
                    try ImageProvenancePolicyMapping.map(
                        manifest
                    ).material.policySHA256
                )
            )
        }
    }

    func testSignerMaterialChangesLifecycleManifestFence()
        throws
    {
        try withFixture { fixture in
            let first = try lifecycleManifestSHA256(
                text: fixture.manifestText,
                manifest: fixture.manifest
            )
            let replacement = Curve25519.Signing.PrivateKey()
            try replacement.publicKey.rawRepresentation.write(
                to: URL(fileURLWithPath: fixture.publicKeyPath),
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fixture.publicKeyPath
            )
            let second = try lifecycleManifestSHA256(
                text: fixture.manifestText,
                manifest: fixture.manifest
            )
            XCTAssertNotEqual(first, second)
        }
    }

    private func seedProvenance(
        _ fixture: ProvenanceLifecycleFixture
    ) throws {
        let build = try ImageBuildProvenanceRecord.parse(
            buildRecord(
                subject: fixture.digest,
                finishedAt: fixture.finishedAt
            ),
            expectedSubjectDigest: fixture.digest
        )
        let signed = try ImageProvenanceDSSEEnvelope.sign(
            statementPayload: build.statementPayload(
                signerID: "release-builder"
            ),
            expectedSubjectDigest: fixture.digest,
            signerID: "release-builder",
            privateKeyText:
                fixture.privateKey.rawRepresentation
                    .base64EncodedString()
        )
        let artifact = try ImageProvenanceArtifact.make(
            envelopePayload: signed.envelopePayload,
            subjectDescriptor: try OCIContentDescriptor(
                mediaType:
                    OCIReferrerDescriptor.manifestMediaType,
                digest: fixture.digest,
                size: 512
            ),
            endpoint: try RegistryEndpoint(
                "https://registry.example.test"
            ),
            repository: try OCIRepositoryName("team/api")
        )
        let discovery = try fixture.store.ociReferrers.saveGraph(
            artifact.graph,
            observedAt: timestamp(Date())
        )
        let mapping = try ImageProvenancePolicyMapping.map(
            fixture.manifest
        )
        let verification = try ImageProvenanceVerifier.verify(
            envelopePayload: signed.envelopePayload,
            expectedSubjectDigest: fixture.digest,
            policy: mapping.policy,
            material: mapping.material,
            at: Date()
        )
        let groupID = try insertOperationGroup(
            store: fixture.store
        )
        _ = try fixture.store.imageProvenance.record(
            ImageProvenanceRecord(
                projectID: "project-demo",
                serviceName: "api",
                referrerDigest:
                    artifact.rootDescriptor.digest.canonicalValue,
                evidenceDiscoveryID: discovery.id,
                evidenceGraphSHA256: discovery.graphSHA256,
                verification: verification,
                operationGroupID: groupID,
                createdAt: timestamp(Date())
            )
        )
    }

    private func lifecyclePlan(
        _ fixture: ProvenanceLifecycleFixture
    ) throws -> LifecyclePlan {
        let desired = try XCTUnwrap(
            fixture.desired.services.first
        )
        return try LifecyclePlan(
            command: .up,
            projectID: "project-demo",
            projectName: "demo",
            projectResourceUUID:
                "11111111-1111-4111-8111-111111111111",
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            manifestSHA256: try lifecycleManifestSHA256(
                text: fixture.manifestText,
                manifest: fixture.manifest
            ),
            observationSHA256:
                String(repeating: "2", count: 64),
            capabilitySHA256:
                String(repeating: "3", count: 64),
            nodes: [
                try LifecyclePlanNode(
                    key: "create-api",
                    action: .create,
                    serviceName: "api",
                    resourceIdentifier: "hostwright-demo-api",
                    resourceUUID:
                        "33333333-3333-4333-8333-333333333333",
                    resourceGeneration: 1,
                    fencingToken:
                        "44444444-4444-4444-8444-444444444444",
                    desiredSpecificationJSONRedacted:
                        try LifecycleRevisionCodec
                            .redactedDesiredJSON(for: desired)
                )
            ]
        )
    }

    private func insertOperationGroup(
        store: SQLiteStateStore
    ) throws -> String {
        let id = HostwrightResourceUUID.generate()
        let identity = id.replacingOccurrences(
            of: "-",
            with: ""
        )
        let record = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "image-provenance-lifecycle-test",
            projectID: "project-demo",
            serviceName: "api",
            plannedActionType: "verify",
            status: .active,
            groupIdempotencyKey: identity + identity,
            planHash: String((identity + identity).reversed()),
            checkpoint: "intent-persisted",
            lockOwner: "test",
            lockExpiresAt: "2099-01-01T00:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "",
            createdAt: timestamp(Date()),
            updatedAt: timestamp(Date()),
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.generate(),
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        let result = try store.operationGroups.acquire(
            record,
            currentTimestamp: record.createdAt
        )
        return try XCTUnwrap(result.acquired?.id)
    }

    private func withFixture(
        _ body: (ProvenanceLifecycleFixture) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-lifecycle-provenance-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyPath = directory
            .appendingPathComponent("release.pub").path
        try privateKey.publicKey.rawRepresentation.write(
            to: URL(fileURLWithPath: publicKeyPath)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: publicKeyPath
        )
        let digest = try OCIContentDigest(
            "sha256:" + String(repeating: "a", count: 64)
        )
        let reference =
            "registry.example.test/team/api@\(digest.canonicalValue)"
        let manifestPath = directory
            .appendingPathComponent("hostwright.yaml").path
        let manifestText = """
        version: 3
        project: demo
        imagePolicy: require-digest
        imageProvenance:
          version: 1
          requirement: required
          builderIDs:
            - urn:hostwright:builder:apple-container
          buildTypes:
            - https://hostwright.dev/build-types/apple-container/v1
          signers:
            - id: release-builder
              publicKey: \(publicKeyPath)
          maximumAgeSeconds: 31536000
          requireReproducible: true
        services:
          api:
            image: \(reference)
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
        """
        try manifestText.write(
            toFile: manifestPath,
            atomically: false,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestPath
        )
        let manifest = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: .live
        ).manifest
        let statePath = directory
            .appendingPathComponent("state.sqlite").path
        let store = SQLiteStateStore(path: statePath)
        try store.migrate()
        let manifestHash = try lifecycleManifestSHA256(
            text: manifestText,
            manifest: manifest
        )
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: manifestPath,
            manifestHash: manifestHash,
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: timestamp(Date()),
            mutationProvider:
                RuntimeProviderID.appleContainerCLI.rawValue
        )
        let lock = try RuntimeImageDigestLock(
            requestedReference: reference,
            resolvedReference: reference,
            descriptorDigest: digest.canonicalValue,
            variantDigest: digest.canonicalValue,
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256:
                String(repeating: "b", count: 64)
        )
        let desired = DesiredRuntimeState(
            projectName: "demo",
            services: [
                DesiredRuntimeService(
                    identity: RuntimeServiceIdentity(
                        projectName: "demo",
                        serviceName: "api"
                    ),
                    logicalServiceName: "api",
                    image: reference,
                    imageLock: lock
                )
            ]
        )
        try body(
            ProvenanceLifecycleFixture(
                store: store,
                manifest: manifest,
                desired: desired,
                digest: digest,
                manifestPath: manifestPath,
                manifestText: manifestText,
                publicKeyPath: publicKeyPath,
                privateKey: privateKey,
                finishedAt: Date().addingTimeInterval(-60)
            )
        )
    }

    private func buildRecord(
        subject: OCIContentDigest,
        finishedAt: Date
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "source": [
                    "uri":
                        "https://source.example.test/repository",
                    "digest": try digest("1").canonicalValue
                ],
                "builder": [
                    "id":
                        "urn:hostwright:builder:apple-container",
                    "version": "1.0.0"
                ],
                "buildType":
                    "https://hostwright.dev/build-types/apple-container/v1",
                "invocationID":
                    "00000000-0000-4000-8000-000000000010",
                "dependencies": [],
                "materials": [[
                    "uri": "urn:hostwright:base-image",
                    "digest": try digest("2").canonicalValue
                ]],
                "command": [
                    "name": "apple-container-build",
                    "version": 1,
                    "contextDigest":
                        try digest("3").canonicalValue,
                    "definitionDigest":
                        try digest("4").canonicalValue
                ],
                "environment": [
                    "mode": "hermetic",
                    "network": "disabled",
                    "variables": [],
                    "secretVariables": []
                ],
                "startedAt":
                    timestamp(
                        finishedAt.addingTimeInterval(-60)
                    ),
                "finishedAt": timestamp(finishedAt),
                "output": [
                    "name": "team/api",
                    "digest": subject.canonicalValue
                ],
                "reproducibility": [
                    "status": "verified",
                    "comparisonDigest":
                        subject.canonicalValue
                ]
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func digest(
        _ scalar: Character
    ) throws -> OCIContentDigest {
        try OCIContentDigest(
            "sha256:" + String(repeating: scalar, count: 64)
        )
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct ProvenanceLifecycleFixture {
    let store: SQLiteStateStore
    let manifest: HostwrightManifest
    let desired: DesiredRuntimeState
    let digest: OCIContentDigest
    let manifestPath: String
    let manifestText: String
    let publicKeyPath: String
    let privateKey: Curve25519.Signing.PrivateKey
    let finishedAt: Date
}
