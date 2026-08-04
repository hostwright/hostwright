import XCTest
@testable import HostwrightCLI

final class PluginCLIOptionsTests: XCTestCase {
    private let digest = "sha256:" + String(repeating: "a", count: 64)
    private let detailDigest = "sha256:" + String(repeating: "b", count: 64)

    func testParsesEveryPluginLifecycleOperation() throws {
        let source = PluginCLISource(
            kind: .httpsRegistry,
            locator: "https://registry.example.com/plugins/weather"
        )
        let signed = [
            "--source", source.locator,
            "--signer", "com.example.plugins.weather",
            "--signer-certificate", "/tmp/weather-signer.der",
        ]
        let cases: [([String], PluginCLIAction, CLIOutputFormat)] = [
            (["extension", "list"], .list(identifier: nil), .text),
            (["extension", "list", "--identifier", "weather"], .list(identifier: "weather"), .text),
            (["extension", "status", "--identifier", "weather"], .status(identifier: "weather", packageDigest: nil), .text),
            (["extension", "status", "--digest", digest], .status(identifier: nil, packageDigest: digest), .text),
            (["extension", "discover"] + signed, .discover(source: source, signerIdentifier: "com.example.plugins.weather", certificatePath: "/tmp/weather-signer.der"), .text),
            (["extension", "install"] + signed, .install(source: source, signerIdentifier: "com.example.plugins.weather", certificatePath: "/tmp/weather-signer.der"), .text),
            (["extension", "update"] + signed + ["--json"], .update(source: source, signerIdentifier: "com.example.plugins.weather", certificatePath: "/tmp/weather-signer.der"), .json),
            (["extension", "activate", "--digest", digest, "--expected-activation-generation", "2"], .activate(packageDigest: digest, expectedActivationGeneration: 2), .text),
            (["extension", "rollback", "--identifier", "weather", "--expected-activation-generation", "3"], .rollback(identifier: "weather", expectedActivationGeneration: 3), .text),
            (["extension", "revoke", "--revocation-id", "revoke-weather", "--target-kind", "package", "--target", digest, "--reason", "revoked-by-policy"], .revoke(revocationID: "revoke-weather", targetKind: "package", targetIdentifier: digest, reason: "revoked-by-policy"), .text),
            (["extension", "quarantine", "--quarantine-id", "quarantine-weather", "--digest", digest, "--reason-code", "signature-failed", "--detail-digest", detailDigest], .quarantine(quarantineID: "quarantine-weather", packageDigest: digest, reasonCode: "signature-failed", detailDigest: detailDigest), .text),
            (["extension", "uninstall", "--digest", digest, "--expected-generation", "4"], .uninstall(packageDigest: digest, expectedGeneration: 4), .text),
        ]

        for (arguments, expectedAction, expectedOutput) in cases {
            let options = try pluginOptions(arguments)
            XCTAssertEqual(options.action, expectedAction, arguments.joined(separator: " "))
            XCTAssertEqual(options.output, expectedOutput, arguments.joined(separator: " "))
        }
    }

    func testRejectsInvalidDuplicateAndUnsafePluginArguments() {
        let validCertificate = "/tmp/weather-signer.der"
        let validSigner = "com.example.plugins.weather"
        let cases: [[String]] = [
            ["extension", "status"],
            ["extension", "status", "--identifier", "weather", "--digest", digest],
            ["extension", "list", "--identifier", "weather", "--identifier", "weather"],
            ["extension", "list", "--json", "--output", "json"],
            ["extension", "list", "--output", "text", "--output", "text"],
            ["extension", "list", "--output", "yaml"],
            ["extension", "install", "--source", "relative/plugin", "--signer", validSigner, "--signer-certificate", validCertificate],
            ["extension", "install", "--source", "/tmp/../plugin", "--signer", validSigner, "--signer-certificate", validCertificate],
            ["extension", "install", "--source", "https://user@registry.example.com/plugin", "--signer", validSigner, "--signer-certificate", validCertificate],
            ["extension", "install", "--source", "https://registry.example.com/plugin?channel=stable", "--signer", validSigner, "--signer-certificate", validCertificate],
            ["extension", "install", "--source", "https://registry.example.com/plugin#fragment", "--signer", validSigner, "--signer-certificate", validCertificate],
            ["extension", "install", "--source", "https://registry.example.com/plugin", "--signer", validSigner, "--signer-certificate", "/tmp/../weather-signer.der"],
            ["extension", "activate", "--digest", "sha256:" + String(repeating: "A", count: 64)],
            ["extension", "activate", "--digest", "sha256:" + String(repeating: "a", count: 63)],
            ["extension", "activate", "--digest", "sha512:" + String(repeating: "a", count: 64)],
            ["extension", "activate", "--digest", digest, "--expected-activation-generation", "0"],
            ["extension", "uninstall", "--digest", digest],
            ["extension", "revoke", "--revocation-id", "revoke-weather", "--target-kind", "host", "--target", "weather", "--reason", "invalid-kind"],
            ["extension", "quarantine", "--quarantine-id", "quarantine-weather", "--digest", digest, "--reason-code", "failed", "--detail-digest", "not-a-digest"],
        ]

        for arguments in cases {
            XCTAssertThrowsError(try CLICommand.parse(arguments: arguments), arguments.joined(separator: " ")) { error in
                XCTAssertTrue(error is CLIUsageError, "Expected CLIUsageError for \(arguments): \(error)")
            }
        }
    }

    func testAcceptsOnlyCanonicalLocalSourcesAndSingleOutputSelection() throws {
        let command = try CLICommand.parse(arguments: [
            "extension", "discover",
            "--source", "/opt/hostwright/plugins/weather",
            "--signer", "com.example.plugins.weather",
            "--signer-certificate", "/etc/hostwright/weather.der",
            "--output", "json",
        ])
        guard case .plugin(let options) = command else {
            return XCTFail("Expected a plugin command.")
        }
        XCTAssertEqual(options.output, .json)
        XCTAssertEqual(
            options.action,
            .discover(
                source: PluginCLISource(
                    kind: .localDirectory,
                    locator: "/opt/hostwright/plugins/weather"
                ),
                signerIdentifier: "com.example.plugins.weather",
                certificatePath: "/etc/hostwright/weather.der"
            )
        )
    }

    private func pluginOptions(_ arguments: [String]) throws -> PluginCLIOptions {
        let command = try CLICommand.parse(arguments: arguments)
        guard case .plugin(let options) = command else {
            throw PluginCLIOptionsTestError.expectedPluginCommand
        }
        return options
    }
}

private enum PluginCLIOptionsTestError: Error {
    case expectedPluginCommand
}
