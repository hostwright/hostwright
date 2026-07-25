import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRegistry
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleImageSBOMPreflightTests: XCTestCase {
    func testRequiredSBOMFailsBeforeMutationWhenEvidenceIsMissing()
        throws
    {
        try withFixture { fixture in
            XCTAssertThrowsError(
                try lifecyclePreflightImageSBOM(
                    planSHA256: String(repeating: "c", count: 64),
                    projectID: "project-demo",
                    providerID: .appleContainerCLI,
                    desiredState: fixture.desired,
                    store: fixture.store,
                    manifest: fixture.manifest
                )
            ) {
                XCTAssertTrue(
                    String(describing: $0).contains(
                        "Required exact image SBOM evidence"
                    )
                )
            }
            XCTAssertTrue(try fixture.store.events.loadAll().isEmpty)
        }
    }

    func testExactSBOMEvidenceAuthorizesLifecycleAndRecovery()
        throws
    {
        try withFixture { fixture in
            try seedSBOM(fixture)
            let plan = try lifecyclePlan(fixture)

            try lifecyclePreflightImageSBOM(
                planSHA256: plan.planSHA256,
                projectID: plan.projectID,
                providerID: plan.providerID,
                desiredState: fixture.desired,
                store: fixture.store,
                manifest: fixture.manifest
            )

            let event = try XCTUnwrap(
                fixture.store.events.loadAll().first {
                    $0.type == "image.sbom.lifecycle.authorized"
                }
            )
            XCTAssertTrue(
                event.payloadJSONRedacted.contains(plan.planSHA256)
            )
            XCTAssertNoThrow(
                try LifecyclePersistedRecoveryDriver(
                    environment: .live
                ).preflightImageSBOMRecovery(
                    plan: plan,
                    store: fixture.store
                )
            )

            let recoveryStore = SQLiteStateStore(
                path: URL(
                    fileURLWithPath: fixture.statePath
                ).deletingLastPathComponent()
                    .appendingPathComponent(
                        "recovery-without-evidence.sqlite"
                    ).path
            )
            try recoveryStore.migrate()
            try recoveryStore.desiredStates.saveManifestSnapshot(
                projectID: "project-demo",
                manifestPath: fixture.manifestPath,
                manifestHash: "recovery-fixture",
                desiredGeneration: 1,
                manifest: fixture.manifest,
                timestamp: "2026-07-24T00:00:00Z",
                mutationProvider:
                    RuntimeProviderID.appleContainerCLI.rawValue
            )
            try recoveryStore.events.append([event])
            XCTAssertThrowsError(
                try LifecyclePersistedRecoveryDriver(
                    environment: .live
                ).preflightImageSBOMRecovery(
                    plan: plan,
                    store: recoveryStore
                )
            )
        }
    }

    func testSBOMPolicyChangesConfirmationManifestHash() throws {
        try withFixture { fixture in
            let source = "version: 2\nproject: demo\n"
            let first = try lifecycleManifestSHA256(
                text: source,
                manifest: fixture.manifest
            )
            var changed = fixture.manifest
            changed.imageSBOM = HostwrightImageSBOMPolicy(
                requirement: .required,
                formats: [.spdxJSON, .cyclonedxJSON]
            )
            let second = try lifecycleManifestSHA256(
                text: source,
                manifest: changed
            )
            XCTAssertNotEqual(first, second)
        }
    }

    private func seedSBOM(_ fixture: Fixture) throws {
        let subject = try OCIContentDigest(fixture.digest)
        let artifact = try ImageSBOMArtifact.make(
            documentPayload: try spdx(subject),
            expectedFormat: .spdxJSON,
            subjectDescriptor: try OCIContentDescriptor(
                mediaType:
                    OCIReferrerDescriptor.manifestMediaType,
                digest: subject,
                size: 512
            ),
            endpoint: try RegistryEndpoint(
                "https://registry.example.test"
            ),
            repository: try OCIRepositoryName("team/api")
        )
        let discovery = try fixture.store.ociReferrers.saveGraph(
            artifact.graph,
            observedAt: "2026-07-24T20:00:00Z"
        )
        _ = try RegistrySBOMCommandRunner(
            action: .ingest(
                discoveryID: discovery.id,
                manifestPath: fixture.manifestPath,
                serviceName: "api"
            ),
            stateDatabasePath: fixture.statePath,
            output: .json,
            environment: .live
        ).run()
    }

    private func lifecyclePlan(
        _ fixture: Fixture
    ) throws -> LifecyclePlan {
        let desired = try XCTUnwrap(fixture.desired.services.first)
        return try LifecyclePlan(
            command: .up,
            projectID: "project-demo",
            projectName: "demo",
            projectResourceUUID:
                "11111111-1111-4111-8111-111111111111",
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            manifestSHA256: String(repeating: "1", count: 64),
            observationSHA256: String(repeating: "2", count: 64),
            capabilitySHA256: String(repeating: "3", count: 64),
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

    private func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-lifecycle-sbom-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory
            .appendingPathComponent("state.sqlite").path
        let manifestPath = directory
            .appendingPathComponent("hostwright.yml").path
        let digest =
            "sha256:" + String(repeating: "a", count: 64)
        let reference =
            "registry.example.test/team/api@\(digest)"
        let manifest = HostwrightManifest(
            version: 2,
            project: "demo",
            imagePolicy: .requireDigest,
            imageTrust: nil,
            imageSBOM: HostwrightImageSBOMPolicy(
                requirement: .required,
                formats: [.spdxJSON]
            ),
            services: [
                HostwrightService(name: "api", image: reference)
            ]
        )
        let manifestText = """
        version: 2
        project: demo
        imagePolicy: require-digest
        imageSBOM:
          version: 1
          requirement: required
          formats:
            - spdx-json
        services:
          api:
            image: \(reference)
        """
        try manifestText.write(
            toFile: manifestPath,
            atomically: false,
            encoding: .utf8
        )
        let store = SQLiteStateStore(path: statePath)
        try store.migrate()
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: manifestPath,
            manifestHash: "fixture",
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: "2026-07-24T00:00:00Z",
            mutationProvider:
                RuntimeProviderID.appleContainerCLI.rawValue
        )
        let lock = try RuntimeImageDigestLock(
            requestedReference: reference,
            resolvedReference: reference,
            descriptorDigest: digest,
            variantDigest: digest,
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "b", count: 64)
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
            Fixture(
                store: store,
                manifest: manifest,
                desired: desired,
                digest: digest,
                statePath: statePath,
                manifestPath: manifestPath
            )
        )
    }

    private func spdx(
        _ subject: OCIContentDigest
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "spdxVersion": "SPDX-2.3",
                "dataLicense": "CC0-1.0",
                "SPDXID": "SPDXRef-DOCUMENT",
                "name": "image sbom",
                "documentNamespace": "urn:hostwright:test",
                "creationInfo": [
                    "created": "2026-07-24T20:00:00Z",
                    "creators": ["Tool: tests"]
                ],
                "packages": [[
                    "name": "image",
                    "SPDXID": "SPDXRef-image",
                    "checksums": [[
                        "algorithm": "SHA256",
                        "checksumValue": subject.encoded
                    ]]
                ]]
            ],
            options: [.sortedKeys]
        )
    }
}

private struct Fixture {
    let store: SQLiteStateStore
    let manifest: HostwrightManifest
    let desired: DesiredRuntimeState
    let digest: String
    let statePath: String
    let manifestPath: String
}
