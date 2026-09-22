import Foundation
import XCTest

final class DaemonQualificationScriptTests: XCTestCase {
    func testAttendedQualificationContractIsResumableAndOwnedOnly() throws {
        let scriptURL = packageRoot()
            .appendingPathComponent("scripts/phase08-daemon-qualification.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "contract"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
    func testPrepareRefusesNonPrivateQualificationRootBeforeMutation() throws {
        let scriptURL = packageRoot()
            .appendingPathComponent("scripts/phase08-daemon-qualification.sh")
        let root = try makeQualificationRoot(permissions: 0o755)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "prepare"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT": root.path,
            "HOSTWRIGHT_PHASE08_HOSTWRIGHT": "/bin/echo",
            "HOSTWRIGHT_PHASE08_DAEMON": "/bin/echo",
            "HOSTWRIGHT_PHASE08_CONFIG": "/etc/hosts"
        ]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 77)
        XCTAssertTrue(
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).contains("must be canonical, current-user-owned, and mode 0700")
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testPrepareRefusesVolatileQualificationRootBeforeMutation() throws {
        let scriptURL = packageRoot()
            .appendingPathComponent("scripts/phase08-daemon-qualification.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase08-gate1-\(UUID().uuidString.lowercased())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "prepare"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOSTWRIGHT_PHASE08_QUALIFICATION_ROOT": root.path,
            "HOSTWRIGHT_PHASE08_HOSTWRIGHT": "/bin/echo",
            "HOSTWRIGHT_PHASE08_DAEMON": "/bin/echo",
            "HOSTWRIGHT_PHASE08_CONFIG": "/etc/hosts"
        ]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 66)
        XCTAssertTrue(
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).contains("must be a persistent phase08-gate1-<canonical-uuid> directory")
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func makeQualificationRoot(permissions: Int) throws -> URL {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hostwright/qualification")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        let root = parent.appendingPathComponent(
            "phase08-gate1-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: permissions]
        )
        return root
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
