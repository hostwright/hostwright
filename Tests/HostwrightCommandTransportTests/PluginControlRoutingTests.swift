import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

final class PluginControlRoutingTests: XCTestCase {
    private let digest = "sha256:" + String(repeating: "a", count: 64)
    private let detailDigest = "sha256:" + String(repeating: "b", count: 64)

    func testEveryPluginVerbRoutesDirectlyToPersistentControlAPI() throws {
        let certificate = try temporaryCertificate(contents: Data([0x30, 0x03, 0x02, 0x01, 0x01]))
        defer { removeTemporaryDirectory(containing: certificate) }

        let source = "https://registry.example.com/plugins/weather"
        let signed = ["--source", source, "--signer", "com.example.weather", "--signer-certificate", certificate.path]
        let cases: [([String], Bool)] = [
            (["extension", "list"], false),
            (["extension", "status", "--identifier", "weather"], false),
            (["extension", "discover"] + signed, false),
            (["extension", "install"] + signed, true),
            (["extension", "update"] + signed, true),
            (["extension", "activate", "--digest", digest], true),
            (["extension", "rollback", "--identifier", "weather"], true),
            (["extension", "revoke", "--revocation-id", "revoke-weather", "--target-kind", "package", "--target", digest, "--reason", "policy"], true),
            (["extension", "quarantine", "--quarantine-id", "quarantine-weather", "--digest", digest, "--reason-code", "policy", "--detail-digest", detailDigest], true),
            (["extension", "uninstall", "--digest", digest, "--expected-generation", "1"], true),
        ]

        for (arguments, mutating) in cases {
            let route = try CLIControlRoute.classify(arguments: arguments)
            XCTAssertEqual(route.transport, .persistentControlAPI, arguments.joined(separator: " "))
            XCTAssertEqual(route.execution, .unary, arguments.joined(separator: " "))
            XCTAssertEqual(route.operation, "plugin.\(arguments[1])", arguments.joined(separator: " "))
            XCTAssertEqual(route.subcommand, arguments[1], arguments.joined(separator: " "))
            XCTAssertEqual(route.mutating, mutating, arguments.joined(separator: " "))
        }
    }

    func testPluginRequestsUseIdempotencyOnlyForMutationsAndEncodeOperationBodies() throws {
        let certificateData = Data([0x30, 0x03, 0x02, 0x01, 0x01])
        let certificate = try temporaryCertificate(contents: certificateData)
        defer { removeTemporaryDirectory(containing: certificate) }

        let source = "https://registry.example.com/plugins/weather"
        let cases: [([String], ControlPlaneJSONValue, Bool)] = [
            (["extension", "list", "--identifier", "weather"], .object(["identifier": .string("weather")]), false),
            (["extension", "status", "--digest", digest], .object(["packageDigest": .string(digest)]), false),
            (["extension", "discover", "--source", source, "--signer", "com.example.weather", "--signer-certificate", certificate.path], signedBody(source: source, certificateData: certificateData), false),
            (["extension", "install", "--source", source, "--signer", "com.example.weather", "--signer-certificate", certificate.path], signedBody(source: source, certificateData: certificateData), true),
            (["extension", "update", "--source", source, "--signer", "com.example.weather", "--signer-certificate", certificate.path], signedBody(source: source, certificateData: certificateData), true),
            (["extension", "activate", "--digest", digest, "--expected-activation-generation", "5"], .object(["packageDigest": .string(digest), "expectedActivationGeneration": .integer(5)]), true),
            (["extension", "rollback", "--identifier", "weather", "--expected-activation-generation", "6"], .object(["identifier": .string("weather"), "expectedActivationGeneration": .integer(6)]), true),
            (["extension", "revoke", "--revocation-id", "revoke-weather", "--target-kind", "signer", "--target", "com.example.weather", "--reason", "policy"], .object(["revocationID": .string("revoke-weather"), "targetKind": .string("signer"), "targetIdentifier": .string("com.example.weather"), "reason": .string("policy")]), true),
            (["extension", "quarantine", "--quarantine-id", "quarantine-weather", "--digest", digest, "--reason-code", "policy", "--detail-digest", detailDigest], .object(["quarantineID": .string("quarantine-weather"), "packageDigest": .string(digest), "reasonCode": .string("policy"), "detailDigest": .string(detailDigest)]), true),
            (["extension", "uninstall", "--digest", digest, "--expected-generation", "7"], .object(["packageDigest": .string(digest), "expectedGeneration": .integer(7)]), true),
        ]

        for (index, entry) in cases.enumerated() {
            let capture = PluginRequestCapture()
            let environment = environment(capture: capture) { request in
                completedPluginResponse(requestID: request.requestID, value: .object(["ok": .bool(true)]))
            }
            let result = HostwrightCommandRunner.run(arguments: entry.0, environment: environment)

            XCTAssertEqual(result.exitCode, 0, entry.0.joined(separator: " "))
            let request = try XCTUnwrap(capture.request)
            XCTAssertEqual(request.operation, "plugin.\(entry.0[1])")
            XCTAssertEqual(request.idempotencyKey, entry.2 ? "plugin-request" : nil, "case \(index)")
            XCTAssertEqual(request.body, entry.1, "case \(index)")
        }
    }

    func testCertificateDEREncodingAcceptsBoundedDataAndRejectsEmptyOrOversizedFiles() throws {
        let exactLimit = Data(repeating: 0xA5, count: 32 * 1_024)
        let bounded = try temporaryCertificate(contents: exactLimit)
        defer { removeTemporaryDirectory(containing: bounded) }

        let capture = PluginRequestCapture()
        let success = HostwrightCommandRunner.run(
            arguments: signedInstall(certificatePath: bounded.path),
            environment: environment(capture: capture) { request in
                completedPluginResponse(requestID: request.requestID, value: .object(["accepted": .bool(true)]))
            }
        )
        XCTAssertEqual(success.exitCode, 0)
        guard case .object(let body)? = capture.request?.body else {
            return XCTFail("Expected a plugin request body.")
        }
        XCTAssertEqual(body["trustedSignerCertificateDER"], .string(exactLimit.base64EncodedString()))

        for contents in [Data(), Data(repeating: 0xA5, count: 32 * 1_024 + 1)] {
            let certificate = try temporaryCertificate(contents: contents)
            defer { removeTemporaryDirectory(containing: certificate) }
            let rejectedCapture = PluginRequestCapture()
            let result = HostwrightCommandRunner.run(
                arguments: signedInstall(certificatePath: certificate.path),
                environment: environment(capture: rejectedCapture) { request in
                    completedPluginResponse(requestID: request.requestID, value: .object([:]))
                }
            )
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.extensionInvalid.rawValue))
            XCTAssertNil(rejectedCapture.request)
        }
    }

    func testPluginResultsRenderGenericPersistentResponseAndDirectCLIRefusesMutation() throws {
        let certificate = try temporaryCertificate(contents: Data([0x30, 0x03, 0x02, 0x01, 0x01]))
        defer { removeTemporaryDirectory(containing: certificate) }
        let value: ControlPlaneJSONValue = .object([
            "generation": .integer(8),
            "plugin": .object(["identifier": .string("weather")]),
        ])
        let capture = PluginRequestCapture()
        let transported = HostwrightCommandRunner.run(
            arguments: signedInstall(certificatePath: certificate.path),
            environment: environment(capture: capture) { request in
                completedPluginResponse(requestID: request.requestID, value: value)
            }
        )
        let expected = String(
            decoding: try ControlPlaneCanonicalJSON.encode(value),
            as: UTF8.self
        ) + "\n"
        XCTAssertEqual(transported.exitCode, 0)
        XCTAssertEqual(transported.standardOutput, expected)
        XCTAssertNotNil(capture.request)

        let direct = HostwrightCLI.run(arguments: signedInstall(certificatePath: certificate.path))
        XCTAssertNotEqual(direct.exitCode, 0)
        XCTAssertTrue(direct.standardError.contains(HostwrightErrorCode.controlAPIUnavailable.rawValue))
        XCTAssertTrue(direct.standardError.contains("require the authenticated persistent Control API"))
    }

    private func signedInstall(certificatePath: String) -> [String] {
        [
            "extension", "install",
            "--source", "https://registry.example.com/plugins/weather",
            "--signer", "com.example.weather",
            "--signer-certificate", certificatePath,
        ]
    }

    private func signedBody(source: String, certificateData: Data) -> ControlPlaneJSONValue {
        .object([
            "source": .object([
                "kind": .string(PluginCLISourceKind.httpsRegistry.rawValue),
                "locator": .string(source),
            ]),
            "trustedSignerIdentifier": .string("com.example.weather"),
            "trustedSignerCertificateDER": .string(certificateData.base64EncodedString()),
        ])
    }

    private func environment(
        capture: PluginRequestCapture,
        response: @escaping @Sendable (ControlRequestEnvelope) -> ControlResponseEnvelope
    ) -> HostwrightCommandTransportEnvironment {
        HostwrightCommandTransportEnvironment(
            socketPath: { "/tmp/hostwright-plugin-test.sock" },
            persistentSend: { _, request in
                capture.request = request
                return response(request)
            },
            bootstrapSend: { _ in throw PluginControlRoutingTestError.unexpectedBootstrap },
            streamRun: { _, _, _ in throw PluginControlRoutingTestError.unexpectedStream },
            requestID: { "plugin-request" },
            workingDirectory: { "/tmp" }
        )
    }

    private func temporaryCertificate(contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-plugin-routing-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let certificate = directory.appendingPathComponent("signer.der")
        try contents.write(to: certificate, options: .atomic)
        return certificate
    }

    private func removeTemporaryDirectory(containing certificate: URL) {
        try? FileManager.default.removeItem(at: certificate.deletingLastPathComponent())
    }
}

private func completedPluginResponse(
    requestID: String,
    value: ControlPlaneJSONValue
) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
        requestID: requestID,
        status: .completed,
        reasonCode: .completed,
        result: value
    )
}

private enum PluginControlRoutingTestError: Error {
    case unexpectedBootstrap
    case unexpectedStream
}

private final class PluginRequestCapture: @unchecked Sendable {
    var request: ControlRequestEnvelope?
}
