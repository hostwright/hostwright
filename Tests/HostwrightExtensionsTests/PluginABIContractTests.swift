import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightExtensions
@testable import HostwrightPolicy

final class PluginABIContractTests: XCTestCase {
    func testExtensionDocumentsDefaultToPluginABIV1() {
        let document = ExecutableExtensionDocument(
            kind: .diagnosticsIntegration,
            identifier: "dev.hostwright.test",
            trust: .reviewedLocal,
            capability: .diagnosticsRead,
            purpose: "Inspect bounded diagnostic evidence.",
            boundaries: [.stateStore, .redaction, .noRuntimeMutation],
            executableSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(document.apiVersion, HostwrightContractVersions.pluginABI)
        XCTAssertEqual(document.protocolVersion, HostwrightContractVersions.pluginABI)
    }

    func testCheckedInPluginABIGoldenDecodesThroughProductionContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v0.0.2/plugin-declaration.json")
        let document = try ExecutableExtensionDocumentParser.parse(Data(contentsOf: root)).document

        XCTAssertEqual(document.apiVersion, HostwrightContractVersions.pluginABI)
        XCTAssertEqual(document.protocolVersion, HostwrightContractVersions.pluginABI)
        XCTAssertEqual(document.identifier, "dev.hostwright.golden")
    }
}
