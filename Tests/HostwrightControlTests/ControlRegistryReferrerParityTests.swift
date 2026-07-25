import Foundation
@testable import HostwrightControl
import XCTest

final class ControlRegistryReferrerParityTests: XCTestCase {
    func testFetchRequestMapsToVersionedCLIWithoutCredentials()
        throws
    {
        let subject =
            "sha256:" + String(repeating: "a", count: 64)
        let request = LocalControlRequest(
            requestID: "referrer-fetch-1",
            operation: .registry,
            registryReferrerOperation: "fetch",
            registryServer: "registry.example.com",
            registryRepository: "team/api",
            registrySubjectDigest: subject,
            registryArtifactType:
                "application/vnd.example.opaque.v1",
            registryOffline: true
        )

        let arguments = try LocalControlAPI.commandArguments(
            for: request,
            configuration: LocalControlConfiguration(
                manifestPath: "/unused",
                stateDatabasePath: "/tmp/state.sqlite"
            )
        )

        XCTAssertEqual(arguments, [
            "registry", "referrers", "fetch",
            "registry.example.com",
            "--repository", "team/api",
            "--subject", subject,
            "--artifact-type",
            "application/vnd.example.opaque.v1",
            "--offline",
            "--state-db", "/tmp/state.sqlite",
            "--json"
        ])
        XCTAssertFalse(
            arguments.contains {
                $0.localizedCaseInsensitiveContains("password") ||
                    $0.localizedCaseInsensitiveContains("token")
            }
        )
    }

    func testPrunePreviewAndConfirmedRequestsHaveCLIParity()
        throws
    {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let digest =
            "sha256:" + String(repeating: "b", count: 64)
        let confirmation = String(repeating: "c", count: 64)
        let preview = LocalControlRequest(
            requestID: "referrer-prune-preview",
            operation: .registry,
            registryReferrerOperation: "prune",
            registryDiscoveryID: discoveryID,
            registryReferrerDigest: digest
        )
        let confirmed = LocalControlRequest(
            requestID: "referrer-prune-confirmed",
            operation: .registry,
            confirmPlan: confirmation,
            registryReferrerOperation: "prune",
            registryDiscoveryID: discoveryID,
            registryReferrerDigest: digest
        )
        let configuration = LocalControlConfiguration(
            manifestPath: "/unused"
        )

        XCTAssertEqual(
            try LocalControlAPI.commandArguments(
                for: preview,
                configuration: configuration
            ),
            [
                "registry", "referrers", "prune", discoveryID,
                "--digest", digest, "--json"
            ]
        )
        XCTAssertEqual(
            try LocalControlAPI.commandArguments(
                for: confirmed,
                configuration: configuration
            ),
            [
                "registry", "referrers", "prune", discoveryID,
                "--digest", digest,
                "--confirm-plan", confirmation,
                "--json"
            ]
        )
    }

    func testParserRejectsCrossOperationAndCredentialFields()
        throws
    {
        let invalid = LocalControlRequest(
            requestID: "invalid-registry",
            operation: .registry,
            registryReferrerOperation: "status",
            registryServer: "registry.example.com",
            registryDiscoveryID:
                "11111111-1111-4111-8111-111111111111"
        )
        XCTAssertThrowsError(
            try LocalControlAPI.commandArguments(
                for: invalid,
                configuration: LocalControlConfiguration(
                    manifestPath: "/unused"
                )
            )
        )

        let encoded = Data(
            """
            {
              "apiVersion": 2,
              "requestID": "credential-leak",
              "operation": "registry",
              "registryReferrerOperation": "status",
              "registryDiscoveryID": "11111111-1111-4111-8111-111111111111",
              "password": "secret"
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try LocalControlRequestParser.parse(encoded)
        )
        XCTAssertThrowsError(
            try LocalControlRequestParser.validate(
                LocalControlRequest(
                    requestID: "invalid-digest",
                    operation: .registry,
                    registryReferrerOperation: "discover",
                    registryServer: "registry.example.com",
                    registryRepository: "team/api",
                    registrySubjectDigest: "latest"
                )
            )
        )
        XCTAssertThrowsError(
            try LocalControlRequestParser.validate(
                LocalControlRequest(
                    requestID: "false-offline",
                    operation: .registry,
                    registryReferrerOperation: "fetch",
                    registryServer: "registry.example.com",
                    registryRepository: "team/api",
                    registrySubjectDigest:
                        "sha256:" +
                        String(repeating: "a", count: 64),
                    registryOffline: false
                )
            )
        )
    }

    func testEveryReferrerOperationHasOneShotMapping() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let fence = "22222222-2222-4222-8222-222222222222"
        let digest =
            "sha256:" + String(repeating: "d", count: 64)
        let confirmation = String(repeating: "e", count: 64)
        let requests = [
            LocalControlRequest(
                requestID: "discover",
                operation: .registry,
                registryReferrerOperation: "discover",
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registrySubjectDigest: digest
            ),
            LocalControlRequest(
                requestID: "fetch",
                operation: .registry,
                registryReferrerOperation: "fetch",
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registrySubjectDigest: digest
            ),
            LocalControlRequest(
                requestID: "publish",
                operation: .registry,
                registryReferrerOperation: "publish",
                registryTargetServer: "target.example.com",
                registryTargetRepository: "team/copy",
                registryDiscoveryID: id
            ),
            LocalControlRequest(
                requestID: "copy",
                operation: .registry,
                registryReferrerOperation: "copy",
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registrySubjectDigest: digest,
                registryTargetServer: "target.example.com",
                registryTargetRepository: "team/copy"
            ),
            LocalControlRequest(
                requestID: "retain",
                operation: .registry,
                registryReferrerOperation: "retain",
                registryDiscoveryID: id,
                registryOwnerID: "verifier",
                registryExpiresAt: "2099-01-01T00:00:00Z"
            ),
            LocalControlRequest(
                requestID: "release",
                operation: .registry,
                registryReferrerOperation: "release",
                registryLeaseID: id,
                registryFencingToken: fence
            ),
            LocalControlRequest(
                requestID: "status",
                operation: .registry,
                registryReferrerOperation: "status",
                registryDiscoveryID: id
            ),
            LocalControlRequest(
                requestID: "prune",
                operation: .registry,
                registryReferrerOperation: "prune",
                registryDiscoveryID: id,
                registryReferrerDigest: digest
            ),
            LocalControlRequest(
                requestID: "resume",
                operation: .registry,
                confirmPlan: confirmation,
                registryReferrerOperation: "resume",
                registryOperationGroupID: id
            )
        ]
        for request in requests {
            let encoded = try JSONEncoder().encode(request)
            XCTAssertEqual(
                try LocalControlRequestParser.parse(encoded),
                request
            )
            let arguments = try LocalControlAPI.commandArguments(
                for: request,
                configuration: LocalControlConfiguration(
                    manifestPath: "/unused"
                )
            )
            XCTAssertEqual(arguments.prefix(2), ["registry", "referrers"])
            XCTAssertEqual(arguments.last, "--json")
        }
    }
}
