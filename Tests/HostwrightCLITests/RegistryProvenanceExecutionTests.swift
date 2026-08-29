import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRegistry
import HostwrightSecrets
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class RegistryProvenanceExecutionTests: XCTestCase {
    func testGenerateVerifyStatusAndSecretNonDisclosure()
        throws
    {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let resolver = ProvenanceFixedResolver(
            privateKey: fixture.privateKey
        )
        let fixedDate = date("2026-07-24T00:05:00Z")
        var environment = CLIEnvironment.live
        environment.secretResolver = { resolver }
        environment.registryDate = { fixedDate }

        let generated = try RegistryProvenanceCommandRunner(
            action: .generate(
                archivePath: fixture.archivePath,
                recordPath: fixture.recordPath,
                manifestPath: fixture.manifestPath,
                serviceName: "api",
                server: "registry.example.test",
                repository: "team/image",
                signerID: "release-builder",
                signingKeyReference:
                    fixture.signingKeyReference
            ),
            stateDatabasePath: fixture.statePath,
            output: .json,
            environment: environment
        ).run()
        let generatedObject = try object(
            generated.standardOutput
        )
        let generatedDetails = try XCTUnwrap(
            generatedObject["details"] as? [String: Any]
        )
        let discoveryID = try XCTUnwrap(
            generatedDetails["discoveryID"] as? String
        )
        let referrerDigest = try XCTUnwrap(
            generatedDetails["referrerDigest"] as? String
        )

        let verified = try RegistryProvenanceCommandRunner(
            action: .verify(
                discoveryID: discoveryID,
                referrerDigest: referrerDigest,
                manifestPath: fixture.manifestPath,
                serviceName: "api"
            ),
            stateDatabasePath: fixture.statePath,
            output: .json,
            environment: environment
        ).run()
        let status = try RegistryProvenanceCommandRunner(
            action: .status(
                manifestPath: fixture.manifestPath,
                serviceName: "api"
            ),
            stateDatabasePath: fixture.statePath,
            output: .json,
            environment: environment
        ).run()

        XCTAssertTrue(
            generated.standardOutput.contains(
                #""status":"generated""#
            )
        )
        XCTAssertTrue(
            verified.standardOutput.contains(
                #""status":"verified""#
            )
        )
        XCTAssertTrue(
            status.standardOutput.contains(
                #""status":"satisfied""#
            )
        )
        XCTAssertEqual(resolver.invocationCount, 1)
        XCTAssertFalse(
            [
                generated.standardOutput,
                verified.standardOutput,
                status.standardOutput
            ].joined().contains(fixture.signingKeyReference)
        )
        XCTAssertFalse(
            [
                generated.standardOutput,
                verified.standardOutput,
                status.standardOutput
            ].joined().contains(fixture.privateKey)
        )

        let store = SQLiteStateStore(path: fixture.statePath)
        let groups = try store.operationGroups.loadAll()
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(
            groups.allSatisfy { $0.status == .succeeded }
        )
        XCTAssertFalse(
            groups.map(\.intentJSONRedacted).joined()
                .contains(fixture.signingKeyReference)
        )
        XCTAssertFalse(
            groups.map(\.intentJSONRedacted).joined()
                .contains(fixture.privateKey)
        )
        let records = try store.imageProvenance.loadRecords(
            projectID: "project-demo",
            serviceName: "api",
            descriptorDigest:
                fixture.subject.canonicalValue,
            policySHA256: try policySHA256(
                manifestPath: fixture.manifestPath,
                environment: environment
            )
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            records[0].referrerDigest,
            referrerDigest
        )
    }

    func testCancelledGenerationResumesOnlyWithExactTypedReference()
        throws
    {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let cancellation = SecureSubprocessCancellation()
        let cancellingResolver = ProvenanceFixedResolver(
            privateKey: fixture.privateKey,
            onResolve: { cancellation.cancel() }
        )
        let fixedDate = date("2026-07-24T00:05:00Z")
        var environment = CLIEnvironment.live
        environment.secretResolver = { cancellingResolver }
        environment.registryDate = { fixedDate }

        XCTAssertThrowsError(
            try RegistryProvenanceCommandRunner(
                action: .generate(
                    archivePath: fixture.archivePath,
                    recordPath: fixture.recordPath,
                    manifestPath: fixture.manifestPath,
                    serviceName: "api",
                    server: "registry.example.test",
                    repository: "team/image",
                    signerID: "release-builder",
                    signingKeyReference:
                        fixture.signingKeyReference
                ),
                stateDatabasePath: fixture.statePath,
                output: .json,
                environment: environment,
                cancellation: cancellation
            ).run()
        ) {
            XCTAssertEqual(
                ($0 as? HostwrightDiagnostic)?.code,
                .partialFailure
            )
        }
        let store = SQLiteStateStore(path: fixture.statePath)
        let interrupted = try XCTUnwrap(
            store.operationGroups.loadAll().first
        )
        XCTAssertEqual(interrupted.status, .interrupted)
        let intent = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    interrupted.intentJSONRedacted.utf8
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(intent.keys),
            [
                "apiVersion", "operation", "projectID",
                "serviceName", "descriptorDigest",
                "policySHA256", "archivePath",
                "archivePathSHA256", "recordPath",
                "recordPathSHA256", "manifestPath",
                "requestedServiceName", "endpoint",
                "repository", "signerID",
                "secretReferenceSHA256", "signingDate"
            ]
        )
        let canonicalIntent = try JSONSerialization.data(
            withJSONObject: intent,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertEqual(
            SHA256.hash(data: canonicalIntent).map {
                String(format: "%02x", $0)
            }.joined(),
            interrupted.planHash
        )
        XCTAssertFalse(
            interrupted.intentJSONRedacted.contains(
                fixture.signingKeyReference
            )
        )

        let wrongReference =
            "keychain://hostwright.provenance/wrong"
        XCTAssertThrowsError(
            try RegistryProvenanceCommandRunner(
                action: .resume(
                    operationGroupID: interrupted.id,
                    confirmationPlanSHA256:
                        interrupted.planHash,
                    signingKeyReference: wrongReference
                ),
                stateDatabasePath: fixture.statePath,
                output: .json,
                environment: environment
            ).run()
        )
        let afterWrongReference = try XCTUnwrap(
            store.operationGroups.load(id: interrupted.id)
        )
        XCTAssertEqual(
            afterWrongReference.status,
            .interrupted
        )
        XCTAssertEqual(
            afterWrongReference.fencingToken,
            interrupted.fencingToken
        )

        let recoveryResolver = ProvenanceFixedResolver(
            privateKey: fixture.privateKey
        )
        environment.secretResolver = { recoveryResolver }
        let resumed = try RegistryProvenanceCommandRunner(
            action: .resume(
                operationGroupID: interrupted.id,
                confirmationPlanSHA256: interrupted.planHash,
                signingKeyReference:
                    fixture.signingKeyReference
            ),
            stateDatabasePath: fixture.statePath,
            output: .json,
            environment: environment
        ).run()

        XCTAssertTrue(
            resumed.standardOutput.contains(
                #""status":"generated""#
            )
        )
        XCTAssertEqual(recoveryResolver.invocationCount, 1)
        XCTAssertEqual(
            try store.operationGroups.load(id: interrupted.id)?
                .status,
            .succeeded
        )
    }

    func testParserRequiresTypedReferenceAndRejectsSecretArguments()
        throws
    {
        let base = [
            "registry", "provenance", "generate",
            "/tmp/image.tar",
            "--record", "/tmp/record.json",
            "--manifest", "/tmp/hostwright.yaml",
            "--server", "registry.example.test",
            "--repository", "team/image",
            "--signer", "release-builder",
            "--signing-key-ref",
            "keychain://hostwright.provenance/release"
        ]
        let parsed = try CLICommand.parse(arguments: base)
        guard case .registry(let options) = parsed,
              case .provenance(.generate(
                  _, _, _, _, _, _, let signer, let reference
              )) = options.action else {
            return XCTFail("Expected provenance generate action.")
        }
        XCTAssertEqual(signer, "release-builder")
        XCTAssertEqual(
            reference,
            "keychain://hostwright.provenance/release"
        )
        XCTAssertThrowsError(
            try CLICommand.parse(
                arguments:
                    Array(base.dropLast()) + ["raw-private-key"]
            )
        )
        XCTAssertThrowsError(
            try CLICommand.parse(
                arguments: base + ["--password", "secret"]
            )
        )
    }

    private func fixture() throws -> ProvenanceCLIFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-provenance-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let archive = try makeArchive(
            at: directory.appendingPathComponent("image.tar")
        )
        let key = Curve25519.Signing.PrivateKey()
        let publicKeyPath = directory
            .appendingPathComponent("release.pub").path
        try key.publicKey.rawRepresentation.write(
            to: URL(fileURLWithPath: publicKeyPath)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: publicKeyPath
        )
        let manifestPath = directory
            .appendingPathComponent("hostwright.yaml").path
        try manifest(
            subject: archive.subject,
            publicKeyPath: publicKeyPath
        ).write(
            toFile: manifestPath,
            atomically: false,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestPath
        )
        let recordPath = directory
            .appendingPathComponent("build-record.json").path
        try buildRecord(subject: archive.subject).write(
            to: URL(fileURLWithPath: recordPath)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recordPath
        )
        return ProvenanceCLIFixture(
            directory: directory,
            archivePath: archive.path,
            manifestPath: manifestPath,
            recordPath: recordPath,
            statePath: directory
                .appendingPathComponent("state.sqlite").path,
            subject: archive.subject,
            privateKey:
                key.rawRepresentation.base64EncodedString(),
            signingKeyReference:
                "keychain://hostwright.provenance/release"
        )
    }

    private func makeArchive(
        at url: URL
    ) throws -> (path: String, subject: OCIContentDigest) {
        let config = try jsonData([
            "architecture": "arm64",
            "os": "linux",
            "rootfs": ["type": "layers", "diff_ids": []]
        ])
        let configDigest = try OCIContentDigest.sha256(
            of: config
        )
        let layer = tar(entries: [
            ("empty", Data(), UInt8(48))
        ])
        let layerDigest = try OCIContentDigest.sha256(
            of: layer
        )
        let manifest = try jsonData([
            "schemaVersion": 2,
            "mediaType":
                OCIReferrerDescriptor.manifestMediaType,
            "config": [
                "mediaType":
                    "application/vnd.oci.image.config.v1+json",
                "digest": configDigest.canonicalValue,
                "size": config.count
            ],
            "layers": [[
                "mediaType":
                    "application/vnd.oci.image.layer.v1.tar",
                "digest": layerDigest.canonicalValue,
                "size": layer.count
            ]]
        ])
        let subject = try OCIContentDigest.sha256(
            of: manifest
        )
        let index = try jsonData([
            "schemaVersion": 2,
            "mediaType": OCIReferrerDescriptor.indexMediaType,
            "manifests": [[
                "mediaType":
                    OCIReferrerDescriptor.manifestMediaType,
                "digest": subject.canonicalValue,
                "size": manifest.count
            ]]
        ])
        let archive = tar(entries: [
            (
                "oci-layout",
                Data(
                    #"{"imageLayoutVersion":"1.0.0"}"#.utf8
                ),
                UInt8(48)
            ),
            ("index.json", index, UInt8(48)),
            (
                "blobs/sha256/\(subject.encoded)",
                manifest,
                UInt8(48)
            ),
            (
                "blobs/sha256/\(configDigest.encoded)",
                config,
                UInt8(48)
            ),
            (
                "blobs/sha256/\(layerDigest.encoded)",
                layer,
                UInt8(48)
            )
        ])
        try archive.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return (url.path, subject)
    }

    private func buildRecord(
        subject: OCIContentDigest
    ) throws -> Data {
        try jsonData([
            "schemaVersion": 1,
            "source": [
                "uri": "https://source.example.test/repository",
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
            "startedAt": "2026-07-24T00:00:00Z",
            "finishedAt": "2026-07-24T00:01:00Z",
            "output": [
                "name": "team/image",
                "digest": subject.canonicalValue
            ],
            "reproducibility": [
                "status": "verified",
                "comparisonDigest": subject.canonicalValue
            ]
        ])
    }

    private func manifest(
        subject: OCIContentDigest,
        publicKeyPath: String
    ) -> String {
        """
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
          maximumAgeSeconds: 3600
          requireReproducible: true
        services:
          api:
            image: registry.example.test/team/image@\(subject.canonicalValue)
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
        """
    }

    private func policySHA256(
        manifestPath: String,
        environment: CLIEnvironment
    ) throws -> String {
        let text = try hostwrightReadManifestText(
            path: manifestPath,
            environment: environment
        )
        let manifest = try hostwrightValidatedManifest(
            text: text,
            teamProfilePath: nil,
            environment: environment
        ).manifest
        return try ImageProvenancePolicyMapping.map(manifest)
            .material.policySHA256
    }

    private func tar(
        entries: [(String, Data, UInt8)]
    ) -> Data {
        var result = Data()
        for (path, payload, type) in entries {
            var header = Data(repeating: 0, count: 512)
            put(path, into: &header, range: 0..<100)
            put("0000600", into: &header, range: 100..<108)
            put("0000000", into: &header, range: 108..<116)
            put("0000000", into: &header, range: 116..<124)
            put(
                String(format: "%011o", payload.count),
                into: &header,
                range: 124..<136
            )
            put(
                "00000000000",
                into: &header,
                range: 136..<148
            )
            for index in 148..<156 { header[index] = 32 }
            header[156] = type
            put("ustar", into: &header, range: 257..<263)
            let checksum = header.reduce(0) {
                $0 + Int($1)
            }
            put(
                String(format: "%06o", checksum),
                into: &header,
                range: 148..<154
            )
            header[154] = 0
            header[155] = 32
            result.append(header)
            result.append(payload)
            result.append(
                Data(
                    repeating: 0,
                    count:
                        (512 - payload.count % 512) % 512
                )
            )
        }
        result.append(Data(repeating: 0, count: 1_024))
        return result
    }

    private func put(
        _ value: String,
        into data: inout Data,
        range: Range<Int>
    ) {
        for (offset, byte) in value.utf8
            .prefix(range.count).enumerated() {
            data[range.lowerBound + offset] = byte
        }
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func object(
        _ value: String
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(value.utf8)
            ) as? [String: Any]
        )
    }

    private func digest(_ scalar: Character) throws
        -> OCIContentDigest
    {
        try OCIContentDigest(
            "sha256:" + String(repeating: scalar, count: 64)
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private struct ProvenanceCLIFixture {
    let directory: URL
    let archivePath: String
    let manifestPath: String
    let recordPath: String
    let statePath: String
    let subject: OCIContentDigest
    let privateKey: String
    let signingKeyReference: String

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ProvenanceFixedResolver:
    HostwrightSecretResolving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let privateKey: String
    private let onResolve: @Sendable () -> Void
    private var count = 0

    init(
        privateKey: String,
        onResolve: @escaping @Sendable () -> Void = {}
    ) {
        self.privateKey = privateKey
        self.onResolve = onResolve
    }

    var invocationCount: Int {
        lock.withLock { count }
    }

    func resolve(
        reference: HostwrightSecretReference,
        for workload: HostwrightSecretWorkloadScope,
        environmentKey: String,
        at resolutionTime: Date
    ) throws -> HostwrightSecretResolution {
        lock.withLock { count += 1 }
        guard reference.rawValue ==
                "keychain://hostwright.provenance/release",
              workload.serviceName == "api",
              workload.generation == 1,
              environmentKey ==
                "HOSTWRIGHT_PROVENANCE_SIGNING_KEY" else {
            throw SecretStoreError.permissionDenied(
                "Unexpected provenance secret boundary."
            )
        }
        onResolve()
        return HostwrightSecretResolution(
            value: try HostwrightSecretValue(privateKey),
            metadata: try HostwrightSecretResolutionMetadata(
                providerID: "keychain",
                providerKind: .keychain,
                version: "1",
                observedAt: resolutionTime
            )
        )
    }
}
