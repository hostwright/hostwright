import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore

final class Phase01ContractCLITests: XCTestCase {
    func testParserRecognizesCapabilitiesAndMigrationPreview() throws {
        XCTAssertEqual(try CLICommand.parse(arguments: ["capabilities"]), .capabilities(output: .text))
        XCTAssertEqual(try CLICommand.parse(arguments: ["capabilities", "--json"]), .capabilities(output: .json))
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["migrate", "preview", "legacy.yaml", "--output", "json"]),
            .migrateManifestPreview(path: "legacy.yaml", output: .json)
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["migrate", "apply", "legacy.yaml"]))
    }

    func testCapabilitiesJSONIsStableAndMachineReadable() throws {
        let first = HostwrightCLI.run(arguments: ["capabilities", "--json"])
        let second = HostwrightCLI.run(arguments: ["capabilities", "--json"])

        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(first.standardError, "")
        XCTAssertEqual(first.standardOutput, second.standardOutput)
        let report = try JSONDecoder().decode(HostwrightCapabilityReport.self, from: Data(first.standardOutput.utf8))
        XCTAssertEqual(report.productVersion, HostwrightIdentity.version)
        XCTAssertEqual(report.releaseTarget, "v0.0.2")
        XCTAssertFalse(report.capabilities.isEmpty)
    }

    func testMigrationPreviewIsReadOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("hostwright.yaml")
        let source = "version: 1\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n"
        try source.write(to: manifestURL, atomically: true, encoding: .utf8)

        let result = HostwrightCLI.run(arguments: ["migrate", "preview", manifestURL.path, "--output", "json"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(try String(contentsOf: manifestURL, encoding: .utf8), source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "manifestMigrationPreview")
        XCTAssertEqual(object["sourceVersion"] as? Int, 1)
        XCTAssertEqual(object["targetVersion"] as? Int, 2)
        XCTAssertTrue((object["migratedManifest"] as? String)?.hasPrefix("version: 2") == true)
    }
}
