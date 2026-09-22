import Foundation
import XCTest
@testable import HostwrightCore

final class HostwrightCoreTests: XCTestCase {

    func testEvidenceContractSeparatesDeterministicAndRealProof() throws {
        let root = try packageRoot()
        let schemaText = try read("schemas/hostwright-evidence.schema.json", root: root)
        let schemaData = try XCTUnwrap(schemaText.data(using: .utf8))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let evidenceClass = try XCTUnwrap(properties["evidenceClass"] as? [String: Any])
        let status = try XCTUnwrap(properties["status"] as? [String: Any])
        let commands = try XCTUnwrap(properties["commands"] as? [String: Any])
        let constraints = try XCTUnwrap(schema["allOf"] as? [[String: Any]])

        XCTAssertEqual(
            evidenceClass["enum"] as? [String],
            [
                "unit-contract",
                "local-integration",
                "live-runtime",
                "hardware-benchmark",
                "distribution-artifact",
                "migration-upgrade",
                "security-assessment",
                "resilience-chaos",
                "multi-host",
                "interop-conformance",
                "ux-accessibility"
            ]
        )
        XCTAssertEqual(status["enum"] as? [String], ["passed", "failed", "blocked"])
        XCTAssertEqual(commands["minItems"] as? Int, 1)
        XCTAssertEqual(constraints.count, 4)
    }

    func testCompatibilityGateRejectsUnsupportedPlatform() {
        let diagnostics = CompatibilityGate.evaluate(
            PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
        )

        XCTAssertEqual(diagnostics.map(\.code), [.unsupportedArchitecture, .unsupportedMacOSVersion])
    }

    private func read(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("README.md").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                throw NSError(domain: "HostwrightCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."])
            }
            url = parent
        }
    }
}
