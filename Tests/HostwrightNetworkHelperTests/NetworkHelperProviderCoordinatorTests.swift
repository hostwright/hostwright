import CryptoKit
import Darwin
import Foundation
import HostwrightNetworkProviders
import XCTest
@testable import HostwrightNetworkHelperCore

final class NetworkHelperProviderCoordinatorTests: XCTestCase {
    func testProductionTrustDirectoryAcceptsPinnedSignerAndRejectsUntrustedSigner()
        async throws
    {
        try await withFixture { fixture in
            let trustedSigner = try ProviderCMSSigner(
                commonName: "Hostwright Trusted Provider"
            )
            try fixture.pinTrustedSigner(trustedSigner.certificateDER)
            let coordinator = try fixture.productionCoordinator()

            let trustedDeclaration = try fixture.declaration(
                signer: trustedSigner.fingerprint
            )
            let accepted = try fixture.dispatch(
                coordinator: coordinator,
                invocation: fixture.invocation(
                    operation: .setup,
                    declaration: trustedDeclaration,
                    detachedCMS: try trustedSigner.sign(
                        trustedDeclaration
                    )
                )
            )
            XCTAssertNil(accepted.error)
            XCTAssertTrue(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )

            let untrustedSigner = try ProviderCMSSigner(
                commonName: "Hostwright Untrusted Provider"
            )
            let untrustedDeclaration = try fixture.declaration(
                signer: untrustedSigner.fingerprint
            )
            let rejected = try fixture.dispatch(
                coordinator: coordinator,
                invocation: fixture.invocation(
                    operation: .status,
                    declaration: untrustedDeclaration,
                    detachedCMS: try untrustedSigner.sign(
                        untrustedDeclaration
                    )
                )
            )
            XCTAssertEqual(rejected.error?.code, .providerRejected)
        }
    }

    func testDispatcherInvokesProviderWithExactReviewedGrant()
        async throws
    {
        try await withFixture { fixture in
            let broker = RecordingProviderBroker()
            let coordinator = try fixture.coordinator(
                broker: broker,
                executor: RespondingProviderExecutor(
                    brokerRequests: [
                        TestBrokerRequest(
                            kind: .https,
                            scope: "https://127.0.0.1:9443",
                            request: Data("probe".utf8)
                        ),
                        TestBrokerRequest(
                            kind: .secretReference,
                            scope: "secret:relay-token",
                            request: Data()
                        )
                    ]
                )
            )
            let response = try fixture.dispatch(
                coordinator: coordinator,
                invocation: fixture.invocation(operation: .setup)
            )

            XCTAssertNil(response.error)
            XCTAssertEqual(
                response.providerResult?.payload,
                ["result": "ok"]
            )
            XCTAssertTrue(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )
            let calls = await broker.calls
            XCTAssertEqual(
                calls,
                [
                    "https:https://127.0.0.1:9443:probe",
                    "secret:secret:relay-token"
                ]
            )
        }
    }

    func testDispatcherRejectsBrokerScopeOutsideExactGrant()
        async throws
    {
        try await withFixture { fixture in
            let broker = RecordingProviderBroker()
            let coordinator = try fixture.coordinator(
                broker: broker,
                executor: RespondingProviderExecutor(
                    brokerRequests: [
                        TestBrokerRequest(
                            kind: .route,
                            scope: "route:other-project",
                            request: Data("route".utf8)
                        )
                    ]
                )
            )
            let response = try fixture.dispatch(
                coordinator: coordinator,
                invocation: fixture.invocation(operation: .setup)
            )

            XCTAssertEqual(response.error?.code, .providerRejected)
            XCTAssertFalse(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )
            let calls = await broker.calls
            XCTAssertEqual(calls, [])
        }
    }

    func testRevocationIsDurableBeforeAuthorityStopsAndSurvivesRestart()
        async throws
    {
        try await withFixture { fixture in
            let coordinator = try fixture.coordinator()
            let setup = try fixture.dispatch(
                coordinator: coordinator,
                invocation: fixture.invocation(operation: .setup)
            )
            XCTAssertNil(setup.error)
            XCTAssertTrue(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )

            let revoked = try fixture.dispatchRevocation(
                coordinator: coordinator
            )
            XCTAssertNil(revoked.error)
            XCTAssertFalse(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )

            let restarted = try fixture.coordinator()
            XCTAssertFalse(
                try restarted.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )
            let rejected = try fixture.dispatch(
                coordinator: restarted,
                invocation: fixture.invocation(operation: .status)
            )
            XCTAssertEqual(rejected.error?.code, .providerRejected)
            let setupRejected = try fixture.dispatch(
                coordinator: restarted,
                invocation: fixture.invocation(operation: .setup)
            )
            XCTAssertEqual(
                setupRejected.error?.code,
                .providerRejected
            )
        }
    }

    func testAuthoritiesAndTeardownAreScopedByProjectIdentity()
        async throws
    {
        try await withFixture { fixture in
            let coordinator = try fixture.coordinator()
            let peerIdentity = fixture.peerIdentity()
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: fixture.identity,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )
            let restarted = try fixture.coordinator()
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: restarted,
                    identity: fixture.identity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: restarted,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error
            )

            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: restarted,
                    identity: fixture.identity,
                    invocation:
                        fixture.invocation(operation: .teardown)
                ).error
            )
            XCTAssertEqual(
                try fixture.dispatch(
                    coordinator: restarted,
                    identity: fixture.identity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error?.code,
                .providerRejected
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: restarted,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error
            )
        }
    }

    func testRevocationRequiresExactActiveProjectIdentity()
        async throws
    {
        try await withFixture { fixture in
            let coordinator = try fixture.coordinator()
            let peerIdentity = fixture.peerIdentity()
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )

            XCTAssertEqual(
                try fixture.dispatchRevocation(
                    coordinator: coordinator,
                    identity: fixture.identity
                ).error?.code,
                .providerRejected
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatchRevocation(
                    coordinator: coordinator,
                    identity: peerIdentity
                ).error
            )
        }
    }

    func testRevocationRemovesOnlyExactProjectAuthority()
        async throws
    {
        try await withFixture { fixture in
            let coordinator = try fixture.coordinator()
            let peerIdentity = fixture.peerIdentity()
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: fixture.identity,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )

            XCTAssertNil(
                try fixture.dispatchRevocation(
                    coordinator: coordinator,
                    identity: fixture.identity
                ).error
            )
            XCTAssertEqual(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: fixture.identity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error?.code,
                .providerRejected
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .teardown)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    identity: peerIdentity,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error
            )
        }
    }

    func testRestartRecoversCrashAfterDurableRevokeBeforeStop()
        async throws
    {
        try await withFixture { fixture in
            let coordinator = try fixture.coordinator()
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )

            let durableRevocations =
                try FileBackedNetworkProviderRevocationStore(
                    directoryURL: fixture.providerStateRoot
                        .appendingPathComponent(
                            "revocations",
                            isDirectory: true
                        )
                )
            try await durableRevocations.revoke(
                identifier: fixture.identifier,
                moduleSHA256: fixture.moduleSHA256,
                at: Date(timeIntervalSince1970: 1_000)
            )
            XCTAssertTrue(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )

            let recovered = try fixture.coordinator()
            XCTAssertFalse(
                try recovered.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )
        }
    }

    func testRestartMigratesCanonicalV1StateAndRequiresExactSetup()
        async throws
    {
        try await withFixture { fixture in
            try fixture.prepareProviderStateRoot()
            let revokedIdentifier = "revoked.example"
            let revokedModuleSHA256 = String(repeating: "f", count: 64)
            let revocations =
                try FileBackedNetworkProviderRevocationStore(
                    directoryURL: fixture.providerStateRoot
                        .appendingPathComponent(
                            "revocations",
                            isDirectory: true
                        )
                )
            try await revocations.revoke(
                identifier: revokedIdentifier,
                moduleSHA256: revokedModuleSHA256,
                at: Date(timeIntervalSince1970: 1_000)
            )
            let revocationState = try Data(
                contentsOf: fixture.revocationStateURL
            )
            try fixture.writeLegacyProviderState()

            let executor = RecordingProviderExecutor()
            let migrated = try fixture.coordinator(executor: executor)

            XCTAssertFalse(migrated.hasActiveAuthorities)
            XCTAssertFalse(
                try migrated.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )
            XCTAssertEqual(
                try Data(contentsOf: fixture.authorityStateURL),
                Data(#"{"authorities":[],"schemaVersion":2}"#.utf8)
            )
            XCTAssertEqual(
                try Data(contentsOf: fixture.revocationStateURL),
                revocationState
            )
            let reopenedRevocations =
                try FileBackedNetworkProviderRevocationStore(
                    directoryURL: fixture.providerStateRoot
                        .appendingPathComponent(
                            "revocations",
                            isDirectory: true
                        )
                )
            let revocationPreserved =
                try await reopenedRevocations.isRevoked(
                    identifier: revokedIdentifier,
                    moduleSHA256: revokedModuleSHA256
                )
            XCTAssertTrue(
                revocationPreserved
            )

            let rejected = try fixture.dispatch(
                coordinator: migrated,
                invocation: fixture.invocation(operation: .status)
            )
            XCTAssertEqual(rejected.error?.code, .providerRejected)
            let migratedOperations = await executor.operations()
            XCTAssertEqual(migratedOperations, [])

            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: migrated,
                    invocation: fixture.invocation(operation: .setup)
                ).error
            )

            let restartedExecutor = RecordingProviderExecutor()
            let restarted = try fixture.coordinator(
                executor: restartedExecutor
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: restarted,
                    invocation: fixture.invocation(operation: .status)
                ).error
            )
            let restartedOperations = await restartedExecutor.operations()
            XCTAssertEqual(restartedOperations, [.status])
        }
    }

    func testWorkerCrashDoesNotActivateAuthorityOrLeakTemporaryState()
        async throws
    {
        try await withFixture { fixture in
            let coordinator = try fixture.coordinator(
                executor: CrashingProviderExecutor()
            )
            let before = try fixture.providerInventory()
            let response = try fixture.dispatch(
                coordinator: coordinator,
                invocation: fixture.invocation(operation: .setup)
            )

            XCTAssertEqual(response.error?.code, .providerRejected)
            XCTAssertFalse(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )
            XCTAssertEqual(try fixture.providerInventory(), before)
        }
    }

    func testOperationsRequireExactActiveAuthorityBeforeExecution()
        async throws
    {
        try await withFixture { fixture in
            let executor = RecordingProviderExecutor()
            let coordinator = try fixture.coordinator(
                executor: executor
            )
            for operation in NetworkProviderOperation.allCases
                where operation != .setup {
                let response = try fixture.dispatch(
                    coordinator: coordinator,
                    invocation:
                        fixture.invocation(operation: operation)
                )
                XCTAssertEqual(
                    response.error?.code,
                    .providerRejected,
                    "\(operation.rawValue) executed without active authority"
                )
            }
            let rejectedOperations = await executor.operations()
            XCTAssertEqual(rejectedOperations, [])

            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )
            let replacedSignerDeclaration = try fixture.declaration(
                signer:
                    "sha256:\(String(repeating: "b", count: 64))"
            )
            let replacedSigner = try fixture.dispatch(
                coordinator: coordinator,
                invocation: fixture.invocation(
                    operation: .status,
                    declaration: replacedSignerDeclaration,
                    detachedCMS: Data("detached-cms".utf8)
                )
            )
            XCTAssertEqual(
                replacedSigner.error?.code,
                .providerRejected
            )
            let signerRejectedOperations = await executor.operations()
            XCTAssertEqual(signerRejectedOperations, [.setup])

            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    invocation:
                        fixture.invocation(operation: .status)
                ).error
            )
            let authorizedOperations = await executor.operations()
            XCTAssertEqual(authorizedOperations, [.setup, .status])
        }
    }

    func testTeardownRemovesOnlyExactActiveAuthority()
        async throws
    {
        try await withFixture { fixture in
            let coordinator = try fixture.coordinator()
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    invocation:
                        fixture.invocation(operation: .setup)
                ).error
            )
            XCTAssertNil(
                try fixture.dispatch(
                    coordinator: coordinator,
                    invocation:
                        fixture.invocation(operation: .teardown)
                ).error
            )
            XCTAssertFalse(
                try coordinator.hasAuthority(
                    identifier: fixture.identifier,
                    moduleSHA256: fixture.moduleSHA256
                )
            )
            XCTAssertFalse(
                try fixture.providerInventory().contains {
                    $0.hasPrefix(".authority-")
                }
            )
        }
    }

    private func withFixture(
        _ body: (ProviderFixture) async throws -> Void
    ) async throws {
        let root = URL(
            fileURLWithPath:
                "/private/tmp/hwnp-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        XCTAssertEqual(mkdir(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(try ProviderFixture(root: root))
    }
}

private struct ProviderFixture {
    let root: URL
    let dnsStore: NetworkHelperStateStore
    let identity: NetworkHelperDNSIdentity
    let module = Data("provider-module".utf8)
    let identifier = "example.reference"

    init(root: URL) throws {
        self.root = root
        dnsStore = try NetworkHelperStateStore(
            rootURL: root.appendingPathComponent(
                "dns-state",
                isDirectory: true
            )
        )
        identity = NetworkHelperDNSIdentity(
            projectUUID: UUID().uuidString.lowercased(),
            dnsUUID: UUID().uuidString.lowercased(),
            generation: 1,
            fencingToken: UUID().uuidString.lowercased()
        )
    }

    var providerStateRoot: URL {
        root.appendingPathComponent(
            "provider-state",
            isDirectory: true
        )
    }

    var authorityStateURL: URL {
        providerStateRoot.appendingPathComponent(
            "authority.json",
            isDirectory: false
        )
    }

    var revocationStateURL: URL {
        providerStateRoot
            .appendingPathComponent(
                "revocations",
                isDirectory: true
            )
            .appendingPathComponent(
                "network-provider-revocations.json",
                isDirectory: false
            )
    }

    var moduleSHA256: String {
        SHA256.hash(data: module)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var declaration: Data {
        get throws {
            try declaration(
                signer:
                    "sha256:\(String(repeating: "a", count: 64))"
            )
        }
    }

    func declaration(signer: String) throws -> Data {
        try canonicalJSON(
            NetworkProviderDeclaration(
                identifier: identifier,
                kind: .tunnelProvider,
                moduleSHA256: moduleSHA256,
                signer: signer
            )
        )
    }

    func productionCoordinator(
        broker: (any NetworkProviderBroker)? = nil,
        executor: any NetworkProviderWasmExecutor =
            RespondingProviderExecutor()
    ) throws -> NetworkHelperProviderCoordinator {
        try NetworkHelperProviderCoordinator(
            stateRootURL: providerStateRoot,
            executor: executor,
            broker: broker ?? RecordingProviderBroker()
        )
    }

    func coordinator(
        broker: (any NetworkProviderBroker)? = nil,
        executor: any NetworkProviderWasmExecutor =
            RespondingProviderExecutor()
    ) throws -> NetworkHelperProviderCoordinator {
        try NetworkHelperProviderCoordinator(
            stateRootURL: providerStateRoot,
            verifier: AcceptingProviderVerifier(),
            executor: executor,
            broker: broker ?? RecordingProviderBroker()
        )
    }

    func invocation(
        operation: NetworkProviderOperation
    ) throws -> NetworkHelperProviderInvocation {
        try invocation(
            operation: operation,
            declaration: declaration,
            detachedCMS: Data("detached-cms".utf8)
        )
    }

    func invocation(
        operation: NetworkProviderOperation,
        declaration: Data,
        detachedCMS: Data
    ) throws -> NetworkHelperProviderInvocation {
        let reviewedDeclaration = try JSONDecoder().decode(
            NetworkProviderDeclaration.self,
            from: declaration
        )
        return NetworkHelperProviderInvocation(
            declaration: declaration,
            detachedCMS: detachedCMS,
            module: module,
            grant: NetworkProviderGrant(
                identifier: identifier,
                kind: .tunnelProvider,
                moduleSHA256: reviewedDeclaration.moduleSHA256,
                signer: reviewedDeclaration.signer,
                allowedHTTPSOrigins: ["https://127.0.0.1:9443"],
                secretReferences: ["secret:relay-token"],
                identityScopes: ["identity:project-a"],
                routeScopes: ["route:project-a"],
                approvedBy: "reviewer",
                expiresAt: .distantFuture
            ),
            operation: operation
        )
    }

    func pinTrustedSigner(_ certificateDER: Data) throws {
        try prepareProviderStateRoot()
        let trustRoot = providerStateRoot.appendingPathComponent(
            NetworkHelperProviderTrustStore.directoryName,
            isDirectory: true
        )
        if mkdir(trustRoot.path, 0o700) != 0,
           errno != EEXIST {
            throw ProviderCMSTestError.fileOperationFailed
        }
        let digest = SHA256.hash(data: certificateDER)
            .map { String(format: "%02x", $0) }
            .joined()
        let certificateURL = trustRoot.appendingPathComponent(
            "\(digest).der",
            isDirectory: false
        )
        let descriptor = open(
            certificateURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw ProviderCMSTestError.fileOperationFailed
        }
        defer { close(descriptor) }
        try certificateDER.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw ProviderCMSTestError.fileOperationFailed
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ProviderCMSTestError.fileOperationFailed
        }
    }

    func prepareProviderStateRoot() throws {
        if mkdir(providerStateRoot.path, 0o700) != 0,
           errno != EEXIST {
            throw ProviderCMSTestError.fileOperationFailed
        }
    }

    func writeLegacyProviderState() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let state = LegacyProviderState(
            schemaVersion: 1,
            authorities: [
                LegacyProviderAuthority(
                    identifier: identifier,
                    moduleSHA256: moduleSHA256,
                    kind: .tunnelProvider,
                    identity: identity,
                    activatedAt: Date(timeIntervalSince1970: 500)
                )
            ]
        )
        try writeProviderState(try encoder.encode(state))
    }

    private func writeProviderState(_ data: Data) throws {
        let descriptor = open(
            authorityStateURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw ProviderCMSTestError.fileOperationFailed
        }
        var retainedError: Error?
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        throw ProviderCMSTestError.fileOperationFailed
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw ProviderCMSTestError.fileOperationFailed
            }
        } catch {
            retainedError = error
        }
        guard close(descriptor) == 0, retainedError == nil else {
            throw retainedError ?? ProviderCMSTestError.fileOperationFailed
        }
    }

    func dispatch(
        coordinator: NetworkHelperProviderCoordinator,
        invocation: NetworkHelperProviderInvocation
    ) throws -> NetworkHelperResponse {
        try dispatch(
            coordinator: coordinator,
            identity: identity,
            invocation: invocation
        )
    }

    func dispatch(
        coordinator: NetworkHelperProviderCoordinator,
        identity: NetworkHelperDNSIdentity,
        invocation: NetworkHelperProviderInvocation
    ) throws -> NetworkHelperResponse {
        try dispatch(
            NetworkHelperDispatcher(
                store: dnsStore,
                providerCoordinator: coordinator
            ),
            NetworkHelperRequest(
                operation: .providerInvoke,
                identity: identity,
                providerInvocation: invocation
            )
        )
    }

    func dispatchRevocation(
        coordinator: NetworkHelperProviderCoordinator
    ) throws -> NetworkHelperResponse {
        try dispatchRevocation(
            coordinator: coordinator,
            identity: identity
        )
    }

    func dispatchRevocation(
        coordinator: NetworkHelperProviderCoordinator,
        identity: NetworkHelperDNSIdentity
    ) throws -> NetworkHelperResponse {
        try dispatch(
            NetworkHelperDispatcher(
                store: dnsStore,
                providerCoordinator: coordinator
            ),
            NetworkHelperRequest(
                operation: .providerRevoke,
                identity: identity,
                providerRevocation:
                    NetworkHelperProviderRevocation(
                        identifier: identifier,
                        moduleSHA256: moduleSHA256
                    )
            )
        )
    }

    func peerIdentity() -> NetworkHelperDNSIdentity {
        NetworkHelperDNSIdentity(
            projectUUID: UUID().uuidString.lowercased(),
            dnsUUID: UUID().uuidString.lowercased(),
            generation: 1,
            fencingToken: UUID().uuidString.lowercased()
        )
    }

    func providerInventory() throws -> Set<String> {
        guard FileManager.default.fileExists(
            atPath: providerStateRoot.path
        ) else {
            return []
        }
        return Set(
            try FileManager.default.subpathsOfDirectory(
                atPath: providerStateRoot.path
            )
        )
    }

    private func dispatch(
        _ dispatcher: NetworkHelperDispatcher,
        _ request: NetworkHelperRequest
    ) throws -> NetworkHelperResponse {
        try NetworkHelperCanonicalJSON.decodeFrame(
            NetworkHelperResponse.self,
            from: dispatcher.dispatch(
                frame: try NetworkHelperCanonicalJSON.frame(request)
            )
        )
    }
}

private struct LegacyProviderState: Codable {
    let schemaVersion: Int
    let authorities: [LegacyProviderAuthority]
}

private struct LegacyProviderAuthority: Codable {
    let identifier: String
    let moduleSHA256: String
    let kind: NetworkProviderKind
    let identity: NetworkHelperDNSIdentity
    let activatedAt: Date
}

private struct AcceptingProviderVerifier: DetachedCMSVerifier {
    func verifyDetachedCMS(
        signature: Data,
        content: Data,
        trustedSigner: String
    ) throws {
        guard signature == Data("detached-cms".utf8),
              !content.isEmpty,
              trustedSigner.hasPrefix("sha256:") else {
            throw NetworkProviderError.untrustedSignature
        }
    }
}

private struct RespondingProviderExecutor:
    NetworkProviderWasmExecutor
{
    let brokerRequests: [TestBrokerRequest]

    init(brokerRequests: [TestBrokerRequest] = []) {
        self.brokerRequests = brokerRequests
    }

    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        let request = try JSONDecoder().decode(
            TestProviderRequest.self,
            from: stdin
        )
        return try canonicalJSON(
            TestProviderResponse(
                version: 1,
                nonce: request.nonce,
                operation: request.operation,
                status: "ok",
                payload: ["result": "ok"],
                brokerRequests:
                    brokerRequests.isEmpty ? nil : brokerRequests
            )
        )
    }
}

private struct CrashingProviderExecutor:
    NetworkProviderWasmExecutor
{
    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        throw NetworkProviderError.executionFailed
    }
}

private actor RecordingProviderExecutor:
    NetworkProviderWasmExecutor
{
    private var recordedOperations: [NetworkProviderOperation] = []

    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        let request = try JSONDecoder().decode(
            TestProviderRequest.self,
            from: stdin
        )
        recordedOperations.append(request.operation)
        return try canonicalJSON(
            TestProviderResponse(
                version: 1,
                nonce: request.nonce,
                operation: request.operation,
                status: "ok",
                payload: ["result": "ok"],
                brokerRequests: nil
            )
        )
    }

    func operations() -> [NetworkProviderOperation] {
        recordedOperations
    }
}

private actor RecordingProviderBroker: NetworkProviderBroker {
    private(set) var calls: [String] = []

    func https(origin: String, request: Data) async throws -> Data {
        calls.append(
            "https:\(origin):\(String(decoding: request, as: UTF8.self))"
        )
        return Data("ok".utf8)
    }

    func secretReference(
        _ reference: String
    ) async throws -> NetworkProviderSecretHandle {
        calls.append("secret:\(reference)")
        return NetworkProviderSecretHandle(identifier: "opaque-handle")
    }

    func identity(scope: String, request: Data) async throws -> Data {
        calls.append("identity:\(scope)")
        return Data()
    }

    func route(scope: String, request: Data) async throws -> Data {
        calls.append("route:\(scope)")
        return Data()
    }
}

private struct TestProviderRequest: Codable {
    let version: Int
    let nonce: String
    let operation: NetworkProviderOperation
    let payload: [String: String]
}

private struct TestProviderResponse: Codable {
    let version: Int
    let nonce: String
    let operation: NetworkProviderOperation
    let status: String
    let payload: [String: String]
    let brokerRequests: [TestBrokerRequest]?
}

private struct TestBrokerRequest: Codable {
    let kind: NetworkProviderBrokerRequestKind
    let scope: String
    let request: Data
}

private final class ProviderCMSSigner {
    let certificateDER: Data
    private let root: URL
    private let keyURL: URL
    private let certificateURL: URL

    var fingerprint: String {
        "sha256:" + SHA256.hash(data: certificateDER)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init(commonName: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-helper-cms-\(UUID().uuidString)",
                isDirectory: true
            )
        keyURL = root.appendingPathComponent("key.pem")
        certificateURL = root.appendingPathComponent("certificate.pem")
        let certificateDERURL =
            root.appendingPathComponent("certificate.der")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        do {
            try Self.runOpenSSL(
                [
                    "req",
                    "-new",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    keyURL.path,
                    "-out",
                    certificateURL.path,
                    "-subj",
                    "/CN=\(commonName)",
                    "-days",
                    "1",
                    "-sha256"
                ]
            )
            try Self.runOpenSSL(
                [
                    "x509",
                    "-in",
                    certificateURL.path,
                    "-outform",
                    "DER",
                    "-out",
                    certificateDERURL.path
                ]
            )
            certificateDER = try Data(contentsOf: certificateDERURL)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func sign(_ content: Data) throws -> Data {
        let contentURL = root.appendingPathComponent(
            "content-\(UUID().uuidString).json"
        )
        let signatureURL = root.appendingPathComponent(
            "signature-\(UUID().uuidString).der"
        )
        defer {
            try? FileManager.default.removeItem(at: contentURL)
            try? FileManager.default.removeItem(at: signatureURL)
        }
        try content.write(to: contentURL)
        try Self.runOpenSSL(
            [
                "smime",
                "-sign",
                "-binary",
                "-in",
                contentURL.path,
                "-signer",
                certificateURL.path,
                "-inkey",
                keyURL.path,
                "-outform",
                "DER",
                "-out",
                signatureURL.path
            ]
        )
        return try Data(contentsOf: signatureURL)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/openssl"
        )
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw ProviderCMSTestError.opensslFailed
        }
    }
}

private enum ProviderCMSTestError: Error {
    case fileOperationFailed
    case opensslFailed
}

private func canonicalJSON<Value: Encodable>(
    _ value: Value
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
