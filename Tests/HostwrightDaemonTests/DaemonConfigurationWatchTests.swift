import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import HostwrightDaemonCore
@testable import HostwrightCore

final class DaemonConfigurationWatchTests: XCTestCase {
    func testSecureReaderAcceptsPrivateAtomicReplacementAndRejectsStaleIdentity() throws {
        try withPrivateQualificationDirectory { directory in
            let path = directory.appendingPathComponent("hostwright.yaml")
            try Data(Self.validManifest.utf8).write(to: path, options: .atomic)
            XCTAssertEqual(chmod(path.path, 0o600), 0)

            let first = try SecureDaemonConfigurationReader.read(
                path: path.path,
                kind: .manifest
            )
            try Data(Self.validManifest.utf8).write(to: path, options: .atomic)
            XCTAssertEqual(chmod(path.path, 0o600), 0)
            let replacement = try SecureDaemonConfigurationReader.read(
                path: path.path,
                kind: .manifest
            )

            XCTAssertEqual(first.target.contentSHA256, replacement.target.contentSHA256)
            XCTAssertNotEqual(first.target.inode, replacement.target.inode)
            XCTAssertThrowsError(
                try SecureDaemonConfigurationReader.read(
                    path: path.path,
                    kind: .manifest,
                    expected: first.target
                )
            )
        }
    }

    func testSecureReaderRejectsPermissionsLinksEncodingAndOversize() throws {
        try withPrivateQualificationDirectory { directory in
            let path = directory.appendingPathComponent("hostwright.yaml")
            try Data(Self.validManifest.utf8).write(to: path)
            XCTAssertEqual(chmod(path.path, 0o660), 0)
            XCTAssertThrowsError(
                try SecureDaemonConfigurationReader.read(path: path.path, kind: .manifest)
            )

            XCTAssertEqual(chmod(path.path, 0o600), 0)
            let hardLink = directory.appendingPathComponent("hardlink.yaml")
            XCTAssertEqual(link(path.path, hardLink.path), 0)
            XCTAssertThrowsError(
                try SecureDaemonConfigurationReader.read(path: path.path, kind: .manifest)
            )
            try FileManager.default.removeItem(at: hardLink)

            let symbolicLink = directory.appendingPathComponent("symlink.yaml")
            try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: path)
            XCTAssertThrowsError(
                try SecureDaemonConfigurationReader.read(path: symbolicLink.path, kind: .manifest)
            )

            try Data([0xff, 0xfe]).write(to: path, options: .atomic)
            XCTAssertEqual(chmod(path.path, 0o600), 0)
            XCTAssertThrowsError(
                try SecureDaemonConfigurationReader.read(path: path.path, kind: .manifest)
            )

            try Data(repeating: 0x61, count: SecureDaemonConfigurationReader.maximumBytes + 1)
                .write(to: path, options: .atomic)
            XCTAssertEqual(chmod(path.path, 0o600), 0)
            XCTAssertThrowsError(
                try SecureDaemonConfigurationReader.read(path: path.path, kind: .manifest)
            )
        }
    }

    func testParentMonitorCoalescesAtomicRenameFloodAndCleansUp() throws {
        try withPrivateQualificationDirectory { directory in
            let path = directory.appendingPathComponent("hostwright.yaml")
            try Data(Self.validManifest.utf8).write(to: path)
            let monitor = DaemonConfigurationChangeMonitor()
            try monitor.replace(paths: [path.path, path.path])

            for index in 0..<32 {
                try Data("\(Self.validManifest)# \(index)\n".utf8)
                    .write(to: path, options: .atomic)
            }
            let deadline = Date().addingTimeInterval(2)
            while !monitor.consumePendingChange(), Date() < deadline {
                usleep(10_000)
            }
            XCTAssertLessThan(Date(), deadline)
            XCTAssertFalse(monitor.consumePendingChange())

            monitor.stop()
            try Data(Self.validManifest.utf8).write(to: path, options: .atomic)
            usleep(100_000)
            XCTAssertFalse(monitor.consumePendingChange())
        }
    }

    func testSystemClockWakesEarlyForConfigurationChange() async throws {
        try await withPrivateQualificationDirectory { directory in
            let path = directory.appendingPathComponent("hostwright.yaml")
            try Data(Self.validManifest.utf8).write(to: path)
            let monitor = DaemonConfigurationChangeMonitor()
            try monitor.replace(paths: [path.path])
            let clock = SystemDaemonClock(
                shutdownToken: DaemonShutdownToken(),
                configurationMonitor: monitor
            )

            try Data("\(Self.validManifest)# changed\n".utf8)
                .write(to: path, options: .atomic)
            let started = Date()
            let reason = try await clock.sleep(seconds: 5)

            XCTAssertEqual(reason, .configurationChanged)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            monitor.stop()
        }
    }

    func testConfigurationSetDigestIgnoresAtomicFileIdentityButBindsContentAndKind() throws {
        let path = "/private/tmp/hostwright.yaml"
        let first = try DaemonConfigurationTarget(
            kind: .manifest,
            path: path,
            contentSHA256: String(repeating: "a", count: 64),
            byteCount: 12,
            device: 1,
            inode: 1
        )
        let replacement = try DaemonConfigurationTarget(
            kind: .manifest,
            path: path,
            contentSHA256: String(repeating: "a", count: 64),
            byteCount: 12,
            device: 2,
            inode: 2
        )
        let changed = try DaemonConfigurationTarget(
            kind: .policy,
            path: path,
            contentSHA256: String(repeating: "b", count: 64),
            byteCount: 12,
            device: 2,
            inode: 2
        )

        XCTAssertEqual(
            DaemonConfigurationSetDigest.sha256([first]),
            DaemonConfigurationSetDigest.sha256([replacement])
        )
        XCTAssertNotEqual(
            DaemonConfigurationSetDigest.sha256([first]),
            DaemonConfigurationSetDigest.sha256([changed])
        )
    }

    private func withPrivateQualificationDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hostwright/qualification-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(base.path, 0o700), 0)
        let directory = base.appendingPathComponent("gate3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withPrivateQualificationDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hostwright/qualification-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(base.path, 0o700), 0)
        let directory = base.appendingPathComponent("gate3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private static let validManifest = """
    version: 2
    project: gate3
    services: {}

    """
}
