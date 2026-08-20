import Darwin
import Foundation
import XCTest
@testable import HostwrightDockerEngine

final class DockerContextTests: XCTestCase {
    func testContextLifecycleIsVersionedPrivateAndExact() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DockerContextStore(rootDirectory: root.path)
        let context = try DockerContext(
            name: "hostwright",
            socketPath: "/private/var/run/hostwright/docker.sock"
        )
        try store.create(context)
        XCTAssertEqual(try store.inspect(name: "hostwright"), context)
        try store.activate(name: "hostwright")
        XCTAssertEqual(try store.active(), context)

        let rotated = try store.rotate(
            name: "hostwright",
            socketPath: "/private/var/run/hostwright/docker-2.sock"
        )
        XCTAssertEqual(rotated.generation, 2)
        XCTAssertEqual(try store.repair(name: "hostwright"), rotated)
        let disabled = try store.disable(name: "hostwright")
        XCTAssertFalse(disabled.enabled)
        XCTAssertThrowsError(try store.activate(name: "hostwright")) { error in
            XCTAssertEqual(error as? DockerContextError, .activeContextUnavailable)
        }
        try store.delete(name: "hostwright")
        XCTAssertThrowsError(try store.inspect(name: "hostwright")) { error in
            XCTAssertEqual(error as? DockerContextError, .notFound)
        }
    }

    func testContextStoreRejectsUnsafeNamesAndModes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DockerContextStore(rootDirectory: root.path)
        XCTAssertThrowsError(
            try DockerContext(name: "../escape", socketPath: "/private/var/run/docker.sock")
        ) { error in
            XCTAssertEqual(error as? DockerContextError, .invalidName)
        }
        XCTAssertThrowsError(
            try DockerContext(name: "safe", socketPath: "relative.sock")
        ) { error in
            XCTAssertEqual(error as? DockerContextError, .invalidSocketPath)
        }
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(
            try DockerContext(name: "linked", socketPath: link.appendingPathComponent("docker.sock").path)
        ) { error in
            XCTAssertEqual(error as? DockerContextError, .invalidSocketPath)
        }
        let context = try DockerContext(
            name: "safe",
            socketPath: "/private/var/run/hostwright/docker.sock"
        )
        try store.create(context)
        let path = root.appendingPathComponent("safe.json")
        XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertThrowsError(try store.inspect(name: "safe")) { error in
            XCTAssertEqual(error as? DockerContextError, .unsafeDirectory)
        }
    }

    func testActiveMarkerMustRemainAnOwnedPrivateRegularFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DockerContextStore(rootDirectory: root.path)
        let context = try DockerContext(
            name: "safe",
            socketPath: "/private/var/run/hostwright/docker.sock"
        )
        try store.create(context)
        try store.activate(name: "safe")

        let active = root.appendingPathComponent("active")
        XCTAssertEqual(chmod(active.path, 0o644), 0)
        XCTAssertThrowsError(try store.active()) { error in
            XCTAssertEqual(error as? DockerContextError, .activeContextUnavailable)
        }

        XCTAssertEqual(chmod(active.path, 0o600), 0)
        try FileManager.default.removeItem(at: active)
        try FileManager.default.createSymbolicLink(
            at: active,
            withDestinationURL: root.appendingPathComponent("safe.json")
        )
        XCTAssertThrowsError(try store.active()) { error in
            XCTAssertEqual(error as? DockerContextError, .activeContextUnavailable)
        }
    }

    private func makeRoot() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory
            .path
            .replacingOccurrences(of: "/var/", with: "/private/var/")
        let root = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .appendingPathComponent(
                "hw-context-" + String(UUID().uuidString.prefix(8)),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }
}
