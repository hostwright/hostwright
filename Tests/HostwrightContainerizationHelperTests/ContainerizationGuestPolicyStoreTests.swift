import CryptoKit
import Darwin
import HostwrightNetworking
import HostwrightRuntime
import XCTest
@testable import HostwrightContainerizationHelper

final class ContainerizationGuestPolicyStoreTests: XCTestCase {
    func testPrepareUpdateAndExactRemovalUsePrivateOwnedFiles() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent(
            "guest-policies",
            isDirectory: true
        )
        let loader = Data("linux-arm64-loader".utf8)
        let store = try ContainerizationGuestPolicyStore(
            rootURL: root,
            asset: ContainerizationGuestPolicyAsset(
                validatedData: loader
            )
        )
        let request = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: try policy(generation: 1),
            workingDirectory: "/"
        )

        let share = try store.prepareShare(
            resourceIdentifier: "project-api-1",
            request: request
        )

        XCTAssertEqual(
            try Data(
                contentsOf: share.appendingPathComponent(
                    "hostwright-netfilter"
                )
            ),
            loader
        )
        let persistedRequest = try JSONDecoder().decode(
            ContainerizationGuestNetworkPolicyLoaderRequest.self,
            from: Data(
                contentsOf: share.appendingPathComponent(
                    "bootstrap-policy.json"
                )
            )
        )
        XCTAssertEqual(persistedRequest, request)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ContainerizationGuestNetworkPolicyLoaderRequest.self,
                from: Data(
                    contentsOf: share.appendingPathComponent(
                        "network-policy.json"
                    )
                )
            ),
            request
        )
        XCTAssertEqual(try mode(share), 0o700)
        XCTAssertEqual(
            try mode(
                share.appendingPathComponent("hostwright-netfilter")
            ),
            0o500
        )
        XCTAssertEqual(
            try mode(
                share.appendingPathComponent("bootstrap-policy.json")
            ),
            0o400
        )
        XCTAssertEqual(
            try mode(
                share.appendingPathComponent("network-policy.json")
            ),
            0o400
        )

        let updated = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: try policy(generation: 2)
        )
        try store.writeUpdateRequest(
            updated,
            resourceIdentifier: "project-api-1"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ContainerizationGuestNetworkPolicyLoaderRequest.self,
                from: Data(
                    contentsOf: share.appendingPathComponent(
                        "network-policy.json"
                    )
                )
            ),
            updated
        )

        try store.removeShare(resourceIdentifier: "project-api-1")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: share.path)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ),
            []
        )
    }

    func testSameGenerationDifferentDigestIsRejectedWithoutChangingFile()
        throws
    {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationGuestPolicyStore(
            rootURL: parent.appendingPathComponent(
                "guest-policies",
                isDirectory: true
            ),
            asset: ContainerizationGuestPolicyAsset(
                validatedData: Data("loader".utf8)
            )
        )
        let first = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: try policy(generation: 1, port: 443)
        )
        let share = try store.prepareShare(
            resourceIdentifier: "project-api-1",
            request: first
        )
        let requestURL = share.appendingPathComponent(
            "bootstrap-policy.json"
        )
        let before = try Data(contentsOf: requestURL)
        let conflicting = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: try policy(generation: 1, port: 8443)
        )

        XCTAssertThrowsError(
            try store.writeUpdateRequest(
                conflicting,
                resourceIdentifier: "project-api-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestPolicyStoreError,
                .generationConflict
            )
        }
        XCTAssertEqual(try Data(contentsOf: requestURL), before)
    }

    func testRepeatedUpdatePreservesRequestFileInode() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationGuestPolicyStore(
            rootURL: parent.appendingPathComponent(
                "guest-policies",
                isDirectory: true
            ),
            asset: ContainerizationGuestPolicyAsset(
                validatedData: Data("loader".utf8)
            )
        )
        let bootstrap = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: try policy(generation: 1)
        )
        let share = try store.prepareShare(
            resourceIdentifier: "project-api-1",
            request: bootstrap
        )
        let requestURL = share.appendingPathComponent(
            "network-policy.json"
        )
        let inodeBefore = try inode(requestURL)
        let first = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: try policy(generation: 2, port: 8443)
        )
        try store.writeUpdateRequest(
            first,
            resourceIdentifier: "project-api-1"
        )
        XCTAssertEqual(try inode(requestURL), inodeBefore)

        let second = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .remove,
            policy: try policy(generation: 3, port: 9443)
        )
        try store.writeUpdateRequest(
            second,
            resourceIdentifier: "project-api-1"
        )

        XCTAssertEqual(try inode(requestURL), inodeBefore)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ContainerizationGuestNetworkPolicyLoaderRequest.self,
                from: Data(contentsOf: requestURL)
            ),
            second
        )
        XCTAssertEqual(try mode(requestURL), 0o400)
    }

    func testUpdateRefusesReplacedRequestPath() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationGuestPolicyStore(
            rootURL: parent.appendingPathComponent(
                "guest-policies",
                isDirectory: true
            ),
            asset: ContainerizationGuestPolicyAsset(
                validatedData: Data("loader".utf8)
            )
        )
        let share = try store.prepareShare(
            resourceIdentifier: "project-api-1",
            request: ContainerizationGuestNetworkPolicyLoaderRequest(
                operation: .apply,
                policy: try policy(generation: 1)
            )
        )
        let requestURL = share.appendingPathComponent(
            "network-policy.json"
        )
        XCTAssertEqual(unlink(requestURL.path), 0)
        XCTAssertEqual(symlink("/etc/passwd", requestURL.path), 0)

        XCTAssertThrowsError(
            try store.writeUpdateRequest(
                ContainerizationGuestNetworkPolicyLoaderRequest(
                    operation: .apply,
                    policy: try policy(generation: 2)
                ),
                resourceIdentifier: "project-api-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestPolicyStoreError,
                .unsafeFile
            )
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: requestURL.path
            ),
            "/etc/passwd"
        )
    }

    func testRemovalRefusesUnexpectedFiles() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationGuestPolicyStore(
            rootURL: parent.appendingPathComponent(
                "guest-policies",
                isDirectory: true
            ),
            asset: ContainerizationGuestPolicyAsset(
                validatedData: Data("loader".utf8)
            )
        )
        let share = try store.prepareShare(
            resourceIdentifier: "project-api-1",
            request: ContainerizationGuestNetworkPolicyLoaderRequest(
                operation: .apply,
                policy: try policy(generation: 1)
            )
        )
        let unexpected = share.appendingPathComponent("unmanaged")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: unexpected.path,
                contents: Data("sentinel".utf8)
            )
        )

        XCTAssertThrowsError(
            try store.removeShare(resourceIdentifier: "project-api-1")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unexpected.path)
        )
    }

    private func policy(
        generation: Int,
        port: Int = 443
    ) throws -> ContainerizationGuestNetworkPolicy {
        try ContainerizationGuestNetworkPolicy(
            generation: generation,
            projectUUID:
                "22222222-2222-4222-8222-222222222222",
            serviceResourceUUID:
                "11111111-1111-4111-8111-111111111111",
            ingressDefault: .deny,
            egressDefault: .deny,
            dnsServers: ["1.1.1.1"],
            ingress: [
                try ContainerizationGuestNetworkPolicyRule(
                    address: "10.0.0.0/24",
                    port: port,
                    protocolName: .tcp
                )
            ],
            egress: []
        )
    }

    private func makePrivateParent() throws -> URL {
        let url = URL(
            fileURLWithPath:
                "/tmp/hostwright-guest-policy-\(getpid())-" +
                UUID().uuidString.lowercased(),
            isDirectory: true
        )
        guard mkdir(url.path, 0o700) == 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        return url
    }

    private func mode(_ url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        return metadata.st_mode & 0o777
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw ContainerizationGuestPolicyStoreError.operationFailed
        }
        return metadata.st_ino
    }
}
