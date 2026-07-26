import Darwin
import Foundation
import HostwrightRuntime
import XCTest
@testable import HostwrightNetworkHelperCore

final class NetworkHelperTests: XCTestCase {
    private let projectUUID = "11111111-1111-4111-8111-111111111111"
    private let dnsUUID = "22222222-2222-4222-8222-222222222222"
    private let firstFence = "33333333-3333-4333-8333-333333333333"
    private let secondFence = "44444444-4444-4444-8444-444444444444"
    private let thirdFence = "55555555-5555-4555-8555-555555555555"

    func testCanonicalFramingRoundTripsAndRejectsNonCanonicalJSON() throws {
        let request = NetworkHelperRequest(
            requestID: UUID(uuidString:
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            operation: .apply,
            identity: identity(),
            corefile: corefile()
        )
        let frame = try NetworkHelperCanonicalJSON.frame(request)
        XCTAssertEqual(
            try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperRequest.self,
                from: frame
            ),
            request
        )

        let canonical = try NetworkHelperCanonicalJSON.encode(request)
        let nonCanonical = Data(" \(String(decoding: canonical, as: UTF8.self))".utf8)
        let nonCanonicalFrame = try ContainerizationHelperFraming.frame(
            nonCanonical
        )
        XCTAssertThrowsError(
            try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperRequest.self,
                from: nonCanonicalFrame
            )
        ) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidFrame)
        }
    }

    func testRequestValidationRejectsInvalidIdentityAndOversizedCorefile() {
        let invalidIdentity = NetworkHelperRequest(
            operation: .apply,
            identity: NetworkHelperDNSIdentity(
                projectUUID: "not-a-uuid",
                dnsUUID: dnsUUID,
                generation: 1,
                fencingToken: firstFence
            ),
            corefile: corefile()
        )
        XCTAssertThrowsError(try invalidIdentity.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidIdentity)
        }

        let oversized = NetworkHelperRequest(
            operation: .apply,
            identity: identity(),
            corefile: String(
                repeating: "a",
                count: NetworkHelperProtocolV1.maximumCorefileBytes + 1
            )
        )
        XCTAssertThrowsError(try oversized.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidCorefile)
        }

        let invalidPredecessor = NetworkHelperRequest(
            operation: .apply,
            identity: identity(),
            corefile: corefile(),
            predecessorFencingToken: "not-a-uuid"
        )
        XCTAssertThrowsError(try invalidPredecessor.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidIdentity)
        }

        let statusWithPredecessor = NetworkHelperRequest(
            operation: .status,
            identity: identity(),
            predecessorFencingToken: firstFence
        )
        XCTAssertThrowsError(try statusWithPredecessor.validated()) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidRequest)
        }
    }

    func testApplyStatusGenerationReplacementAndExactRemove() throws {
        try withStore { store, root in
            let first = identity()
            let applied = try store.apply(
                identity: first,
                corefile: corefile()
            )
            XCTAssertEqual(applied.disposition, .active)
            XCTAssertEqual(try store.status(identity: first), applied)
            XCTAssertEqual(
                try store.apply(identity: first, corefile: corefile()),
                applied
            )

            let second = identity(generation: 2, fence: secondFence)
            XCTAssertThrowsError(
                try store.apply(
                    identity: second,
                    corefile: corefile(ttl: 10)
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertThrowsError(
                try store.apply(
                    identity: second,
                    corefile: corefile(ttl: 10),
                    predecessorFencingToken: thirdFence
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertEqual(
                try store.status(identity: first).disposition,
                .active
            )
            XCTAssertEqual(
                try store.apply(
                    identity: second,
                    corefile: corefile(ttl: 10),
                    predecessorFencingToken: firstFence
                )
                    .disposition,
                .active
            )
            let third = identity(generation: 3, fence: thirdFence)
            XCTAssertThrowsError(
                try store.apply(
                    identity: third,
                    corefile: corefile(ttl: 20),
                    predecessorFencingToken: firstFence
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertEqual(
                try store.status(identity: second).disposition,
                .active
            )
            XCTAssertEqual(
                try store.status(identity: first).disposition,
                .conflict
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: generationURL(root: root, generation: 1).path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: generationURL(root: root, generation: 2).path
                )
            )

            XCTAssertThrowsError(try store.remove(identity: first)) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
            XCTAssertEqual(
                try store.remove(identity: second).disposition,
                .absent
            )
            XCTAssertEqual(
                try store.status(identity: second).disposition,
                .absent
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root
                        .appendingPathComponent(projectUUID)
                        .path
                )
            )
        }
    }

    func testSameGenerationWithDifferentFenceCannotReplaceOwnership() throws {
        try withStore { store, _ in
            _ = try store.apply(identity: identity(), corefile: corefile())
            XCTAssertThrowsError(
                try store.apply(
                    identity: identity(fence: secondFence),
                    corefile: corefile()
                )
            ) {
                XCTAssertEqual($0 as? NetworkHelperError, .conflict)
            }
        }
    }

    func testActiveDirectoryRemainsStableAcrossRefreshAndRestart() throws {
        try withStore { store, root in
            let first = identity()
            _ = try store.apply(identity: first, corefile: corefile())
            let active = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
                .appendingPathComponent("active")
            let directoryDescriptor = open(
                active.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
            defer { Darwin.close(directoryDescriptor) }
            var before = stat()
            XCTAssertEqual(fstat(directoryDescriptor, &before), 0)

            let second = identity(generation: 2, fence: secondFence)
            let refreshedCorefile = corefile(ttl: 17)
            _ = try store.apply(
                identity: second,
                corefile: refreshedCorefile,
                predecessorFencingToken: firstFence
            )
            var after = stat()
            XCTAssertEqual(lstat(active.path, &after), 0)
            XCTAssertEqual(before.st_dev, after.st_dev)
            XCTAssertEqual(before.st_ino, after.st_ino)

            let activeCorefileDescriptor = openat(
                directoryDescriptor,
                "Corefile",
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            XCTAssertGreaterThanOrEqual(activeCorefileDescriptor, 0)
            XCTAssertEqual(
                try readAll(descriptor: activeCorefileDescriptor),
                Data(refreshedCorefile.utf8)
            )

            let recovered = try NetworkHelperStateStore(rootURL: root)
            XCTAssertEqual(
                try recovered.status(identity: second).disposition,
                .active
            )
            var restarted = stat()
            XCTAssertEqual(lstat(active.path, &restarted), 0)
            XCTAssertEqual(before.st_dev, restarted.st_dev)
            XCTAssertEqual(before.st_ino, restarted.st_ino)

            _ = try recovered.remove(identity: second)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: active.path)
            )
        }
    }

    func testTamperedCorefileIsQuarantinedAndCannotBeRemoved() throws {
        try withStore { store, root in
            let identity = identity()
            _ = try store.apply(identity: identity, corefile: corefile())
            let corefileURL = generationURL(root: root, generation: 1)
                .appendingPathComponent("Corefile")
            let handle = try FileHandle(forWritingTo: corefileURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("tampered\n".utf8))
            try handle.close()

            XCTAssertEqual(
                try store.status(identity: identity).disposition,
                .quarantined
            )
            XCTAssertThrowsError(try store.remove(identity: identity)) {
                XCTAssertEqual($0 as? NetworkHelperError, .quarantined)
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: corefileURL.path)
            )
        }
    }

    func testSymlinkedCurrentPointerFailsClosedWithoutDeletingState() throws {
        try withStore { store, root in
            let identity = identity()
            _ = try store.apply(identity: identity, corefile: corefile())
            let dnsRoot = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
            let current = dnsRoot.appendingPathComponent("current.json")
            XCTAssertEqual(unlink(current.path), 0)
            XCTAssertEqual(
                symlink(
                    generationURL(root: root, generation: 1)
                        .appendingPathComponent("Corefile")
                        .path,
                    current.path
                ),
                0
            )

            XCTAssertThrowsError(try store.status(identity: identity)) {
                XCTAssertEqual($0 as? NetworkHelperError, .unsafePath)
            }
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: generationURL(root: root, generation: 1)
                        .appendingPathComponent("Corefile")
                        .path
                )
            )
        }
    }

    func testRestartRecoveryRemovesIncompleteOwnedPendingGeneration() throws {
        try withStore { store, root in
            let identity = identity()
            _ = try store.apply(identity: identity, corefile: corefile())
            let pending = root
                .appendingPathComponent(projectUUID)
                .appendingPathComponent(dnsUUID)
                .appendingPathComponent("generations")
                .appendingPathComponent(
                    ".pending-55555555-5555-4555-8555-555555555555"
                )
            XCTAssertEqual(mkdir(pending.path, 0o700), 0)
            XCTAssertEqual(chmod(pending.path, 0o700), 0)

            let recovered = try NetworkHelperStateStore(rootURL: root)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: pending.path)
            )
            XCTAssertEqual(
                try recovered.status(identity: identity).disposition,
                .active
            )
        }
    }

    func testDispatcherReturnsTypedConflictWithoutChangingState() throws {
        try withStore { store, _ in
            let dispatcher = NetworkHelperDispatcher(store: store)
            let first = NetworkHelperRequest(
                operation: .apply,
                identity: identity(),
                corefile: corefile()
            )
            let firstResponse = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(first)
                )
            )
            XCTAssertEqual(firstResponse.status?.disposition, .active)

            let conflicting = NetworkHelperRequest(
                operation: .apply,
                identity: identity(fence: secondFence),
                corefile: corefile()
            )
            let conflictResponse = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(conflicting)
                )
            )
            XCTAssertEqual(conflictResponse.error?.code, .conflict)
            XCTAssertNil(conflictResponse.status)
            XCTAssertEqual(
                try store.status(identity: identity()).disposition,
                .active
            )
        }
    }

    func testRuntimeDirectorySocketModesAndSameUIDAuthentication() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtimeURL = parent.appendingPathComponent(
            "runtime",
            isDirectory: true
        )
        let runtime =
            try ContainerizationHelperRuntimeDirectory.prepare(
                at: runtimeURL,
                socketName: "network-helper.sock"
            )
        XCTAssertEqual(mode(at: runtimeURL), 0o700)
        let lease = try runtime.makeListeningSocket()
        XCTAssertEqual(mode(at: runtime.socketURL), 0o600)

        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
            0
        )
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        XCTAssertNoThrow(
            try NetworkHelperPeerSecurity.validateSameUser(
                connectionDescriptor: descriptors[0]
            )
        )
        XCTAssertThrowsError(
            try NetworkHelperPeerSecurity.validateSameUser(
                connectionDescriptor: descriptors[0],
                expectedUserID: geteuid() &+ 1
            )
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperCodeIdentityError,
                .userMismatch
            )
        }

        try lease.closeAndRemove()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtime.socketURL.path)
        )
    }

    func testConnectionHandlerAppliesOneBoundedCanonicalFrame() async throws {
        try await withAsyncStore { store, _ in
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(
                socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
                0
            )
            let server = descriptors[0]
            let client = descriptors[1]
            defer {
                Darwin.close(server)
                Darwin.close(client)
            }

            let request = NetworkHelperRequest(
                operation: .apply,
                identity: identity(),
                corefile: corefile()
            )
            let requestFrame = try NetworkHelperCanonicalJSON.frame(request)
            let task = Task.detached {
                try NetworkHelperConnectionHandler.handle(
                    descriptor: server,
                    dispatcher: NetworkHelperDispatcher(store: store)
                )
            }
            let written = requestFrame.withUnsafeBytes {
                Darwin.write(client, $0.baseAddress, $0.count)
            }
            XCTAssertEqual(written, requestFrame.count)
            let responseFrame = try NetworkHelperConnectionHandler.readFrame(
                descriptor: client
            )
            try await task.value

            let response = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: responseFrame
            )
            XCTAssertEqual(response.requestID, request.requestID)
            XCTAssertEqual(response.status?.disposition, .active)
            XCTAssertNil(response.error)
        }
    }

    func testConnectionHandlerRejectsFrameLargerThanEightMiB() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
            0
        )
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        let oversizedHeader = Data([0, 128, 0, 1])
        let written = oversizedHeader.withUnsafeBytes {
            Darwin.write(descriptors[1], $0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, oversizedHeader.count)
        XCTAssertThrowsError(
            try NetworkHelperConnectionHandler.readFrame(
                descriptor: descriptors[0]
            )
        ) {
            XCTAssertEqual($0 as? NetworkHelperError, .invalidFrame)
        }
    }

    private func identity(
        generation: Int = 1,
        fence: String? = nil
    ) -> NetworkHelperDNSIdentity {
        NetworkHelperDNSIdentity(
            projectUUID: projectUUID,
            dnsUUID: dnsUUID,
            generation: generation,
            fencingToken: fence ?? firstFence
        )
    }

    private func corefile(ttl: Int = 5) -> String {
        """
        \(projectUUID).hostwright.internal {
            cache \(ttl)
            hosts {
                192.0.2.10 api.\(projectUUID).hostwright.internal
                fallthrough
            }
        }
        """
    }

    private func generationURL(root: URL, generation: Int) -> URL {
        root
            .appendingPathComponent(projectUUID)
            .appendingPathComponent(dnsUUID)
            .appendingPathComponent("generations")
            .appendingPathComponent(String(generation))
    }

    private func withStore(
        _ body: (
            NetworkHelperStateStore,
            URL
        ) throws -> Void
    ) throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("state", isDirectory: true)
        let store = try NetworkHelperStateStore(rootURL: root)
        try body(store, root)
    }

    private func withAsyncStore(
        _ body: (
            NetworkHelperStateStore,
            URL
        ) async throws -> Void
    ) async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("state", isDirectory: true)
        let store = try NetworkHelperStateStore(rootURL: root)
        try await body(store, root)
    }

    private func makePrivateParent() throws -> URL {
        let identifier = UUID().uuidString
            .lowercased()
            .prefix(8)
        let url = URL(
            fileURLWithPath: "/private/tmp/hwnh-\(identifier)",
            isDirectory: true
        )
        XCTAssertEqual(mkdir(url.path, 0o700), 0)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }

    private func mode(at url: URL) -> mode_t {
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        return metadata.st_mode & mode_t(0o7777)
    }

    private func readAll(descriptor: Int32) throws -> Data {
        defer { Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = Darwin.read(
                descriptor,
                &buffer,
                buffer.count
            )
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            if count == 0 { return result }
            result.append(contentsOf: buffer[0..<count])
        }
    }
}
