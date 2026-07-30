import CryptoKit
import Foundation
import XCTest
@testable import HostwrightNetworkProviders

final class NetworkProviderSPITests: XCTestCase {
    func testSignedReferenceUsesOnlyExactBrokeredAuthorities() async throws {
        let module = Data("reference-wasm".utf8)
        let declaration = try declaration(for: module)
        let broker = RecordingBroker()
        let executor = Executor { input, sandbox in
            XCTAssertEqual(
                sandbox.memoryLimitBytes,
                NetworkProviderSandbox.maximumMemoryBytes
            )
            XCTAssertFalse(sandbox.directSockets)
            XCTAssertFalse(sandbox.preopenedFilesystem)
            XCTAssertFalse(sandbox.inheritedEnvironment)
            let request = try JSONDecoder().decode(TestRequest.self, from: input)
            return try canonicalJSON(
                TestResponse(
                    version: 1,
                    nonce: request.nonce,
                    operation: request.operation,
                    status: "ok",
                    payload: ["result": "ok"],
                    brokerRequests: [
                        TestBrokerRequest(
                            kind: .https,
                            scope: "https://127.0.0.1:9443",
                            request: Data("local-probe".utf8)
                        ),
                        TestBrokerRequest(
                            kind: .secretReference,
                            scope: "secret:relay-token",
                            request: Data()
                        ),
                        TestBrokerRequest(
                            kind: .identity,
                            scope: "identity:project-a",
                            request: Data("identity-request".utf8)
                        ),
                        TestBrokerRequest(
                            kind: .route,
                            scope: "route:project-a",
                            request: Data("route-request".utf8)
                        )
                    ]
                )
            )
        }
        let host = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declaration,
                expectedSigner: "local-test"
            ),
            executor: executor,
            revocations: Revocations(),
            broker: broker
        )

        let result = try await host.invoke(
            declaration: declaration,
            detachedCMS: Data("detached-cms".utf8),
            module: module,
            grant: grant(),
            operation: .setup
        )

        XCTAssertEqual(result, ["result": "ok"])
        let calls = await broker.recordedCalls
        let returnedSecretValues = await broker.returnedSecretValues
        XCTAssertEqual(
            calls,
            [
                "https:https://127.0.0.1:9443:local-probe",
                "secret:secret:relay-token",
                "identity:identity:project-a:identity-request",
                "route:route:project-a:route-request"
            ]
        )
        XCTAssertEqual(returnedSecretValues, [])
    }

    func testStrictDeclarationDigestSignatureAndGrantValidation() async throws {
        let module = Data("reference-wasm".utf8)
        let validDeclaration = try declaration(for: module)
        let executor = Executor { input, _ in
            let request = try JSONDecoder().decode(TestRequest.self, from: input)
            return try canonicalJSON(TestResponse.success(for: request))
        }
        let validHost = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: validDeclaration,
                expectedSigner: "local-test"
            ),
            executor: executor,
            revocations: Revocations()
        )

        let noncanonical = Data(
            String(decoding: validDeclaration, as: UTF8.self)
                .replacingOccurrences(of: "{", with: "{ ")
                .utf8
        )
        await assertProviderError(.invalidDeclaration) {
            try await validHost.invoke(
                declaration: noncanonical,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }

        let unknownField = Data(
            """
            {"apiVersion":1,"identifier":"example.reference","kind":"tunnelProvider","moduleSHA256":"\(digest(module))","signer":"local-test","unexpected":true}
            """.utf8
        )
        await assertProviderError(.invalidDeclaration) {
            try await validHost.invoke(
                declaration: unknownField,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }

        let wrongDigestDeclaration = try canonicalJSON(
            NetworkProviderDeclaration(
                identifier: "example.reference",
                kind: .tunnelProvider,
                moduleSHA256: String(repeating: "0", count: 64),
                signer: "local-test"
            )
        )
        let digestHost = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: wrongDigestDeclaration,
                expectedSigner: "local-test"
            ),
            executor: executor,
            revocations: Revocations()
        )
        await assertProviderError(.digestMismatch) {
            try await digestHost.invoke(
                declaration: wrongDigestDeclaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(
                    moduleSHA256: String(repeating: "0", count: 64)
                ),
                operation: .status
            )
        }

        let signatureHost = RestrictedNetworkProviderHost(
            verifier: RejectingVerifier(),
            executor: executor,
            revocations: Revocations()
        )
        await assertProviderError(.untrustedSignature) {
            try await signatureHost.invoke(
                declaration: validDeclaration,
                detachedCMS: Data("wrong-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }
        await assertProviderError(.untrustedSignature) {
            try await validHost.invoke(
                declaration: validDeclaration,
                detachedCMS: Data(),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }

        await assertProviderError(.expiredGrant) {
            try await validHost.invoke(
                declaration: validDeclaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(expiresAt: Date(timeIntervalSince1970: 1)),
                operation: .status,
                now: Date(timeIntervalSince1970: 2)
            )
        }
        await assertProviderError(.deniedGrant) {
            try await validHost.invoke(
                declaration: validDeclaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(identifier: "other.reference"),
                operation: .status
            )
        }
    }

    func testGrantCannotBeReusedByDifferentModuleOrSigner() async throws {
        let moduleA = Data("reference-wasm-a".utf8)
        let moduleB = Data("reference-wasm-b".utf8)
        let declarationB = try declaration(for: moduleB)
        let executions = Counter()
        let hostB = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declarationB,
                expectedSigner: "local-test"
            ),
            executor: Executor { _, _ in
                executions.increment()
                return Data()
            },
            revocations: Revocations()
        )
        let grantA = grant(moduleSHA256: digest(moduleA))
        let grantWire = try canonicalJSON(grantA)
        let grantObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: grantWire)
                as? [String: Any]
        )

        XCTAssertEqual(grantObject["moduleSHA256"] as? String, digest(moduleA))
        XCTAssertEqual(grantObject["signer"] as? String, "local-test")
        await assertProviderError(.deniedGrant) {
            try await hostB.invoke(
                declaration: declarationB,
                detachedCMS: Data("detached-cms".utf8),
                module: moduleB,
                grant: grantA,
                operation: .status
            )
        }

        let signerBDeclaration = try canonicalJSON(
            NetworkProviderDeclaration(
                identifier: "example.reference",
                kind: .tunnelProvider,
                moduleSHA256: digest(moduleA),
                signer: "other-signer"
            )
        )
        let signerBHost = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: signerBDeclaration,
                expectedSigner: "other-signer"
            ),
            executor: Executor { _, _ in
                executions.increment()
                return Data()
            },
            revocations: Revocations()
        )
        await assertProviderError(.deniedGrant) {
            try await signerBHost.invoke(
                declaration: signerBDeclaration,
                detachedCMS: Data("detached-cms".utf8),
                module: moduleA,
                grant: grantA,
                operation: .status
            )
        }
        XCTAssertEqual(executions.value, 0)
    }

    func testRevokedGrantStopsBeforeExecution() async throws {
        let module = Data("reference-wasm".utf8)
        let declaration = try declaration(for: module)
        let executions = Counter()
        let host = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declaration,
                expectedSigner: "local-test"
            ),
            executor: Executor { _, _ in
                executions.increment()
                return Data()
            },
            revocations: Revocations(revoked: true)
        )

        await assertProviderError(.revoked) {
            try await host.invoke(
                declaration: declaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }
        XCTAssertEqual(executions.value, 0)
    }

    func testReplayAndProtocolMismatchFailClosed() async throws {
        let module = Data("reference-wasm".utf8)
        let declaration = try declaration(for: module)
        let replayExecutor = ReplayExecutor()
        let replayHost = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declaration,
                expectedSigner: "local-test"
            ),
            executor: replayExecutor,
            revocations: Revocations()
        )
        _ = try await replayHost.invoke(
            declaration: declaration,
            detachedCMS: Data("detached-cms".utf8),
            module: module,
            grant: grant(),
            operation: .status
        )
        await assertProviderError(.replayDetected) {
            try await replayHost.invoke(
                declaration: declaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }

        let mismatchHost = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declaration,
                expectedSigner: "local-test"
            ),
            executor: Executor { input, _ in
                let request = try JSONDecoder().decode(TestRequest.self, from: input)
                return try canonicalJSON(
                    TestResponse(
                        version: 2,
                        nonce: request.nonce,
                        operation: request.operation,
                        status: "ok",
                        payload: [:]
                    )
                )
            },
            revocations: Revocations()
        )
        await assertProviderError(.invalidProtocol) {
            try await mismatchHost.invoke(
                declaration: declaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }
    }

    func testMaliciousPathsAndExcessiveBrokerRequestsAreDeniedBeforeBrokerUse() async throws {
        let module = Data("reference-wasm".utf8)
        let declaration = try declaration(for: module)
        let broker = RecordingBroker()

        for request in [
            TestBrokerRequest(
                kind: .https,
                scope: "https://127.0.0.1:9443/admin",
                request: Data()
            ),
            TestBrokerRequest(
                kind: .route,
                scope: "route:../admin",
                request: Data()
            )
        ] {
            let host = host(
                declaration: declaration,
                broker: broker,
                responseRequests: [request]
            )
            await assertProviderError(.deniedGrant) {
                try await host.invoke(
                    declaration: declaration,
                    detachedCMS: Data("detached-cms".utf8),
                    module: module,
                    grant: self.grant(),
                    operation: .status
                )
            }
        }

        let excessive = (0...RestrictedNetworkProviderHost.maximumBrokerRequests)
            .map { index in
                TestBrokerRequest(
                    kind: .https,
                    scope: "https://127.0.0.1:9443",
                    request: Data("\(index)".utf8)
                )
            }
        let excessiveHost = host(
            declaration: declaration,
            broker: broker,
            responseRequests: excessive
        )
        await assertProviderError(.deniedGrant) {
            try await excessiveHost.invoke(
                declaration: declaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }
        let brokerCalls = await broker.recordedCalls
        XCTAssertEqual(brokerCalls, [])
    }

    func testOutputOverflowAndNoncanonicalResponseAreRejected() async throws {
        let module = Data("reference-wasm".utf8)
        let declaration = try declaration(for: module)
        let overflowHost = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declaration,
                expectedSigner: "local-test"
            ),
            executor: Executor { _, _ in
                Data(
                    repeating: 0,
                    count: NetworkProviderSandbox.maximumOutputBytes + 1
                )
            },
            revocations: Revocations()
        )
        await assertProviderError(.outputLimitExceeded) {
            try await overflowHost.invoke(
                declaration: declaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }

        let noncanonicalHost = RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declaration,
                expectedSigner: "local-test"
            ),
            executor: Executor { input, _ in
                let request = try JSONDecoder().decode(TestRequest.self, from: input)
                let canonical = try canonicalJSON(TestResponse.success(for: request))
                var noncanonical = Data([0x20])
                noncanonical.append(canonical)
                return noncanonical
            },
            revocations: Revocations()
        )
        await assertProviderError(.invalidProtocol) {
            try await noncanonicalHost.invoke(
                declaration: declaration,
                detachedCMS: Data("detached-cms".utf8),
                module: module,
                grant: self.grant(),
                operation: .status
            )
        }
    }

    func testRevocationPersistsBeforeStoppingAuthority() async throws {
        let store = Revocations()
        let host = RestrictedNetworkProviderHost(
            verifier: RejectingVerifier(),
            executor: Executor { _, _ in Data() },
            revocations: store
        )
        let stopped = Flag()

        try await host.revokeThenStop(
            identifier: "example.reference",
            moduleSHA256: String(repeating: "a", count: 64)
        ) {
            let persisted = await store.wasRevoked
            XCTAssertTrue(persisted)
            await stopped.set()
        }

        let didStop = await stopped.value
        XCTAssertTrue(didStop)
    }

    private func host(
        declaration: Data,
        broker: RecordingBroker,
        responseRequests: [TestBrokerRequest]
    ) -> RestrictedNetworkProviderHost {
        RestrictedNetworkProviderHost(
            verifier: Verifier(
                expectedContent: declaration,
                expectedSigner: "local-test"
            ),
            executor: Executor { input, _ in
                let request = try JSONDecoder().decode(TestRequest.self, from: input)
                return try canonicalJSON(
                    TestResponse(
                        version: 1,
                        nonce: request.nonce,
                        operation: request.operation,
                        status: "ok",
                        payload: [:],
                        brokerRequests: responseRequests
                    )
                )
            },
            revocations: Revocations(),
            broker: broker
        )
    }

    private func declaration(for module: Data) throws -> Data {
        try canonicalJSON(
            NetworkProviderDeclaration(
                identifier: "example.reference",
                kind: .tunnelProvider,
                moduleSHA256: digest(module),
                signer: "local-test"
            )
        )
    }

    private func grant(
        identifier: String = "example.reference",
        moduleSHA256: String = digest(Data("reference-wasm".utf8)),
        signer: String = "local-test",
        expiresAt: Date = .distantFuture
    ) -> NetworkProviderGrant {
        NetworkProviderGrant(
            identifier: identifier,
            kind: .tunnelProvider,
            moduleSHA256: moduleSHA256,
            signer: signer,
            allowedHTTPSOrigins: ["https://127.0.0.1:9443"],
            secretReferences: ["secret:relay-token"],
            identityScopes: ["identity:project-a"],
            routeScopes: ["route:project-a"],
            approvedBy: "reviewer",
            expiresAt: expiresAt
        )
    }
}

private struct TestRequest: Codable, Sendable {
    let version: Int
    let nonce: String
    let operation: NetworkProviderOperation
    let payload: [String: String]
}

private struct TestResponse: Codable, Sendable {
    let version: Int
    let nonce: String
    let operation: NetworkProviderOperation
    let status: String
    let payload: [String: String]
    let brokerRequests: [TestBrokerRequest]?
    let httpsOrigin: String?
    let secretReference: String?
    let identityScope: String?
    let routeScope: String?

    init(
        version: Int,
        nonce: String,
        operation: NetworkProviderOperation,
        status: String,
        payload: [String: String],
        brokerRequests: [TestBrokerRequest]? = nil,
        httpsOrigin: String? = nil,
        secretReference: String? = nil,
        identityScope: String? = nil,
        routeScope: String? = nil
    ) {
        self.version = version
        self.nonce = nonce
        self.operation = operation
        self.status = status
        self.payload = payload
        self.brokerRequests = brokerRequests
        self.httpsOrigin = httpsOrigin
        self.secretReference = secretReference
        self.identityScope = identityScope
        self.routeScope = routeScope
    }

    static func success(for request: TestRequest) -> TestResponse {
        TestResponse(
            version: 1,
            nonce: request.nonce,
            operation: request.operation,
            status: "ok",
            payload: ["result": "ok"]
        )
    }
}

private struct TestBrokerRequest: Codable, Sendable {
    let kind: NetworkProviderBrokerRequestKind
    let scope: String
    let request: Data
}

private struct Verifier: DetachedCMSVerifier {
    let expectedContent: Data
    let expectedSigner: String

    func verifyDetachedCMS(
        signature: Data,
        content: Data,
        trustedSigner: String
    ) throws {
        guard signature == Data("detached-cms".utf8),
              content == expectedContent,
              trustedSigner == expectedSigner
        else {
            throw TestFailure.rejected
        }
    }
}

private struct RejectingVerifier: DetachedCMSVerifier {
    func verifyDetachedCMS(
        signature: Data,
        content: Data,
        trustedSigner: String
    ) throws {
        throw TestFailure.rejected
    }
}

private actor Revocations: NetworkProviderRevocationStore {
    private var revoked: Bool

    init(revoked: Bool = false) {
        self.revoked = revoked
    }

    var wasRevoked: Bool {
        revoked
    }

    func isRevoked(
        identifier: String,
        moduleSHA256: String,
        scope: String?
    ) async throws -> Bool {
        revoked
    }

    func revoke(
        identifier: String,
        moduleSHA256: String,
        scope: String?,
        at: Date
    ) async throws {
        revoked = true
    }
}

private actor Flag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock {
            count
        }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private struct Executor: NetworkProviderWasmExecutor {
    let work: @Sendable (Data, NetworkProviderSandbox) throws -> Data

    init(
        _ work: @escaping @Sendable (Data, NetworkProviderSandbox) throws -> Data
    ) {
        self.work = work
    }

    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        try work(stdin, sandbox)
    }
}

private actor ReplayExecutor: NetworkProviderWasmExecutor {
    private var firstResponse: Data?

    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        if let firstResponse {
            return firstResponse
        }
        let request = try JSONDecoder().decode(TestRequest.self, from: stdin)
        let response = try canonicalJSON(TestResponse.success(for: request))
        firstResponse = response
        return response
    }
}

private actor RecordingBroker: NetworkProviderBroker {
    private(set) var recordedCalls: [String] = []
    private(set) var returnedSecretValues: [String] = []

    func https(origin: String, request: Data) async throws -> Data {
        recordedCalls.append(
            "https:\(origin):\(String(decoding: request, as: UTF8.self))"
        )
        return Data("local-https-response".utf8)
    }

    func secretReference(
        _ reference: String
    ) async throws -> NetworkProviderSecretHandle {
        recordedCalls.append("secret:\(reference)")
        return NetworkProviderSecretHandle(identifier: "opaque-handle")
    }

    func identity(scope: String, request: Data) async throws -> Data {
        recordedCalls.append(
            "identity:\(scope):\(String(decoding: request, as: UTF8.self))"
        )
        return Data("public-identity".utf8)
    }

    func route(scope: String, request: Data) async throws -> Data {
        recordedCalls.append(
            "route:\(scope):\(String(decoding: request, as: UTF8.self))"
        )
        return Data("route-applied".utf8)
    }
}

private enum TestFailure: Error {
    case rejected
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func assertProviderError(
    _ expected: NetworkProviderError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Any
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as NetworkProviderError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}
