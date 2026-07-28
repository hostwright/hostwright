import Darwin
import Foundation
import HostwrightNetworking
import HostwrightRuntime
import XCTest
@testable import HostwrightNetworkHelperCore

final class NetworkHelperTests: XCTestCase {
    private let projectUUID = "11111111-1111-4111-8111-111111111111"
    private let dnsUUID = "22222222-2222-4222-8222-222222222222"
    private let firstFence = "33333333-3333-4333-8333-333333333333"
    private let secondFence = "44444444-4444-4444-8444-444444444444"
    private let thirdFence = "55555555-5555-4555-8555-555555555555"

    func testHostAccessConfigurationPersistsAndRecoversExactly()
        throws
    {
        try withStore { store, root in
            let binding = hostAccessBinding()
            let applied = try store.apply(
                identity: identity(),
                corefile: corefile(),
                hostAccessBindings: [binding]
            )
            let expected = try XCTUnwrap(
                applied.hostAccessSHA256
            )
            XCTAssertEqual(expected.count, 64)
            XCTAssertEqual(
                try store.activeHostAccessConfigurations(),
                [
                    NetworkHelperPersistedHostAccessConfiguration(
                        identity: identity(),
                        bindings: [binding],
                        sha256: expected
                    ),
                ]
            )

            let restarted = try NetworkHelperStateStore(
                rootURL: root
            )
            XCTAssertEqual(
                try restarted.status(identity: identity()),
                applied
            )
            XCTAssertEqual(
                try restarted
                    .activeHostAccessConfigurations()
                    .first?.bindings,
                [binding]
            )
            _ = try restarted.remove(identity: identity())
            XCTAssertTrue(
                try restarted
                    .activeHostAccessConfigurations()
                    .isEmpty
            )
        }
    }

    func testHostAccessBrokerForwardsOnlyTheExactTCPBinding()
        throws
    {
        guard let interfaceAddress = firstActiveNonLoopbackIPv4()
        else {
            throw XCTSkip(
                "No active non-loopback IPv4 interface is available."
            )
        }
        let target = try makeLoopbackTCPServer()
        defer { Darwin.close(target.descriptor) }
        let binding = ProjectDNSHostAccessBinding(
            hostname: "host-api.internal",
            protocolName: .tcp,
            addressClass: .loopback,
            listenAddress: interfaceAddress,
            clientCIDR: "\(interfaceAddress)/32",
            targetAddress: "127.0.0.1",
            port: target.port
        )
        let targetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { targetFinished.signal() }
            guard waitReadable(
                target.descriptor,
                milliseconds: 5_000
            ) else {
                return
            }
            let connection = Darwin.accept(
                target.descriptor,
                nil,
                nil
            )
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var bytes = [UInt8](repeating: 0, count: 16)
            let count = Darwin.read(
                connection,
                &bytes,
                bytes.count
            )
            guard count == 4,
                  String(decoding: bytes[0..<count], as: UTF8.self)
                    == "ping" else {
                return
            }
            _ = Darwin.write(
                connection,
                Array("pong".utf8),
                4
            )
        }

        let broker = NetworkHelperHostAccessBroker()
        XCTAssertNotNil(
            try broker.apply(
                identity: identity(),
                bindings: [binding]
            )
        )
        defer { broker.remove(identity: identity()) }

        let client = try connectTCP(
            address: interfaceAddress,
            port: target.port
        )
        defer { Darwin.close(client) }
        XCTAssertEqual(
            Darwin.write(client, Array("ping".utf8), 4),
            4
        )
        XCTAssertTrue(
            waitReadable(client, milliseconds: 5_000)
        )
        var response = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(
            Darwin.read(client, &response, response.count),
            4
        )
        XCTAssertEqual(
            String(decoding: response, as: UTF8.self),
            "pong"
        )
        XCTAssertEqual(
            targetFinished.wait(timeout: .now() + 5),
            .success
        )
    }

    func testHostAccessBrokerForwardsOnlyTheExactUDPBinding()
        throws
    {
        guard let interfaceAddress = firstActiveNonLoopbackIPv4()
        else {
            throw XCTSkip(
                "No active non-loopback IPv4 interface is available."
            )
        }
        let target = try makeLoopbackUDPServer()
        defer { Darwin.close(target.descriptor) }
        let binding = ProjectDNSHostAccessBinding(
            hostname: "host-dns.internal",
            protocolName: .udp,
            addressClass: .loopback,
            listenAddress: interfaceAddress,
            clientCIDR: "\(interfaceAddress)/32",
            targetAddress: "127.0.0.1",
            port: target.port
        )
        let targetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { targetFinished.signal() }
            guard waitReadable(
                target.descriptor,
                milliseconds: 5_000
            ) else {
                return
            }
            var peer = sockaddr_in()
            var peerLength = socklen_t(
                MemoryLayout<sockaddr_in>.size
            )
            var bytes = [UInt8](repeating: 0, count: 16)
            let count = withUnsafeMutablePointer(to: &peer) {
                pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.recvfrom(
                        target.descriptor,
                        &bytes,
                        bytes.count,
                        0,
                        $0,
                        &peerLength
                    )
                }
            }
            guard count == 4,
                  String(
                    decoding: bytes[0..<count],
                    as: UTF8.self
                  ) == "ping" else {
                return
            }
            var mutablePeer = peer
            _ = withUnsafePointer(to: &mutablePeer) {
                pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.sendto(
                        target.descriptor,
                        Array("pong".utf8),
                        4,
                        0,
                        $0,
                        peerLength
                    )
                }
            }
        }

        let broker = NetworkHelperHostAccessBroker()
        XCTAssertNotNil(
            try broker.apply(
                identity: identity(),
                bindings: [binding]
            )
        )
        defer { broker.remove(identity: identity()) }

        XCTAssertEqual(
            try udpRoundTrip(
                address: interfaceAddress,
                port: target.port,
                payload: Data("ping".utf8)
            ),
            Data("pong".utf8)
        )
        XCTAssertEqual(
            targetFinished.wait(timeout: .now() + 5),
            .success
        )
    }

    func testHostAccessValidationRejectsEscapesAndDuplicateListeners()
        throws
    {
        let valid = hostAccessBinding()
        let invalid = [
            ProjectDNSHostAccessBinding(
                hostname: "metadata",
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: valid.listenAddress,
                clientCIDR: valid.clientCIDR,
                targetAddress: valid.targetAddress,
                port: valid.port
            ),
            ProjectDNSHostAccessBinding(
                hostname: valid.hostname,
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: valid.listenAddress,
                clientCIDR: "192.168.65.0/24",
                targetAddress: valid.targetAddress,
                port: valid.port
            ),
            ProjectDNSHostAccessBinding(
                hostname: valid.hostname,
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: valid.listenAddress,
                clientCIDR: valid.clientCIDR,
                targetAddress: "192.168.64.10",
                port: valid.port
            ),
        ]
        for binding in invalid {
            XCTAssertThrowsError(
                try NetworkHelperHostAccessValidation
                    .validated([binding])
            ) {
                XCTAssertEqual(
                    $0 as? NetworkHelperError,
                    .invalidRequest
                )
            }
        }
        let duplicateListener =
            ProjectDNSHostAccessBinding(
                hostname: "host-api-two.internal",
                protocolName: valid.protocolName,
                addressClass: valid.addressClass,
                listenAddress: valid.listenAddress,
                clientCIDR: valid.clientCIDR,
                targetAddress: valid.targetAddress,
                port: valid.port
            )
        XCTAssertThrowsError(
            try NetworkHelperHostAccessValidation.validated(
                [valid, duplicateListener]
            )
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperError,
                .invalidRequest
            )
        }
        let secondPort = ProjectDNSHostAccessBinding(
            hostname: valid.hostname,
            protocolName: valid.protocolName,
            addressClass: valid.addressClass,
            listenAddress: valid.listenAddress,
            clientCIDR: valid.clientCIDR,
            targetAddress: valid.targetAddress,
            port: valid.port + 1
        )
        XCTAssertEqual(
            try NetworkHelperHostAccessValidation.validated(
                [secondPort, valid]
            ),
            [valid, secondPort]
        )
    }

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

    func testDispatcherStaleRemoveKeepsActiveHostAccessBindings() throws {
        guard let interfaceAddress = firstActiveNonLoopbackIPv4()
        else {
            throw XCTSkip("No active non-loopback IPv4 interface is available.")
        }
        let target = try makeLoopbackTCPServer()
        defer { Darwin.close(target.descriptor) }

        try withStore { store, _ in
            let broker = NetworkHelperHostAccessBroker()
            let dispatcher = NetworkHelperDispatcher(
                store: store,
                hostAccessBroker: broker
            )
            let binding = ProjectDNSHostAccessBinding(
                hostname: "host-api.internal",
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: interfaceAddress,
                clientCIDR: "\(interfaceAddress)/32",
                targetAddress: "127.0.0.1",
                port: target.port
            )
            let first = identity()
            let second = identity(generation: 2, fence: secondFence)

            _ = try dispatcher.dispatch(
                frame: try NetworkHelperCanonicalJSON.frame(
                    NetworkHelperRequest(
                        operation: .apply,
                        identity: first,
                        corefile: corefile(),
                        hostAccessBindings: [binding]
                    )
                )
            )
            let applied = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .apply,
                            identity: second,
                            corefile: corefile(),
                            hostAccessBindings: [binding],
                            predecessorFencingToken: firstFence
                        )
                    )
                )
            )
            let staleRemove = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .remove,
                            identity: first
                        )
                    )
                )
            )

            XCTAssertEqual(staleRemove.error?.code, .conflict)
            XCTAssertEqual(
                broker.sha256(identity: second),
                applied.status?.hostAccessSHA256
            )
            XCTAssertTrue(broker.hasActiveBindings)
        }
    }

    func testDispatcherStagesInactiveExactHostAccessBindingForRetryAndRemoval()
        throws
    {
        try withStore { store, _ in
            let broker = NetworkHelperHostAccessBroker()
            let dispatcher = NetworkHelperDispatcher(
                store: store,
                hostAccessBroker: broker
            )
            let binding = ProjectDNSHostAccessBinding(
                hostname: "host-api.internal",
                protocolName: .tcp,
                addressClass: .loopback,
                listenAddress: "192.0.2.1",
                clientCIDR: "192.0.2.0/24",
                targetAddress: "127.0.0.1",
                port: 6_508
            )
            let identity = identity()

            let applied = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .apply,
                            identity: identity,
                            corefile: corefile(),
                            hostAccessBindings: [binding]
                        )
                    )
                )
            )
            let digest = try XCTUnwrap(applied.status?.hostAccessSHA256)
            XCTAssertEqual(applied.status?.disposition, .active)
            XCTAssertEqual(digest.count, 64)
            XCTAssertEqual(applied.status?.hostAccessActive, false)
            XCTAssertFalse(broker.hasActiveBindings)

            let staged = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .status,
                            identity: identity
                        )
                    )
                )
            )
            XCTAssertEqual(staged.status?.disposition, .active)
            XCTAssertEqual(staged.status?.hostAccessSHA256, digest)
            XCTAssertEqual(staged.status?.hostAccessActive, false)
            XCTAssertFalse(broker.hasActiveBindings)

            let removed = try NetworkHelperCanonicalJSON.decodeFrame(
                NetworkHelperResponse.self,
                from: dispatcher.dispatch(
                    frame: try NetworkHelperCanonicalJSON.frame(
                        NetworkHelperRequest(
                            operation: .remove,
                            identity: identity
                        )
                    )
                )
            )
            XCTAssertEqual(removed.status?.disposition, .absent)
            XCTAssertFalse(broker.hasActiveBindings)
            XCTAssertTrue(
                try store.activeHostAccessConfigurations().isEmpty
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

    private func hostAccessBinding()
        -> ProjectDNSHostAccessBinding
    {
        ProjectDNSHostAccessBinding(
            hostname: "host-api.internal",
            protocolName: .tcp,
            addressClass: .loopback,
            listenAddress: "192.168.64.1",
            clientCIDR: "192.168.64.0/24",
            targetAddress: "127.0.0.1",
            port: 6_508
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

private func firstActiveNonLoopbackIPv4() -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0 else { return nil }
    defer { freeifaddrs(pointer) }
    var current = pointer
    while let item = current {
        defer { current = item.pointee.ifa_next }
        guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              let address = item.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else {
            continue
        }
        var value = UnsafeRawPointer(address)
            .assumingMemoryBound(to: sockaddr_in.self)
            .pointee.sin_addr
        var buffer = [CChar](
            repeating: 0,
            count: Int(INET_ADDRSTRLEN)
        )
        guard inet_ntop(
            AF_INET,
            &value,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            continue
        }
        return buffer.withUnsafeBufferPointer { bytes in
            String(
                decoding: bytes
                    .prefix { $0 != 0 }
                    .map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
    }
    return nil
}

private func makeLoopbackTCPServer() throws
    -> (descriptor: Int32, port: Int)
{
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var succeeded = false
    defer {
        if !succeeded { Darwin.close(descriptor) }
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard "127.0.0.1".withCString({
        inet_pton(AF_INET, $0, &address.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let loaded = withUnsafeMutablePointer(to: &actual) {
        pointer in
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard loaded == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    succeeded = true
    return (
        descriptor,
        Int(in_port_t(bigEndian: actual.sin_port))
    )
}

private func makeLoopbackUDPServer() throws
    -> (descriptor: Int32, port: Int)
{
    let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var succeeded = false
    defer {
        if !succeeded { Darwin.close(descriptor) }
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard "127.0.0.1".withCString({
        inet_pton(AF_INET, $0, &address.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bound == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let loaded = withUnsafeMutablePointer(to: &actual) {
        pointer in
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard loaded == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    succeeded = true
    return (
        descriptor,
        Int(in_port_t(bigEndian: actual.sin_port))
    )
}

private func connectTCP(address: String, port: Int) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    var succeeded = false
    defer {
        if !succeeded { Darwin.close(descriptor) }
    }
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = in_port_t(port).bigEndian
    guard address.withCString({
        inet_pton(AF_INET, $0, &target.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let result = withUnsafePointer(to: &target) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard result == 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    succeeded = true
    return descriptor
}

private func udpRoundTrip(
    address: String,
    port: Int,
    payload: Data
) throws -> Data {
    let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    defer { Darwin.close(descriptor) }
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = in_port_t(port).bigEndian
    guard address.withCString({
        inet_pton(AF_INET, $0, &target.sin_addr)
    }) == 1 else {
        throw NetworkHelperError.bindingUnavailable
    }
    let sent = payload.withUnsafeBytes { bytes in
        withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.sendto(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    $0,
                    socklen_t(
                        MemoryLayout<sockaddr_in>.size
                    )
                )
            }
        }
    }
    guard sent == payload.count,
          waitReadable(descriptor, milliseconds: 5_000) else {
        throw NetworkHelperError.bindingUnavailable
    }
    var response = [UInt8](repeating: 0, count: 64 * 1_024)
    let count = Darwin.recv(
        descriptor,
        &response,
        response.count,
        0
    )
    guard count > 0 else {
        throw NetworkHelperError.bindingUnavailable
    }
    return Data(response[0..<count])
}

private func waitReadable(
    _ descriptor: Int32,
    milliseconds: Int32
) -> Bool {
    var value = pollfd(
        fd: descriptor,
        events: Int16(POLLIN),
        revents: 0
    )
    return Darwin.poll(&value, 1, milliseconds) > 0
        && value.revents & Int16(POLLIN | POLLHUP) != 0
}
