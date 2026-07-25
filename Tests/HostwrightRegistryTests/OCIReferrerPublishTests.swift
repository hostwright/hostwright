import Foundation
@testable import HostwrightRegistry
import XCTest

final class OCIReferrerPublishTests: XCTestCase {
    func testNativePublishUploadsChildrenFirstAndObservesExactState()
        throws
    {
        let fixture = try makeGraph()
        let endpoint = try RegistryEndpoint("registry.example.com")
        let emptyIndex = indexData([])
        let finalIndex = indexData([
            descriptorObject(
                fixture.graph.verifiedReferrers[0]
            )
        ])
        let transport = ReferrerPublishTransport([
            .success(response(200, body: emptyIndex, contentType: OCIReferrerIndex.mediaType)),
            .success(response(404)),
            .success(
                response(
                    202,
                    headers: [
                        "location":
                            "/v2/team/app/blobs/uploads/session-1"
                    ]
                )
            ),
            .success(
                response(
                    201,
                    headers: [
                        "docker-content-digest":
                            fixture.blobDigest.canonicalValue
                    ]
                )
            ),
            .success(
                response(
                    200,
                    headers: [
                        "docker-content-digest":
                            fixture.blobDigest.canonicalValue,
                        "content-length":
                            String(fixture.blob.count)
                    ]
                )
            ),
            .success(response(404)),
            .success(
                response(
                    201,
                    headers: [
                        "docker-content-digest":
                            fixture.manifestDigest.canonicalValue,
                        "oci-subject":
                            fixture.subject.canonicalValue
                    ]
                )
            ),
            .success(
                response(
                    200,
                    body: fixture.manifest,
                    contentType:
                        OCIReferrerDescriptor.manifestMediaType,
                    headers: [
                        "docker-content-digest":
                            fixture.manifestDigest.canonicalValue
                    ]
                )
            ),
            .success(response(200, body: finalIndex, contentType: OCIReferrerIndex.mediaType))
        ])

        let result = try makeClient(transport).publish(
            fixture.graph,
            endpoint: endpoint,
            repository: OCIRepositoryName("team/app")
        )

        XCTAssertEqual(result.mode, .native)
        XCTAssertEqual(
            result.publishedDigests,
            [fixture.blobDigest, fixture.manifestDigest]
        )
        XCTAssertTrue(result.reusedDigests.isEmpty)
        XCTAssertEqual(transport.requests.count, 9)
        XCTAssertEqual(transport.requests[2].method, .post)
        XCTAssertEqual(transport.requests[3].method, .put)
        XCTAssertEqual(transport.requests[3].body, fixture.blob)
        XCTAssertEqual(transport.requests[6].body, fixture.manifest)
        XCTAssertFalse(
            transport.requests.contains {
                $0.method == .delete
            }
        )
    }

    func testPublishReusesExactExistingObjectsWithoutMutation() throws {
        let fixture = try makeGraph()
        let finalIndex = indexData([
            descriptorObject(
                fixture.graph.verifiedReferrers[0]
            )
        ])
        let transport = ReferrerPublishTransport([
            .success(response(200, body: finalIndex, contentType: OCIReferrerIndex.mediaType)),
            .success(
                response(
                    200,
                    headers: [
                        "docker-content-digest":
                            fixture.blobDigest.canonicalValue,
                        "content-length": String(fixture.blob.count)
                    ]
                )
            ),
            .success(
                response(
                    200,
                    headers: [
                        "docker-content-digest":
                            fixture.manifestDigest.canonicalValue,
                        "content-length":
                            String(fixture.manifest.count)
                    ]
                )
            ),
            .success(
                response(
                    200,
                    body: fixture.manifest,
                    contentType:
                        OCIReferrerDescriptor.manifestMediaType,
                    headers: [
                        "docker-content-digest":
                            fixture.manifestDigest.canonicalValue
                    ]
                )
            ),
            .success(response(200, body: finalIndex, contentType: OCIReferrerIndex.mediaType))
        ])

        let result = try makeClient(transport).publish(
            fixture.graph,
            endpoint: RegistryEndpoint("registry.example.com"),
            repository: OCIRepositoryName("team/app")
        )

        XCTAssertTrue(result.publishedDigests.isEmpty)
        XCTAssertEqual(
            result.reusedDigests,
            [fixture.blobDigest, fixture.manifestDigest]
        )
        XCTAssertFalse(
            transport.requests.contains {
                [.post, .put, .patch, .delete].contains($0.method)
            }
        )
    }

    func testFallbackWithoutConflictValidatorRefusesBeforeMutation()
        throws
    {
        let fixture = try makeGraph()
        let transport = ReferrerPublishTransport([
            .success(response(404)),
            .success(
                response(
                    200,
                    body: indexData([]),
                    contentType: OCIReferrerIndex.mediaType
                )
            )
        ])

        XCTAssertThrowsError(
            try makeClient(transport).publish(
                fixture.graph,
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app")
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .fallbackWriteUnavailable
            )
        }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(
            transport.requests.allSatisfy { $0.method == .get }
        )
    }

    func testFallbackPublishUsesETagAndObservesUpdatedIndex() throws {
        let fixture = try makeGraph()
        let emptyIndex = indexData([])
        let finalIndex = indexData([
            descriptorObject(fixture.graph.verifiedReferrers[0])
        ])
        let transport = ReferrerPublishTransport([
            .success(response(404)),
            .success(
                response(
                    200,
                    body: emptyIndex,
                    contentType: OCIReferrerIndex.mediaType,
                    headers: ["etag": #""before""#]
                )
            ),
            .success(
                response(
                    200,
                    headers: [
                        "docker-content-digest":
                            fixture.blobDigest.canonicalValue,
                        "content-length": String(fixture.blob.count)
                    ]
                )
            ),
            .success(
                response(
                    200,
                    headers: [
                        "docker-content-digest":
                            fixture.manifestDigest.canonicalValue,
                        "content-length": String(fixture.manifest.count)
                    ]
                )
            ),
            .success(
                response(
                    200,
                    body: fixture.manifest,
                    contentType:
                        OCIReferrerDescriptor.manifestMediaType,
                    headers: [
                        "docker-content-digest":
                            fixture.manifestDigest.canonicalValue
                    ]
                )
            ),
            .success(response(201)),
            .success(
                response(
                    200,
                    body: finalIndex,
                    contentType: OCIReferrerIndex.mediaType,
                    headers: ["etag": #""after""#]
                )
            ),
            .success(response(404)),
            .success(
                response(
                    200,
                    body: finalIndex,
                    contentType: OCIReferrerIndex.mediaType,
                    headers: ["etag": #""after""#]
                )
            )
        ])

        let result = try makeClient(transport).publish(
            fixture.graph,
            endpoint: RegistryEndpoint("registry.example.com"),
            repository: OCIRepositoryName("team/app")
        )

        XCTAssertEqual(result.mode, .tagFallback)
        XCTAssertTrue(result.publishedDigests.isEmpty)
        XCTAssertEqual(
            result.reusedDigests,
            [fixture.blobDigest, fixture.manifestDigest]
        )
        let update = transport.requests[5]
        XCTAssertEqual(update.method, .put)
        XCTAssertEqual(update.headers["If-Match"], #""before""#)
        XCTAssertNil(update.headers["If-None-Match"])
        XCTAssertEqual(
            update.url.path,
            "/v2/team/app/manifests/\(fixture.subject.referrersTag)"
        )
    }

    func testCancelledBlobUploadCancelsOnlyExactSession() throws {
        let fixture = try makeGraph()
        let transport = ReferrerPublishTransport([
            .success(
                response(
                    200,
                    body: indexData([]),
                    contentType: OCIReferrerIndex.mediaType
                )
            ),
            .success(response(404)),
            .success(
                response(
                    202,
                    headers: [
                        "location":
                            "/v2/team/app/blobs/uploads/session-1"
                    ]
                )
            ),
            .failure(RegistryTransportError.cancelled),
            .success(response(202))
        ])

        XCTAssertThrowsError(
            try makeClient(transport).publish(
                fixture.graph,
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app")
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .cancelled
            )
        }
        XCTAssertEqual(transport.requests.count, 5)
        XCTAssertEqual(transport.requests[4].method, .delete)
        XCTAssertEqual(
            transport.requests[4].url.path,
            "/v2/team/app/blobs/uploads/session-1"
        )
        XCTAssertNil(transport.requests[4].body)
    }

    func testCrossOriginUploadLocationIsRejectedWithoutForwardingBody()
        throws
    {
        let fixture = try makeGraph()
        let transport = ReferrerPublishTransport([
            .success(
                response(
                    200,
                    body: indexData([]),
                    contentType: OCIReferrerIndex.mediaType
                )
            ),
            .success(response(404)),
            .success(
                response(
                    202,
                    headers: [
                        "location":
                            "https://evil.example.com/collect"
                    ]
                )
            )
        ])

        XCTAssertThrowsError(
            try makeClient(transport).publish(
                fixture.graph,
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app")
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .unsafeUploadLocation
            )
        }
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertFalse(
            transport.requests.contains {
                $0.url.host == "evil.example.com" ||
                    $0.body == fixture.blob
            }
        )
    }

    private func makeClient(
        _ transport: ReferrerPublishTransport
    ) -> OCIReferrerRegistryClient {
        OCIReferrerRegistryClient(
            authenticationClient: RegistryAuthenticationClient(
                transport: transport
            )
        )
    }

    private func makeGraph() throws -> (
        graph: OCIReferrerGraph,
        subject: OCIContentDigest,
        blob: Data,
        blobDigest: OCIContentDigest,
        manifest: Data,
        manifestDigest: OCIContentDigest
    ) {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "1", count: 64)
        )
        let blob = Data("opaque-payload".utf8)
        let blobDigest = try OCIContentDigest.sha256(of: blob)
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType":
                    OCIReferrerDescriptor.manifestMediaType,
                "artifactType":
                    "application/vnd.example.opaque.v1",
                "subject": [
                    "mediaType":
                        OCIReferrerDescriptor.manifestMediaType,
                    "digest": subject.canonicalValue,
                    "size": 1
                ],
                "config": [
                    "mediaType": "application/vnd.example.opaque.v1",
                    "digest": blobDigest.canonicalValue,
                    "size": blob.count
                ],
                "layers": []
            ],
            options: [.sortedKeys]
        )
        let manifestDigest = try OCIContentDigest.sha256(of: manifest)
        let child = try OCIContentDescriptor(
            mediaType: "application/vnd.example.opaque.v1",
            digest: blobDigest,
            size: blob.count
        )
        let root = try OCIReferrerFetchedObject(
            digest: manifestDigest,
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            size: manifest.count,
            kind: .manifest,
            payload: manifest,
            childDescriptors: [child]
        )
        let blobObject = try OCIReferrerFetchedObject(
            digest: blobDigest,
            mediaType: child.mediaType,
            size: blob.count,
            kind: .blob,
            payload: blob,
            childDescriptors: []
        )
        let descriptor = try OCIReferrerDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: manifestDigest,
            size: manifest.count,
            artifactType: OCIArtifactType(
                "application/vnd.example.opaque.v1"
            ),
            annotations: [:]
        )
        let discovery = OCIReferrerDiscoveryResult(
            endpoint: try RegistryEndpoint("source.example.com"),
            repository: try OCIRepositoryName("source/app"),
            subjectDigest: subject,
            artifactType: nil,
            mode: .native,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: [descriptor],
            etag: nil
        )
        return (
            try OCIReferrerGraph(
                discovery: discovery,
                verifiedReferrers: [descriptor],
                objects: [root, blobObject]
            ),
            subject,
            blob,
            blobDigest,
            manifest,
            manifestDigest
        )
    }

    private func descriptorObject(
        _ descriptor: OCIReferrerDescriptor
    ) -> [String: Any] {
        [
            "mediaType": descriptor.mediaType,
            "digest": descriptor.digest.canonicalValue,
            "size": descriptor.size,
            "artifactType": descriptor.artifactType!.value
        ]
    }

    private func indexData(
        _ descriptors: [[String: Any]]
    ) -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType": OCIReferrerIndex.mediaType,
                "manifests": descriptors
            ],
            options: [.sortedKeys]
        )
    }

    private func response(
        _ status: Int,
        body: Data = Data(),
        contentType: String? = nil,
        headers: [String: String] = [:]
    ) -> RegistryTransportResponse {
        var values = headers
        if let contentType {
            values["content-type"] = contentType
        }
        return RegistryTransportResponse(
            statusCode: status,
            headers: values,
            body: body
        )
    }
}

private final class ReferrerPublishTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var responses:
        [Result<RegistryTransportResponse, Error>]
    private var recordedRequests: [RegistryTransportRequest] = []

    init(
        _ responses: [Result<RegistryTransportResponse, Error>]
    ) {
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
            return try responses.removeFirst().get()
        }
    }
}
