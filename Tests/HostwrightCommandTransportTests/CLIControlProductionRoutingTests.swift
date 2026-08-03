import Foundation
import XCTest

final class CLIControlProductionRoutingTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNormalExecutableHasNoDirectCLIStateOrRuntimeFallback() throws {
        let source = try text("Sources/HostwrightCommand/main.swift")
        XCTAssertTrue(source.contains("import HostwrightCommandTransport"))
        XCTAssertTrue(source.contains("HostwrightCommandRunner.run"))
        XCTAssertFalse(source.contains("import HostwrightCLI"))
        XCTAssertFalse(source.contains("HostwrightCLI.run"))
        XCTAssertFalse(source.contains("SQLiteStateStore"))
        XCTAssertFalse(source.contains("RuntimeAdapter"))
    }

    func testDirectCLIExecutionExistsOnlyBehindFrozenServerOrPresentationBoundaries() throws {
        let allowed = [
            "Sources/HostwrightCommandTransport/BootstrapControlAPI.swift",
            "Sources/HostwrightCommandTransport/CLIControlCommandExecutor.swift",
            "Sources/HostwrightCommandTransport/HostwrightCommandRunner.swift",
            "Sources/HostwrightControl/LocalControlAPI.swift",
        ]
        let enumerator = FileManager.default.enumerator(
            at: repository.appendingPathComponent("Sources"),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var matches: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift",
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let contents = try String(contentsOf: file, encoding: .utf8)
            if contents.contains("HostwrightCLI.run(") {
                matches.append(file.path.replacingOccurrences(
                    of: repository.path + "/", with: ""
                ))
            }
        }
        XCTAssertEqual(matches.sorted(), allowed)

        XCTAssertTrue(try text(allowed[0]).contains("expectedTransport: .bootstrapAPI"))
        XCTAssertTrue(try text(allowed[1]).contains("CLIControlRoute.validate(request:"))
        XCTAssertTrue(try text(allowed[2]).contains("route.transport == .localPresentation"))
        XCTAssertTrue(try text(allowed[3]).contains(
            "let arguments = try Self.commandArguments(for: parsedRequest"
        ))
    }

    func testPackageRoutesExecutableAndDaemonThroughSingleTransportModule() throws {
        let manifest = try text("Package.swift")
        XCTAssertTrue(manifest.contains(
            "name: \"HostwrightCommand\",\n            dependencies: [\"HostwrightCommandTransport\"]"
        ))
        XCTAssertTrue(manifest.contains(
            "name: \"HostwrightCommandTransport\""
        ))
        let daemonRange = try XCTUnwrap(manifest.range(of: "name: \"HostwrightDaemon\""))
        let daemonTail = String(manifest[daemonRange.lowerBound...].prefix(1_000))
        XCTAssertTrue(daemonTail.contains("\"HostwrightCommandTransport\""))
    }

    func testOneShotCompanionIsPlanOnlyAndBootstrapIsExplicit() throws {
        let source = try text("Sources/HostwrightControlTool/main.swift")
        XCTAssertTrue(source.contains("case .bootstrap:"))
        XCTAssertTrue(source.contains("BootstrapControlAPI.run"))
        XCTAssertTrue(source.contains("guard parsed.operation == .plan"))
        XCTAssertTrue(source.contains(
            "The revision-2.0 one-shot companion accepts only plan."
        ))
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
