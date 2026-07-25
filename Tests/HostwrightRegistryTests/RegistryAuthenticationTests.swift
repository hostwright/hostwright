import Foundation
@testable import HostwrightRegistry
import XCTest

final class RegistryAuthenticationTests: XCTestCase {
    func testAnonymousRegistryReportsStructuredCapability() throws {
        let transport = ScriptedRegistryTransport([
            .success(
                RegistryTransportResponse(
                    statusCode: 200,
                    headers: [
                        "docker-distribution-api-version": "registry/2.0"
                    ],
                    body: Data()
                )
            )
        ])
        let result = try RegistryAuthenticationClient(
            transport: transport
        ).authenticate(endpoint: RegistryEndpoint("registry.example.com"))

        XCTAssertEqual(result.kind, .anonymous)
        XCTAssertTrue(result.distributionAPIVersionVerified)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNil(transport.requests[0].authorization)
    }

    func testBasicChallengeUsesBoundedAuthorizationWithoutDisclosure() throws {
        let transport = ScriptedRegistryTransport([
            .success(
                RegistryTransportResponse(
                    statusCode: 401,
                    headers: ["www-authenticate": #"Basic realm="private""#],
                    body: Data()
                )
            ),
            .success(
                RegistryTransportResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data()
                )
            )
        ])
        let result = try RegistryAuthenticationClient(
            transport: transport
        ).authenticate(
            endpoint: RegistryEndpoint("registry.example.com"),
            requestedScopes: Self.pullScope(),
            credential: RegistryCredential(
                username: "developer",
                secret: "not-in-output"
            )
        )

        XCTAssertEqual(result.kind, .basic)
        XCTAssertEqual(result.requestedScopes, try Self.pullScope())
        XCTAssertEqual(result.grantedScopes, .empty)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(
            transport.requests[1].authorization?.scheme,
            .basic
        )
        XCTAssertFalse(
            String(describing: transport.requests[1])
                .contains("not-in-output")
        )
    }

    func testDirectIdentityTokenDoesNotClaimUnprovenRepositoryScope() throws {
        let transport = ScriptedRegistryTransport([
            .success(Self.registrySuccess())
        ])
        let requested = try Self.pullScope()
        let result = try RegistryAuthenticationClient(
            transport: transport
        ).authenticate(
            endpoint: RegistryEndpoint("registry.example.com"),
            requestedScopes: requested,
            credential: RegistryCredential(
                username: "identity-token",
                secret: "not-in-output"
            ),
            credentialKind: .identityToken
        )

        XCTAssertEqual(result.kind, .bearer)
        XCTAssertEqual(result.requestedScopes, requested)
        XCTAssertEqual(result.grantedScopes, .empty)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].authorization?.scheme, .bearer)
    }

    func testBearerTokenRefreshesAfterExpiryWithoutReprobingRegistry() throws {
        let clock = LockedRegistryClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let transport = ScriptedRegistryTransport([
            .success(Self.bearerChallenge()),
            .success(
                Self.tokenResponse(
                    token: "access-one",
                    refreshToken: "refresh-one",
                    expiresIn: 1
                )
            ),
            .success(Self.registrySuccess()),
            .success(
                Self.tokenResponse(
                    token: "access-two",
                    refreshToken: "refresh-two",
                    expiresIn: 300
                )
            ),
            .success(Self.registrySuccess())
        ])
        let client = RegistryAuthenticationClient(
            transport: transport,
            now: { clock.value }
        )
        let endpoint = try RegistryEndpoint("registry.example.com")
        let scope = try Self.pullScope()
        let credential = try RegistryCredential(
            username: "developer",
            secret: "rotatable-secret"
        )

        let first = try client.authenticate(
            endpoint: endpoint,
            requestedScopes: scope,
            credential: credential
        )
        clock.value = clock.value.addingTimeInterval(2)
        let second = try client.authenticate(
            endpoint: endpoint,
            requestedScopes: scope,
            credential: credential
        )

        XCTAssertEqual(first.kind, .bearer)
        XCTAssertTrue(first.tokenRefreshAvailable)
        XCTAssertEqual(second.kind, .bearer)
        XCTAssertEqual(transport.requests.count, 5)
        XCTAssertEqual(transport.requests[3].method, .post)
        XCTAssertEqual(
            transport.requests[3].url.absoluteString,
            "https://auth.example.com/token"
        )
        XCTAssertEqual(transport.requests[4].authorization?.scheme, .bearer)
    }

    func testCredentialRotationInvalidatesCachedToken() throws {
        let transport = ScriptedRegistryTransport([
            .success(Self.bearerChallenge()),
            .success(Self.tokenResponse(token: "one", expiresIn: 300)),
            .success(Self.registrySuccess()),
            .success(Self.bearerChallenge()),
            .success(Self.tokenResponse(token: "two", expiresIn: 300)),
            .success(Self.registrySuccess())
        ])
        let client = RegistryAuthenticationClient(transport: transport)
        let endpoint = try RegistryEndpoint("registry.example.com")
        let scope = try Self.pullScope()

        _ = try client.authenticate(
            endpoint: endpoint,
            requestedScopes: scope,
            credential: RegistryCredential(username: "developer", secret: "one")
        )
        _ = try client.authenticate(
            endpoint: endpoint,
            requestedScopes: scope,
            credential: RegistryCredential(username: "developer", secret: "two")
        )

        XCTAssertEqual(transport.requests.count, 6)
        XCTAssertNil(transport.requests[3].authorization)
    }

    func testChallengeCannotEscalateRequestedScope() throws {
        let transport = ScriptedRegistryTransport([
            .success(
                RegistryTransportResponse(
                    statusCode: 401,
                    headers: [
                        "www-authenticate":
                            #"Bearer realm="https://auth.example.com/token",service="registry.example.com",scope="repository:team/app:pull,push""#
                    ],
                    body: Data()
                )
            )
        ])

        XCTAssertThrowsError(
            try RegistryAuthenticationClient(
                transport: transport
            ).authenticate(
                endpoint: RegistryEndpoint("registry.example.com"),
                requestedScopes: Self.pullScope(),
                credential: RegistryCredential(
                    username: "developer",
                    secret: "secret"
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryAuthenticationError,
                .scopeDenied
            )
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testUntrustedRedirectAndCancellationFailClosed() throws {
        let redirected = ScriptedRegistryTransport([
            .failure(RegistryTransportError.redirectRejected)
        ])
        XCTAssertThrowsError(
            try RegistryAuthenticationClient(
                transport: redirected
            ).authenticate(
                endpoint: RegistryEndpoint("registry.example.com")
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryAuthenticationError,
                .invalidResponse
            )
        }

        let cancellation = RegistryTransportCancellation()
        cancellation.cancel()
        let cancelled = ScriptedRegistryTransport([])
        XCTAssertThrowsError(
            try RegistryAuthenticationClient(
                transport: cancelled
            ).authenticate(
                endpoint: RegistryEndpoint("registry.example.com"),
                cancellation: cancellation
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryAuthenticationError,
                .cancelled
            )
        }
        XCTAssertTrue(cancelled.requests.isEmpty)
    }

    func testLiveDockerHubBearerScopeWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment[
            "HOSTWRIGHT_LIVE_REGISTRY"
        ] == "1" else {
            throw XCTSkip(
                "Set HOSTWRIGHT_LIVE_REGISTRY=1 for the explicit TLS/token-service cell."
            )
        }
        let requested = try Self.pullScope(
            repository: "library/alpine"
        )
        let result = try RegistryAuthenticationClient().authenticate(
            endpoint: RegistryEndpoint("registry-1.docker.io"),
            requestedScopes: requested
        )

        XCTAssertEqual(result.kind, .bearer)
        XCTAssertTrue(requested.isSubset(of: result.grantedScopes))
        XCTAssertTrue(result.distributionAPIVersionVerified)
        XCTAssertNotNil(result.tokenExpiresAt)
    }

    private static func pullScope(
        repository: String = "team/app"
    ) throws -> RegistryAccessScopeSet {
        try RegistryAccessScopeSet([
            RegistryAccessScope(
                resourceType: .repository,
                name: repository,
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

    private static func registrySuccess() -> RegistryTransportResponse {
        RegistryTransportResponse(
            statusCode: 200,
            headers: ["docker-distribution-api-version": "registry/2.0"],
            body: Data()
        )
    }

    private static func tokenResponse(
        token: String,
        refreshToken: String? = nil,
        expiresIn: Int
    ) -> RegistryTransportResponse {
        var object: [String: Any] = [
            "expires_in": expiresIn,
            "token": token
        ]
        if let refreshToken {
            object["refresh_token"] = refreshToken
        }
        return RegistryTransportResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: try! JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        )
    }
}

private final class ScriptedRegistryTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var responses: [Result<RegistryTransportResponse, Error>]
    private var recordedRequests: [RegistryTransportRequest] = []

    init(_ responses: [Result<RegistryTransportResponse, Error>]) {
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

private final class LockedRegistryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        storedValue = value
    }

    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
