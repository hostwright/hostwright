import HostwrightCore
import Darwin
import Foundation
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationSDKSeederTests: XCTestCase {
    func testSignedPgrepAbsenceRequiresExactNoMatchResult() throws {
        func result(_ status: Int32 = 1, signal: Int32? = nil, output: Data = Data(), error: Data = Data(),
                    outputTruncated: Bool = false, errorTruncated: Bool = false) -> SecureSubprocessResult {
            SecureSubprocessResult(exitStatus: status, terminationSignal: signal, standardOutput: output,
                standardError: error, durationMilliseconds: 1, standardOutputTruncated: outputTruncated,
                standardErrorTruncated: errorTruncated)
        }
        XCTAssertNoThrow(try RuntimeQualificationSDKSeeder.validateHelperAbsence(result()))
        for failed in [result(0, output: Data("123\n".utf8)), result(0), result(2), result(3),
                       result(signal: 9), result(output: Data([0xff])), result(error: Data("failure".utf8)),
                       result(outputTruncated: true), result(errorTruncated: true)] {
            XCTAssertThrowsError(try RuntimeQualificationSDKSeeder.validateHelperAbsence(failed))
        }
    }

    func testParserRequiresExactInputBindingsAndRejectsDuplicateUnknownOrRelativePaths() throws {
        let args = ["--config", "/Users/sdk/config.json", "--config-sha256", String(repeating: "a", count: 64),
                    "--layout", "/Users/sdk/layout", "--layout-sha256", String(repeating: "b", count: 64),
                    "--reference", "docker.io/library/python:qualified", "--descriptor", "sha256:" + String(repeating: "c", count: 64),
                    "--variant", "sha256:" + String(repeating: "d", count: 64)]
        let parsed = try RuntimeQualificationSDKSeeder.parse(args)
        XCTAssertEqual(parsed.config.path, "/Users/sdk/config.json")
        XCTAssertEqual(parsed.reference, "docker.io/library/python:qualified")
        XCTAssertThrowsError(try RuntimeQualificationSDKSeeder.parse(args + ["--config", "/another/config"]))
        var unknown = args; unknown[0] = "--passed"
        XCTAssertThrowsError(try RuntimeQualificationSDKSeeder.parse(unknown))
        var relative = args; relative[1] = "relative.json"
        XCTAssertThrowsError(try RuntimeQualificationSDKSeeder.parse(relative))
        var badHash = args; badHash[3] = "true"
        XCTAssertThrowsError(try RuntimeQualificationSDKSeeder.parse(badHash))
    }

    func testSeedScopeRejectsOverlapInEitherDirection() {
        let root = URL(fileURLWithPath: "/Users/sdk/root")
        XCTAssertTrue(RuntimeQualificationSDKSeeder.overlap(root, root))
        XCTAssertTrue(RuntimeQualificationSDKSeeder.overlap(root, root.appendingPathComponent("layout")))
        XCTAssertTrue(RuntimeQualificationSDKSeeder.overlap(root, root.deletingLastPathComponent()))
        XCTAssertFalse(RuntimeQualificationSDKSeeder.overlap(root, URL(fileURLWithPath: "/Users/sdk/root-other")))
    }

    func testSecureInputRejectsSymlinksAndNonPrivateConfiguration() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hostwright-sdk-seed-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)
        XCTAssertEqual(chmod(config.path, 0o600), 0)
        XCTAssertEqual(try RuntimeQualificationSDKSeeder.readSafe(config, privateFile: true), Data("{}".utf8))
        XCTAssertEqual(chmod(config.path, 0o644), 0)
        XCTAssertThrowsError(try RuntimeQualificationSDKSeeder.readSafe(config, privateFile: true))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        XCTAssertThrowsError(try RuntimeQualificationSDKSeeder.readSafe(link))
    }
}
