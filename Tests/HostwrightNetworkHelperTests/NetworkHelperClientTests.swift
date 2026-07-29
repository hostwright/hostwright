import Darwin
import Foundation
import HostwrightNetworking
import HostwrightRuntime
import Security
import XCTest
@testable import HostwrightNetworkHelperCore

final class NetworkHelperClientTests: XCTestCase {
    func testClientPreservesStructuredHelperErrorCategories() {
        let expected: [
            (NetworkHelperErrorCode, NetworkHelperClientError)
        ] = [
            (.invalidRequest, .invalidRequest),
            (.unsupportedProtocolVersion, .unsupportedProtocolVersion),
            (.invalidIdentity, .invalidIdentity),
            (.invalidCorefile, .invalidCorefile),
            (.invalidFrame, .invalidFrame),
            (.conflict, .conflict),
            (.quarantined, .quarantined),
            (.unsafePath, .unsafeState),
            (.ioFailure, .ioFailure),
            (.permissionDenied, .permissionDenied),
            (.bindingUnavailable, .bindingUnavailable),
        ]

        for (code, clientError) in expected {
            XCTAssertEqual(NetworkHelperClient.map(code), clientError)
        }
    }

    private let projectUUID = "11111111-1111-4111-8111-111111111111"
    private let dnsUUID = "22222222-2222-4222-8222-222222222222"
    private let fence = "33333333-3333-4333-8333-333333333333"

    func testCodeRequirementsAreCanonicalAndParseable() {
        let helper = NetworkHelperCodeIdentityPolicy.requirementSource(
            identifier: NetworkHelperCodeIdentityPolicy.helperIdentifier
        )
        XCTAssertEqual(
            helper,
            #"identifier "hostwright-network-helper" and anchor apple generic and certificate leaf[subject.OU] = "993YC3JY4Q""#
        )
        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                helper as CFString,
                [],
                &requirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(requirement)
        XCTAssertEqual(
            NetworkHelperCodeIdentityPolicy.allowedClientIdentifiers,
            [
                "dev.hostwright.cli",
                "hostwright",
                "hostwright-control",
                "hostwrightd"
            ]
        )
    }

    func testProductionPeerAuthenticationRejectsUnexpectedPID() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
            0
        )
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        let actual = try NetworkHelperPeerSecurity.peerProcessID(
            connectionDescriptor: descriptors[0]
        )
        let authenticator =
            NetworkHelperServerPeerAuthenticator.production()
        XCTAssertThrowsError(
            try authenticator.validate(
                connectionDescriptor: descriptors[0],
                expectedProcessID: actual &+ 1
            )
        ) {
            XCTAssertEqual(
                $0 as? NetworkHelperCodeIdentityError,
                .processMismatch
            )
        }
    }

    func testClientExchangesWithInjectedServerAndExposesOnlyActiveCorefile()
        async throws {
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
        let store = try NetworkHelperStateStore(
            rootURL: runtimeURL.appendingPathComponent(
                "dns-state",
                isDirectory: true
            )
        )
        let ingressBroker = NetworkHelperIngressBroker()
        let server = NetworkHelperUnixServer(
            runtimeDirectory: runtime,
            dispatcher: NetworkHelperDispatcher(
                store: store,
                ingressBroker: ingressBroker
            ),
            authenticator: NetworkHelperPeerAuthenticator { descriptor in
                _ = try NetworkHelperPeerSecurity.validateSameUser(
                    connectionDescriptor: descriptor
                )
            },
            idleTimeoutMilliseconds: 500
        )
        let serverTask = Task.detached {
            try server.run()
        }

        let configuration = NetworkHelperClientConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            runtimeDirectoryURL: runtimeURL,
            launchTimeoutMilliseconds: 2_000,
            requestTimeoutMilliseconds: 2_000,
            helperIdleTimeoutMilliseconds: 500
        )
        let client = NetworkHelperClient(
            configuration: configuration,
            executableValidator: NetworkHelperExecutableValidator { _ in },
            peerAuthenticator: NetworkHelperServerPeerAuthenticator {
                descriptor, _ in
                _ = try NetworkHelperPeerSecurity.validateSameUser(
                    connectionDescriptor: descriptor
                )
            },
            launcher: NetworkHelperProcessLauncher { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["1"]
                process.environment = [:]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                return NetworkHelperProcessLease(
                    processID: process.processIdentifier,
                    isRunning: { process.isRunning },
                    terminate: {
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                )
            }
        )
        let identity = NetworkHelperDNSIdentity(
            projectUUID: projectUUID,
            dnsUUID: dnsUUID,
            generation: 1,
            fencingToken: fence
        )
        let ingressPort = try reserveLoopbackPortForClient()
        let ingress = ProjectIngressListenerBinding(
            name: "api",
            bindAddress: "127.0.0.1",
            port: ingressPort,
            exposure: .localhost,
            routes: [ProjectIngressRouteBinding(
                hostname: "api.internal",
                pathPrefix: "/",
                methods: ["GET"],
                protocolName: .http,
                targetServiceName: "api",
                targetServiceUUIDs: [projectUUID],
                targetPort: 8_080,
                backends: []
            )]
        )
        let policy = try NetworkPolicyCompiler.compile(
            projectName: "client-test",
            projectUUID: projectUUID,
            generation: 1,
            services: [(
                name: "api",
                resourceUUID: dnsUUID,
                policy: HostwrightServiceNetworkPolicy(egress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .tcp,
                        port: 443,
                        dns: "updates.example.test"
                    ),
                ])
            )]
        )
        let active = try await client.apply(
            identity: identity,
            corefile: corefile(),
            ingressBindings: [ingress],
            policyPlan: policy
        )
        XCTAssertEqual(active.identity, identity)
        XCTAssertTrue(active.url.path.hasSuffix("/active/Corefile"))
        XCTAssertEqual(active.sha256.count, 64)
        XCTAssertEqual(active.policySHA256, policy.sha256)
        XCTAssertTrue(active.policyActive)
        XCTAssertGreaterThan(active.inode, 0)
        let persisted = try store.status(identity: identity)
        XCTAssertEqual(persisted.ingressSHA256?.count, 64)
        XCTAssertEqual(ingressBroker.sha256(identity: identity), persisted.ingressSHA256)

        let status = try await client.status(identity: identity)
        XCTAssertEqual(status.disposition, .active)
        XCTAssertEqual(status.activeCorefile, active)
        XCTAssertEqual(
            status.activeCorefile?.policySHA256,
            policy.sha256
        )

        try await client.remove(identity: identity)
        let removedStatus = try await client.status(identity: identity)
        XCTAssertEqual(
            removedStatus.disposition,
            .absent
        )
        XCTAssertFalse(ingressBroker.hasActiveBindings)
        XCTAssertTrue(try store.activeIngressConfigurations().isEmpty)
        try await client.close()
        try await serverTask.value
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtime.socketURL.path
            )
        )
    }

    func testRealHelperSubprocessBootstrapsAndCleansPrivateSocket()
        async throws {
        let helperURL = Bundle(for: NetworkHelperClientTests.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent(
            "hostwright-network-helper",
            isDirectory: false
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: helperURL.path)
        )

        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtimeURL = parent.appendingPathComponent(
            "runtime",
            isDirectory: true
        )
        let client = NetworkHelperClient(
            configuration: NetworkHelperClientConfiguration(
                executableURL: helperURL,
                runtimeDirectoryURL: runtimeURL,
                launchTimeoutMilliseconds: 3_000,
                requestTimeoutMilliseconds: 1_000,
                helperIdleTimeoutMilliseconds: 250
            ),
            executableValidator: NetworkHelperExecutableValidator { _ in },
            peerAuthenticator: NetworkHelperServerPeerAuthenticator {
                descriptor, expectedProcessID in
                let processID =
                    try NetworkHelperPeerSecurity.validateSameUser(
                        connectionDescriptor: descriptor
                    )
                guard processID == expectedProcessID else {
                    throw NetworkHelperCodeIdentityError.processMismatch
                }
            }
        )

        try await client.bootstrap()
        let socketURL = runtimeURL.appendingPathComponent(
            "network-helper.sock",
            isDirectory: false
        )
        XCTAssertEqual(mode(at: runtimeURL), 0o700)
        XCTAssertEqual(mode(at: socketURL), 0o600)
        try await client.close()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketURL.path)
        )
    }

    func testSecondClientAttachesToPersistentGuardedHostAccessHelper()
        async throws
    {
        guard let interfaceAddress =
                firstActiveNonLoopbackIPv4ForClient() else {
            throw XCTSkip(
                "No active non-loopback IPv4 interface is available."
            )
        }
        let target = try makeLoopbackTCPServerForClient()
        defer { Darwin.close(target.descriptor) }
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
        let store = try NetworkHelperStateStore(
            rootURL: runtimeURL.appendingPathComponent(
                "dns-state",
                isDirectory: true
            )
        )
        let server = NetworkHelperUnixServer(
            runtimeDirectory: runtime,
            dispatcher:
                NetworkHelperDispatcher(store: store),
            authenticator:
                NetworkHelperPeerAuthenticator {
                    descriptor in
                    _ = try NetworkHelperPeerSecurity
                        .validateSameUser(
                            connectionDescriptor: descriptor
                        )
                },
            idleTimeoutMilliseconds: 250
        )
        let serverTask = Task.detached {
            try server.run()
        }
        let socketURL = runtimeURL.appendingPathComponent(
            "network-helper.sock",
            isDirectory: false
        )
        let startupDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(
            atPath: socketURL.path
        ),
        Date() < startupDeadline {
            try await Task.sleep(
                nanoseconds: 10_000_000
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: socketURL.path
            )
        )
        let configuration = NetworkHelperClientConfiguration(
            executableURL: URL(
                fileURLWithPath: "/bin/sleep"
            ),
            runtimeDirectoryURL: runtimeURL,
            launchTimeoutMilliseconds: 3_000,
            requestTimeoutMilliseconds: 1_000,
            helperIdleTimeoutMilliseconds: 250
        )
        let authenticator =
            NetworkHelperServerPeerAuthenticator {
                descriptor, expectedProcessID in
                let processID =
                    try NetworkHelperPeerSecurity
                        .validateSameUser(
                            connectionDescriptor: descriptor
                        )
                if let expectedProcessID,
                   processID != expectedProcessID {
                    throw NetworkHelperCodeIdentityError
                        .processMismatch
                }
            }
        let first = NetworkHelperClient(
            configuration: configuration,
            executableValidator:
                NetworkHelperExecutableValidator { _ in },
            peerAuthenticator: authenticator,
            launcher: NetworkHelperProcessLauncher { _ in
                throw NetworkHelperClientError.launchFailed
            }
        )
        let identity = NetworkHelperDNSIdentity(
            projectUUID: projectUUID,
            dnsUUID: dnsUUID,
            generation: 1,
            fencingToken: fence
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
        let active = try await first.apply(
            identity: identity,
            corefile: corefile(),
            hostAccessBindings: [binding]
        )
        XCTAssertNotNil(active.hostAccessSHA256)
        try await first.close()

        let second = NetworkHelperClient(
            configuration: configuration,
            executableValidator:
                NetworkHelperExecutableValidator { _ in },
            peerAuthenticator: authenticator,
            launcher: NetworkHelperProcessLauncher { _ in
                throw NetworkHelperClientError.launchFailed
            }
        )
        let attached = try await second.status(
            identity: identity
        )
        XCTAssertEqual(attached.disposition, .active)
        XCTAssertEqual(
            attached.activeCorefile?.hostAccessSHA256,
            active.hostAccessSHA256
        )
        try await second.remove(identity: identity)
        try await second.close()

        try await serverTask.value
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: socketURL.path
            )
        )
    }

    private func corefile() -> String {
        """
        \(projectUUID).hostwright.internal {
            cache 5
            hosts {
                192.0.2.10 api.\(projectUUID).hostwright.internal
                fallthrough
            }
        }
        """
    }

    private func makePrivateParent() throws -> URL {
        let identifier = UUID().uuidString
            .lowercased()
            .prefix(8)
        let url = URL(
            fileURLWithPath: "/private/tmp/hwnc-\(identifier)",
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
}

private func reserveLoopbackPortForClient() throws -> Int {
    let listener = try makeLoopbackTCPServerForClient()
    Darwin.close(listener.descriptor)
    return listener.port
}

private func firstActiveNonLoopbackIPv4ForClient() -> String? {
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
        return String(
            decoding: buffer
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
    return nil
}

private func makeLoopbackTCPServerForClient() throws
    -> (descriptor: Int32, port: Int)
{
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NetworkHelperClientError.socketUnavailable
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
        throw NetworkHelperClientError.socketUnavailable
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bound == 0,
          Darwin.listen(descriptor, 4) == 0 else {
        throw NetworkHelperClientError.socketUnavailable
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
        throw NetworkHelperClientError.socketUnavailable
    }
    succeeded = true
    return (
        descriptor,
        Int(in_port_t(bigEndian: actual.sin_port))
    )
}
