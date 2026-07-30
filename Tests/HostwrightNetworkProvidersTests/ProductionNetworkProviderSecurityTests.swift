import CryptoKit
import Foundation
import XCTest
@testable import HostwrightNetworkProviders

final class ProductionNetworkProviderSecurityTests: XCTestCase {
    func testSecurityVerifierAcceptsOnePinnedDetachedCMSSigner() throws {
        let fixture = try DetachedCMSFixture()
        let fingerprint = "sha256:" + SHA256.hash(data: fixture.certificateDER)
            .map { String(format: "%02x", $0) }
            .joined()
        let verifier = SecurityDetachedCMSVerifier(
            trustedCertificateDER: [fixture.certificateDER]
        )

        XCTAssertNoThrow(
            try verifier.verifyDetachedCMS(
                signature: fixture.signature,
                content: fixture.content,
                trustedSigner: fingerprint
            )
        )
        XCTAssertThrowsError(
            try verifier.verifyDetachedCMS(
                signature: fixture.signature,
                content: Data("tampered".utf8),
                trustedSigner: fingerprint
            )
        )
        XCTAssertThrowsError(
            try verifier.verifyDetachedCMS(
                signature: fixture.signature,
                content: fixture.content,
                trustedSigner: "sha256:" + String(repeating: "0", count: 64)
            )
        )
    }

    func testSignedConformanceModuleUsesOnlyReviewedLocalHTTPSOrigin() async throws {
        let reviewedOrigin = "https://127.0.0.1:9443"
        let noncePlaceholder = "00000000-0000-0000-0000-000000000000"
        let responseTemplate = try canonicalSecurityJSON(
            IntegratedProviderResponse(
                version: 1,
                nonce: noncePlaceholder,
                operation: .setup,
                status: "ok",
                payload: ["result": "local-https-ok"],
                brokerRequests: [
                    NetworkProviderBrokerRequest(
                        kind: .https,
                        scope: reviewedOrigin,
                        request: Data("probe".utf8)
                    )
                ]
            )
        )
        let module = try providerConformanceModule(
            responseTemplate: responseTemplate,
            noncePlaceholder: noncePlaceholder
        )
        let fixture = try DetachedCMSFixture(contentBuilder: { certificateDER in
            let fingerprint = "sha256:"
                + SHA256.hash(data: certificateDER)
                    .map { String(format: "%02x", $0) }
                    .joined()
            return try canonicalSecurityJSON(
                NetworkProviderDeclaration(
                    identifier: "example.reference",
                    kind: .tunnelProvider,
                    moduleSHA256: SHA256.hash(data: module)
                        .map { String(format: "%02x", $0) }
                        .joined(),
                    signer: fingerprint
                )
            )
        })
        let fingerprint = "sha256:"
            + SHA256.hash(data: fixture.certificateDER)
                .map { String(format: "%02x", $0) }
                .joined()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalHTTPSReferenceProtocol.self]
        let broker = URLSessionNetworkProviderBroker(
            configuration: configuration,
            secretReferenceResolver: { _ in
                throw NetworkProviderError.deniedGrant
            },
            identityHandler: { _, _ in
                throw NetworkProviderError.deniedGrant
            },
            routeHandler: { _, _ in
                throw NetworkProviderError.deniedGrant
            }
        )
        let revocationRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: revocationRoot)
        }
        let host = RestrictedNetworkProviderHost(
            verifier: SecurityDetachedCMSVerifier(
                trustedCertificateDER: [fixture.certificateDER]
            ),
            executor: try WasmKitNetworkProviderExecutor(
                workerExecutableURL: workerExecutable()
            ),
            revocations: try FileBackedNetworkProviderRevocationStore(
                directoryURL: revocationRoot
            ),
            broker: broker
        )
        LocalHTTPSReferenceProtocol.resetHandledRequestCount()
        let reviewedGrant = NetworkProviderGrant(
            identifier: "example.reference",
            kind: .tunnelProvider,
            allowedHTTPSOrigins: [reviewedOrigin],
            approvedBy: "reviewer",
            expiresAt: .distantFuture
        )

        let result = try await host.invoke(
            declaration: fixture.content,
            detachedCMS: fixture.signature,
            module: module,
            grant: reviewedGrant,
            operation: .setup
        )

        XCTAssertEqual(result, ["result": "local-https-ok"])
        XCTAssertEqual(LocalHTTPSReferenceProtocol.handledRequestCount, 1)
        let outOfGrant = NetworkProviderGrant(
            identifier: "example.reference",
            kind: .tunnelProvider,
            allowedHTTPSOrigins: ["https://127.0.0.1:9444"],
            approvedBy: "reviewer",
            expiresAt: .distantFuture
        )
        do {
            _ = try await host.invoke(
                declaration: fixture.content,
                detachedCMS: fixture.signature,
                module: module,
                grant: outOfGrant,
                operation: .setup
            )
            XCTFail("Expected an out-of-grant origin to be denied")
        } catch let error as NetworkProviderError {
            XCTAssertEqual(error, .deniedGrant)
        }
        XCTAssertEqual(LocalHTTPSReferenceProtocol.handledRequestCount, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(
                NetworkProviderDeclaration.self,
                from: fixture.content
            ).signer,
            fingerprint
        )
    }

    func testFileBackedRevocationPersistsAtomicallyAcrossInstances() async throws {
        let root = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let digest = String(repeating: "a", count: 64)
        let first = try FileBackedNetworkProviderRevocationStore(
            directoryURL: root
        )

        try await first.revoke(
            identifier: "example.reference",
            moduleSHA256: digest,
            at: Date(timeIntervalSince1970: 1_000)
        )

        let second = try FileBackedNetworkProviderRevocationStore(
            directoryURL: root
        )
        let persisted = try await second.isRevoked(
            identifier: "example.reference",
            moduleSHA256: digest
        )
        XCTAssertTrue(persisted)
        let stateURL = root.appendingPathComponent(
            "network-provider-revocations.json"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: stateURL.path
        )
        XCTAssertEqual(
            attributes[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasSuffix(".tmp") }
        )
    }

    func testConcreteRevocationIsDurableBeforeAuthorityStops() async throws {
        let root = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let digest = String(repeating: "b", count: 64)
        let store = try FileBackedNetworkProviderRevocationStore(
            directoryURL: root
        )
        let host = RestrictedNetworkProviderHost(
            verifier: AlwaysRejectVerifier(),
            executor: NeverExecutor(),
            revocations: store
        )
        let stopped = StopFlag()

        try await host.revokeThenStop(
            identifier: "example.reference",
            moduleSHA256: digest
        ) {
            let reopened = try FileBackedNetworkProviderRevocationStore(
                directoryURL: root
            )
            guard try await reopened.isRevoked(
                identifier: "example.reference",
                moduleSHA256: digest
            ) else {
                throw TestSecurityError.notDurable
            }
            await stopped.set()
        }

        let didStop = await stopped.value
        XCTAssertTrue(didStop)
    }

    func testFileBackedRevocationRejectsSymlinkAndCorruptState() throws {
        let parent = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        let target = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        XCTAssertThrowsError(
            try FileBackedNetworkProviderRevocationStore(directoryURL: link)
        )

        let corrupt = parent.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(
            at: corrupt,
            withIntermediateDirectories: false
        )
        try Data("not-json".utf8).write(
            to: corrupt.appendingPathComponent(
                "network-provider-revocations.json"
            )
        )
        XCTAssertThrowsError(
            try FileBackedNetworkProviderRevocationStore(directoryURL: corrupt)
        )
    }

    func testURLSessionBrokerCallsOnlyExactLocalHTTPSOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalHTTPSReferenceProtocol.self]
        let broker = URLSessionNetworkProviderBroker(
            configuration: configuration,
            secretReferenceResolver: { reference in
                guard reference == "secret:relay-token" else {
                    throw NetworkProviderError.deniedGrant
                }
                return NetworkProviderSecretHandle(identifier: "opaque-handle")
            },
            identityHandler: { scope, request in
                Data("\(scope):\(request.count)".utf8)
            },
            routeHandler: { scope, request in
                Data("\(scope):\(request.count)".utf8)
            }
        )

        let response = try await broker.https(
            origin: "https://127.0.0.1:9443",
            request: Data("probe".utf8)
        )
        XCTAssertEqual(response, Data("local-https-ok".utf8))
        let handle = try await broker.secretReference("secret:relay-token")
        XCTAssertEqual(handle.identifier, "opaque-handle")
        do {
            _ = try await broker.https(
                origin: "https://127.0.0.1:9443/admin",
                request: Data()
            )
            XCTFail("Expected a non-origin path to be denied")
        } catch let error as NetworkProviderError {
            XCTAssertEqual(error, .deniedGrant)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-revocation-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func workerExecutable() throws -> URL {
        let candidate = Bundle(for: ProductionNetworkProviderSecurityTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                WasmKitNetworkProviderExecutor.workerExecutableName
            )
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("Worker executable was not built at \(candidate.path)")
        }
        return candidate
    }
}

private struct IntegratedProviderResponse: Encodable {
    let version: Int
    let nonce: String
    let operation: NetworkProviderOperation
    let status: String
    let payload: [String: String]
    let brokerRequests: [NetworkProviderBrokerRequest]
    let httpsOrigin: String? = nil
    let secretReference: String? = nil
    let identityScope: String? = nil
    let routeScope: String? = nil
}

private struct DetachedCMSFixture {
    let content: Data
    let certificateDER: Data
    let signature: Data

    init() throws {
        try self.init { _ in
            Data(
                #"{"apiVersion":1,"identifier":"example.reference"}"#.utf8
            )
        }
    }

    init(contentBuilder: (Data) throws -> Data) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-cms-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let contentURL = root.appendingPathComponent("content.json")
        let keyURL = root.appendingPathComponent("key.pem")
        let certificateURL = root.appendingPathComponent("certificate.pem")
        let certificateDERURL = root.appendingPathComponent("certificate.der")
        let signatureURL = root.appendingPathComponent("signature.der")

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
                "/CN=Hostwright Provider Test",
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
        let certificateDER = try Data(contentsOf: certificateDERURL)
        let content = try contentBuilder(certificateDER)
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
        self.content = content
        self.certificateDER = certificateDER
        self.signature = try Data(contentsOf: signatureURL)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0
        else {
            throw TestSecurityError.opensslFailed
        }
    }
}

private struct AlwaysRejectVerifier: DetachedCMSVerifier {
    func verifyDetachedCMS(
        signature: Data,
        content: Data,
        trustedSigner: String
    ) throws {
        throw TestSecurityError.notDurable
    }
}

private struct NeverExecutor: NetworkProviderWasmExecutor {
    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        throw TestSecurityError.notDurable
    }
}

private actor StopFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private enum TestSecurityError: Error {
    case notDurable
    case opensslFailed
}

private final class LocalHTTPSReferenceProtocol: URLProtocol {
    private static let handledRequests = LockedRequestCount()

    static var handledRequestCount: Int {
        handledRequests.value
    }

    static func resetHandledRequestCount() {
        handledRequests.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString == "https://127.0.0.1:9443"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.httpMethod == "POST",
              Self.body(for: request) == Data("probe".utf8),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/octet-stream"]
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: TestSecurityError.notDurable
            )
            return
        }
        Self.handledRequests.increment()
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data("local-https-ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
    }

    private static func body(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer {
            stream.close()
        }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }
            guard count > 0 else {
                return body
            }
            body.append(buffer, count: count)
        }
    }
}

private final class LockedRequestCount: @unchecked Sendable {
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

    func reset() {
        lock.withLock {
            count = 0
        }
    }
}

private func canonicalSecurityJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
