import Foundation
import XCTest

final class CLIControlProductionRoutingTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPackageRoutesExecutableAndDaemonThroughSingleTransportModule() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-package-graph-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // SwiftPM holds the main build lock while running this test.
        process.arguments = ["swift", "package", "--scratch-path", scratch.path, "dump-package"]
        process.currentDirectoryURL = repository
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let package = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(package["targets"] as? [[String: Any]])

        func dependencies(of name: String) throws -> [String] {
            let target = try XCTUnwrap(targets.first { $0["name"] as? String == name })
            let dependencies = try XCTUnwrap(target["dependencies"] as? [[String: Any]])
            return try dependencies.map { dependency in
                let components = try XCTUnwrap(
                    (dependency["byName"] ?? dependency["target"] ?? dependency["product"]) as? [Any]
                )
                return try XCTUnwrap(components.first as? String)
            }
        }

        XCTAssertEqual(try dependencies(of: "HostwrightCommand"), ["HostwrightCommandTransport"])
        XCTAssertTrue(targets.contains { $0["name"] as? String == "HostwrightCommandTransport" })
        XCTAssertTrue(try dependencies(of: "HostwrightDaemon").contains("HostwrightCommandTransport"))
    }

}
