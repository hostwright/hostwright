import Darwin
import Foundation
import XCTest
@testable import HostwrightRuntime

final class RuntimeUnixSocketPublicationSecurityTests: XCTestCase {
    func testOwnedSocketLifecycleBindsInodeAppliesModeAndCleansExactly()
        throws {
        let fixture = try SocketFixture(mode: .ownerAndGroup)
        defer { fixture.cleanup() }

        let leases = try fixture.prepare()
        var listener = try unixListener(at: fixture.publication.hostPath)
        defer {
            if listener >= 0 {
                Darwin.close(listener)
            }
        }

        try RuntimeUnixSocketPublicationSecurity.verifyCreated(
            leases,
            rootDirectory: fixture.root
        )
        XCTAssertEqual(
            try fileMode(at: fixture.publication.hostPath),
            0o660
        )
        XCTAssertEqual(
            chmod(fixture.publication.hostPath, 0o777),
            0
        )
        try RuntimeUnixSocketPublicationSecurity.verifyExisting(
            [fixture.publication],
            context: fixture.context,
            resourceIdentifier: fixture.resourceIdentifier,
            rootDirectory: fixture.root
        )
        XCTAssertEqual(
            try fileMode(at: fixture.publication.hostPath),
            0o660
        )
        let deletion = try fixture.prepareForDelete()
        Darwin.close(listener)
        listener = -1
        try RuntimeUnixSocketPublicationSecurity.finalizeDelete(
            deletion,
            rootDirectory: fixture.root
        )

        XCTAssertEqual(try fixture.rootContents(), [])
    }

    func testDeleteRefusesAReplacedSocketInode() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let leases = try fixture.prepare()
        var listener = try unixListener(
            at: fixture.publication.hostPath
        )
        try RuntimeUnixSocketPublicationSecurity.verifyCreated(
            leases,
            rootDirectory: fixture.root
        )
        let deletion = try fixture.prepareForDelete()

        Darwin.close(listener)
        try FileManager.default.removeItem(
            atPath: fixture.publication.hostPath
        )
        listener = try unixListener(at: fixture.publication.hostPath)
        defer { Darwin.close(listener) }

        XCTAssertThrowsError(
            try RuntimeUnixSocketPublicationSecurity.finalizeDelete(
                deletion,
                rootDirectory: fixture.root
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.publication.hostPath
            )
        )
    }

    func testCancellationBeforeRuntimeEffectRemovesOnlyOwnedMarker()
        throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let sentinel = fixture.parent + "/sentinel"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: sentinel,
                contents: Data("unmanaged".utf8)
            )
        )

        let leases = try fixture.prepare()
        try RuntimeUnixSocketPublicationSecurity.cleanupNoEffect(
            leases,
            rootDirectory: fixture.root
        )

        XCTAssertEqual(try fixture.rootContents(), [])
        XCTAssertEqual(
            try String(contentsOfFile: sentinel, encoding: .utf8),
            "unmanaged"
        )
    }

    func testPrepareRefusesUnmanagedSocketWithoutCreatingOwnershipMetadata()
        throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            atPath: fixture.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let listener = try unixListener(
            at: fixture.publication.hostPath
        )
        defer { Darwin.close(listener) }

        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(
            try fixture.rootContents(),
            [URL(fileURLWithPath: fixture.publication.hostPath)
                .lastPathComponent]
        )
    }

    func testPrepareRecoversOnlyExactOwnedInactiveSocket() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }

        let first = try fixture.prepare()
        let listener = try unixListener(
            at: fixture.publication.hostPath
        )
        try RuntimeUnixSocketPublicationSecurity.verifyCreated(
            first,
            rootDirectory: fixture.root
        )
        Darwin.close(listener)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.publication.hostPath
            )
        )

        try RuntimeUnixSocketPublicationSecurity.prepareForActivation(
            [fixture.publication],
            context: fixture.context,
            resourceIdentifier: fixture.resourceIdentifier,
            rootDirectory: fixture.root
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.publication.hostPath
            )
        )

        try RuntimeUnixSocketPublicationSecurity.cleanupNoEffect(
            first,
            rootDirectory: fixture.root
        )
        XCTAssertEqual(try fixture.rootContents(), [])
    }

    func testPrepareRefusesSymlinkAndDuplicateHostPaths() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            atPath: fixture.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let target = fixture.parent + "/sentinel"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: target,
                contents: Data("sentinel".utf8)
            )
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.publication.hostPath,
            withDestinationPath: target
        )

        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(
            try String(contentsOfFile: target, encoding: .utf8),
            "sentinel"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.publication.hostPath
            ),
            target
        )

        try FileManager.default.removeItem(
            atPath: fixture.publication.hostPath
        )
        XCTAssertThrowsError(
            try RuntimeUnixSocketPublicationSecurity.prepareForCreate(
                [fixture.publication, fixture.publication],
                context: fixture.context,
                resourceIdentifier: fixture.resourceIdentifier,
                rootDirectory: fixture.root
            )
        )
        XCTAssertEqual(try fixture.rootContents(), [])
    }
}

private struct SocketFixture {
    let parent: String
    let root: String
    let publication: RuntimeUnixSocketPublication
    let context: RuntimeMutationContext
    let resourceIdentifier = "hostwright-demo-api"

    init(mode: RuntimeUnixSocketMode = .ownerOnly) throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        parent = "/tmp/hwus-\(suffix)"
        root = parent + "/s"
        publication = RuntimeUnixSocketPublication(
            hostPath: root + "/api.sock",
            containerPath: "/run/api.sock",
            mode: mode
        )
        context = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "phase07-unix-socket-test",
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 1,
            projectResourceUUID:
                "22222222-2222-4222-8222-222222222222",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func prepare() throws -> [RuntimeUnixSocketPublicationLease] {
        try RuntimeUnixSocketPublicationSecurity.prepareForCreate(
            [publication],
            context: context,
            resourceIdentifier: resourceIdentifier,
            rootDirectory: root
        )
    }

    func prepareForDelete()
        throws -> [RuntimeUnixSocketPublicationLease] {
        try RuntimeUnixSocketPublicationSecurity.prepareForDelete(
            [publication],
            context: context,
            resourceIdentifier: resourceIdentifier,
            rootDirectory: root
        )
    }

    func rootContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root).sorted()
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: parent)
    }
}

private func unixListener(at path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(.EIO)
    }
    do {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(
            ofValue: address.sun_path
        ) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.initializeMemory(as: UInt8.self, repeating: 0)
            $0.copyBytes(from: bytes)
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func fileMode(at path: String) throws -> mode_t {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(
            POSIXErrorCode(rawValue: errno) ?? .EIO
        )
    }
    return metadata.st_mode & 0o777
}
