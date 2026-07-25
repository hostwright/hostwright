import Foundation
@testable import HostwrightRegistry
import XCTest

final class OCIReferrerFetchTests: XCTestCase {
    private let subject =
        "sha256:" + String(repeating: "1", count: 64)
    private let artifactType =
        "application/vnd.example.attestation.v1+json"

    func testFetchValidatesSubjectManifestAndBlobGraph() throws {
        let config = Data(#"{"predicateType":"opaque"}"#.utf8)
        let layer = Data("opaque-artifact-payload".utf8)
        let configDigest = try OCIContentDigest.sha256(of: config)
        let layerDigest = try OCIContentDigest.sha256(of: layer)
        let manifest = try manifestData(
            subject: subject,
            config: descriptor(
                mediaType: "application/vnd.example.config.v1+json",
                digest: configDigest.canonicalValue,
                size: config.count
            ),
            layers: [
                descriptor(
                    mediaType: "application/vnd.example.payload.v1+json",
                    digest: layerDigest.canonicalValue,
                    size: layer.count
                )
            ]
        )
        let manifestDigest = try OCIContentDigest.sha256(of: manifest)
        let transport = ReferrerFetchTransport([
            discoveryResponse(
                manifestDigest: manifestDigest,
                manifestBytes: manifest.count
            ),
            objectResponse(
                manifest,
                mediaType: OCIReferrerDescriptor.manifestMediaType,
                digest: manifestDigest
            ),
            objectResponse(
                config,
                mediaType: "application/vnd.example.config.v1+json",
                digest: configDigest
            ),
            objectResponse(
                layer,
                mediaType: "application/vnd.example.payload.v1+json",
                digest: layerDigest
            )
        ])

        let graph = try makeClient(transport).fetch(
            endpoint: RegistryEndpoint("registry.example.com"),
            repository: OCIRepositoryName("team/app"),
            subjectDigest: OCIContentDigest(subject)
        )

        XCTAssertEqual(graph.discovery.mode, .native)
        XCTAssertEqual(
            graph.verifiedReferrers.map(\.digest),
            [manifestDigest]
        )
        XCTAssertEqual(graph.objects.count, 3)
        XCTAssertEqual(graph.totalBytes, manifest.count + config.count + layer.count)
        XCTAssertEqual(
            graph.objects.map(\.digest.canonicalValue).sorted(),
            [
                manifestDigest.canonicalValue,
                configDigest.canonicalValue,
                layerDigest.canonicalValue
            ].sorted()
        )
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testFetchRejectsWrongSubjectBeforeFetchingChildren() throws {
        let config = Data("{}".utf8)
        let configDigest = try OCIContentDigest.sha256(of: config)
        let manifest = try manifestData(
            subject: "sha256:" + String(repeating: "9", count: 64),
            config: descriptor(
                mediaType: "application/vnd.example.config.v1+json",
                digest: configDigest.canonicalValue,
                size: config.count
            ),
            layers: []
        )
        let manifestDigest = try OCIContentDigest.sha256(of: manifest)
        let transport = ReferrerFetchTransport([
            discoveryResponse(
                manifestDigest: manifestDigest,
                manifestBytes: manifest.count
            ),
            objectResponse(
                manifest,
                mediaType: OCIReferrerDescriptor.manifestMediaType,
                digest: manifestDigest
            )
        ])

        XCTAssertThrowsError(
            try makeClient(transport).fetch(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: OCIContentDigest(subject)
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .subjectMismatch
            )
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testFetchRejectsDigestAndDescriptorLimitMismatch() throws {
        let content = Data(#"{"schemaVersion":2}"#.utf8)
        let declaredDigest = try OCIContentDigest.sha256(
            of: Data("different".utf8)
        )
        let mismatch = ReferrerFetchTransport([
            discoveryResponse(
                manifestDigest: declaredDigest,
                manifestBytes: content.count
            ),
            objectResponse(
                content,
                mediaType: OCIReferrerDescriptor.manifestMediaType,
                digest: declaredDigest
            )
        ])
        XCTAssertThrowsError(
            try makeClient(mismatch).fetch(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: OCIContentDigest(subject)
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .digestMismatch
            )
        }

        let layers = (0...OCIReferrerLimits.maximumGraphDescriptors).map {
            descriptor(
                mediaType: "application/vnd.example.payload.v1",
                digest: "sha256:" + String(
                    format: "%064llx",
                    UInt64($0 + 1)
                ),
                size: 1
            )
        }
        let emptyDigest = try OCIContentDigest.sha256(of: Data())
        let oversizedGraphManifest = try manifestData(
            subject: subject,
            config: descriptor(
                mediaType: "application/vnd.oci.empty.v1+json",
                digest: emptyDigest.canonicalValue,
                size: 0
            ),
            layers: layers
        )
        let rootDigest = try OCIContentDigest.sha256(
            of: oversizedGraphManifest
        )
        let oversized = ReferrerFetchTransport([
            discoveryResponse(
                manifestDigest: rootDigest,
                manifestBytes: oversizedGraphManifest.count
            ),
            objectResponse(
                oversizedGraphManifest,
                mediaType: OCIReferrerDescriptor.manifestMediaType,
                digest: rootDigest
            )
        ])
        XCTAssertThrowsError(
            try makeClient(oversized).fetch(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: OCIContentDigest(subject)
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .limitExceeded
            )
        }
        XCTAssertEqual(oversized.requests.count, 2)
    }

    func testFetchedObjectDescriptionsNeverReflectPayload() throws {
        let payload = Data("private-opaque-payload".utf8)
        let object = try OCIReferrerFetchedObject(
            digest: OCIContentDigest.sha256(of: payload),
            mediaType: "application/vnd.example.payload.v1",
            size: payload.count,
            kind: .blob,
            payload: payload,
            childDescriptors: []
        )

        XCTAssertFalse(object.description.contains("private-opaque-payload"))
        XCTAssertFalse(object.debugDescription.contains("private-opaque-payload"))
    }

    private func makeClient(
        _ transport: ReferrerFetchTransport
    ) -> OCIReferrerRegistryClient {
        OCIReferrerRegistryClient(
            authenticationClient: RegistryAuthenticationClient(
                transport: transport
            )
        )
    }

    private func discoveryResponse(
        manifestDigest: OCIContentDigest,
        manifestBytes: Int
    ) -> RegistryTransportResponse {
        let body = try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType": OCIReferrerIndex.mediaType,
                "manifests": [[
                    "mediaType":
                        OCIReferrerDescriptor.manifestMediaType,
                    "digest": manifestDigest.canonicalValue,
                    "size": manifestBytes,
                    "artifactType": artifactType
                ]]
            ],
            options: [.sortedKeys]
        )
        return RegistryTransportResponse(
            statusCode: 200,
            headers: ["content-type": OCIReferrerIndex.mediaType],
            body: body
        )
    }

    private func objectResponse(
        _ body: Data,
        mediaType: String,
        digest: OCIContentDigest
    ) -> RegistryTransportResponse {
        RegistryTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": mediaType,
                "docker-content-digest": digest.canonicalValue
            ],
            body: body
        )
    }

    private func manifestData(
        subject: String,
        config: [String: Any],
        layers: [[String: Any]]
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType": OCIReferrerDescriptor.manifestMediaType,
                "artifactType": artifactType,
                "subject": descriptor(
                    mediaType: OCIReferrerDescriptor.manifestMediaType,
                    digest: subject,
                    size: 1
                ),
                "config": config,
                "layers": layers
            ],
            options: [.sortedKeys]
        )
    }

    private func descriptor(
        mediaType: String,
        digest: String,
        size: Int
    ) -> [String: Any] {
        [
            "mediaType": mediaType,
            "digest": digest,
            "size": size
        ]
    }
}

private final class ReferrerFetchTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var responses: [RegistryTransportResponse]
    private var recordedRequests: [RegistryTransportRequest] = []

    init(_ responses: [RegistryTransportResponse]) {
        self.responses = responses
    }

    var requests: [RegistryTransportRequest] {
        lock.withLock { recordedRequests }
    }

    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        try lock.withLock {
            recordedRequests.append(request)
            guard !responses.isEmpty else {
                throw RegistryTransportError.transportFailed
            }
            return responses.removeFirst()
        }
    }
}
