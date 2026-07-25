import Foundation
@testable import HostwrightControl
import XCTest

final class ControlRegistrySBOMParityTests: XCTestCase {
    func testEverySBOMOperationMapsToExactOneShotCLI() throws {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let descriptor =
            "sha256:" + String(repeating: "a", count: 64)
        let referrer =
            "sha256:" + String(repeating: "b", count: 64)
        let confirmation = String(repeating: "c", count: 64)
        let configuration = LocalControlConfiguration(
            manifestPath: "/tmp/hostwright.yml",
            stateDatabasePath: "/tmp/state.sqlite"
        )
        let requests: [(LocalControlRequest, [String])] = [
            (
                LocalControlRequest(
                    requestID: "sbom-generate",
                    operation: .registry,
                    registryServer: "registry.example.com",
                    registryRepository: "team/api",
                    registrySBOMOperation: "generate",
                    registrySBOMArchivePath: "/tmp/image.tar",
                    registrySBOMFormat: "spdx-json",
                    registryProvenanceDescriptorDigest: descriptor,
                    registryProvenanceReferrerDigest: referrer,
                    registryServiceName: "api"
                ),
                [
                    "registry", "sbom", "generate",
                    "/tmp/image.tar",
                    "--manifest", "/tmp/hostwright.yml",
                    "--server", "registry.example.com",
                    "--repository", "team/api",
                    "--format", "spdx-json",
                    "--service", "api",
                    "--provenance-descriptor-digest", descriptor,
                    "--provenance-referrer-digest", referrer,
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "sbom-ingest",
                    operation: .registry,
                    registryDiscoveryID: discoveryID,
                    registrySBOMOperation: "ingest",
                    registryServiceName: "api"
                ),
                [
                    "registry", "sbom", "ingest", discoveryID,
                    "--manifest", "/tmp/hostwright.yml",
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "sbom-query",
                    operation: .registry,
                    registrySBOMOperation: "query",
                    registryServiceName: "api"
                ),
                [
                    "registry", "sbom", "query",
                    "/tmp/hostwright.yml",
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "sbom-export",
                    operation: .registry,
                    registrySBOMOperation: "export",
                    registrySBOMFormat: "cyclonedx-json",
                    registrySBOMOutputPath: "/tmp/api.cdx.json",
                    registryServiceName: "api"
                ),
                [
                    "registry", "sbom", "export",
                    "/tmp/hostwright.yml",
                    "--format", "cyclonedx-json",
                    "--output-path", "/tmp/api.cdx.json",
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "sbom-resume",
                    operation: .registry,
                    confirmPlan: confirmation,
                    registryOperationGroupID: discoveryID,
                    registrySBOMOperation: "resume"
                ),
                [
                    "registry", "sbom", "resume", discoveryID,
                    "--confirm-plan", confirmation,
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
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
                arguments.contains {
                    $0.localizedCaseInsensitiveContains("password") ||
                        $0.localizedCaseInsensitiveContains("token")
                }
            )
        }
    }

    func testSBOMRequestsRejectUnsafeAndCrossOperationFields() {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let invalid = [
            LocalControlRequest(
                requestID: "sbom-cross-operation",
                operation: .registry,
                registryDiscoveryID: discoveryID,
                registryTrustOperation: "status",
                registrySBOMOperation: "ingest"
            ),
            LocalControlRequest(
                requestID: "sbom-relative-archive",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registrySBOMOperation: "generate",
                registrySBOMArchivePath: "image.tar",
                registrySBOMFormat: "spdx-json"
            ),
            LocalControlRequest(
                requestID: "sbom-half-provenance",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registrySBOMOperation: "generate",
                registrySBOMArchivePath: "/tmp/image.tar",
                registrySBOMFormat: "spdx-json",
                registryProvenanceDescriptorDigest:
                    "sha256:" + String(repeating: "a", count: 64)
            ),
            LocalControlRequest(
                requestID: "sbom-query-with-discovery",
                operation: .registry,
                registryDiscoveryID: discoveryID,
                registrySBOMOperation: "query"
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
                      "requestID": "sbom-credential-field",
                      "operation": "registry",
                      "registrySBOMOperation": "query",
                      "token": "secret"
                    }
                    """.utf8
                )
            )
        )
    }
}
