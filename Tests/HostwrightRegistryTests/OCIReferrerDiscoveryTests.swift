import Foundation
@testable import HostwrightRegistry
import XCTest

final class OCIReferrerDiscoveryTests: XCTestCase {
    private let subjectValue =
        "sha256:" + String(repeating: "1", count: 64)
    private let signatureType =
        "application/vnd.example.signature.v1+json"
    private let sbomType =
        "application/vnd.example.sbom.v1+json"

    func testNativeDiscoveryFollowsSameSubjectPaginationAndFiltersLocally()
        throws
    {
        let subject = try OCIContentDigest(subjectValue)
        let signature = "sha256:" + String(repeating: "2", count: 64)
        let sbom = "sha256:" + String(repeating: "3", count: 64)
        let next =
            "</v2/team/app/referrers/\(subjectValue)" +
            "?artifactType=\(signatureType)&page=2>; rel=\"next\""
        let transport = ReferrerDiscoveryTransport([
            Self.response(
                body: Self.index([
                    Self.descriptor(
                        digest: signature,
                        artifactType: signatureType
                    )
                ]),
                headers: ["link": next]
            ),
            Self.response(
                body: Self.index([
                    Self.descriptor(
                        digest: sbom,
                        artifactType: sbomType
                    )
                ])
            )
        ])

        let result = try OCIReferrerRegistryClient(
            authenticationClient: RegistryAuthenticationClient(
                transport: transport
            )
        ).discover(
            endpoint: RegistryEndpoint("registry.example.com"),
            repository: OCIRepositoryName("team/app"),
            subjectDigest: subject,
            artifactType: OCIArtifactType(signatureType)
        )

        XCTAssertEqual(result.mode, .native)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertFalse(result.serverFilterApplied)
        XCTAssertEqual(
            result.descriptors.map(\.digest.canonicalValue),
            [signature]
        )
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(
            transport.requests[1].url.host,
            "registry.example.com"
        )
    }

    func testNativeDiscoveryReportsServerSideFilter() throws {
        let transport = ReferrerDiscoveryTransport([
            Self.response(
                body: Self.index([
                    Self.descriptor(
                        digest: "sha256:" + String(repeating: "2", count: 64),
                        artifactType: signatureType
                    )
                ]),
                headers: ["oci-filters-applied": "artifactType"]
            )
        ])

        let result = try makeClient(transport).discover(
            endpoint: RegistryEndpoint("registry.example.com"),
            repository: OCIRepositoryName("team/app"),
            subjectDigest: OCIContentDigest(subjectValue),
            artifactType: OCIArtifactType(signatureType)
        )

        XCTAssertTrue(result.serverFilterApplied)
        XCTAssertEqual(result.descriptors.count, 1)
    }

    func testNativeDiscoveryRejectsDeclaredMismatchedSubject() throws {
        let wrongSubject =
            "sha256:" + String(repeating: "9", count: 64)
        let transport = ReferrerDiscoveryTransport([
            Self.response(
                body: Data(
                    """
                    {
                      "schemaVersion": 2,
                      "mediaType": "\(OCIReferrerIndex.mediaType)",
                      "subject": {
                        "mediaType": "\(OCIReferrerDescriptor.manifestMediaType)",
                        "digest": "\(wrongSubject)",
                        "size": 1
                      },
                      "manifests": []
                    }
                    """.utf8
                )
            )
        ])

        XCTAssertThrowsError(
            try makeClient(transport).discover(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: OCIContentDigest(subjectValue)
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .invalidResponse
            )
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSHA512RefusesNonInjectiveFallbackAfterNative404() throws {
        let subject = try OCIContentDigest(
            "sha512:" + String(repeating: "a", count: 128)
        )
        let transport = ReferrerDiscoveryTransport([
            RegistryTransportResponse(
                statusCode: 404,
                headers: [:],
                body: Data()
            )
        ])

        XCTAssertThrowsError(
            try makeClient(transport).discover(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: subject
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .fallbackDigestUnsupported
            )
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func test404UsesExactReferrersTagFallback() throws {
        let descriptorDigest =
            "sha256:" + String(repeating: "2", count: 64)
        let transport = ReferrerDiscoveryTransport([
            RegistryTransportResponse(
                statusCode: 404,
                headers: [:],
                body: Data()
            ),
            Self.response(
                body: Self.index([
                    Self.descriptor(
                        digest: descriptorDigest,
                        artifactType: signatureType
                    )
                ]),
                headers: ["etag": #""fallback-v1""#]
            )
        ])

        let result = try makeClient(transport).discover(
            endpoint: RegistryEndpoint("registry.example.com"),
            repository: OCIRepositoryName("team/app"),
            subjectDigest: OCIContentDigest(subjectValue)
        )

        XCTAssertEqual(result.mode, .tagFallback)
        XCTAssertEqual(result.etag, #""fallback-v1""#)
        XCTAssertEqual(result.descriptors.count, 1)
        XCTAssertEqual(
            transport.requests[1].url.absoluteString,
            "https://registry.example.com/v2/team/app/manifests/" +
                "sha256-" + String(repeating: "1", count: 64)
        )
    }

    func testMissingFallbackTagIsExplicitEmptyCapability() throws {
        let transport = ReferrerDiscoveryTransport([
            RegistryTransportResponse(
                statusCode: 404,
                headers: [:],
                body: Data()
            ),
            RegistryTransportResponse(
                statusCode: 404,
                headers: [:],
                body: Data()
            )
        ])

        let result = try makeClient(transport).discover(
            endpoint: RegistryEndpoint("registry.example.com"),
            repository: OCIRepositoryName("team/app"),
            subjectDigest: OCIContentDigest(subjectValue)
        )

        XCTAssertEqual(result.mode, .tagFallbackEmpty)
        XCTAssertTrue(result.descriptors.isEmpty)
        XCTAssertFalse(result.serverFilterApplied)
    }

    func testCrossOriginPaginationAndMalformedFallbackFailClosed() throws {
        let crossOrigin = ReferrerDiscoveryTransport([
            Self.response(
                body: Self.index([]),
                headers: [
                    "link":
                        "<https://evil.example.com/v2/team/app/referrers/" +
                        "\(subjectValue)?page=2>; rel=\"next\""
                ]
            )
        ])
        XCTAssertThrowsError(
            try makeClient(crossOrigin).discover(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: OCIContentDigest(subjectValue)
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .paginationRejected
            )
        }
        XCTAssertEqual(crossOrigin.requests.count, 1)

        let malformedFallback = ReferrerDiscoveryTransport([
            RegistryTransportResponse(
                statusCode: 404,
                headers: [:],
                body: Data()
            ),
            Self.response(body: Data(#"{"schemaVersion":2}"#.utf8))
        ])
        XCTAssertThrowsError(
            try makeClient(malformedFallback).discover(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: OCIContentDigest(subjectValue)
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .invalidResponse
            )
        }
    }

    func testCancellationStopsBeforeDiscoveryRequest() throws {
        let transport = ReferrerDiscoveryTransport([])
        let cancellation = RegistryTransportCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(
            try makeClient(transport).discover(
                endpoint: RegistryEndpoint("registry.example.com"),
                repository: OCIRepositoryName("team/app"),
                subjectDigest: OCIContentDigest(subjectValue),
                cancellation: cancellation
            )
        ) {
            XCTAssertEqual(
                $0 as? OCIReferrerRegistryError,
                .cancelled
            )
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    private func makeClient(
        _ transport: ReferrerDiscoveryTransport
    ) -> OCIReferrerRegistryClient {
        OCIReferrerRegistryClient(
            authenticationClient: RegistryAuthenticationClient(
                transport: transport
            )
        )
    }

    private static func response(
        body: Data,
        headers: [String: String] = [:]
    ) -> RegistryTransportResponse {
        var values = [
            "content-type": OCIReferrerIndex.mediaType
        ]
        values.merge(headers) { _, new in new }
        return RegistryTransportResponse(
            statusCode: 200,
            headers: values,
            body: body
        )
    }

    private static func index(_ descriptors: [String]) -> Data {
        Data(
            """
            {"schemaVersion":2,"mediaType":"\(OCIReferrerIndex.mediaType)","manifests":[\(descriptors.joined(separator: ","))]}
            """.utf8
        )
    }

    private static func descriptor(
        digest: String,
        artifactType: String
    ) -> String {
        """
        {"mediaType":"\(OCIReferrerDescriptor.manifestMediaType)","digest":"\(digest)","size":64,"artifactType":"\(artifactType)"}
        """
    }
}

private final class ReferrerDiscoveryTransport:
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
