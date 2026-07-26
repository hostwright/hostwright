import Darwin
import Foundation
import XCTest
@testable import HostwrightStorage

final class GuardedMountSecurityTests: XCTestCase {
    func testOpensRegularFileAndRevalidatesStableIdentity() throws {
        let fixture = try Fixture()
        let file = fixture.root.appendingPathComponent("data.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try chmodSafe(file.path, mode: 0o600)

        let lease = try GuardedMountSecurity.openBindSource(file.path)
        defer { _ = lease }

        XCTAssertEqual(lease.path, file.path)
        XCTAssertGreaterThanOrEqual(lease.descriptor, 0)
        XCTAssertNoThrow(try GuardedMountSecurity.revalidate(lease))
    }

    func testRejectsHostRootTraversalSymlinkAndWorldWritablePaths() throws {
        XCTAssertThrowsError(try GuardedMountSecurity.openBindSource("/")) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .hostRootForbidden)
        }
        XCTAssertThrowsError(try GuardedMountSecurity.openBindSource("/tmp/../etc")) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .parentTraversalForbidden)
        }

        let fixture = try Fixture()
        let target = fixture.root.appendingPathComponent("target")
        try "ok".write(to: target, atomically: true, encoding: .utf8)
        let link = fixture.root.appendingPathComponent("link")
        XCTAssertEqual(symlink(target.path, link.path), 0)
        XCTAssertThrowsError(try GuardedMountSecurity.openBindSource(link.path)) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .symlinkForbidden)
        }

        let redirected = fixture.root.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: false)
        let nested = redirected.appendingPathComponent("nested.txt")
        try "nested".write(to: nested, atomically: true, encoding: .utf8)
        try chmodSafe(nested.path, mode: 0o600)
        let parentLink = fixture.root.appendingPathComponent("parent-link")
        XCTAssertEqual(symlink(redirected.path, parentLink.path), 0)
        XCTAssertThrowsError(try GuardedMountSecurity.openBindSource(parentLink.appendingPathComponent("nested.txt").path)) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .symlinkForbidden)
        }

        let unsafe = fixture.root.appendingPathComponent("unsafe")
        try "unsafe".write(to: unsafe, atomically: true, encoding: .utf8)
        try chmodSafe(unsafe.path, mode: 0o666)
        XCTAssertThrowsError(try GuardedMountSecurity.openBindSource(unsafe.path)) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .unsafeOwnership)
        }
    }

    func testRejectsReplacementDuringOpenAndDetectsIdentityChangeOnRevalidate() throws {
        let fixture = try Fixture()
        let original = fixture.root.appendingPathComponent("original")
        try "a".write(to: original, atomically: true, encoding: .utf8)
        try chmodSafe(original.path, mode: 0o600)

        let lease = try GuardedMountSecurity.openBindSource(original.path)

        let replacement = fixture.root.appendingPathComponent("replacement")
        try "b".write(to: replacement, atomically: true, encoding: .utf8)
        try chmodSafe(replacement.path, mode: 0o600)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: replacement, to: original)

        XCTAssertThrowsError(try GuardedMountSecurity.revalidate(lease)) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .identityChanged)
        }
    }

    func testRejectsDeviceNodes() throws {
        XCTAssertThrowsError(try GuardedMountSecurity.openBindSource("/dev/null")) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .unsupportedFileType)
        }
    }

    func testDetectsParentSymlinkSwapOnRevalidate() throws {
        let fixture = try Fixture()
        let safe = fixture.root.appendingPathComponent("safe", isDirectory: true)
        let redirected = fixture.root.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: false)

        let nested = safe.appendingPathComponent("nested.txt")
        try "safe".write(to: nested, atomically: true, encoding: .utf8)
        try chmodSafe(nested.path, mode: 0o600)

        let redirectedNested = redirected.appendingPathComponent("nested.txt")
        try "redirected".write(to: redirectedNested, atomically: true, encoding: .utf8)
        try chmodSafe(redirectedNested.path, mode: 0o600)

        let lease = try GuardedMountSecurity.openBindSource(nested.path)

        let parked = fixture.root.appendingPathComponent("safe-parked", isDirectory: true)
        try FileManager.default.moveItem(at: safe, to: parked)
        XCTAssertEqual(symlink(redirected.path, safe.path), 0)

        XCTAssertThrowsError(try GuardedMountSecurity.revalidate(lease)) {
            XCTAssertEqual($0 as? GuardedMountSecurityError, .identityChanged)
        }
    }

    private func chmodSafe(_ path: String, mode: mode_t) throws {
        guard chmod(path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class Fixture {
    let root: URL

    init() throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".guarded-mount-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
