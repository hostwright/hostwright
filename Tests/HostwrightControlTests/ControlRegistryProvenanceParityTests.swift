import Foundation
@testable import HostwrightControl
import XCTest

final class ControlRegistryProvenanceParityTests: XCTestCase {
    func testEveryProvenanceOperationMapsToExactOneShotCLI()
        throws
    {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let groupID =
            "22222222-2222-4222-8222-222222222222"
        let referrer =
            "sha256:" + String(repeating: "a", count: 64)
        let confirmation = String(repeating: "b", count: 64)
        let keyReference =
            "keychain://hostwright.provenance/api-signer"
        let configuration = LocalControlConfiguration(
            manifestPath: "/tmp/hostwright.yml",
            stateDatabasePath: "/tmp/state.sqlite"
        )
        let requests: [(LocalControlRequest, [String])] = [
            (
                LocalControlRequest(
                    requestID: "provenance-generate",
                    operation: .registry,
                    registryServer: "registry.example.com",
                    registryRepository: "team/api",
                    registryProvenanceOperation: "generate",
                    registryProvenanceArchivePath:
                        "/tmp/api-image.tar",
                    registryProvenanceBuildRecordPath:
                        "/tmp/api-build.json",
                    registryProvenanceSignerID: "release-builder",
                    registryProvenanceSigningKeyReference:
                        keyReference,
                    registryServiceName: "api"
                ),
                [
                    "registry", "provenance", "generate",
                    "/tmp/api-image.tar",
                    "--record", "/tmp/api-build.json",
                    "--manifest", "/tmp/hostwright.yml",
                    "--server", "registry.example.com",
                    "--repository", "team/api",
                    "--signer", "release-builder",
                    "--signing-key-ref", keyReference,
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "provenance-verify",
                    operation: .registry,
                    registryDiscoveryID: discoveryID,
                    registryReferrerDigest: referrer,
                    registryProvenanceOperation: "verify",
                    registryServiceName: "api"
                ),
                [
                    "registry", "provenance", "verify",
                    discoveryID,
                    "--digest", referrer,
                    "--manifest", "/tmp/hostwright.yml",
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "provenance-status",
                    operation: .registry,
                    registryProvenanceOperation: "status",
                    registryServiceName: "api"
                ),
                [
                    "registry", "provenance", "status",
                    "/tmp/hostwright.yml",
                    "--service", "api",
                    "--state-db", "/tmp/state.sqlite",
                    "--json"
                ]
            ),
            (
                LocalControlRequest(
                    requestID: "provenance-resume",
                    operation: .registry,
                    confirmPlan: confirmation,
                    registryOperationGroupID: groupID,
                    registryProvenanceOperation: "resume",
                    registryProvenanceSigningKeyReference:
                        keyReference
                ),
                [
                    "registry", "provenance", "resume",
                    groupID,
                    "--confirm-plan", confirmation,
                    "--signing-key-ref", keyReference,
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
            XCTAssertEqual(
                try LocalControlAPI.commandArguments(
                    for: request,
                    configuration: configuration
                ),
                expected
            )
        }
    }

    func testProvenanceRejectsMalformedAndAmbiguousRequests() {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let referrer =
            "sha256:" + String(repeating: "a", count: 64)
        let invalid = [
            LocalControlRequest(
                requestID: "provenance-cross-operation",
                operation: .registry,
                registryDiscoveryID: discoveryID,
                registryReferrerDigest: referrer,
                registrySBOMOperation: "ingest",
                registryProvenanceOperation: "verify"
            ),
            LocalControlRequest(
                requestID: "provenance-missing-record",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registryProvenanceOperation: "generate",
                registryProvenanceArchivePath:
                    "/tmp/api-image.tar",
                registryProvenanceSignerID: "release-builder",
                registryProvenanceSigningKeyReference:
                    "keychain://hostwright.provenance/api"
            ),
            LocalControlRequest(
                requestID: "provenance-raw-key",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registryProvenanceOperation: "generate",
                registryProvenanceArchivePath:
                    "/tmp/api-image.tar",
                registryProvenanceBuildRecordPath:
                    "/tmp/api-build.json",
                registryProvenanceSignerID: "release-builder",
                registryProvenanceSigningKeyReference:
                    String(repeating: "A", count: 44)
            ),
            LocalControlRequest(
                requestID: "provenance-default-key",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registryProvenanceOperation: "generate",
                registryProvenanceArchivePath:
                    "/tmp/api-image.tar",
                registryProvenanceBuildRecordPath:
                    "/tmp/api-build.json",
                registryProvenanceSignerID: "release-builder",
                registryProvenanceSigningKeyReference: "default"
            ),
            LocalControlRequest(
                requestID: "provenance-relative-archive",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registryProvenanceOperation: "generate",
                registryProvenanceArchivePath: "api-image.tar",
                registryProvenanceBuildRecordPath:
                    "/tmp/api-build.json",
                registryProvenanceSignerID: "release-builder",
                registryProvenanceSigningKeyReference:
                    "keychain://hostwright.provenance/api"
            ),
            LocalControlRequest(
                requestID: "provenance-control-only-signer-colon",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registryProvenanceOperation: "generate",
                registryProvenanceArchivePath:
                    "/tmp/api-image.tar",
                registryProvenanceBuildRecordPath:
                    "/tmp/api-build.json",
                registryProvenanceSignerID: "release:builder",
                registryProvenanceSigningKeyReference:
                    "keychain://hostwright.provenance/api"
            ),
            LocalControlRequest(
                requestID: "provenance-control-only-signer-at",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registryProvenanceOperation: "generate",
                registryProvenanceArchivePath:
                    "/tmp/api-image.tar",
                registryProvenanceBuildRecordPath:
                    "/tmp/api-build.json",
                registryProvenanceSignerID: "builder@example",
                registryProvenanceSigningKeyReference:
                    "keychain://hostwright.provenance/api"
            ),
            LocalControlRequest(
                requestID: "provenance-status-with-key",
                operation: .registry,
                registryProvenanceOperation: "status",
                registryProvenanceSigningKeyReference:
                    "keychain://hostwright.provenance/api"
            ),
            LocalControlRequest(
                requestID: "provenance-verify-with-sbom-digest",
                operation: .registry,
                registryDiscoveryID: discoveryID,
                registryReferrerDigest: referrer,
                registryProvenanceOperation: "verify",
                registryProvenanceDescriptorDigest: referrer
            )
        ]
        for request in invalid {
            XCTAssertThrowsError(
                try LocalControlRequestParser.validate(request),
                request.requestID
            )
        }
    }

    func testProvenanceAcceptsSupportedTypedSecretReferences()
        throws
    {
        for (index, reference) in [
            "keychain://hostwright.provenance/api",
            "external://vault/api-signing-key",
            "plugin://team-secrets/api-signing-key",
            "env-file:///tmp/hostwright.env#SIGNING_KEY",
            "local-file:///tmp/api-signing-key"
        ].enumerated() {
            let request = LocalControlRequest(
                requestID: "provenance-reference-\(index)",
                operation: .registry,
                registryServer: "registry.example.com",
                registryRepository: "team/api",
                registryProvenanceOperation: "generate",
                registryProvenanceArchivePath:
                    "/tmp/api-image.tar",
                registryProvenanceBuildRecordPath:
                    "/tmp/api-build.json",
                registryProvenanceSignerID: "release-builder",
                registryProvenanceSigningKeyReference: reference
            )
            XCTAssertNoThrow(
                try LocalControlRequestParser.validate(request),
                reference
            )
        }
    }

    func testUnknownCredentialValueIsRejectedWithoutEcho() throws {
        let secret = "unapproved-raw-signing-key-value"
        let request = Data(
            """
            {
              "apiVersion": 2,
              "requestID": "provenance-credential",
              "operation": "registry",
              "registryProvenanceOperation": "status",
              "privateKey": "\(secret)"
            }
            """.utf8
        )
        let result = LocalControlAPI(
            configuration: LocalControlConfiguration(
                manifestPath: "/unavailable"
            )
        ).run(requestData: request)

        XCTAssertEqual(
            result.exitCode,
            LocalControlExitCode.invalidRequest.rawValue
        )
        XCTAssertFalse(
            String(decoding: result.standardOutput, as: UTF8.self)
                .contains(secret)
        )
    }
}
