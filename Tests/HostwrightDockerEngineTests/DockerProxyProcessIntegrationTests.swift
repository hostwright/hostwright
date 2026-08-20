import Darwin
import Foundation
import XCTest

final class DockerProxyProcessIntegrationTests: XCTestCase {
    func testExecutableOwnsPrivateSocketAndServesFragmentedLocalRequests() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proxy = try launchProxy(root: root)
        defer { stopProxy(proxy) }

        XCTAssertEqual(mode(of: root), 0o700)
        XCTAssertEqual(mode(of: URL(fileURLWithPath: proxy.socketPath)), 0o600)

        let ping = try exchange(
            path: proxy.socketPath,
            fragments: [
                Data("GET /v1.".utf8),
                Data("52/_ping HTTP/1.1\r\nHo".utf8),
                Data("st: docker\r\n\r\n".utf8),
            ]
        )
        let pingText = String(decoding: ping, as: UTF8.self)
        XCTAssertTrue(pingText.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(pingText.contains("Api-Version: 1.52\r\n"))
        XCTAssertTrue(pingText.hasSuffix("OK"))

        let version = try exchange(
            path: proxy.socketPath,
            fragments: [Data("GET /v1.55/version HTTP/1.1\r\nHost: docker\r\n\r\n".utf8)]
        )
        let versionText = String(decoding: version, as: UTF8.self)
        XCTAssertTrue(versionText.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(versionText.contains("Api-Version: 1.55\r\n"))
        XCTAssertTrue(versionText.contains("\"ApiVersion\":\"1.55\""))

        for version in ["1.52", "1.53", "1.54", "1.55"] {
            let negotiated = try exchange(
                path: proxy.socketPath,
                fragments: [Data("GET /v\(version)/_ping HTTP/1.1\r\nHost: docker\r\n\r\n".utf8)]
            )
            let negotiatedText = String(decoding: negotiated, as: UTF8.self)
            XCTAssertTrue(negotiatedText.contains("HTTP/1.1 200 OK"), version)
            XCTAssertTrue(negotiatedText.contains("Api-Version: \(version)\r\n"), version)
        }

        for version in ["1.51", "1.56"] {
            let unsupported = try exchange(
                path: proxy.socketPath,
                fragments: [Data("GET /v\(version)/_ping HTTP/1.1\r\nHost: docker\r\n\r\n".utf8)]
            )
            XCTAssertEqual(
                String(decoding: unsupported, as: UTF8.self),
                "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 45\r\nContent-Type: application/json\r\n\r\n{\"message\":\"Unsupported Docker API version.\"}",
                version
            )
        }
    }

    func testExecutableKeepsChunkedUpgradeAndMalformedRequestsBeforeControl() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proxy = try launchProxy(root: root)
        defer { stopProxy(proxy) }

        let chunked = try exchange(
            path: proxy.socketPath,
            fragments: [Data(
                "POST /v1.52/_ping HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n0\r\n\r\n".utf8
            )]
        )
        XCTAssertEqual(
            String(decoding: chunked, as: UTF8.self),
            "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 76\r\nContent-Type: application/json\r\n\r\n{\"message\":\"The requested Docker operation is not supported by Hostwright.\"}"
        )

        let upgrade = try exchange(
            path: proxy.socketPath,
            fragments: [Data(
                "GET /v1.52/_ping HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n".utf8
            )]
        )
        XCTAssertEqual(
            String(decoding: upgrade, as: UTF8.self),
            "HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 57\r\nContent-Type: application/json\r\n\r\n{\"message\":\"Docker protocol upgrades are not supported.\"}"
        )

        let malformed = try exchange(
            path: proxy.socketPath,
            fragments: [Data(
                "GET /v1.52/_ping HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8
            )]
        )
        XCTAssertEqual(
            String(decoding: malformed, as: UTF8.self),
            "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 51\r\nContent-Type: application/json\r\n\r\n{\"message\":\"The Docker request target is invalid.\"}"
        )
    }

    func testExecutableRecoversOwnedStaleSocketAndTerminatesCleanly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("docker.sock").path
        let staleDescriptor = try bindStaleSocket(at: socketPath)
        var staleStatus = stat()
        XCTAssertEqual(lstat(socketPath, &staleStatus), 0)
        _ = close(staleDescriptor)

        let proxy = try launchProxy(root: root)
        try waitForSocketReplacement(socketPath, previousInode: staleStatus.st_ino)
        XCTAssertEqual(mode(of: URL(fileURLWithPath: socketPath)), 0o600)
        var currentStatus = stat()
        XCTAssertEqual(lstat(socketPath, &currentStatus), 0)
        XCTAssertNotEqual(currentStatus.st_ino, staleStatus.st_ino)
        _ = try exchange(
            path: socketPath,
            fragments: [Data("HEAD /v1.54/_ping HTTP/1.1\r\nHost: docker\r\n\r\n".utf8)]
        )

        stopProxy(proxy)
        var removedStatus = stat()
        XCTAssertNotEqual(lstat(socketPath, &removedStatus), 0)
        XCTAssertEqual(proxy.process.terminationStatus, 0)
    }

    func testExecutableCancellationClosesAFragmentedRequestCleanly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proxy = try launchProxy(root: root)
        defer { stopProxy(proxy) }

        let client = try connect(to: proxy.socketPath)
        defer { _ = close(client) }
        try writeAll(
            Data("GET /v1.52/_ping HTTP/1.1\r\nHost: docker\r\n".utf8),
            descriptor: client
        )

        stopProxy(proxy)
    }

    private struct RunningProxy {
        let process: Process
        let socketPath: String
    }

    private enum IntegrationError: Error {
        case proxyExecutableMissing
        case socketTimedOut
        case socketIO
    }

    private func launchProxy(root: URL) throws -> RunningProxy {
        let process = Process()
        process.executableURL = try proxyExecutable()
        let socketPath = root.appendingPathComponent("docker.sock").path
        let controlPath = root.appendingPathComponent("control.sock").path
        process.arguments = [
            "--socket", socketPath,
            "--control-socket", controlPath,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try waitForSocket(socketPath)
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw error
        }
        return RunningProxy(process: process, socketPath: socketPath)
    }

    private func stopProxy(_ proxy: RunningProxy) {
        guard proxy.process.isRunning else { return }
        proxy.process.terminate()
        proxy.process.waitUntilExit()
        XCTAssertEqual(proxy.process.terminationStatus, 0)
        var status = stat()
        XCTAssertNotEqual(lstat(proxy.socketPath, &status), 0)
    }

    private func proxyExecutable() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["HOSTWRIGHT_DOCKER_PROXY_PATH"] {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("hostwright-docker-proxy")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        for relative in [
            ".build/arm64-apple-macosx/debug/hostwright-docker-proxy",
            ".build/debug/hostwright-docker-proxy",
        ] {
            let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(relative)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw IntegrationError.proxyExecutableMissing
    }

    private func waitForSocket(_ path: String) throws {
        for _ in 0..<200 {
            var status = stat()
            if lstat(path, &status) == 0,
               (status.st_mode & S_IFMT) == S_IFSOCK,
               (status.st_mode & 0o7777) == 0o600 {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw IntegrationError.socketTimedOut
    }

    private func waitForSocketReplacement(_ path: String, previousInode: UInt64) throws {
        for _ in 0..<200 {
            var status = stat()
            if lstat(path, &status) == 0,
               (status.st_mode & S_IFMT) == S_IFSOCK,
               status.st_ino != previousInode {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw IntegrationError.socketTimedOut
    }

    private func exchange(path: String, fragments: [Data]) throws -> Data {
        let descriptor = try connect(to: path)
        defer { _ = close(descriptor) }
        for fragment in fragments {
            try writeAll(fragment, descriptor: descriptor)
            Thread.sleep(forTimeInterval: 0.005)
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return response
            } else if errno != EINTR {
                throw IntegrationError.socketIO
            }
        }
    }

    private func connect(to path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IntegrationError.socketIO }
        do {
            var address = try sockaddrAddress(path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
                    )
                }
            }
            guard connected == 0 else { throw IntegrationError.socketIO }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw IntegrationError.socketIO
            }
        }
    }

    private func bindStaleSocket(at path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IntegrationError.socketIO }
        do {
            var address = try sockaddrAddress(path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
                    )
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0 else { throw IntegrationError.socketIO }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private func sockaddrAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw IntegrationError.socketIO
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private func makeRoot() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
            .replacingOccurrences(of: "/var/", with: "/private/var/")
        let root = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .appendingPathComponent(
                "hw-docker-process-" + String(UUID().uuidString.prefix(8)),
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
}
