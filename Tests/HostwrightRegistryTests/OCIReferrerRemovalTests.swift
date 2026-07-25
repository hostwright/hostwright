import Foundation
@testable import HostwrightRegistry
import XCTest

final class OCIReferrerRemovalTests: XCTestCase {
    func testNativeRemovalDeletesOnlyExactVerifiedManifest() throws {
        let fixture = try makeFixture()
        let transport = ReferrerRemovalTransport([
            .success(indexResponse([fixture.descriptor])),
            .success(manifestResponse(fixture)),
            .success(response(202)),
            .success(response(404)),
            .success(indexResponse([]))
        ])

        let result = try makeClient(transport).removeOwnedReferrer(
            graph: fixture.graph,
            referrerDigest: fixture.manifestDigest,
            endpoint: fixture.endpoint,
            repository: fixture.repository,
            ownershipProofSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.mode, .native)
        let mutations = transport.requests.filter {
            [.put, .post, .patch, .delete].contains($0.method)
        }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations[0].method, .delete)
        XCTAssertEqual(
            mutations[0].url.path,
            "/v2/team/app/manifests/" +
                fixture.manifestDigest.canonicalValue
        )
    }

    func testRemovalRefusesUnverifiedOwnershipBeforeTransport() throws {
        let fixture = try makeFixture()
        let transport = ReferrerRemovalTransport([])

        XCTAssertThrowsError(
            try makeClient(transport).removeOwnedReferrer(
                graph: fixture.graph,
                referrerDigest: fixture.manifestDigest,
                endpoint: fixture.endpoint,
                repository: fixture.repository,
                ownershipProofSHA256: "not-a-proof"
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .ownershipUnverified
            )
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFallbackRemovalFencesIndexThenDeletesExactManifest()
        throws
    {
        let fixture = try makeFixture()
        let transport = ReferrerRemovalTransport([
            .success(response(404)),
            .success(
                indexResponse(
                    [fixture.descriptor],
                    etag: #""before""#
                )
            ),
            .success(manifestResponse(fixture)),
            .success(response(201)),
            .success(indexResponse([], etag: #""after""#)),
            .success(response(202)),
            .success(response(404)),
            .success(response(404)),
            .success(indexResponse([], etag: #""final""#))
        ])

        let result = try makeClient(transport).removeOwnedReferrer(
            graph: fixture.graph,
            referrerDigest: fixture.manifestDigest,
            endpoint: fixture.endpoint,
            repository: fixture.repository,
            ownershipProofSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.mode, .tagFallback)
        XCTAssertEqual(transport.requests[3].method, .put)
        XCTAssertEqual(
            transport.requests[3].headers["If-Match"],
            #""before""#
        )
        XCTAssertEqual(transport.requests[5].method, .delete)
        XCTAssertFalse(
            transport.requests.contains {
                $0.method == .delete &&
                    $0.url.path.contains("/blobs/")
            }
        )
    }

    func testFallbackDeleteFailureRestoresIndexWithObservedETag()
        throws
    {
        let fixture = try makeFixture()
        let transport = ReferrerRemovalTransport([
            .success(response(404)),
            .success(
                indexResponse(
                    [fixture.descriptor],
                    etag: #""before""#
                )
            ),
            .success(manifestResponse(fixture)),
            .success(response(201)),
            .success(indexResponse([], etag: #""after-remove""#)),
            .success(response(500)),
            .success(manifestResponse(fixture)),
            .success(response(201)),
            .success(
                indexResponse(
                    [fixture.descriptor],
                    etag: #""restored""#
                )
            )
        ])

        XCTAssertThrowsError(
            try makeClient(transport).removeOwnedReferrer(
                graph: fixture.graph,
                referrerDigest: fixture.manifestDigest,
                endpoint: fixture.endpoint,
                repository: fixture.repository,
                ownershipProofSHA256: String(repeating: "c", count: 64)
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .unexpectedStatus(500)
            )
        }
        XCTAssertEqual(transport.requests[7].method, .put)
        XCTAssertEqual(
            transport.requests[7].headers["If-Match"],
            #""after-remove""#
        )
        XCTAssertEqual(
            transport.requests.filter { $0.method == .delete }.count,
            1
        )
    }

    func testRecoveryDeletesOwnedManifestWhenIndexIsAlreadyAbsent()
        throws
    {
        let fixture = try makeFixture()
        let transport = ReferrerRemovalTransport([
            .success(response(404)),
            .success(indexResponse([], etag: #""after-remove""#)),
            .success(manifestResponse(fixture)),
            .success(response(202)),
            .success(response(404))
        ])

        let result = try makeClient(transport).removeOwnedReferrer(
            graph: fixture.graph,
            referrerDigest: fixture.manifestDigest,
            endpoint: fixture.endpoint,
            repository: fixture.repository,
            ownershipProofSHA256: String(repeating: "d", count: 64)
        )

        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.mode, .tagFallback)
        XCTAssertEqual(
            transport.requests.filter { $0.method == .delete }.count,
            1
        )
        XCTAssertEqual(
            transport.requests.last?.url.path,
            "/v2/team/app/manifests/" +
                fixture.manifestDigest.canonicalValue
        )
    }

    private func makeClient(
        _ transport: ReferrerRemovalTransport
    ) -> OCIReferrerRegistryClient {
        OCIReferrerRegistryClient(
            authenticationClient: RegistryAuthenticationClient(
                transport: transport
            )
        )
    }

    private func makeFixture() throws -> RemovalFixture {
        let endpoint = try RegistryEndpoint("registry.example.com")
        let repository = try OCIRepositoryName("team/app")
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "1", count: 64)
        )
        let blob = Data("opaque".utf8)
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
        let descriptor = try OCIReferrerDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: manifestDigest,
            size: manifest.count,
            artifactType: OCIArtifactType(
                "application/vnd.example.opaque.v1"
            ),
            annotations: [:]
        )
        let child = try OCIContentDescriptor(
            mediaType: "application/vnd.example.opaque.v1",
            digest: blobDigest,
            size: blob.count
        )
        let manifestObject = try OCIReferrerFetchedObject(
            digest: manifestDigest,
            mediaType: descriptor.mediaType,
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
        let discovery = OCIReferrerDiscoveryResult(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subject,
            artifactType: nil,
            mode: .native,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: [descriptor],
            etag: nil
        )
        return RemovalFixture(
            endpoint: endpoint,
            repository: repository,
            subject: subject,
            manifest: manifest,
            manifestDigest: manifestDigest,
            descriptor: descriptor,
            graph: try OCIReferrerGraph(
                discovery: discovery,
                verifiedReferrers: [descriptor],
                objects: [manifestObject, blobObject]
            )
        )
    }

    private func manifestResponse(
        _ fixture: RemovalFixture
    ) -> RegistryTransportResponse {
        response(
            200,
            body: fixture.manifest,
            contentType: fixture.descriptor.mediaType,
            headers: [
                "docker-content-digest":
                    fixture.manifestDigest.canonicalValue
            ]
        )
    }

    private func indexResponse(
        _ descriptors: [OCIReferrerDescriptor],
        etag: String? = nil
    ) -> RegistryTransportResponse {
        let values = descriptors.map { descriptor -> [String: Any] in
            [
                "mediaType": descriptor.mediaType,
                "digest": descriptor.digest.canonicalValue,
                "size": descriptor.size,
                "artifactType": descriptor.artifactType!.value
            ]
        }
        var headers: [String: String] = [:]
        if let etag {
            headers["etag"] = etag
        }
        return response(
            200,
            body: try! JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 2,
                    "mediaType": OCIReferrerIndex.mediaType,
                    "manifests": values
                ],
                options: [.sortedKeys]
            ),
            contentType: OCIReferrerIndex.mediaType,
            headers: headers
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

private struct RemovalFixture {
    let endpoint: RegistryEndpoint
    let repository: OCIRepositoryName
    let subject: OCIContentDigest
    let manifest: Data
    let manifestDigest: OCIContentDigest
    let descriptor: OCIReferrerDescriptor
    let graph: OCIReferrerGraph
}

private final class ReferrerRemovalTransport:
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
