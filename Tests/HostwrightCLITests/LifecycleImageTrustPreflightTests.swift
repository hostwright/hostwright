import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleImageTrustPreflightTests: XCTestCase {
    func testMissingVerificationFailsBeforeMutationBoundary() throws {
        try withFixture { fixture in
            XCTAssertThrowsError(
                try lifecyclePreflightImageTrust(
                    planSHA256: String(repeating: "c", count: 64),
                    projectID: "project-demo",
                    providerID: .appleContainerCLI,
                    desiredState: fixture.desired,
                    store: fixture.store,
                    manifest: fixture.manifest
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "No current image trust verification"
                    )
                )
            }
            XCTAssertTrue(try fixture.store.events.loadAll().isEmpty)
        }
    }

    func testExactActiveExceptionAllowsPreflightAndIsAudited()
        throws
    {
        try withFixture { fixture in
            let material = try ImageTrustPolicyMapping.map(
                fixture.manifest
            ).material
            let exception = try fixture.store.imageTrust.recordException(
                ImageTrustExceptionRecord(
                    projectID: "project-demo",
                    serviceName: "api",
                    descriptorDigest: fixture.digest,
                    policySHA256: material.policySHA256,
                    reason: "bounded emergency rollout",
                    approver: "release-operator",
                    approvedAt: "2020-01-01T00:00:00Z",
                    expiresAt: "2099-01-01T00:00:00Z",
                    idempotencyKey:
                        "11111111-1111-4111-8111-111111111111"
                )
            )

            XCTAssertNoThrow(
                try lifecyclePreflightImageTrust(
                    planSHA256: String(repeating: "c", count: 64),
                    projectID: "project-demo",
                    providerID: .appleContainerCLI,
                    desiredState: fixture.desired,
                    store: fixture.store,
                    manifest: fixture.manifest
                )
            )
            let events = try fixture.store.events.loadAll()
            XCTAssertEqual(events.map(\.type), [
                "image.trust.exception.used",
                "image.trust.lifecycle.authorized"
            ])
            XCTAssertTrue(
                events[0].payloadJSONRedacted.contains(exception.id)
            )
        }
    }

    func testTrustMaterialChangesConfirmationManifestHash()
        throws
    {
        try withFixture { fixture in
            let source = "version: 3\nproject: demo\n"
            let first = try lifecycleManifestSHA256(
                text: source,
                manifest: fixture.manifest
            )
            try Data("replacement-public-key".utf8).write(
                to: URL(fileURLWithPath: fixture.keyPath),
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fixture.keyPath
            )
            let second = try lifecycleManifestSHA256(
                text: source,
                manifest: fixture.manifest
            )
            XCTAssertNotEqual(first, second)
        }
    }

    func testRecoveryRevalidatesPersistedExceptionAuthorization()
        throws
    {
        try withFixture { fixture in
            let policy = try ImageTrustPolicyMapping.map(
                fixture.manifest
            ).material
            let exception = try fixture.store.imageTrust.recordException(
                ImageTrustExceptionRecord(
                    projectID: "project-demo",
                    serviceName: "api",
                    descriptorDigest: fixture.digest,
                    policySHA256: policy.policySHA256,
                    reason: "bounded recovery window",
                    approver: "release-operator",
                    approvedAt: "2020-01-01T00:00:00Z",
                    expiresAt: "2099-01-01T00:00:00Z",
                    idempotencyKey:
                        "22222222-2222-4222-8222-222222222222"
                )
            )
            let desired = try XCTUnwrap(fixture.desired.services.first)
            let plan = try LifecyclePlan(
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

            try lifecyclePreflightImageTrust(
                planSHA256: plan.planSHA256,
                projectID: plan.projectID,
                providerID: plan.providerID,
                desiredState: fixture.desired,
                store: fixture.store,
                manifest: fixture.manifest
            )
            let authorization = try XCTUnwrap(
                fixture.store.events.loadAll().first {
                    $0.type == "image.trust.lifecycle.authorized"
                }
            )
            XCTAssertTrue(
                authorization.payloadJSONRedacted.contains(
                    plan.planSHA256
                )
            )
            XCTAssertTrue(
                authorization.payloadJSONRedacted.contains(
                    exception.id
                )
            )
            let authorizationObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: Data(
                        authorization.payloadJSONRedacted.utf8
                    )
                ) as? [String: Any]
            )
            XCTAssertEqual(
                authorizationObject["projectID"] as? String,
                plan.projectID
            )
            XCTAssertEqual(
                authorizationObject["serviceName"] as? String,
                "api"
            )
            XCTAssertEqual(
                authorizationObject["descriptorDigest"] as? String,
                fixture.digest
            )
            XCTAssertEqual(
                authorizationObject["policySHA256"] as? String,
                policy.policySHA256
            )
            XCTAssertEqual(
                authorizationObject["decision"] as? String,
                "exception"
            )
            XCTAssertNotNil(
                try fixture.store.imageTrust.activeException(
                    projectID: plan.projectID,
                    serviceName: "api",
                    descriptorDigest: fixture.digest,
                    policySHA256: policy.policySHA256,
                    currentTimestamp: hostwrightTimestamp()
                )
            )
            XCTAssertNoThrow(
                try LifecyclePersistedRecoveryDriver(
                    environment: .live
                ).preflightImageTrustRecovery(
                    plan: plan,
                    store: fixture.store
                )
            )

            XCTAssertTrue(
                try fixture.store.imageTrust.revokeException(
                    idempotencyKey: exception.idempotencyKey,
                    revokedAt: "2026-07-24T19:30:00Z"
                )
            )
            XCTAssertThrowsError(
                try LifecyclePersistedRecoveryDriver(
                    environment: .live
                ).preflightImageTrustRecovery(
                    plan: plan,
                    store: fixture.store
                )
            )
        }
    }

    private func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-lifecycle-trust-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyPath = directory.appendingPathComponent("signer.pub").path
        try Data("test-public-key".utf8).write(
            to: URL(fileURLWithPath: keyPath),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyPath
        )
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        let digest =
            "sha256:" + String(repeating: "a", count: 64)
        let reference = "registry.example.com/team/api@\(digest)"
        let manifest = HostwrightManifest(
            version: 3,
            project: "demo",
            imagePolicy: .requireDigest,
            imageTrust: HostwrightImageTrustPolicy(
                threshold: 1,
                authorities: [
                    HostwrightImageTrustAuthority(
                        id: "release",
                        type: .keyed,
                        publicKey: keyPath
                    )
                ]
            ),
            services: [
                HostwrightService(name: "api", image: reference)
            ]
        )
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: "hostwright.yml",
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
                keyPath: keyPath
            )
        )
    }
}

private struct Fixture {
    let store: SQLiteStateStore
    let manifest: HostwrightManifest
    let desired: DesiredRuntimeState
    let digest: String
    let keyPath: String
}
