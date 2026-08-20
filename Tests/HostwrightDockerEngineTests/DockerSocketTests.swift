import Darwin
import Foundation
import HostwrightControlPlane
import XCTest
@testable import HostwrightDockerEngine

final class DockerSocketTests: XCTestCase {
    func testSocketDirectoryAndSocketModesArePrivateAndCleanupIsPinned() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("run/docker.sock").path
        let listener = try DockerUnixSocketListener(
            socketPath: socketPath,
            recoverStaleSocket: true
        )
        XCTAssertEqual(mode(of: root.appendingPathComponent("run")), 0o700)
        XCTAssertEqual(mode(of: URL(fileURLWithPath: socketPath)), 0o600)

        listener.closeAndRemoveOwnedSocket()
        var status = stat()
        XCTAssertNotEqual(lstat(socketPath, &status), 0)
    }

    func testUnsafeSocketModeAndSymlinkedParentFailClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(run.path, 0o755), 0)
        XCTAssertThrowsError(
            try DockerUnixSocketListener(
                socketPath: run.appendingPathComponent("docker.sock").path,
                recoverStaleSocket: true
            )
        ) { error in
            XCTAssertEqual(error as? DockerSocketError, .unsafePath)
        }

        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(
            try DockerUnixSocketListener(
                socketPath: link.appendingPathComponent("docker.sock").path,
                recoverStaleSocket: true
            )
        ) { error in
            XCTAssertEqual(error as? DockerSocketError, .unsafePath)
        }
    }

    func testSameEffectiveUserPeerCanConnect() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try DockerUnixSocketListener(
            socketPath: root.appendingPathComponent("docker.sock").path,
            recoverStaleSocket: true
        )
        defer { listener.closeAndRemoveOwnedSocket() }

        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { _ = close(client) }
        var address = try sockaddrAddress(listener.path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sa_family_t>.size + listener.path.utf8.count + 1))
            }
        }
        XCTAssertEqual(connected, 0)
        let accepted = try listener.accept(timeoutMilliseconds: 1_000)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        _ = close(accepted)
    }

    func testPeerMismatchIsRejectedBeforeHTTPParsing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try DockerUnixSocketListener(
            socketPath: root.appendingPathComponent("docker.sock").path,
            recoverStaleSocket: true,
            peerUserIDReader: { _ in UInt32(geteuid()) + 1 }
        )
        defer { listener.closeAndRemoveOwnedSocket() }
        let client = try connect(to: listener.path)
        defer { _ = close(client) }
        XCTAssertThrowsError(try listener.accept(timeoutMilliseconds: 1_000)) { error in
            XCTAssertEqual(error as? DockerSocketError, .peerMismatch)
        }
    }

    func testSafeStaleSocketReplacementPinsTheNewInode() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("docker.sock").path
        let stale = try bindStaleSocket(at: path)
        var staleStatus = stat()
        XCTAssertEqual(lstat(path, &staleStatus), 0)
        _ = close(stale)

        let listener = try DockerUnixSocketListener(
            socketPath: path,
            recoverStaleSocket: true
        )
        defer { listener.closeAndRemoveOwnedSocket() }
        XCTAssertNotEqual(
            listener.identity,
            DockerSocketIdentity(
                device: UInt64(staleStatus.st_dev),
                inode: UInt64(staleStatus.st_ino)
            )
        )
        XCTAssertEqual(mode(of: URL(fileURLWithPath: path)), 0o600)
    }

    func testRawHTTPDaemonRoundTripUsesTheBoundedProxy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("docker.sock").path
        let listener = try DockerUnixSocketListener(
            socketPath: socketPath,
            recoverStaleSocket: true
        )
        let adapter = DockerControlAdapter(sendRequest: { request in
            ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object(["containers": .array([])])
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: socketPath,
                controlSocketPath: "/private/tmp/hostwright-docker-control-test.sock"
            ),
            adapter: adapter
        )
        let daemon = DockerProxyDaemon(server: server, listener: listener)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            do {
                let descriptor = try listener.accept(timeoutMilliseconds: 5_000)
                try daemon.serve(descriptor: descriptor)
            } catch {
                XCTFail("proxy round trip failed: \(error)")
            }
            completed.signal()
        }

        let client = try connect(to: socketPath)
        defer { _ = close(client) }
        let raw = Data("GET /v1.52/_ping HTTP/1.1\r\nHost: docker\r\n\r\n".utf8)
        let written = raw.withUnsafeBytes {
            Darwin.write(client, $0.baseAddress!, raw.count)
        }
        XCTAssertEqual(written, raw.count)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        let rendered = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(rendered.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(rendered.hasSuffix("OK"))
        listener.closeAndRemoveOwnedSocket()
    }

    private func makeRoot() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
            .replacingOccurrences(of: "/var/", with: "/private/var/")
        let root = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .appendingPathComponent(
                "hw-docker-" + String(UUID().uuidString.prefix(8)),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }

    private func mode(of url: URL) -> UInt16 {
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        return UInt16(status.st_mode & 0o7777)
    }

    private func sockaddrAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DockerSocketError.unsafePath
        }
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private func connect(to path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DockerSocketError.socketCreationFailed }
        do {
            var address = try sockaddrAddress(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
                    )
                }
            }
            guard result == 0 else { throw DockerSocketError.ioFailure }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private func bindStaleSocket(at path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DockerSocketError.socketCreationFailed }
        do {
            var address = try sockaddrAddress(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
                    )
                }
            }
            guard result == 0, chmod(path, 0o600) == 0 else {
                throw DockerSocketError.socketBindFailed
            }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }
}
