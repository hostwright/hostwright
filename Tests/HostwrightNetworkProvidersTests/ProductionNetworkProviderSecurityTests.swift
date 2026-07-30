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
}

private struct DetachedCMSFixture {
    let content = Data(
        #"{"apiVersion":1,"identifier":"example.reference"}"#.utf8
    )
    let certificateDER: Data
    let signature: Data

    init() throws {
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
        try content.write(to: contentURL)

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
        signature = try Data(contentsOf: signatureURL)
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
