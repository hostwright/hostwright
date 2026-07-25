import Foundation
import XCTest
@testable import HostwrightRegistry

final class RegistryAuthContractTests: XCTestCase {
    func testEndpointCanonicalizesHTTPSOriginsAndDockerHubAliases() throws {
        let dockerAliases = try [
            RegistryEndpoint("docker.io"),
            RegistryEndpoint("https://index.docker.io"),
            RegistryEndpoint("registry-1.docker.io:443")
        ]
        XCTAssertEqual(Set(dockerAliases.map(\.authority)), ["registry-1.docker.io"])
        XCTAssertEqual(dockerAliases[0].canonicalURLString, "https://registry-1.docker.io")

        let privateRegistry = try RegistryEndpoint("REGISTRY.example.com:5443")
        XCTAssertEqual(privateRegistry.host, "registry.example.com")
        XCTAssertEqual(privateRegistry.port, 5_443)
        XCTAssertEqual(privateRegistry.url.absoluteString, "https://registry.example.com:5443")

        let ipv6 = try RegistryEndpoint("[2001:db8::1]:5000")
        XCTAssertEqual(ipv6.host, "2001:db8::1")
        XCTAssertEqual(ipv6.authority, "[2001:db8::1]:5000")
    }

    func testEndpointRejectsNonOriginsAndInvalidAuthorities() {
        for value in [
            "",
            " http://registry.example.com",
            "http://registry.example.com",
            "https://user:password@registry.example.com",
            "https://registry.example.com/v2",
            "https://registry.example.com?token=x",
            "https://registry.example.com#fragment",
            "registry.example.com/",
            "https://registry.example.com:",
            "999.1.1.1",
            "[:::]",
            "-registry.example.com",
            String(repeating: "a", count: RegistryEndpoint.maximumInputBytes + 1)
        ] {
            XCTAssertThrowsError(try RegistryEndpoint(value), value)
        }
    }

    func testCredentialKeychainAccountIsDeterministicAndNonRevealing() throws {
        let alias = try RegistryEndpoint("docker.io")
        let canonical = try RegistryEndpoint("registry-1.docker.io")
        XCTAssertEqual(alias.credentialKeychainAccount, canonical.credentialKeychainAccount)
        XCTAssertEqual(alias.credentialKeychainAccount.count, 64)
        XCTAssertFalse(alias.credentialKeychainAccount.contains("docker"))
        XCTAssertEqual(
            RegistryEndpoint.credentialKeychainService,
            "dev.hostwright.registry"
        )
    }

    func testDistributionScopesCanonicalizeAndEnforceSubsetWithoutEscalation() throws {
        let pull = try RegistryAccessScope.parse("repository:team/app:pull")
        let pullPush = try RegistryAccessScope.parse("repository:team/app:push,pull")
        let delete = try RegistryAccessScope.parse("repository:team/app:delete")
        let wildcard = try RegistryAccessScope.parse("repository:team/app:*")
        let other = try RegistryAccessScope.parse("repository:team/other:pull")

        XCTAssertEqual(pullPush.canonicalValue, "repository:team/app:pull,push")
        XCTAssertTrue(pull.isSubset(of: pullPush))
        XCTAssertFalse(pullPush.isSubset(of: pull))
        XCTAssertFalse(delete.isSubset(of: pullPush))
        XCTAssertTrue(delete.isSubset(of: wildcard))
        XCTAssertFalse(wildcard.isSubset(of: pullPush))
        XCTAssertFalse(pull.isSubset(of: other))

        let requested = try RegistryAccessScopeSet([pullPush])
        let returned = try RegistryAccessScopeSet.parse("repository:team/app:pull")
        XCTAssertTrue(returned.isSubset(of: requested))
        XCTAssertFalse(
            try RegistryAccessScopeSet([delete]).isSubset(of: requested)
        )
    }

    func testScopeSetMergesSameResourceDeterministically() throws {
        let set = try RegistryAccessScopeSet.parse(
            "repository:team/app:push repository:team/app:pull registry:catalog:*"
        )
        XCTAssertEqual(
            set.canonicalValue,
            "registry:catalog:* repository:team/app:pull,push"
        )
        XCTAssertEqual(set.scopes.count, 2)
    }

    func testScopesRejectMalformedDuplicateUnknownAndOversizedValues() {
        for value in [
            "Repository:team/app:pull",
            "repository:Team/App:pull",
            "repository:team/app:read",
            "repository:team/app:pull,pull",
            "repository:team/app:*,pull",
            "registry:catalog:pull",
            "registry:other:*",
            "repository::pull",
            "repository:team/app:",
            " repository:team/app:pull",
            String(repeating: "a", count: RegistryAccessScope.maximumBytes + 1)
        ] {
            XCTAssertThrowsError(try RegistryAccessScope.parse(value), value)
        }
        XCTAssertThrowsError(
            try RegistryAccessScopeSet.parse(
                "repository:team/app:pull  repository:team/other:pull"
            )
        )
    }

    func testCredentialStorageRoundTripsAtBoundaryAndAlwaysRedacts() throws {
        let secret = String(repeating: "s", count: RegistryCredential.maximumSecretBytes)
        let credential = try RegistryCredential(username: "builder", secret: secret)
        let encoded = try credential.encodedForStorage()
        XCTAssertLessThanOrEqual(encoded.count, RegistryCredential.maximumStorageBytes)

        let decoded = try RegistryCredential.decodeFromStorage(encoded)
        XCTAssertEqual(decoded.username, "builder")
        XCTAssertEqual(decoded.withSecret { $0 }, secret)
        XCTAssertFalse(credential.description.contains("builder"))
        XCTAssertFalse(credential.description.contains(secret))
        XCTAssertFalse(credential.debugDescription.contains("builder"))
        XCTAssertFalse(credential.debugDescription.contains(secret))
    }

    func testCredentialRejectsMalformedStorageAndSecretOverflow() {
        XCTAssertThrowsError(
            try RegistryCredential(
                username: "builder",
                secret: String(repeating: "s", count: RegistryCredential.maximumSecretBytes + 1)
            )
        )
        XCTAssertThrowsError(try RegistryCredential(username: "bad:user", secret: "secret"))
        XCTAssertThrowsError(
            try RegistryCredential.decodeFromStorage(
                Data(#"{"schemaVersion":1,"schemaVersion":1,"secretBase64":"cw==","username":"u"}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try RegistryCredential.decodeFromStorage(
                Data(#"{"schemaVersion":1,"secretBase64":"cw==","username":"u","unknown":true}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try RegistryCredential.decodeFromStorage(
                Data(#"{"schemaVersion":2,"secretBase64":"cw==","username":"u"}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try RegistryCredential.decodeFromStorage(
                Data(repeating: 0x20, count: RegistryCredential.maximumStorageBytes + 1)
            )
        )
    }

    func testBasicChallengeParsesQuotedEscapesAndUnknownParameters() throws {
        let challenge = try RegistryAuthenticationChallenge.parse(
            #"Basic realm="private \"registry\"", charset="UTF-8", extension="accepted""#
        )
        guard case .basic(let basic) = challenge else {
            return XCTFail("Expected Basic challenge.")
        }
        XCTAssertEqual(basic.realm, #"private "registry""#)
        XCTAssertTrue(basic.usesUTF8)
    }

    func testBearerChallengeParsesHTTPSRealmServiceAndScopes() throws {
        let challenge = try RegistryAuthenticationChallenge.parse(
            #"Bearer realm="https://auth.example.com/token",service="registry.example.com",scope="repository:team/app:pull,push",extension="accepted""#
        )
        guard case .bearer(let bearer) = challenge else {
            return XCTFail("Expected Bearer challenge.")
        }
        XCTAssertEqual(bearer.realm.absoluteString, "https://auth.example.com/token")
        XCTAssertEqual(bearer.service, "registry.example.com")
        XCTAssertEqual(
            bearer.scopes.canonicalValue,
            "repository:team/app:pull,push"
        )
    }

    func testChallengesRejectDuplicatesInsecureRealmMalformedAndOversizedValues() {
        for value in [
            #"Bearer realm="https://auth.example.com/token",realm="https://other.example.com/token""#,
            #"Bearer realm="http://auth.example.com/token""#,
            #"Bearer realm="https://user:password@auth.example.com/token""#,
            #"Bearer realm="https://auth.example.com/token#fragment""#,
            #"Bearer realm="https://[:::]/token""#,
            #"Bearer realm="https://auth.example.com/token",scope="repository:team/app:admin""#,
            #"Basic realm="a",charset="ISO-8859-1""#,
            #"Basic realm="unterminated"#,
            "Basic realm=",
            #"Digest realm="registry""#,
            #"Bearer realm="https://auth.example.com/token","#,
            String(repeating: "a", count: RegistryAuthenticationChallenge.maximumHeaderBytes + 1)
        ] {
            XCTAssertThrowsError(
                try RegistryAuthenticationChallenge.parse(value),
                value
            )
        }
    }

    func testTokenResponseParsesAliasExpiryRefreshAndUnknownFields() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let requested = try RegistryAccessScopeSet.parse(
            "repository:team/app:pull,push"
        )
        let data = Data(
            #"""
            {
              "access_token":"access-secret",
              "token":"access-secret",
              "expires_in":120,
              "issued_at":"2023-11-14T22:13:20Z",
              "refresh_token":"refresh-secret",
              "scope":"repository:team/app:pull",
              "unknown":{"future":true}
            }
            """#.utf8
        )
        let response = try RegistryTokenResponse.parse(
            data,
            receivedAt: receivedAt,
            requestedScopes: requested
        )
        XCTAssertEqual(response.withAccessToken { $0 }, "access-secret")
        XCTAssertEqual(response.withRefreshToken { $0 }, "refresh-secret")
        XCTAssertEqual(response.expiresAt, receivedAt.addingTimeInterval(120))
        XCTAssertFalse(response.needsRefresh(at: receivedAt.addingTimeInterval(89)))
        XCTAssertTrue(response.needsRefresh(at: receivedAt.addingTimeInterval(90)))
        XCTAssertFalse(response.isExpired(at: receivedAt.addingTimeInterval(119.999)))
        XCTAssertTrue(response.isExpired(at: receivedAt.addingTimeInterval(120)))
        XCTAssertFalse(response.description.contains("access-secret"))
        XCTAssertFalse(response.debugDescription.contains("refresh-secret"))
    }

    func testTokenResponseUsesDeterministicDefaults() throws {
        let receivedAt = Date(timeIntervalSince1970: 100)
        let response = try RegistryTokenResponse.parse(
            Data(#"{"token":"secret"}"#.utf8),
            receivedAt: receivedAt
        )
        XCTAssertEqual(response.issuedAt, receivedAt)
        XCTAssertEqual(
            response.expiresAt,
            receivedAt.addingTimeInterval(RegistryTokenResponse.defaultLifetime)
        )
        XCTAssertNil(response.withRefreshToken { $0 })
        XCTAssertTrue(
            response.needsRefresh(
                at: receivedAt,
                minimumRemainingLifetime: .infinity
            )
        )
    }

    func testTokenResponseRejectsMalformedDuplicateConflictEscalationAndOversize() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let requested = try RegistryAccessScopeSet.parse(
            "repository:team/app:pull"
        )
        let invalid: [Data] = [
            Data(),
            Data(#"{"token":"a","token":"b"}"#.utf8),
            Data(#"{"token":"a","access_token":"b"}"#.utf8),
            Data(#"{"token":1}"#.utf8),
            Data(#"{"token":""}"#.utf8),
            Data(#"{"token":"a","expires_in":true}"#.utf8),
            Data(#"{"token":"a","expires_in":-1}"#.utf8),
            Data(#"{"token":"a","expires_in":31536001}"#.utf8),
            Data(#"{"token":"a","issued_at":"not-a-date"}"#.utf8),
            Data(#"{"token":"a","refresh_token":7}"#.utf8),
            Data(#"{"token":"a","scope":"repository:team/app:pull,push"}"#.utf8),
            Data(repeating: 0x20, count: RegistryTokenResponse.maximumResponseBytes + 1)
        ]
        for data in invalid {
            XCTAssertThrowsError(
                try RegistryTokenResponse.parse(
                    data,
                    receivedAt: receivedAt,
                    requestedScopes: requested
                )
            )
        }
    }

    func testTokenResponseRejectsIssuedAtBeyondClockSkew() {
        let receivedAt = Date(timeIntervalSince1970: 0)
        XCTAssertThrowsError(
            try RegistryTokenResponse.parse(
                Data(#"{"token":"a","issued_at":"1970-01-01T00:05:01Z"}"#.utf8),
                receivedAt: receivedAt
            )
        )
    }
}
