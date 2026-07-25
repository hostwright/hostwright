import Foundation
@testable import HostwrightRegistry
import XCTest

final class RegistryAuthorizedRequestTests: XCTestCase {
    func testBearerChallengeAuthorizesExactRegistryRequest() throws {
        let transport = AuthorizedRequestTransport([
            Self.bearerChallenge(),
            Self.tokenResponse(),
            RegistryTransportResponse(
                statusCode: 200,
                headers: ["content-type": OCIReferrerIndex.mediaType],
                body: Data("{}".utf8)
            )
        ])
        let endpoint = try RegistryEndpoint("registry.example.com")
        let request = RegistryTransportRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://registry.example.com/v2/team/app/referrers/sha256:" +
                        String(repeating: "a", count: 64)
                )
            ),
            method: .get,
            headers: ["Accept": OCIReferrerIndex.mediaType]
        )

        let result = try RegistryAuthenticationClient(
            transport: transport
        ).sendAuthorized(
            request,
            endpoint: endpoint,
            requestedScopes: try Self.scope(),
            credential: try RegistryCredential(
                username: "operator",
                secret: "must-not-leak"
            )
        )

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(result.authentication.kind, .bearer)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[0].url, request.url)
        XCTAssertNil(transport.requests[0].authorization)
        XCTAssertEqual(transport.requests[2].url, request.url)
        XCTAssertEqual(transport.requests[2].authorization?.scheme, .bearer)
        XCTAssertFalse(String(describing: result).contains("must-not-leak"))
        XCTAssertFalse(
            transport.requests.map(String.init(describing:))
                .joined()
                .contains("must-not-leak")
        )
    }

    func testAuthorizedRequestReturnsRegistry404WithoutReclassifyingIt() throws {
        let transport = AuthorizedRequestTransport([
            RegistryTransportResponse(
                statusCode: 404,
                headers: ["content-type": "application/json"],
                body: Data()
            )
        ])
        let endpoint = try RegistryEndpoint("registry.example.com")
        let request = RegistryTransportRequest(
            url: endpoint.url.appendingPathComponent(
                "v2/team/app/referrers/" +
                    "sha256:" + String(repeating: "a", count: 64)
            ),
            method: .get
        )

        let result = try RegistryAuthenticationClient(
            transport: transport
        ).sendAuthorized(
            request,
            endpoint: endpoint,
            requestedScopes: try Self.scope()
        )

        XCTAssertEqual(result.response.statusCode, 404)
        XCTAssertEqual(result.authentication.kind, .anonymous)
    }

    func testAuthorizedRequestRejectsCrossOriginAndCallerAuthorization() throws {
        let endpoint = try! RegistryEndpoint("registry.example.com")
        let transport = AuthorizedRequestTransport([])
        let client = RegistryAuthenticationClient(transport: transport)
        let crossOrigin = RegistryTransportRequest(
            url: URL(string: "https://evil.example.com/v2/team/app/manifests/x")!,
            method: .get
        )
        XCTAssertThrowsError(
            try client.sendAuthorized(
                crossOrigin,
                endpoint: endpoint,
                requestedScopes: try Self.scope()
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryAuthenticationError,
                .invalidRequest
            )
        }

        let preauthorized = RegistryTransportRequest(
            url: URL(
                string:
                    "https://registry.example.com/v2/team/app/manifests/x"
            )!,
            method: .get,
            authorization: try! RegistryTransportAuthorization(
                scheme: .bearer,
                value: "caller-secret"
            )
        )
        XCTAssertThrowsError(
            try client.sendAuthorized(
                preauthorized,
                endpoint: endpoint,
                requestedScopes: try Self.scope()
            )
        )
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAuthorizedRequestReusesScopedTokenAndHonorsCancellation() throws {
        let transport = AuthorizedRequestTransport([
            Self.bearerChallenge(),
            Self.tokenResponse(),
            RegistryTransportResponse(statusCode: 200, headers: [:], body: Data()),
            RegistryTransportResponse(statusCode: 200, headers: [:], body: Data())
        ])
        let endpoint = try RegistryEndpoint("registry.example.com")
        let request = RegistryTransportRequest(
            url: URL(
                string:
                    "https://registry.example.com/v2/team/app/manifests/" +
                    "sha256:" + String(repeating: "b", count: 64)
            )!,
            method: .get
        )
        let client = RegistryAuthenticationClient(transport: transport)
        let scope = try Self.scope()

        _ = try client.sendAuthorized(
            request,
            endpoint: endpoint,
            requestedScopes: scope
        )
        _ = try client.sendAuthorized(
            request,
            endpoint: endpoint,
            requestedScopes: scope
        )
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(transport.requests[3].authorization?.scheme, .bearer)

        let cancellation = RegistryTransportCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try client.sendAuthorized(
                request,
                endpoint: endpoint,
                requestedScopes: scope,
                cancellation: cancellation
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryAuthenticationError,
                .cancelled
            )
        }
        XCTAssertEqual(transport.requests.count, 4)
    }

    private static func scope() throws -> RegistryAccessScopeSet {
        try RegistryAccessScopeSet([
            RegistryAccessScope(
                resourceType: .repository,
                name: "team/app",
                actions: [.pull]
            )
        ])
    }

    private static func bearerChallenge() -> RegistryTransportResponse {
        RegistryTransportResponse(
            statusCode: 401,
            headers: [
                "www-authenticate":
                    #"Bearer realm="https://auth.example.com/token",service="registry.example.com""#
            ],
            body: Data()
        )
    }

    private static func tokenResponse() -> RegistryTransportResponse {
        RegistryTransportResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(
                """
                {"token":"access-token","expires_in":300,"scope":"repository:team/app:pull"}
                """.utf8
            )
        )
    }
}

private final class AuthorizedRequestTransport:
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
