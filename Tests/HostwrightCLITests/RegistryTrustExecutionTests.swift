import CryptoKit
import Darwin
import Foundation
import HostwrightRegistry
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class RegistryTrustExecutionTests: XCTestCase {
    func testVerifyPersistsExactEvidenceAndStatusReadsIt()
        throws
    {
        try withFixture { fixture in
            var environment = CLIEnvironment.live
            environment.imageTrustVerification = {
                _, _, subjectDigest, bundles, policy in
                let material = try ImageTrustPolicyMaterial.resolve(
                    policy
                )
                return ImageTrustVerificationResult(
                    outcome: .passed,
                    subjectDigest: subjectDigest,
                    matchedAuthorityIDs: ["release"],
                    threshold: 1,
                    verifierVersion: "v3.1.2",
                    verifierSHA256:
                        String(repeating: "f", count: 64),
                    trustedRootSHA256:
                        material.trustedRootSHA256,
                    authorityMaterialSHA256:
                        material.authorityMaterialSHA256,
                    bundleDigests:
                        bundles.map(\.digest).sorted()
                )
            }
            let verify = try RegistryTrustCommandRunner(
                action: .verify(
                    discoveryID: fixture.discoveryID,
                    manifestPath: fixture.manifestPath,
                    subjectManifestPath: fixture.subjectPath,
                    cosignPath: fixture.cosignPath,
                    serviceName: "api"
                ),
                stateDatabasePath: fixture.statePath,
                output: .json,
                environment: environment
            ).run()
            XCTAssertTrue(
                verify.standardOutput.contains(#""status":"passed""#)
            )
            XCTAssertFalse(
                verify.standardOutput.localizedCaseInsensitiveContains(
                    "password"
                )
            )

            let store = SQLiteStateStore(path: fixture.statePath)
            let records = try store.imageTrust.loadVerifications(
                projectID: "project-demo",
                serviceName: "api",
                descriptorDigest: fixture.subjectDigest
            )
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].outcome, "passed")
            XCTAssertEqual(
                records[0].evidenceDiscoveryID,
                fixture.discoveryID
            )
            XCTAssertEqual(
                try store.operationGroups.load(
                    id: records[0].operationGroupID
                )?.status,
                .succeeded
            )
            XCTAssertEqual(
                try store.operationGroups.load(
                    id: records[0].operationGroupID
                )?.projectID,
                "project-demo"
            )
            XCTAssertNotNil(
                try store.imageTrust.loadSubjectManifest(
                    endpoint: "https://registry.example.com",
                    repository: "team/api",
                    descriptorDigest: fixture.subjectDigest
                )
            )

            let status = try RegistryTrustCommandRunner(
                action: .status(
                    manifestPath: fixture.manifestPath,
                    serviceName: "api"
                ),
                stateDatabasePath: fixture.statePath,
                output: .json,
                environment: environment
            ).run()
            XCTAssertTrue(
                status.standardOutput.contains(
                    #""verificationCount":1"#
                )
            )

            let configuration = StateStoreConfiguration(
                explicitDatabasePath: fixture.statePath
            )
            let events = EventsCommandRunner(
                stateStoreConfiguration: configuration,
                projectName: "demo",
                filters: EventFilters(),
                output: .json
            ).run()
            XCTAssertEqual(events.exitCode, 0)
            XCTAssertTrue(
                events.standardOutput.contains(
                    "image.trust.verification.passed"
                )
            )

            let recovery = RecoveryCommandRunner(
                stateStoreConfiguration: configuration,
                action: .inspect,
                projectName: "demo",
                output: .json,
                environment: environment
            ).run()
            XCTAssertEqual(recovery.exitCode, 0)
            XCTAssertTrue(
                recovery.standardOutput.contains(
                    records[0].operationGroupID
                )
            )
        }
    }

    private func withFixture(
        _ body: (TrustExecutionFixture) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-registry-trust-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = Data(#"{"schemaVersion":2}"#.utf8)
        let subjectDigest = digest(subject)
        let subjectPath =
            directory.appendingPathComponent("subject.json").path
        let keyPath = directory.appendingPathComponent("release.pub").path
        let cosignPath =
            directory.appendingPathComponent("cosign").path
        let manifestPath =
            directory.appendingPathComponent("hostwright.yml").path
        let statePath =
            directory.appendingPathComponent("state.sqlite").path
        try subject.write(to: URL(fileURLWithPath: subjectPath))
        try Data("public-key".utf8).write(
            to: URL(fileURLWithPath: keyPath)
        )
        try Data(
            """
            #!/bin/sh
            if [ "$1" = "version" ]; then
              printf '%s' '{"gitVersion":"v3.1.2","platform":"darwin/arm64"}'
              exit 0
            fi
            exit 0
            """.utf8
        ).write(to: URL(fileURLWithPath: cosignPath))
        for path in [subjectPath, keyPath, manifestPath] {
            if path != manifestPath {
                XCTAssertEqual(chmod(path, 0o600), 0)
            }
        }
        XCTAssertEqual(chmod(cosignPath, 0o700), 0)
        let manifest = """
        version: 3
        project: demo
        imagePolicy: require-digest
        imageTrust:
          version: 1
          threshold: 1
          authorities:
            - id: release
              type: keyed
              publicKey: \(keyPath)
        services:
          api:
            image: registry.example.com/team/api@\(subjectDigest)
        """
        try Data(manifest.utf8).write(
            to: URL(fileURLWithPath: manifestPath)
        )
        XCTAssertEqual(chmod(manifestPath, 0o600), 0)

        let bundlePayload = bundlePayload(subject: subject)
        let bundleDigest = try OCIContentDigest.sha256(
            of: bundlePayload
        )
        let bundleDescriptor = try OCIContentDescriptor(
            mediaType: SigstoreBundleEvidence.mediaType,
            digest: bundleDigest,
            size: bundlePayload.count
        )
        let rootPayload = Data("signature-manifest".utf8)
        let rootDigest = try OCIContentDigest.sha256(of: rootPayload)
        let rootDescriptor = try OCIReferrerDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: rootDigest,
            size: rootPayload.count,
            artifactType: try OCIArtifactType(
                SigstoreBundleEvidence.mediaType
            ),
            annotations: [:]
        )
        let discovery = OCIReferrerDiscoveryResult(
            endpoint: try RegistryEndpoint(
                "https://registry.example.com"
            ),
            repository: try OCIRepositoryName("team/api"),
            subjectDigest: try OCIContentDigest(subjectDigest),
            artifactType: nil,
            mode: .native,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: [rootDescriptor],
            etag: nil
        )
        let graph = try OCIReferrerGraph(
            discovery: discovery,
            verifiedReferrers: [rootDescriptor],
            objects: [
                try OCIReferrerFetchedObject(
                    digest: rootDigest,
                    mediaType:
                        OCIReferrerDescriptor.manifestMediaType,
                    size: rootPayload.count,
                    kind: .manifest,
                    payload: rootPayload,
                    childDescriptors: [bundleDescriptor]
                ),
                try OCIReferrerFetchedObject(
                    digest: bundleDigest,
                    mediaType: SigstoreBundleEvidence.mediaType,
                    size: bundlePayload.count,
                    kind: .blob,
                    payload: bundlePayload,
                    childDescriptors: []
                )
            ]
        )
        let store = SQLiteStateStore(path: statePath)
        try store.migrate()
        let record = try store.ociReferrers.saveGraph(
            graph,
            observedAt: "2026-07-24T00:00:00Z"
        )
        try body(
            TrustExecutionFixture(
                statePath: statePath,
                manifestPath: manifestPath,
                subjectPath: subjectPath,
                cosignPath: cosignPath,
                subjectDigest: subjectDigest,
                discoveryID: record.id
            )
        )
    }

    private func bundlePayload(subject: Data) -> Data {
        let encoded = Data(SHA256.hash(data: subject))
            .base64EncodedString()
        return Data(
            """
            {"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","messageSignature":{"messageDigest":{"algorithm":"SHA2_256","digest":"\(encoded)"},"signature":"fixture"},"verificationMaterial":{}}
            """.utf8
        )
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct TrustExecutionFixture {
    let statePath: String
    let manifestPath: String
    let subjectPath: String
    let cosignPath: String
    let subjectDigest: String
    let discoveryID: String
}
