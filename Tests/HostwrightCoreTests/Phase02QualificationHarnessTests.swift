import Foundation
import XCTest

final class Phase02QualificationHarnessTests: XCTestCase {
    func testHarnessSelfTestAndCommandSurface() throws {
        let script = try qualificationScript()
        let selfTest = try runPython([script.path, "self-test"])

        XCTAssertEqual(selfTest.status, 0, selfTest.error)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(selfTest.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(document["kind"] as? String, "phase02QualificationSelfTest")
        XCTAssertEqual(document["passed"] as? Int, 7)
        XCTAssertEqual(document["failed"] as? Int, 0)

        let help = try runPython([script.path, "--help"])
        XCTAssertEqual(help.status, 0, help.error)
        for command in ["state", "doctor", "sqlite-power-loss", "verify-release", "self-test"] {
            XCTAssertTrue(help.output.contains(command), "Missing command \(command)")
        }
    }

    func testPowerLossLaneBlocksOutsideExplicitDisposableVM() throws {
        let script = try qualificationScript()
        let recordRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-power-loss-refusal-\(UUID().uuidString)")
        let result = try runPython(
            [
                script.path,
                "sqlite-power-loss",
                "prepare",
                "--hostwright",
                "/usr/bin/false",
                "--manifest",
                "/etc/hosts",
                "--record",
                recordRoot.appendingPathComponent("session.json").path,
            ],
            environment: ["HOSTWRIGHT_DISPOSABLE_VM": nil]
        )

        XCTAssertEqual(result.status, 69)
        XCTAssertTrue(result.error.contains("BLOCKED:"))
        XCTAssertTrue(result.error.contains("disposable qualification VM"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordRoot.path))
    }

    func testHarnessKeepsPublicAndDestructiveBoundariesExplicit() throws {
        let script = try qualificationScript()
        let source = try String(contentsOf: script, encoding: .utf8)
        let mode = try script.resourceValues(forKeys: [.fileSizeKey])

        XCTAssertGreaterThan(mode.fileSize ?? 0, 0)
        XCTAssertFalse(source.contains("shell=True"))
        XCTAssertFalse(source.contains("os.system("))
        XCTAssertTrue(source.contains("stdin=subprocess.DEVNULL"))
        XCTAssertTrue(source.contains("HOSTWRIGHT_DISPOSABLE_VM"))
        XCTAssertTrue(source.contains("post-cut authoritative rows match a fully acknowledged state"))
        XCTAssertTrue(source.contains("cleanup_power_workspace(record, state)"))
        XCTAssertTrue(source.contains("[gh, \"release\", \"download\""))
        XCTAssertTrue(source.contains("[gh, \"attestation\", \"verify\""))
        XCTAssertTrue(source.contains("\"-R=notarized\",\n            \"--check-notarization\""))
        XCTAssertTrue(source.contains("\"--type\", \"install\", package"))
        XCTAssertFalse(source.contains("\"--type\", \"execute\""))
        XCTAssertFalse(source.contains("[gh, \"release\", \"create\""))
        XCTAssertFalse(source.contains("[gh, \"api\", \"--method\", \"DELETE\""))
        XCTAssertFalse(source.contains("shutdown"))
        XCTAssertFalse(source.contains("reboot"))
        XCTAssertFalse(source.contains("rm -rf"))
    }

    private func qualificationScript() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/phase02-qualification.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        return script
    }

    private func runPython(
        _ arguments: [String],
        environment overrides: [String: String?] = [:]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        for (key, value) in overrides {
            environment[key] = value
        }
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
