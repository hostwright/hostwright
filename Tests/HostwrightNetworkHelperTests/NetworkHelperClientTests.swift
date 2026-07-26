import Darwin
import Foundation
import HostwrightRuntime
import Security
import XCTest
@testable import HostwrightNetworkHelperCore

final class NetworkHelperClientTests: XCTestCase {
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
        let server = NetworkHelperUnixServer(
            runtimeDirectory: runtime,
            dispatcher: NetworkHelperDispatcher(store: store),
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
                return NetworkHelperProcessLease(process: process)
            }
        )
        let identity = NetworkHelperDNSIdentity(
            projectUUID: projectUUID,
            dnsUUID: dnsUUID,
            generation: 1,
            fencingToken: fence
        )
        let active = try await client.apply(
            identity: identity,
            corefile: corefile()
        )
        XCTAssertEqual(active.identity, identity)
        XCTAssertTrue(active.url.path.hasSuffix("/active/Corefile"))
        XCTAssertEqual(active.sha256.count, 64)
        XCTAssertGreaterThan(active.inode, 0)

        let status = try await client.status(identity: identity)
        XCTAssertEqual(status.disposition, .active)
        XCTAssertEqual(status.activeCorefile, active)

        try await client.remove(identity: identity)
        let removedStatus = try await client.status(identity: identity)
        XCTAssertEqual(
            removedStatus.disposition,
            .absent
        )
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
