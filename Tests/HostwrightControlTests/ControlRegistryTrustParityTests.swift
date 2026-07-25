import Foundation
@testable import HostwrightControl
import XCTest

final class ControlRegistryTrustParityTests: XCTestCase {
    func testEveryTrustOperationMapsToExactOneShotCLI() throws {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let exceptionID =
            "22222222-2222-4222-8222-222222222222"
        let configuration = LocalControlConfiguration(
            manifestPath: "/tmp/hostwright.yml",
            stateDatabasePath: "/tmp/state.sqlite"
        )
        let requests: [(LocalControlRequest, [String])] = [
            (
                LocalControlRequest(
                    requestID: "trust-verify",
                    operation: .registry,
                    registryDiscoveryID: discoveryID,
                    registryTrustOperation: "verify",
                    registrySubjectManifestPath: "/tmp/subject.json",
                    registryCosignPath: "/opt/homebrew/bin/cosign",
                    registryServiceName: "api"
                ),
                [
                    "registry", "trust", "verify", discoveryID,
                    "--manifest", "/tmp/hostwright.yml",
                    "--subject-manifest", "/tmp/subject.json",
                    "--cosign", "/opt/homebrew/bin/cosign",
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite", "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "trust-status",
                    operation: .registry,
                    registryTrustOperation: "status",
                    registryServiceName: "api"
                ),
                [
                    "registry", "trust", "status",
                    "/tmp/hostwright.yml",
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite", "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "trust-grant",
                    operation: .registry,
                    registryTrustOperation: "grant-exception",
                    registryApprovalRecordPath: "/tmp/approval.json"
                ),
                [
                    "registry", "trust", "grant-exception",
                    "/tmp/approval.json",
                    "--manifest", "/tmp/hostwright.yml",
                    "--state-db", "/tmp/state.sqlite", "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "trust-revoke",
                    operation: .registry,
                    registryTrustOperation: "revoke-exception",
                    registryExceptionID: exceptionID
                ),
                [
                    "registry", "trust", "revoke-exception",
                    exceptionID,
                    "--state-db", "/tmp/state.sqlite", "--json"
                ]
            )
        ]

        for (request, expected) in requests {
            let encoded = try JSONEncoder().encode(request)
            XCTAssertEqual(
                try LocalControlRequestParser.parse(encoded),
                request
            )
            let arguments = try LocalControlAPI.commandArguments(
                for: request,
                configuration: configuration
            )
            XCTAssertEqual(arguments, expected)
            XCTAssertFalse(
                arguments.contains(where: {
                    $0.localizedCaseInsensitiveContains("password") ||
                        $0.localizedCaseInsensitiveContains("token")
                })
            )
        }
    }

    func testTrustRequestsRejectCrossOperationAndUnsafeFields() {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let invalid = [
            LocalControlRequest(
                requestID: "both-operations",
                operation: .registry,
                registryReferrerOperation: "status",
                registryDiscoveryID: discoveryID,
                registryTrustOperation: "verify",
                registrySubjectManifestPath: "/tmp/subject.json",
                registryCosignPath: "/usr/bin/cosign"
            ),
            LocalControlRequest(
                requestID: "relative-subject",
                operation: .registry,
                registryDiscoveryID: discoveryID,
                registryTrustOperation: "verify",
                registrySubjectManifestPath: "subject.json",
                registryCosignPath: "/usr/bin/cosign"
            ),
            LocalControlRequest(
                requestID: "grant-with-service",
                operation: .registry,
                registryTrustOperation: "grant-exception",
                registryServiceName: "api",
                registryApprovalRecordPath: "/tmp/approval.json"
            )
        ]
        for request in invalid {
            XCTAssertThrowsError(
                try LocalControlRequestParser.validate(request)
            )
        }

        XCTAssertThrowsError(
            try LocalControlRequestParser.parse(
                Data(
                    """
                    {
                      "apiVersion": 2,
                      "requestID": "credential-field",
                      "operation": "registry",
                      "registryTrustOperation": "status",
                      "password": "secret"
                    }
                    """.utf8
                )
            )
        )
    }
}
