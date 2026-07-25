import CryptoKit
import Foundation
@testable import HostwrightRegistry
import XCTest

final class ImageProvenanceTests: XCTestCase {
    func testRegistryPublishFetchRoundTripPreservesVerifiableProvenance()
        throws
    {
        let subject = try digest("9")
        let key = Curve25519.Signing.PrivateKey()
        let record = try ImageBuildProvenanceRecord.parse(
            buildRecord(subject: subject),
            expectedSubjectDigest: subject
        )
        let signed = try ImageProvenanceDSSEEnvelope.sign(
            statementPayload: record.statementPayload(
                signerID: "release-builder"
            ),
            expectedSubjectDigest: subject,
            signerID: "release-builder",
            privateKeyText:
                key.rawRepresentation.base64EncodedString()
        )
        let endpoint = try RegistryEndpoint(
            "https://registry.example.test"
        )
        let repository = try OCIRepositoryName("team/image")
        let artifact = try ImageProvenanceArtifact.make(
            envelopePayload: signed.envelopePayload,
            subjectDescriptor: try subjectDescriptor(subject),
            endpoint: endpoint,
            repository: repository
        )
        let transport = try InMemoryProvenanceRegistryTransport(
            graph: artifact.graph
        )
        let client = OCIReferrerRegistryClient(
            authenticationClient: RegistryAuthenticationClient(
                transport: transport
            )
        )

        let published = try client.publish(
            artifact.graph,
            endpoint: endpoint,
            repository: repository
        )
        let fetched = try client.fetch(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subject,
            artifactType: try OCIArtifactType(
                ImageProvenanceDSSEEnvelope.artifactType
            )
        )
        let evidence = try ImageProvenanceEvidenceExtractor.extract(
            from: fetched,
            expectedSubjectDigest: subject
        )
        let fixture = try policyFixture(
            key: key.publicKey.rawRepresentation
        )
        defer { fixture.cleanup() }
        let verified = try ImageProvenanceVerifier.verify(
            envelopePayload: try XCTUnwrap(
                evidence.first?.envelopePayload
            ),
            expectedSubjectDigest: subject,
            policy: fixture.policy,
            material: fixture.material,
            at: try date("2026-07-24T00:05:00Z")
        )

        XCTAssertEqual(
            Set(published.publishedDigests),
            Set(artifact.graph.objects.map(\.digest))
        )
        XCTAssertEqual(
            fetched.verifiedReferrers,
            artifact.graph.verifiedReferrers
        )
        XCTAssertEqual(
            fetched.objects.sorted {
                $0.digest.canonicalValue <
                    $1.digest.canonicalValue
            },
            artifact.graph.objects.sorted {
                $0.digest.canonicalValue <
                    $1.digest.canonicalValue
            }
        )
        XCTAssertEqual(
            verified.statement.statementDigest,
            signed.envelope.statement.statementDigest
        )
        XCTAssertTrue(transport.sawMutation)
        XCTAssertTrue(transport.sawPostMutationObservation)
    }

    func testGeneratesSignsPublishesExtractsAndVerifiesExactProvenance()
        throws
    {
        let subject = try digest("a")
        let key = Curve25519.Signing.PrivateKey()
        let record = try ImageBuildProvenanceRecord.parse(
            buildRecord(subject: subject),
            expectedSubjectDigest: subject
        )
        let statement = try record.statementPayload(
            signerID: "release-builder"
        )
        let signed = try ImageProvenanceDSSEEnvelope.sign(
            statementPayload: statement,
            expectedSubjectDigest: subject,
            signerID: "release-builder",
            privateKeyText:
                key.rawRepresentation.base64EncodedString()
        )
        let artifact = try ImageProvenanceArtifact.make(
            envelopePayload: signed.envelopePayload,
            subjectDescriptor: try subjectDescriptor(
                subject
            ),
            endpoint: try RegistryEndpoint(
                "https://registry.example.test"
            ),
            repository: try OCIRepositoryName("team/image")
        )
        let evidence = try ImageProvenanceEvidenceExtractor.extract(
            from: artifact.graph,
            expectedSubjectDigest: subject
        )
        let fixture = try policyFixture(
            key: key.publicKey.rawRepresentation
        )
        defer { fixture.cleanup() }

        let verification = try ImageProvenanceVerifier.verify(
            envelopePayload: try XCTUnwrap(
                evidence.first?.envelopePayload
            ),
            expectedSubjectDigest: subject,
            policy: fixture.policy,
            material: fixture.material,
            at: try date("2026-07-24T00:05:00Z")
        )

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(
            evidence[0].referrerDigest,
            artifact.rootDescriptor.digest
        )
        XCTAssertEqual(
            verification.statement.statementDigest,
            signed.envelope.statement.statementDigest
        )
        XCTAssertEqual(
            verification.statement.subjectDigest,
            subject
        )
        XCTAssertEqual(
            verification.envelopeDigest,
            signed.envelope.envelopeDigest
        )
        XCTAssertEqual(
            verification.signerPublicKeySHA256,
            signed.publicKeySHA256
        )
        XCTAssertEqual(
            verification.policySHA256,
            fixture.material.policySHA256
        )
        XCTAssertEqual(
            verification.statement.resolvedDependencies.map(\.uri),
            [
                "https://packages.example.test/library.json",
                "https://source.example.test/repository",
                "urn:hostwright:base-image"
            ]
        )
    }

    func testRejectsTamperedDSSEPayloadAndWrongSignerMaterial()
        throws
    {
        let subject = try digest("b")
        let key = Curve25519.Signing.PrivateKey()
        let record = try ImageBuildProvenanceRecord.parse(
            buildRecord(subject: subject),
            expectedSubjectDigest: subject
        )
        let signed = try ImageProvenanceDSSEEnvelope.sign(
            statementPayload: record.statementPayload(
                signerID: "release-builder"
            ),
            expectedSubjectDigest: subject,
            signerID: "release-builder",
            privateKeyText:
                key.rawRepresentation.base64EncodedString()
        )
        let fixture = try policyFixture(
            key: key.publicKey.rawRepresentation
        )
        defer { fixture.cleanup() }
        let tampered = try tamperBuilderVersion(
            signed.envelopePayload
        )

        XCTAssertThrowsError(
            try ImageProvenanceVerifier.verify(
                envelopePayload: tampered,
                expectedSubjectDigest: subject,
                policy: fixture.policy,
                material: fixture.material,
                at: try date("2026-07-24T00:05:00Z")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .signatureInvalid
            )
        }

        let wrongFixture = try policyFixture(
            key: Curve25519.Signing.PrivateKey()
                .publicKey.rawRepresentation
        )
        defer { wrongFixture.cleanup() }
        XCTAssertThrowsError(
            try ImageProvenanceVerifier.verify(
                envelopePayload: signed.envelopePayload,
                expectedSubjectDigest: subject,
                policy: wrongFixture.policy,
                material: wrongFixture.material,
                at: try date("2026-07-24T00:05:00Z")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .signatureInvalid
            )
        }
    }

    func testRejectsWrongSubjectBuilderAgeAndReproducibility()
        throws
    {
        let subject = try digest("c")
        let key = Curve25519.Signing.PrivateKey()
        let signed = try signedFixture(
            subject: subject,
            key: key,
            reproducibilityStatus: "not-verified"
        )
        let fixture = try policyFixture(
            key: key.publicKey.rawRepresentation,
            requireReproducible: true
        )
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try ImageProvenanceVerifier.verify(
                envelopePayload: signed,
                expectedSubjectDigest: try digest("d"),
                policy: fixture.policy,
                material: fixture.material,
                at: try date("2026-07-24T00:05:00Z")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .invalidStatement
            )
        }
        XCTAssertThrowsError(
            try ImageProvenanceVerifier.verify(
                envelopePayload: signed,
                expectedSubjectDigest: subject,
                policy: fixture.policy,
                material: fixture.material,
                at: try date("2026-07-24T00:05:00Z")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .policyRejected
            )
        }

        let builderFixture = try policyFixture(
            key: key.publicKey.rawRepresentation,
            builderIDs: ["urn:hostwright:builder:other"]
        )
        defer { builderFixture.cleanup() }
        XCTAssertThrowsError(
            try ImageProvenanceVerifier.verify(
                envelopePayload: signed,
                expectedSubjectDigest: subject,
                policy: builderFixture.policy,
                material: builderFixture.material,
                at: try date("2026-07-24T00:05:00Z")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .policyRejected
            )
        }

        let ageFixture = try policyFixture(
            key: key.publicKey.rawRepresentation,
            maximumAgeSeconds: 60
        )
        defer { ageFixture.cleanup() }
        XCTAssertThrowsError(
            try ImageProvenanceVerifier.verify(
                envelopePayload: signed,
                expectedSubjectDigest: subject,
                policy: ageFixture.policy,
                material: ageFixture.material,
                at: try date("2026-07-24T00:10:00Z")
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .policyRejected
            )
        }
    }

    func testStrictRecordRejectsSecretsHostPathsAndUnknownFields()
        throws
    {
        let subject = try digest("e")
        var unknown = try jsonObject(
            buildRecord(subject: subject)
        )
        unknown["buildArgs"] = ["--secret", "value"]
        XCTAssertThrowsError(
            try ImageBuildProvenanceRecord.parse(
                try jsonData(unknown),
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .invalidRecord
            )
        }

        var hostPath = try jsonObject(
            buildRecord(subject: subject)
        )
        hostPath["source"] = [
            "uri": "file:///Users/example/private",
            "digest": try digest("1").canonicalValue
        ]
        XCTAssertThrowsError(
            try ImageBuildProvenanceRecord.parse(
                try jsonData(hostPath),
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .invalidRecord
            )
        }

        var credentialQuery = try jsonObject(
            buildRecord(subject: subject)
        )
        credentialQuery["source"] = [
            "uri":
                "https://source.example.test/repository?token=do-not-record",
            "digest": try digest("1").canonicalValue
        ]
        XCTAssertThrowsError(
            try ImageBuildProvenanceRecord.parse(
                try jsonData(credentialQuery),
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .invalidRecord
            )
        }

        var secretValue = try jsonObject(
            buildRecord(subject: subject)
        )
        var environment = try XCTUnwrap(
            secretValue["environment"] as? [String: Any]
        )
        environment["secretVariables"] = [
            "REGISTRY_TOKEN=do-not-record"
        ]
        secretValue["environment"] = environment
        XCTAssertThrowsError(
            try ImageBuildProvenanceRecord.parse(
                try jsonData(secretValue),
                expectedSubjectDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .invalidRecord
            )
        }
    }

    func testRejectsConflictingResourceDigestAcrossInputSets()
        throws
    {
        let subject = try digest("f")
        var object = try jsonObject(
            buildRecord(subject: subject)
        )
        object["dependencies"] = [[
            "uri": "https://source.example.test/repository",
            "digest": try digest("9").canonicalValue
        ]]
        let record = try ImageBuildProvenanceRecord.parse(
            try jsonData(object),
            expectedSubjectDigest: subject
        )

        XCTAssertThrowsError(
            try record.statementPayload(
                signerID: "release-builder"
            )
        ) {
            XCTAssertEqual(
                $0 as? ImageProvenanceError,
                .invalidRecord
            )
        }
    }

    private func signedFixture(
        subject: OCIContentDigest,
        key: Curve25519.Signing.PrivateKey,
        reproducibilityStatus: String
    ) throws -> Data {
        let record = try ImageBuildProvenanceRecord.parse(
            buildRecord(
                subject: subject,
                reproducibilityStatus: reproducibilityStatus
            ),
            expectedSubjectDigest: subject
        )
        return try ImageProvenanceDSSEEnvelope.sign(
            statementPayload: record.statementPayload(
                signerID: "release-builder"
            ),
            expectedSubjectDigest: subject,
            signerID: "release-builder",
            privateKeyText:
                key.rawRepresentation.base64EncodedString()
        ).envelopePayload
    }

    private func buildRecord(
        subject: OCIContentDigest,
        reproducibilityStatus: String = "verified"
    ) throws -> Data {
        var reproducibility: [String: Any] = [
            "status": reproducibilityStatus
        ]
        if reproducibilityStatus == "verified" {
            reproducibility["comparisonDigest"] =
                subject.canonicalValue
        }
        return try jsonData([
            "schemaVersion": 1,
            "source": [
                "uri": "https://source.example.test/repository",
                "digest": try digest("1").canonicalValue
            ],
            "builder": [
                "id": "urn:hostwright:builder:apple-container",
                "version": "1.0.0"
            ],
            "buildType":
                "https://hostwright.dev/build-types/apple-container/v1",
            "invocationID":
                "00000000-0000-4000-8000-000000000010",
            "dependencies": [[
                "uri": "https://packages.example.test/library.json",
                "digest": try digest("2").canonicalValue
            ]],
            "materials": [[
                "uri": "urn:hostwright:base-image",
                "digest": try digest("3").canonicalValue
            ]],
            "command": [
                "name": "apple-container-build",
                "version": 1,
                "contextDigest": try digest("4").canonicalValue,
                "definitionDigest":
                    try digest("5").canonicalValue,
                "target": "release"
            ],
            "environment": [
                "mode": "allowlisted",
                "network": "declared",
                "variables": ["LANG"],
                "secretVariables": ["REGISTRY_TOKEN"]
            ],
            "startedAt": "2026-07-24T00:00:00Z",
            "finishedAt": "2026-07-24T00:01:00Z",
            "output": [
                "name": "team/image",
                "digest": subject.canonicalValue
            ],
            "reproducibility": reproducibility
        ])
    }

    private func policyFixture(
        key: Data,
        builderIDs: [String] = [
            "urn:hostwright:builder:apple-container"
        ],
        maximumAgeSeconds: Int = 3_600,
        requireReproducible: Bool = false
    ) throws -> (
        policy: ImageProvenancePolicy,
        material: ImageProvenancePolicyMaterial,
        cleanup: () -> Void
    ) {
        let directory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "hostwright-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let keyURL = directory.appendingPathComponent("signer.pub")
        try key.write(to: keyURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyURL.path
        )
        let policy = try ImageProvenancePolicy(
            requirement: .required,
            builderIDs: builderIDs,
            buildTypes: [
                "https://hostwright.dev/build-types/apple-container/v1"
            ],
            signers: [
                try ImageProvenanceSigner(
                    id: "release-builder",
                    publicKeyPath: keyURL.path
                )
            ],
            maximumAgeSeconds: maximumAgeSeconds,
            requireReproducible: requireReproducible
        )
        let material = try ImageProvenancePolicyMaterial.resolve(
            policy
        )
        return (
            policy,
            material,
            {
                try? FileManager.default.removeItem(at: directory)
            }
        )
    }

    private func tamperBuilderVersion(_ envelope: Data) throws
        -> Data
    {
        var object = try jsonObject(envelope)
        let payload = try XCTUnwrap(
            Data(
                base64Encoded: try XCTUnwrap(
                    object["payload"] as? String
                )
            )
        )
        var statement = try jsonObject(payload)
        var predicate = try XCTUnwrap(
            statement["predicate"] as? [String: Any]
        )
        var runDetails = try XCTUnwrap(
            predicate["runDetails"] as? [String: Any]
        )
        var builder = try XCTUnwrap(
            runDetails["builder"] as? [String: Any]
        )
        builder["version"] = ["hostwright": "tampered"]
        runDetails["builder"] = builder
        predicate["runDetails"] = runDetails
        statement["predicate"] = predicate
        object["payload"] = try jsonData(statement)
            .base64EncodedString()
        return try jsonData(object)
    }

    private func subjectDescriptor(
        _ subject: OCIContentDigest
    ) throws -> OCIContentDescriptor {
        try OCIContentDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: subject,
            size: 512
        )
    }

    private func digest(_ scalar: Character) throws
        -> OCIContentDigest
    {
        try OCIContentDigest(
            "sha256:" + String(repeating: scalar, count: 64)
        )
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func jsonObject(_ data: Data) throws
        -> [String: Any]
    {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private final class InMemoryProvenanceRegistryTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let subjectDigest: OCIContentDigest
    private let rootDescriptor: OCIReferrerDescriptor
    private let expectedObjects:
        [OCIContentDigest: OCIReferrerFetchedObject]
    private var storedObjects:
        [OCIContentDigest: OCIReferrerFetchedObject] = [:]
    private var rootPublished = false
    private var mutationObserved = false
    private var postMutationObserved = false
    private var uploadSequence = 0

    init(graph: OCIReferrerGraph) throws {
        guard graph.verifiedReferrers.count == 1,
              let root = graph.verifiedReferrers.first else {
            throw RegistryTransportError.invalidResponse
        }
        subjectDigest = graph.discovery.subjectDigest
        rootDescriptor = root
        expectedObjects = Dictionary(
            uniqueKeysWithValues: graph.objects.map {
                ($0.digest, $0)
            }
        )
    }

    var sawMutation: Bool {
        lock.withLock { mutationObserved }
    }

    var sawPostMutationObservation: Bool {
        lock.withLock { postMutationObserved }
    }

    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        try lock.withLock {
            guard !cancellation.isCancelled else {
                throw RegistryTransportError.cancelled
            }
            if request.url.path.contains("/referrers/") {
                guard request.method == .get else {
                    throw RegistryTransportError.invalidMethod
                }
                if mutationObserved {
                    postMutationObserved = true
                }
                return try indexResponse()
            }
            if request.method == .post,
               request.url.path.contains("/blobs/uploads") {
                uploadSequence += 1
                mutationObserved = true
                return response(
                    202,
                    headers: [
                        "location":
                            "/v2/team/image/blobs/uploads/" +
                            "session-\(uploadSequence)"
                    ]
                )
            }
            if request.url.path.contains("/blobs/uploads/") {
                guard request.method == .put,
                      let digestValue = URLComponents(
                          url: request.url,
                          resolvingAgainstBaseURL: false
                      )?.queryItems?.first(where: {
                          $0.name == "digest"
                      })?.value,
                      let body = request.body else {
                    throw RegistryTransportError.invalidResponse
                }
                let digest = try OCIContentDigest(digestValue)
                try store(body, digest: digest, kind: .blob)
                mutationObserved = true
                return response(
                    201,
                    headers: [
                        "docker-content-digest":
                            digest.canonicalValue
                    ]
                )
            }
            if let digest = try objectDigest(
                request.url,
                collection: "blobs"
            ) {
                return try objectResponse(
                    request,
                    digest: digest,
                    kind: .blob
                )
            }
            if let digest = try objectDigest(
                request.url,
                collection: "manifests"
            ) {
                if request.method == .put {
                    guard let body = request.body else {
                        throw RegistryTransportError.invalidResponse
                    }
                    try store(
                        body,
                        digest: digest,
                        kind: .manifest
                    )
                    mutationObserved = true
                    if digest == rootDescriptor.digest {
                        rootPublished = true
                    }
                    var headers = [
                        "docker-content-digest":
                            digest.canonicalValue
                    ]
                    if digest == rootDescriptor.digest {
                        headers["oci-subject"] =
                            subjectDigest.canonicalValue
                    }
                    return response(201, headers: headers)
                }
                return try objectResponse(
                    request,
                    digest: digest,
                    kind: .manifest
                )
            }
            throw RegistryTransportError.invalidURL
        }
    }

    private func objectDigest(
        _ url: URL,
        collection: String
    ) throws -> OCIContentDigest? {
        let marker = "/\(collection)/"
        guard let range = url.path.range(of: marker) else {
            return nil
        }
        let value = String(url.path[range.upperBound...])
        guard !value.isEmpty, !value.contains("/") else {
            throw RegistryTransportError.invalidURL
        }
        return try OCIContentDigest(value)
    }

    private func store(
        _ body: Data,
        digest: OCIContentDigest,
        kind: OCIReferrerObjectKind
    ) throws {
        guard let expected = expectedObjects[digest],
              expected.kind == kind,
              expected.payload == body,
              try digest.matches(body) else {
            throw RegistryTransportError.invalidResponse
        }
        storedObjects[digest] = expected
    }

    private func objectResponse(
        _ request: RegistryTransportRequest,
        digest: OCIContentDigest,
        kind: OCIReferrerObjectKind
    ) throws -> RegistryTransportResponse {
        guard let object = storedObjects[digest],
              object.kind == kind else {
            return response(404)
        }
        let headers = [
            "content-type": object.mediaType,
            "content-length": String(object.size),
            "docker-content-digest": digest.canonicalValue
        ]
        switch request.method {
        case .head:
            if mutationObserved {
                postMutationObserved = true
            }
            return response(200, headers: headers)
        case .get:
            if mutationObserved {
                postMutationObserved = true
            }
            return response(
                200,
                body: object.payload,
                headers: headers
            )
        default:
            throw RegistryTransportError.invalidMethod
        }
    }

    private func indexResponse() throws -> RegistryTransportResponse {
        var descriptors: [[String: Any]] = []
        if rootPublished {
            var descriptor: [String: Any] = [
                "mediaType": rootDescriptor.mediaType,
                "digest": rootDescriptor.digest.canonicalValue,
                "size": rootDescriptor.size,
                "artifactType":
                    try XCTUnwrap(rootDescriptor.artifactType).value
            ]
            if !rootDescriptor.annotations.isEmpty {
                descriptor["annotations"] =
                    rootDescriptor.annotations
            }
            descriptors.append(descriptor)
        }
        let body = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType": OCIReferrerIndex.mediaType,
                "manifests": descriptors
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return response(
            200,
            body: body,
            headers: [
                "content-type": OCIReferrerIndex.mediaType
            ]
        )
    }

    private func response(
        _ statusCode: Int,
        body: Data = Data(),
        headers: [String: String] = [:]
    ) -> RegistryTransportResponse {
        RegistryTransportResponse(
            statusCode: statusCode,
            headers: headers,
            body: body
        )
    }
}
